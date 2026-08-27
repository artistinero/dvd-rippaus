#!/usr/bin/env bash
# dvdq/lib/dispatch.sh — dispatcher + worker + kaatumistoipuminen (§8, §4).
# Worker pitää slot-lukkoa ITSE (fd auki koko elinajan) ja commitoi oman jobinsa.
# Enkooderi ajetaan omassa sessiossaan (setsid → oma pgid) lämpövahtia (vaihe 5) ja
# toipumisen kill-reapia varten. Testattavissa STUB-enkooderilla (DVDQ_STUB_ENCODER).
# EI set -e (§8.1). Sourcaa common.sh + jobs.sh + commands.sh ensin.
set -uo pipefail

# --- prosessin käynnistysaika (/proc/<pid>/stat kenttä 22) — (pid,starttime)-pari (§4) -------
proc_starttime() {
  local pid=$1 st
  st=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null) || return 1
  [ -n "$st" ] && printf '%s' "$st" || return 1
}
proc_alive_same() {  # proc_alive_same <pid> <starttime> → 0 jos sama prosessi yhä elossa
  local pid=$1 want=$2 now
  [ -n "$pid" ] && [ "$pid" != null ] || return 1
  now=$(proc_starttime "$pid") || return 1
  [ "$now" = "$want" ]
}

# --- slotit (§8.1) — slot-lukko on toipumisen totuus (§4) -------------------------------------
_slot_lock() { printf '%s/slot-%s.lock' "$(slots_dir)" "$1"; }
slot_held() {   # slot_held <N> → 0 jos jokin worker pitää lukkoa (emme saa sitä)
  local lf; lf=$(_slot_lock "$1")
  [ -e "$lf" ] || { : ; }   # olemassaolo ei riitä; ratkaisee flock
  if flock -n "$lf" -c true 2>/dev/null; then return 1; else return 0; fi
}
count_running() {  # pidettyjen slottien määrä (1..PARALLEL_MAX)
  local i n=0
  for i in $(seq 1 "${CFG[PARALLEL_MAX]}"); do slot_held "$i" && n=$((n+1)); done
  printf '%s' "$n"
}
free_slot() {  # ensimmäinen vapaa slot-indeksi, tai tyhjä
  local i
  for i in $(seq 1 "${CFG[PARALLEL_MAX]}"); do slot_held "$i" || { printf '%s' "$i"; return 0; }; done
  return 1
}

