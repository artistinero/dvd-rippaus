#!/usr/bin/env bash
# tests/test_eta.sh — totuudenmukainen ETA: mitattu nopeus + jäljellä olevat videosekunnit +
# queue_eta + HandBraken live-progress-parseri. Synkroninen.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../lib/common.sh"; source "$HERE/../lib/jobs.sh"
source "$HERE/../lib/commands.sh"; source "$HERE/../lib/eta.sh"

TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"; mkdir -p "$TESTROOT/work" "$TESTROOT/dest"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" "PARALLEL=2" > "$DVDQ_CONFIG"
config_load; state_init_dirs

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s  (%s)\n' "$1" "${2-}"; }

mkdone(){ local dur=$1 wall=$2 id now fin st; id=$(_sha1_12 "d$RANDOM$dur$wall$SECONDS")
  now=$(date +%s); fin=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ); st=$(date -u -d "@$((now-wall))" +%Y-%m-%dT%H:%M:%SZ)
  job_put "$id" "$(jq -cn --arg id "$id" --arg st "$st" --arg fin "$fin" --argjson d "$dur" \
    '{id:$id,status:"done",started:$st,finished:$fin,duration_s:$d,name:"D",dest_dir:"/d",out_name:"d.mkv",disc_key:"/x",title:1}')" >/dev/null; }
mkpend(){ local dur=$1 id; id=$(_sha1_12 "p$RANDOM$dur$SECONDS")
  job_put "$id" "$(jq -cn --arg id "$id" --argjson d "$dur" \
    '{id:$id,status:"pending",duration_s:$d,name:"P",dest_dir:"/d",out_name:"p.mkv",disc_key:"/x",title:1}')" >/dev/null; printf '%s' "$id"; }

echo "== ei mittausdataa → queue_eta tyhjä (rehellinen: ei arvausta) =="
mkpend 600 >/dev/null
[ -z "$(queue_eta_s)" ] && ok "ennen valmistumisia ETA = tyhjä (null)" || bad "eta-null" "$(queue_eta_s)"

echo "== mitattu nopeuskerroin (mediaani duration/wall) =="
mkdone 100 100   # ratio 1.0
mkdone 100 200   # ratio 0.5
mkdone 100 50    # ratio 2.0
sp=$(encode_speed_factor)
awk -v s="$sp" 'BEGIN{exit !(s>0.95 && s<1.05)}' && ok "speed_factor mediaani ~1.0 (sai $sp)" || bad "speed" "$sp"

echo "== jäljellä olevat videosekunnit (pending+encoding) =="
mkpend 400 >/dev/null            # nyt pending: 600 + 400 = 1000
enc=$(mkpend 200); job_apply "$enc" '.status="encoding"' >/dev/null   # + encoding 200 = 1200
[ "$(remaining_video_s)" = 1200 ] && ok "remaining = 1200 s" || bad "remaining" "$(remaining_video_s)"

echo "== queue_eta = jäljellä ÷ nopeus ÷ PARALLEL =="
# 1200 s / 1.0 / 2 = 600 s
e=$(queue_eta_s); awk -v e="$e" 'BEGIN{exit !(e>=560 && e<=640)}' && ok "queue_eta ~600 s (sai $e)" || bad "eta" "$e"

echo "== status.json sisältää queue_eta_s + speed_factor =="
# tarvitsee cleanup.sh:n mittariguardit → sourcaa
source "$HERE/../lib/cleanup.sh"
st=$(cmd_status)
[ "$(printf '%s' "$st"|jq -r '.queue_eta_s')" != null ] && ok "status.queue_eta_s asetettu" || bad "statuseta" "$st"
[ "$(printf '%s' "$st"|jq -r '.speed_factor')" != null ] && ok "status.speed_factor asetettu" || bad "statussp" "$st"

echo "== HandBrake live-progress-parseri (oikea rivimuoto) =="
id=$(mkpend 5000); job_apply "$id" '.status="encoding"|.slot=1' >/dev/null
# HandBraken oikea rivi (\r-päivittyvä); kirjoita per-job-lokiin
printf 'Encoding: task 1 of 1, 73.59 %% (10.50 fps, avg 12.04 fps, ETA 00h19m05s)\r' > "$STATE/hb-$id.log"
prog=$(hb_progress_parse "$id")
[ "$(printf '%s' "$prog"|jq -r '.pct')" = 73.59 ] && ok "pct 73.59" || bad "pct" "$(printf '%s' "$prog"|jq -r .pct)"
[ "$(printf '%s' "$prog"|jq -r '.fps')" = 10.50 ] && ok "fps 10.50" || bad "fps" "$(printf '%s' "$prog"|jq -r .fps)"
[ "$(printf '%s' "$prog"|jq -r '.eta_s')" = 1145 ] && ok "eta_s 1145 (19m05s)" || bad "etas" "$(printf '%s' "$prog"|jq -r .eta_s)"
# ja status näyttää sen encoding-listalla
st2=$(cmd_status); [ "$(printf '%s' "$st2"|jq -r '.encoding[]|select(.id=="'"$id"'").fps')" = 10.50 ] && ok "status.encoding[].fps live" || bad "statusfps" "$(printf '%s' "$st2"|jq -c '.encoding')"
# ei lokia → {}
[ "$(hb_progress_parse nonexistent)" = '{}' ] && ok "ei lokia → {}" || bad "nolog" "$(hb_progress_parse nonexistent)"

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
