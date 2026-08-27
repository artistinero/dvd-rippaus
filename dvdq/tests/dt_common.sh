#!/usr/bin/env bash
# dt_common.sh — jaettu esiasetus dispatcher-osiotesteille. Kukin osio ajetaan OMANA prosessinaan
# (dt_slots/dt_recover/dt_commit/dt_gates) → ei kumulatiivista fd/tila-vuotoa.
set -u
DT_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DT_HERE/../lib/common.sh"; source "$DT_HERE/../lib/jobs.sh"
source "$DT_HERE/../lib/commands.sh"; source "$DT_HERE/../lib/dispatch.sh"

DT_PASS=0; DT_FAIL=0
ok(){ DT_PASS=$((DT_PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ DT_FAIL=$((DT_FAIL+1)); printf '  FAIL %s  (%s)\n' "$1" "${2-}"; }
dt_report(){ printf 'SECTION %s: %s ok, %s FAIL\n' "${1-?}" "$DT_PASS" "$DT_FAIL"; [ "$DT_FAIL" -eq 0 ]; }

dt_setup(){   # luo tuore tila; export STATE ym.
  TESTROOT=$(mktemp -d)
  trap 'pkill -f stub_encoder.sh 2>/dev/null; rm -rf "$TESTROOT"' EXIT
  export DVDQ_CONFIG="$TESTROOT/config"
  mkdir -p "$TESTROOT/work" "$TESTROOT/dest" "$TESTROOT/src/disc-1"
  printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" \
    "PARALLEL=2" "PARALLEL_MAX=4" "RIP_MIN_FREE_GB=0" "DEST_MIN_FREE_GB=0" "LOOP_INTERVAL=1" > "$DVDQ_CONFIG"
  export DVDQ_STUB_ENCODER="$DT_HERE/stub_encoder.sh"
  config_load; state_init_dirs
}
mkq(){ cmd_enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title "$1" --kind movie --name "M$1" | jq -r .id; }
enc_n(){ local n=0 p; for p in "$STATE/jobs"/*.json; do [ -e "$p" ]&&[ "$(jq -r .status "$p")" = encoding ]&&n=$((n+1)); done; echo $n; }
pend_n(){ local n=0 p; for p in "$STATE/jobs"/*.json; do [ -e "$p" ]&&[ "$(jq -r .status "$p")" = pending ]&&n=$((n+1)); done; echo $n; }
