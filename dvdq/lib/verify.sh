#!/usr/bin/env bash
# dvdq/lib/verify.sh — verifiointi (§8.4) ITSENÄISENÄ funktiona (§15 B4). Kolme kutsujaa jo nyt:
# worker-commit, cleanup-recheck, migraation done-päätös. Kaksi tasoa:
#   (a) RAKENTEELLINEN (kova, hylkää failed:iin): tiedosto ehjä + odotetut raidat + kesto toleranssissa.
#   (b) SISÄLTÖHEURISTIIKKA (pehmeä, warnings[]): esim. tekstityksen kattavuus — EI hylkää.
# Rehellinen rajaus (§14 R2): havaitsee katkenneen/tyhjän/vääränmittaisen, EI "väärä-mutta-
# oikeanmittainen". Sourcaa common.sh (num_ge) ensin.
set -uo pipefail

# --- ffprobe-apurit ----------------------------------------------------------------------------
_vf_stream_count() {  # _vf_stream_count <file> <v|a|s> → raitojen määrä
  ffprobe -v error -select_streams "$2" -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null | grep -c .
}
_vf_duration() {      # tiedoston kesto sekunteina (desimaali); tyhjä jos ei saatavilla
  ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$1" 2>/dev/null | grep -E '^[0-9.]+$' | head -1
}
_vf_last_video_pts() {  # viimeisen videopaketin pts (loppupään otos) — ennenaikaisen lopun havaitsemiseen
  ffprobe -v error -read_intervals '99%' -select_streams v \
    -show_entries packet=pts_time -of csv=p=0 "$1" 2>/dev/null | grep -E '^[0-9.]+$' | sort -g | tail -1
}
_vf_readable() {      # ffprobe lukee ilman virhettä (tyhjä stderr) → tiedosto ei katkennut/korruptoitunut
  local err; err=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>&1 >/dev/null)
  [ -z "$err" ]
}

# --- (a) rakenteellinen verifiointi ------------------------------------------------------------
# verify_structural <file> <expected_duration_s> <min_audio> → rc 0 ok. Aseta VERIFY_REASON jos hylkää.
VERIFY_REASON=""
verify_structural() {
  local f=$1 exp=$2 minaudio=$3
  VERIFY_REASON=""
  [ -s "$f" ]        || { VERIFY_REASON="tyhjä/puuttuva tiedosto"; return 1; }
  _vf_readable "$f"  || { VERIFY_REASON="ffprobe-lukuvirhe (katkennut/korruptoitunut)"; return 1; }
  local nv na dur tol lastpts
  nv=$(_vf_stream_count "$f" v); na=$(_vf_stream_count "$f" a)
  [ "${nv:-0}" -ge 1 ]        || { VERIFY_REASON="ei videoraitaa"; return 1; }
  [ "${na:-0}" -ge "$minaudio" ] || { VERIFY_REASON="ääniraitoja $na < odotettu $minaudio"; return 1; }
  if [ -n "$exp" ] && [ "$exp" != null ] && [ "$exp" -gt 0 ] 2>/dev/null; then
    dur=$(_vf_duration "$f"); [ -n "$dur" ] || { VERIFY_REASON="kestoa ei saatu"; return 1; }
    # toleranssi = max(2, ceil(0.005*exp)) sekuntia (§8.4a) — awk-numeriikka (§2.4)
    tol=$(awk -v e="$exp" 'BEGIN{t=2; c=(e*0.005); if(c>t)t=c; printf "%d", (t==int(t)?t:int(t)+1)}')
    awk -v d="$dur" -v e="$exp" -v t="$tol" 'BEGIN{x=d-e; if(x<0)x=-x; exit !(x<=t)}' \
      || { VERIFY_REASON="kesto $dur poikkeaa odotetusta $exp yli ${tol}s"; return 1; }
    # ennenaikainen loppu: viimeinen videopaketti pitää olla lähellä kestoa (ei tyngä joka osui toleranssiin)
    lastpts=$(_vf_last_video_pts "$f")
    if [ -n "$lastpts" ]; then
      awk -v p="$lastpts" -v e="$exp" 'BEGIN{exit !(p >= e*0.9)}' \
        || { VERIFY_REASON="viimeinen videopaketti $lastpts « kesto $exp (ennenaikainen loppu)"; return 1; }
    fi
  fi
  return 0
}

