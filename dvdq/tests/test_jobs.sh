#!/usr/bin/env bash
# tests/test_jobs.sh — §5.1 datamalli, §2.6 CAS, §3 reconcile, §15 B3 counters/state_rev, A6 index.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../lib/common.sh"
source "$HERE/../lib/jobs.sh"

TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" > "$DVDQ_CONFIG"
mkdir -p "$TESTROOT/work" "$TESTROOT/dest"
config_load; state_init_dirs

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

mkjob(){ jq -cn --arg id "$1" --arg st "$2" --arg name "$3" \
  '{id:$id,status:$st,name:$name,dest_dir:"/d",title:1,disc_key:"/src/disc-1",source:"/src/disc-1/VIDEO_TS"}'; }

echo "== §5.1 id determinismi =="
check "job_id determ."        '[ "$(job_id /src/disc-1 11)" = "$(job_id /src/disc-1 11)" ]'
check "job_id eri titteli≠"   '[ "$(job_id /src/disc-1 11)" != "$(job_id /src/disc-1 12)" ]'
check "disc_id prefix"        '[[ "$(disc_id /src/disc-1)" == disc:* ]]'

echo "== §2.6/§3 job_put sijoittaa tilaluokan mukaan =="
ID=$(job_id /src/disc-1 11)
job_put "$ID" "$(mkjob "$ID" pending Fargo)"
check "pending → jobs/"       '[ -f "$STATE/jobs/$ID.json" ]'
check "rev=1 ensimmäinen"     '[ "$(job_field "$ID" .rev)" = 1 ]'
job_apply "$ID" '.status="encoding"'
check "encoding pysyy jobs/"  '[ -f "$STATE/jobs/$ID.json" ]'
check "rev=2 muutoksen jälk." '[ "$(job_field "$ID" .rev)" = 2 ]'
job_apply "$ID" '.status="done" | .finished="2026-08-27T10:00:00Z"'
check "done → jobs/done/"     '[ -f "$STATE/jobs/done/$ID.json" ]'
check "vanha jobs/ poistettu" '[ ! -f "$STATE/jobs/$ID.json" ]'
check "rev=3"                 '[ "$(job_field "$ID" .rev)" = 3 ]'

echo "== A6 index.jsonl arkistoituu =="
check "index rivi lisätty"    'grep -q "\"id\":\"$ID\"" "$STATE/jobs/done/index.jsonl"'
check "index status=done"     '[ "$(jq -r "select(.id==\"$ID\").status" "$STATE/jobs/done/index.jsonl")" = done ]'

echo "== §15 B3 counters + state_rev =="
check "counters done=1"       '[ "$(jq .done "$STATE/counters.json")" = 1 ]'
check "counters pending=0"    '[ "$(jq .pending "$STATE/counters.json")" = 0 ]'
sr1=$(state_rev_get)
job_apply "$ID" '.warnings=["x"]'   # ei tilaluokan muutosta
sr2=$(state_rev_get)
check "state_rev kasvaa ilman luokkamuutosta" '[ "$sr2" -gt "$sr1" ]'
check "counters done yhä 1"   '[ "$(jq .done "$STATE/counters.json")" = 1 ]'

echo "== A1 rev-invariantti: ei koskaan nollaudu/laske =="
# simuloi kaatumis-kaksoisrecord: sama id jobs/:ssa (rev 5), sitten job_put -> pitää olla max+1=6
ID2=$(job_id /src/disc-2 1)
printf '%s' "$(mkjob "$ID2" failed X)" | jq '.rev=5' > "$STATE/problematic/$ID2.json"
job_put "$ID2" "$(mkjob "$ID2" pending X)"    # "--force"-tyyppinen uudelleenluonti
check "rev=6 (max5+1, ei nollaus)" '[ "$(job_field "$ID2" .rev)" = 6 ]'
check "siirtyi problematic→jobs" '[ -f "$STATE/jobs/$ID2.json" ] && [ ! -f "$STATE/problematic/$ID2.json" ]'

echo "== §3 reconcile: suurin rev voittaa =="
ID3=$(job_id /src/disc-3 1)
printf '%s' "$(mkjob "$ID3" failed R)" | jq '.rev=2' > "$STATE/problematic/$ID3.json"   # vanha
printf '%s' "$(mkjob "$ID3" pending R)" | jq '.rev=7' > "$STATE/jobs/$ID3.json"          # uusi (retry)
reconcile 2>/dev/null
check "reconcile pitää rev=7"   '[ -f "$STATE/jobs/$ID3.json" ] && [ "$(jq -r .rev "$STATE/jobs/$ID3.json")" = 7 ]'
check "reconcile poistaa rev=2" '[ ! -f "$STATE/problematic/$ID3.json" ]'
# tasapeli → terminaalisin
ID4=$(job_id /src/disc-4 1)
printf '%s' "$(mkjob "$ID4" pending T)" | jq '.rev=4' > "$STATE/jobs/$ID4.json"
printf '%s' "$(mkjob "$ID4" done T)" | jq '.rev=4' > "$STATE/jobs/done/$ID4.json"
reconcile 2>/dev/null
check "tasapeli → jobs/done"    '[ -f "$STATE/jobs/done/$ID4.json" ] && [ ! -f "$STATE/jobs/$ID4.json" ]'

echo "== reconcile rakentaa counters uudelleen (drift-korjaus) =="
# turmele counters käsin
printf '{"pending":99,"encoding":0,"failed":0,"broken":0,"done":0,"user_skip":0,"abandoned":0,"state_rev":1}' > "$STATE/counters.json"
reconcile 2>/dev/null
check "counters ei enää 99"     '[ "$(jq .pending "$STATE/counters.json")" != 99 ]'
check "counters state_rev kasvoi" '[ "$(jq .state_rev "$STATE/counters.json")" -ge 2 ]'

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
