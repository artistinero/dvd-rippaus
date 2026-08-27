#!/usr/bin/env bash
# tests/test_foundation.sh — §2/§5/§6.1 perusprimitiivien testit.
# Ajettavissa ilman jq:ta (write_json_atomic putoaa python3:een). Ei kosketa NASia.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../lib/common.sh"

TESTROOT=$(mktemp -d)
trap 'rm -rf "$TESTROOT"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

echo "== §2.4 numeeriset & yksiköt =="
check "num_ge 85>=85"        'num_ge 85 85'
check "num_gt 58.0<85 ei"    '! num_gt 58.0 85'
check "num_gt 96>95 (kill)"  'num_gt 96 95'
check "gb_to_bytes 60"       '[ "$(gb_to_bytes 60)" = 64424509440 ]'
check "is_uint 0"            'is_uint 0'
check "is_uint abc ei"       '! is_uint abc'
check "is_uint tyhjä ei"     '! is_uint ""'

echo "== §6.1 virhekuori =="
out=$(err_out config_invalid PARALLEL 8 "1..4" 2>/dev/null)
check "err_out ok=false"     'printf "%s" "$out" | grep -q "\"ok\":false"'
check "err_out koodi"        'printf "%s" "$out" | grep -q "\"error\":\"config_invalid\""'
check "err_out detail.got"   'printf "%s" "$out" | grep -q "\"got\":\"8\""'
check "err_out rc=1"         'err_out x >/dev/null 2>&1; [ $? -eq 1 ]'
out=$(ok_out '"pending":5')
check "ok_out ok=true"       'printf "%s" "$out" | grep -q "{\"ok\":true,\"pending\":5}"'
check "_json_str escapes"    '[ "$(_json_str "a\"b\\c")" = "\"a\\\"b\\\\c\"" ]'

echo "== §5.3 config-parsinta =="
CFGF="$TESTROOT/config"; export DVDQ_CONFIG="$CFGF"
printf '%s\n' \
  '# kommentti omalla rivillä' \
  'PARALLEL=2   ' \
  'DEST_ROOT=/mnt/my movies' \
  'CRF=21' > "$CFGF"
printf 'ENCODER=x265\r\n' >> "$CFGF"   # CR-pääte
check "trailing-välit striptattu" '[ "$(config_get PARALLEL)" = "2" ]'
check "väli polussa säilyy"        '[ "$(config_get DEST_ROOT)" = "/mnt/my movies" ]'
check "CR striptattu"              '[ "$(config_get ENCODER)" = "x265" ]'
check "puuttuva avain tyhjä"       '[ -z "$(config_get NONEXISTENT)" ]'

echo "== §5.4 config-validointi =="
mkconf(){ printf '%s\n' "$@" > "$CFGF"; }
# kelvollinen
mkconf 'PARALLEL=2' 'PARALLEL_MAX=4' 'CRF=21' 'TEMP_WARN=85' 'TEMP_KILL=95' \
       "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest"
config_load
check "kelvollinen config läpi"    'config_validate_common >/dev/null 2>&1'
check "STATE johdettu WORK_DIRistä" '[ "$STATE" = "$TESTROOT/work/state" ]'
# puuttuva config → oletukset (PARALLEL=1)
export DVDQ_CONFIG="$TESTROOT/ei-ole"; config_load
check "puuttuva config → PARALLEL=1" '[ "${CFG[PARALLEL]}" = "1" ]'
export DVDQ_CONFIG="$CFGF"
# virheelliset → kieltäytyminen
mkconf 'PARALLEL=0'; config_load
check "PARALLEL=0 hylätään"         '! config_validate_common >/dev/null 2>&1'
mkconf 'PARALLEL=8' 'PARALLEL_MAX=4'; config_load
check "PARALLEL>MAX hylätään"       '! config_validate_common >/dev/null 2>&1'
mkconf 'CRF=abc'; config_load
check "CRF=abc hylätään"            '! config_validate_common >/dev/null 2>&1'
mkconf 'TEMP_WARN=95' 'TEMP_KILL=85'; config_load
check "TEMP_WARN>=KILL hylätään"    '! config_validate_common >/dev/null 2>&1'
mkconf 'DIR_MOVIES=/abs'; config_load
check "DIR_* absoluuttinen hylätään" '! config_validate_common >/dev/null 2>&1'
mkconf 'AUDIO_POLICY=roska'; config_load
check "AUDIO_POLICY roska hylätään" '! config_validate_common >/dev/null 2>&1'

echo "== §2.2/§2.5 write_json_atomic (durable) =="
mkconf "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest"; config_load; state_init_dirs
tgt="$STATE/jobs/x.json"
printf '{"id":"x","status":"pending"}' | write_json_atomic "$tgt"
check "kelvollinen JSON kirjoitettu" '[ -f "$tgt" ]'
check "sisältö oikein"               '[ "$(jq -r .id "$tgt" 2>/dev/null || python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[\"id\"])" "$tgt")" = "x" ]'
# virheellinen JSON → target koskematon, ei jää temppiä
cp "$tgt" "$tgt.bak"
printf 'EI-JSONIA{{{' | write_json_atomic "$tgt"; rc=$?
check "virheellinen JSON rc=1"       '[ "$rc" = 1 ]'
check "target koskematon"            'diff -q "$tgt" "$tgt.bak" >/dev/null'
check "ei jäänyt .tmp-roskaa"        '[ -z "$(ls "$STATE/jobs"/.tmp.* 2>/dev/null)" ]'

echo "== §5.1 seqfile (monotoninen, atominen) =="
a=$(next_seq); b=$(next_seq); c=$(next_seq)
check "seq kasvaa 1,2,3"             '[ "$a" = 1 ] && [ "$b" = 2 ] && [ "$c" = 3 ]'
# rinnakkainen: 20 prosessia, ei duplikaatteja
for i in $(seq 1 20); do next_seq & done >"$TESTROOT/seqs" 2>/dev/null; wait
n=$(sort -u "$TESTROOT/seqs" | wc -l); tot=$(wc -l <"$TESTROOT/seqs")
check "20 rinnakkaista seq: ei dupleja" '[ "$n" = "$tot" ] && [ "$tot" = 20 ]'

echo "== §2.3 with_lock (serialisointi) =="
CNT="$TESTROOT/cnt"; echo 0 >"$CNT"
_inc(){ local v; v=$(cat "$CNT"); sleep 0.01; echo $((v+1)) >"$CNT"; }
for i in $(seq 1 10); do with_lock "$(lock_dir)/t.lock" _inc & done; wait
check "10 lukittua inkr. → 10"       '[ "$(cat "$CNT")" = 10 ]'

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