# --- levytila & lämpö (§8.1 may_open_slot) ----------------------------------------------------
_free_bytes() { df --output=avail -B1 "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
_thermal_ok() {
  # Heartbeat puuttuu = lämpövahtia ei ole otettu käyttöön (dev/test) → salli.
  # Heartbeat olemassa mutta vanhentunut = vahti kuollut → fail-closed (§8.2).
  local hb="$STATE/thermal.heartbeat" age now ts
  [ -f "$hb" ] || return 0
  ts=$(cat "$hb" 2>/dev/null); is_uint "$ts" || return 0
  now=$(date +%s); age=$((now - ts))
  [ "$age" -le $(( ${CFG[LOOP_INTERVAL]} * 3 )) ]
}
may_open_slot() {   # §8.1: kaikki neljä ehtoa yhtenä predikaattina
  [ -f "$STATE/paused" ] && return 1                                   # (4) pause
  [ "$(count_running)" -lt "${CFG[PARALLEL]}" ] || return 1            # (1) pidetyt < PARALLEL
  num_ge "$(_free_bytes "${CFG[WORK_DIR]}")"  "$(gb_to_bytes "${CFG[RIP_MIN_FREE_GB]}")"  || return 1
  num_ge "$(_free_bytes "${CFG[DEST_ROOT]}")" "$(gb_to_bytes "${CFG[DEST_MIN_FREE_GB]}")" || return 1  # (2) tila
  _thermal_ok || return 1                                             # (3) lämpö
  return 0
}

# --- enkooderi (stub-injektoitava; oikea HandBrake vaiheessa 7) --------------------------------
DEST_TMP() { printf '%s/.tmp' "${CFG[DEST_ROOT]}"; }
# encoder_start <slotfd> <id> <source> <title> <out_tmp> → tulostaa enkooderin pgid:n (setsid-leader).
# <slotfd> suljetaan enkooderilta ({fd}>&-) ettei se peri slot-lukkoa (muuten "slot held" valehtelisi
# workerin kuoltua). Enkooderi omassa sessiossaan (setsid → oma pgid) lämpövahtia/reapia varten.
encoder_start() {
  local sfd=$1; shift
  mkdir -p "$(DEST_TMP)"
  if [ -n "${DVDQ_STUB_ENCODER:-}" ]; then
    setsid "$DVDQ_STUB_ENCODER" "$@" >/dev/null 2>&1 {sfd}>&- & printf '%s' "$!"
  else
    setsid false >/dev/null 2>&1 {sfd}>&- & printf '%s' "$!"   # oikea HandBrake vaiheessa 7
  fi
}
verify_output() {  # <tmp> <id> → 0 ok. §8.4 rakenteellinen verifiointi (verify.sh).
  if [ -n "${DVDQ_STUB_VERIFY:-}" ]; then "$DVDQ_STUB_VERIFY" "$@"; return $?; fi
  command -v verify_structural >/dev/null 2>&1 || { [ -s "$1" ]; return $?; }   # verify.sh ei sourcattu
  local tmp=$1 id=$2 exp mina
  exp=$(job_field "$id" .duration_s)
  mina=$(job_read "$id" | jq -r '(.want_audio // []) | length')
  verify_structural "$tmp" "${exp:-}" "${mina:-0}"
}

# --- worker (§4) ------------------------------------------------------------------------------
# worker_run <id> <slot> — job on JO varattu encoding-tilaan dispatcherissa (reserve_job).
# Worker pitää slot-lukkoa fd:n kautta koko elinajan; enkooderi ei peri sitä ({WFD}>&-).
worker_run() {
  local id=$1 slot=$2
  local lf; lf=$(_slot_lock "$slot")
  exec {WFD}>>"$lf" || { _release_reservation "$id"; exit 0; }
  if ! flock -n "$WFD"; then _release_reservation "$id"; exit 0; fi   # ristikäytäntö-race: vapauta varaus
  local src title tmp epid starttime
  src=$(job_field "$id" .source); title=$(job_field "$id" .title); tmp="$(DEST_TMP)/$id.mkv"
  epid=$(encoder_start "$WFD" "$id" "$src" "$title" "$tmp")
  starttime=$(proc_starttime "$BASHPID")
  job_apply "$id" \
    '.pid=$pid|.pgid=$pgid|.starttime=$stt|.started=(now|todate)' \
    --argjson pid "$BASHPID" --argjson pgid "$epid" --arg stt "$starttime" >/dev/null 2>&1
  wait "$epid"; local erc=$?
  _worker_commit "$id" "$tmp" "$erc"
  exit 0
}
_release_reservation() {  # varaus (encoding, ei workeria) → takaisin pendingiksi
  job_apply "$1" '.status="pending"|.slot=null|.pid=null|.pgid=null|.starttime=null|.started=null' >/dev/null 2>&1
}

# _backup_existing_dest <dest> — jos kohde on jo olemassa, siirrä vanha versio BACKUP_DIR:iin
# (kirjaston ULKOPUOLELLA, §10) aikaleimatulla nimellä. Audit-rivi ENNEN siirtoa (§15 B2). Rc≠0 jos
# backup epäonnistuu → kutsuja EI ylikirjoita (datahävikin esto). Ei kohdetta → rc 0 (ei tehtävää).
_backup_existing_dest() {
  local dest=$1 bdir="${CFG[BACKUP_DIR]}" base ts bak
  [ -e "$dest" ] || return 0
  mkdir -p "$bdir" 2>/dev/null || return 1
  base=$(basename "$dest"); ts=$(date +%Y%m%d-%H%M%S); bak="$bdir/$base.$ts"
  audit_append library_replace "$dest" "$(stat -c%s "$dest" 2>/dev/null)" "worker-commit"
  mv -f "$dest" "$bak" && sync_dir "$bdir"
}

_worker_commit() {  # <id> <tmp> <erc>  — commitoi tulos (§2.5 rc-käsittely, §4 thermal/skip)
  local id=$1 tmp=$2 erc=$3
  local skip tk; skip=$(job_field "$id" .skip_requested); tk=$(job_field "$id" .thermal_kill)
  if [ "$erc" = 0 ]; then
    if [ "$skip" = true ]; then rm -f "$tmp"; job_apply "$id" '.status="user_skip"|.finished=(now|todate)|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1; return; fi
    if verify_output "$tmp" "$id"; then
      local dest_dir out_name dest
      dest_dir=$(job_field "$id" .dest_dir); out_name=$(job_field "$id" .out_name)
      dest="$dest_dir/$out_name"; mkdir -p "$dest_dir"
      # §8.6: varmuuskopioi mahdollinen vanha versio (audit ENNEN) — jos backup epäonnistuu, EI
      # ylikirjoiteta (datahävikin esto). §2.1/§2.5: sama fs, sync -d tiedosto, mv, sync hakemisto.
      if _backup_existing_dest "$dest" && sync_file "$tmp" && mv -f "$tmp" "$dest" && sync_dir "$dest_dir"; then
        job_apply "$id" '.status="done"|.finished=(now|todate)|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
      else
        job_apply "$id" '.status="failed"|.fail_reason="mv/sync/backup"|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
      fi
    else
      rm -f "$tmp"; job_apply "$id" '.status="failed"|.fail_reason="verify"|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
    fi
  else
    rm -f "$tmp"
    if [ "$tk" = true ]; then
      job_apply "$id" '.status="pending"|.thermal_kill=false|.slot=null|.pid=null|.pgid=null|.started=null' >/dev/null 2>&1   # lämpötappo → pending, ei failed (§8.2)
    elif [ "$skip" = true ]; then
      job_apply "$id" '.status="user_skip"|.finished=(now|todate)|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
    else
      job_apply "$id" '.status="failed"|.fail_reason=$r|.slot=null|.pid=null|.pgid=null' --arg r "rc=$erc" >/dev/null 2>&1
    fi
  fi
}

# --- toipuminen (§4: neljä tapausta, slot-lukko totuutena) -------------------------------------
recover() {
  local p id slot pgid pid stt
  for p in "$STATE/jobs"/*.json; do
    [ -e "$p" ] || continue
    [ "$(jq -r '.status' "$p")" = encoding ] || continue
    id=$(jq -r '.id' "$p"); slot=$(jq -r '.slot // empty' "$p")
    if [ -n "$slot" ] && slot_held "$slot"; then
      continue   # A: slot-lukko varattu → worker elää → älä koske
    fi
    # B/C/D: slot vapaa → worker kuollut. Reap mahdollinen orpo-enkooderi pgid:n kautta, poista temp.
    pgid=$(jq -r '.pgid // empty' "$p")
    [ -n "$pgid" ] && [ "$pgid" != null ] && kill -TERM -"$pgid" 2>/dev/null
    rm -f "$(DEST_TMP)/$id.mkv"
    job_apply "$id" '.status="pending"|.slot=null|.pid=null|.pgid=null|.starttime=null|.started=null' >/dev/null 2>&1
  done
}

# --- dispatch-pass & daemon -------------------------------------------------------------------
_next_pending_id() {  # pienin seq pending ensin (§8.1 sivuhuomio)
  local p; for p in "$STATE/jobs"/*.json; do [ -e "$p" ] || continue;
    jq -r 'select(.status=="pending")|"\(.seq) \(.id)"' "$p" 2>/dev/null; done | sort -n | head -1 | awk '{print $2}'
}
write_status() { cmd_status > "$STATE/status.json.t" 2>/dev/null && mv -f "$STATE/status.json.t" "$STATE/status.json"; }

# reserve_job <id> <slot> — atominen pending→encoding varaus (§2.6). Estää saman jobin
# kaksoiskäytön: kun tila on encoding, _next_pending_id ei enää palauta sitä.
reserve_job() {
  local id=$1 slot=$2
  job_apply "$id" \
    'if .status=="pending" then .status="encoding"|.slot=$slot else error("not_pending") end' \
    --argjson slot "$slot" >/dev/null 2>&1
}
_free_slot_excl() {  # ensimmäinen slot joka ei ole held EIKÄ used[] (this-pass) → tyhjä jos ei
  local -n _used=$1; local i
  for i in $(seq 1 "${CFG[PARALLEL_MAX]}"); do
    [ -n "${_used[$i]:-}" ] && continue
    slot_held "$i" && continue
    printf '%s' "$i"; return 0
  done
  return 1
}
dispatch_pass() {   # yksi täyttökierros: varaa jobeja + käynnistä workereita
  local -A used=(); local base assigned=0 id slot guard=0
  base=$(count_running)               # cross-pass käynnissä olevat (slot-lukot)
  while :; do
    guard=$((guard+1)); [ "$guard" -gt $(( ${CFG[PARALLEL_MAX]} * 4 + 4 )) ] && break  # turvakatto (ei fork-bombia)
    [ $(( base + assigned )) -lt "${CFG[PARALLEL]}" ] || break   # (1) < PARALLEL
    [ -f "$STATE/paused" ] && break                              # (4) pause
    _thermal_ok || break                                        # (3) lämpö
    num_ge "$(_free_bytes "${CFG[WORK_DIR]}")"  "$(gb_to_bytes "${CFG[RIP_MIN_FREE_GB]}")"  || break
    num_ge "$(_free_bytes "${CFG[DEST_ROOT]}")" "$(gb_to_bytes "${CFG[DEST_MIN_FREE_GB]}")" || break  # (2) tila
    id=$(_next_pending_id); [ -n "$id" ] || break
    slot=$(_free_slot_excl used) || break
    reserve_job "$id" "$slot" || continue        # ei enää pending (race) → seuraava
    used[$slot]=1; assigned=$((assigned+1))
    _launch_worker "$id" "$slot"
  done
  write_status
}
# _launch_worker <id> <slot> — käynnistä worker taustalle (stdio /dev/null: ei pidä kutsujan putkea).
# Erillinen funktio jotta testit voivat korvata sen (synkroninen/no-op) ilman taustaprosesseja.
_launch_worker() { ( worker_run "$1" "$2" ) >/dev/null 2>&1 & disown; }

cmd_dispatch() {
  local once=0; [ "${1-}" = --once ] && once=1
  # single-instance (§8.1)
  local pf="$STATE/dispatch.pid"
  exec {DFD}>>"$pf" || { err_out lock_timeout DISPATCH "$pf" "avattavissa"; return 1; }
  if ! flock -n "$DFD"; then err_out bad_state dispatch running "toinen dispatcher käynnissä jo"; return 1; fi
  recover
  if [ "$once" = 1 ]; then dispatch_pass; exec {DFD}>&-; return 0; fi
  trap 'exec {DFD}>&- 2>/dev/null; exit 0' TERM INT
  while true; do dispatch_pass; _ensure_backup_watchdog; sleep "${CFG[LOOP_INTERVAL]}"; done
}

# _ensure_backup_watchdog — §8.2 fail-safe (>6× vanhentuma): jos lämpövahdin heartbeat on ollut
# pysähdyksissä yli 6× pollausvälin (= erillinen vahti kuollut) JA heartbeat-tiedosto on olemassa
# (= vahti oli käytössä, ei pelkkä "ei koskaan otettu käyttöön"), dispatcher käynnistää MINIMAALISEN
# erillisen VARAVAHTIPROSESSIN — EI ota pollausta omaan silmukkaansa (§8.2 kohta 7). Fail-closed
# (uusia slotteja ei avata, may_open_slot) pysyy voimassa; varavahti hoitaa aktiivisen suojan
# käynnissä oleville. Vain tuotanto-daemonissa; brainbin-integraatiossa todennettava.
_ensure_backup_watchdog() {
  command -v thermal_heartbeat_age >/dev/null 2>&1 || return 0    # thermal.sh ei sourcattu (esim. testit)
  [ -f "$STATE/thermal.heartbeat" ] || return 0                   # vahtia ei otettu käyttöön → ei varaa
  [ "$(thermal_heartbeat_age)" -gt $(( ${CFG[LOOP_INTERVAL]} * 6 )) ] || return 0
  [ -n "${DVDQ_HOME:-}" ] || return 0                            # binäärin polku (dvdq-entry asettaa)
  # Varavahti on erillinen prosessi (oma sessio), joka RE-SOURCAA kirjastot (dvdq-binääri) ja pitää
  # thermal-backup.lockia koko elinaikansa. flock -n takaa yksikäsitteisyyden: jos varavahti jo elää,
  # lukko on varattu → uutta ei käynnisty. Poistuu itse kun päävahdin heartbeat tuoreutuu.
  setsid flock -n "$STATE/thermal-backup.lock" "$DVDQ_HOME/dvdq" thermal --backup >/dev/null 2>&1 & disown
}
