#!/usr/bin/env bash
# tests/test_control.sh — §15 B5 pause/resume + review-problematic (§6.2). CLI-binäärin kautta.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); DVDQ="$HERE/../dvdq"
TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"
mkdir -p "$TESTROOT/work" "$TESTROOT/dest" "$TESTROOT/src/disc-1"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" > "$DVDQ_CONFIG"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s  (%s)\n' "$1" "${2-}"; }
run(){ OUT=$("$DVDQ" "$@" 2>/dev/null); RC=$?; }; jg(){ printf '%s' "$OUT"|jq -r "$1"; }
STATE="$TESTROOT/work/state"

echo "== pause/resume =="
run pause;  [ "$(jg .paused)" = true ]  && [ -f "$STATE/paused" ] && ok "pause → lippu + paused:true" || bad pause "$OUT"
run status; [ "$(jg .paused)" = true ]  && ok "status näyttää paused:true" || bad statuspause "$OUT"
run resume; [ "$(jg .paused)" = false ] && [ ! -f "$STATE/paused" ] && ok "resume → lippu pois" || bad resume "$OUT"

echo "== review-problematic =="
id=$("$DVDQ" enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 1 --kind movie --name X 2>/dev/null | jq -r .id)
( source "$HERE/../lib/common.sh"; source "$HERE/../lib/jobs.sh"; export DVDQ_CONFIG; config_load
  job_apply "$id" '.status="failed"|.fail_reason="testi"' >/dev/null 2>&1 )
run review-problematic
[ "$(jg '.problematic|length')" = 1 ] && [ "$(jg '.problematic[0].fail_reason')" = testi ] && ok "listaa failed-jobin" || bad review "$OUT"
run status; [ "$(jg .paused)" = false ] && ok "status toimii (readonly)" || bad statusro "$OUT"

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
