#!/usr/bin/env bash
# dvdq/lib/eta.sh — TOTUUDENMUKAINEN aikaennuste. Ei HandBraken per-kohde-optimismia eikä rivilaskureita:
#   - jäljellä oleva työ = pending/encoding-jobien tallennettujen VIDEOSEKUNTIEN summa (oikeat kestot)
#   - nopeus = MITATTU toteutuneista done-jobeista (started→finished seinäaika vs duration_s)
#   - queue_eta = jäljellä olevat videosekunnit ÷ mitattu nopeus ÷ PARALLEL
# Lisäksi live-fps/% HandBraken oikeasta progress-rivistä (ei arvausta). Sourcaa common.sh + jobs.sh.
set -uo pipefail

_epoch() { date -d "$1" +%s 2>/dev/null; }   # ISO-8601 → epoch (tyhjä jos ei jäsenny)

# encode_speed_factor — MITATTU nopeuskerroin: mediaani(duration_s / wall_s) viim. 20 done-jobista.
# Esim. 0.90 = enkoodaa 0,9 videosekuntia per seinäsekunti (~reaaliaika). Tyhjä jos ei mittausdataa.
encode_speed_factor() {
  local p rows
  rows=$(for p in "$STATE/jobs/done"/*.json; do
    [ -e "$p" ] || continue
    jq -r 'select(.status=="done" and .started and .finished and (.duration_s//0)>0)
           | [.finished,.started,.duration_s] | @tsv' "$p" 2>/dev/null
  done)
  [ -n "$rows" ] || return 0
  # LC_ALL=C: desimaalierotin AINA piste (ei suomen pilkku) → kelpaa jq:lle / vertailuihin.
  printf '%s\n' "$rows" | sort -r | head -20 | while IFS=$'\t' read -r fin st dur; do
    local fe se wall; fe=$(_epoch "$fin") || continue; se=$(_epoch "$st") || continue
    wall=$((fe - se)); [ "$wall" -gt 0 ] || continue
    LC_ALL=C awk -v d="$dur" -v w="$wall" 'BEGIN{printf "%.4f\n", d/w}'
  done | sort -n | LC_ALL=C awk '{a[NR]=$1} END{ if(NR==0) exit;
    if(NR%2) printf "%.4f\n", a[(NR+1)/2]; else printf "%.4f\n", (a[NR/2]+a[NR/2+1])/2 }'
}

# remaining_video_s — pending + encoding -jobien duration_s-summa (todellinen jäljellä oleva työ).
remaining_video_s() {
  local p
  { for p in "$STATE/jobs"/*.json; do [ -e "$p" ] && cat "$p"; done; } \
    | jq -s 'map(select(.status=="pending" or .status=="encoding") | .duration_s // 0) | add // 0' 2>/dev/null \
    || printf '0'
}

# queue_eta_s — MITATTU jonon kokonaiskesto sekunteina. Tyhjä jos ei nopeusmittausta (rehellinen:
# ennen ensimmäisiä valmistumisia ETAa ei VOI tietää → null, ei arvausta).
queue_eta_s() {
  local speed rem par; speed=$(encode_speed_factor); [ -n "$speed" ] || return 0
  rem=$(remaining_video_s); par=${CFG[PARALLEL]:-1}
  awk -v r="${rem:-0}" -v s="$speed" -v p="$par" 'BEGIN{ if(s<=0||p<=0) exit; printf "%d", r/s/p }'
}

# --- live-progress HandBraken oikeasta stderr-rivistä (ei --json-riippuvuutta) ------------------
_hb_log() { printf '%s/hb-%s.log' "$STATE" "$1"; }   # per-job HandBrake-stderr-loki
# hb_progress_parse <id> → {"pct":N,"fps":F,"eta_s":S} viimeisimmästä progress-rivistä, tai {}.
# Muoto: "73.59 % (10.50 fps, avg 12.04 fps, ETA 00h19m05s)".
hb_progress_parse() {
  local log; log=$(_hb_log "$1"); [ -f "$log" ] || { printf '{}'; return; }
  local line; line=$(tr '\r' '\n' < "$log" 2>/dev/null | grep -oE '[0-9.]+ %[^)]*fps[^)]*ETA [0-9hms]+' | tail -1)
  [ -n "$line" ] || { printf '{}'; return; }
  local pct fps eta h m s
  pct=$(printf '%s' "$line" | grep -oE '^[0-9.]+'); fps=$(printf '%s' "$line" | grep -oE '[0-9.]+ fps' | head -1 | grep -oE '^[0-9.]+')
  eta=$(printf '%s' "$line" | grep -oE 'ETA [0-9]+h[0-9]+m[0-9]+s' | grep -oE '[0-9]+h[0-9]+m[0-9]+s')
  h=${eta%%h*}; m=${eta#*h}; m=${m%%m*}; s=${eta#*m}; s=${s%%s*}
  local etas=""; [ -n "$eta" ] && etas=$(( 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} ))
  jq -cn --argjson pct "${pct:-0}" --argjson fps "${fps:-null}" --argjson eta "${etas:-null}" \
    '{pct:$pct,fps:$fps,eta_s:$eta}' 2>/dev/null || printf '{}'
}