# --- (b) sisältöheuristiikka (pehmeä) ----------------------------------------------------------
# verify_soft <file> <expected_duration_s> → tulostaa varoitukset (yksi per rivi). EI koskaan hylkää.
verify_soft() {
  local f=$1 exp=$2 ns lastsub
  ns=$(_vf_stream_count "$f" s)
  if [ "${ns:-0}" -ge 1 ] && [ -n "$exp" ] && [ "$exp" != null ] && [ "$exp" -gt 0 ] 2>/dev/null; then
    lastsub=$(ffprobe -v error -select_streams s -show_entries packet=pts_time -of csv=p=0 "$f" 2>/dev/null \
      | grep -E '^[0-9.]+$' | sort -g | tail -1)
    if [ -n "$lastsub" ]; then
      awk -v p="$lastsub" -v e="$exp" 'BEGIN{exit !(p < e*0.6)}' \
        && printf 'tekstityksen kattavuus matala (viimeinen %s / kesto %s) — mahd. desync tai harva tekstitys\n' "$lastsub" "$exp"
    fi
  fi
}

# --- yhdistetty: verify_file → rakenteinen JSON-tulos ------------------------------------------
# verify_file <file> <expected_duration_s> <min_audio> → JSON {ok, reason, warnings:[]}, rc 0 jos ok.
verify_file() {
  local f=$1 exp=${2:-} minaudio=${3:-0} rc warns
  if verify_structural "$f" "$exp" "$minaudio"; then rc=0; else rc=1; fi
  warns=$(verify_soft "$f" "$exp" | jq -R . | jq -cs .)
  jq -cn --argjson ok "$([ $rc = 0 ] && echo true || echo false)" \
        --arg reason "$VERIFY_REASON" --argjson warnings "${warns:-[]}" \
    '{ok:$ok,reason:(($reason|select(.!="")) // null),warnings:$warnings}'
  return $rc
}

# --- verify-komento (§15 B4) -------------------------------------------------------------------
# cmd_verify [<id>|--all] — tarkista kirjaston tiedosto(t) jälkikäteen. --all on RASKAS (§15 B4):
# tarkoitettu tyhjälle jonolle / pausen aikana + kohteliaisuusehto (väistää käynnissä olevaa enkoodausta).
cmd_verify() {
  local target=${1-}
  [ -n "$target" ] || { err_out bad_state args "" "id tai --all"; return 1; }
  if [ "$target" = --all ]; then
    # kohteliaisuus: jos enkoodauksia käynnissä, kieltäydy (aja tyhjälle jonolle)
    local enc; enc=$(jq -r '.encoding // 0' "$STATE/counters.json" 2>/dev/null)
    if [ "$(_verify_encoding_running)" -gt 0 ]; then
      err_out bad_state busy running "verify --all vain tyhjälle jonolle / pausen aikana"; return 1
    fi
    local p id result any=0
    { for p in "$STATE/jobs/done"/*.json; do
        [ -e "$p" ] || continue
        [ "$(jq -r '.status' "$p")" = done ] || continue
        any=1; id=$(jq -r '.id' "$p")
        _verify_one "$id"
      done
    } | jq -cs '{ok:(all(.[];.ok)),results:.}'
    return 0
  fi
  _verify_one "$target"
}
_verify_encoding_running() {  # käynnissä olevien encoding-jobien määrä
  local n=0 p; for p in "$STATE/jobs"/*.json; do [ -e "$p" ]&&[ "$(jq -r .status "$p")" = encoding ]&&n=$((n+1)); done; printf '%s' "$n"
}
_verify_one() {  # tulosta yhden jobin verify-tulos (id + verify_file)
  local id=$1 j f exp mina
  j=$(job_read "$id") || { err_out id_not_found id "$id" "olemassa oleva job"; return 1; }
  f="$(printf '%s' "$j" | jq -r '.dest_dir')/$(printf '%s' "$j" | jq -r '.out_name')"
  exp=$(printf '%s' "$j" | jq -r '.duration_s // ""')
  mina=$(printf '%s' "$j" | jq -r 'if ((.want_audio // [])|length)>0 then 1 else 0 end')  # R8 alaraja
  verify_file "$f" "$exp" "$mina" | jq -c --arg id "$id" '{id:$id} + .'
}
