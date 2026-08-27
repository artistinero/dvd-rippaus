#!/usr/bin/env bash
# dvdq/lib/thermal.sh — lämpövahti (§8.2). ERILLINEN riippumaton prosessi, EI dispatch-silmukassa
# (jottei blokkaava NAS-mv viivästytä lämmön pollausta). Keskeiset invariantit:
#   - HEARTBEAT kirjoitetaan LUKON ULKOPUOLELLA (elossaolosignaali, ei ohjaus) — muuten pää-/varavahti
#     lukkiutuisivat (v11:n regressio, §8.2). Vain STOP/CONT/kill-ohjaus tehdään thermal.lockin sisällä.
#   - TEMP_WARN → -STOP enkooderi-prosessiryhmille (palautuva), -CONT kun lämpö laskee.
#   - TEMP_KILL → thermal_kill=true (vain encoding-jobille) + kill → worker palauttaa pendingiksi (§4),
#     EI failed → lämpö ei koskaan valu karanteeniin.
# Sourcaa common.sh + jobs.sh ensin. Ei set -e (turvavahti ei saa kaatua yhteen glitchiin).
set -uo pipefail

# --- lämpötilan luku ---------------------------------------------------------------------------
# Palauttaa koneen korkeimman ydin-/pakettilämmön (desimaali). Testeissä ohitettavissa
# DVDQ_STUB_TEMP:llä (kiinteä arvo tai tiedoston polku, jonka ensimmäinen rivi on lämpötila).
thermal_read_temp() {
  if [ -n "${DVDQ_STUB_TEMP:-}" ]; then
    if [ -f "$DVDQ_STUB_TEMP" ]; then head -1 "$DVDQ_STUB_TEMP"; else printf '%s' "$DVDQ_STUB_TEMP"; fi
    return 0
  fi
  # sensors -j → poimi kaikki *_input-lämmöt, palauta suurin. Puuttuva anturi → 0 (ei ohjausta).
  sensors -j 2>/dev/null \
    | grep -oE '"temp[0-9]+_input": *[0-9.]+' | grep -oE '[0-9.]+$' \
    | sort -g | tail -1 | grep . || printf '0'
}

# --- heartbeat (LUKON ULKOPUOLELLA) ------------------------------------------------------------
_thermal_hb() { printf '%s/thermal.heartbeat' "$STATE"; }
thermal_write_heartbeat() {   # kirjoita nykyinen epoch-aika; atominen temp+mv
  local hb; hb=$(_thermal_hb)
  printf '%s' "$(date +%s)" > "$hb.t" && mv -f "$hb.t" "$hb"
}
thermal_heartbeat_age() {     # sekunteja viimeisestä heartbeatista; suuri luku jos puuttuu
  local hb ts now; hb=$(_thermal_hb)
  [ -f "$hb" ] || { printf '999999'; return; }
  ts=$(cat "$hb" 2>/dev/null); is_uint "$ts" || { printf '999999'; return; }
  now=$(date +%s); printf '%s' "$(( now - ts ))"
}

# --- enkooderi-prosessiryhmien signalointi -----------------------------------------------------
# Kohteena encoding-jobien pgid:t (§5.1). Signaali kohdistetaan koko PROSESSIRYHMÄLLE (-pgid),
# koska HandBrake haarauttaa aliprosesseja. Ohitettavissa testeissä (funktio korvataan).
thermal_pg_signal() { kill -"$1" -"$2" 2>/dev/null; }   # thermal_pg_signal <SIG> <pgid>
_thermal_encoding_pgids() {   # tulosta encoding-jobien pgid:t (yksi per rivi)
  local p pg
  for p in "$STATE/jobs"/*.json; do
    [ -e "$p" ] || continue
    [ "$(jq -r '.status' "$p")" = encoding ] || continue
    pg=$(jq -r '.pgid // empty' "$p")
    [ -n "$pg" ] && [ "$pg" != null ] && printf '%s\n' "$pg"
  done
}
thermal_signal_all() {   # lähetä signaali kaikille käynnissä oleville enkooderiryhmille
  local sig=$1 pg
  while read -r pg; do [ -n "$pg" ] && thermal_pg_signal "$sig" "$pg"; done < <(_thermal_encoding_pgids)
}

# --- ohjauspäätös (thermal.lockin SISÄLLÄ) -----------------------------------------------------
_thermal_stopped_flag() { printf '%s/thermal.stopped' "$STATE"; }

# thermal_control — yksi ohjauskierros: lue lämpö, päätä toimi. Ajetaan thermal.lockin sisällä
# (vain yksi vahti kerrallaan ohjaa pgid:tä, §8.2). EI kirjoita heartbeatia (se on lukon ulkopuolella).
thermal_control() {
  local temp; temp=$(thermal_read_temp)
  if num_ge "$temp" "${CFG[TEMP_KILL]}"; then
    thermal_apply_kill                                   # TEMP_KILL: pysyvä pysäytys → pending
  elif num_ge "$temp" "${CFG[TEMP_WARN]}"; then
    thermal_signal_all STOP; : > "$(_thermal_stopped_flag)"   # TEMP_WARN: palautuva jäädytys
  else
    if [ -f "$(_thermal_stopped_flag)" ]; then           # jäähtyi → jatka
      thermal_signal_all CONT; rm -f "$(_thermal_stopped_flag)"
    fi
  fi
}

# thermal_apply_kill — TEMP_KILL: merkitse jokainen encoding-job thermal_kill=true (vain jos yhä
# encoding, §2.6 no-op muuten) ENNEN killiä, sitten tapa ryhmät. Worker/reclaim lukee lipun ja
# palauttaa jobin pendingiksi (§4), ei failed.
thermal_apply_kill() {
  local p id
  for p in "$STATE/jobs"/*.json; do
    [ -e "$p" ] || continue
    [ "$(jq -r '.status' "$p")" = encoding ] || continue
    id=$(jq -r '.id' "$p")
    job_apply "$id" 'if .status=="encoding" then .thermal_kill=true else . end' >/dev/null 2>&1
  done
  thermal_signal_all TERM
  rm -f "$(_thermal_stopped_flag)"
}

# --- vahtisilmukka (pää- ja varavahti, §8.2) ---------------------------------------------------
# role=main: kirjoittaa heartbeatin (lukon ulkopuolella) joka kierros + ohjaa (lukon sisällä).
# role=backup: EI kirjoita heartbeatia; ohjaa; poistuu heti kun havaitsee heartbeatin tuoreutuvan
# (päävahti elpyi). Näin korkeintaan yksi vahti ohjaa pgid:tä ja fail-closed purkautuu (§8.2).
thermal_watchdog() {
  local role=${1:-main}
  local interval="${CFG[LOOP_INTERVAL]}"
  trap 'exit 0' TERM INT
  while true; do
    [ "$role" = main ] && thermal_write_heartbeat        # HEARTBEAT LUKON ULKOPUOLELLA
    if [ "$role" = backup ] && [ "$(thermal_heartbeat_age)" -le $(( interval * 3 )) ]; then
      break                                              # päävahti elpyi → varavahti väistyy
    fi
    with_lock "$(lock_dir)/thermal.lock" thermal_control  # OHJAUS lukon sisällä
    sleep "$interval"
  done
}
