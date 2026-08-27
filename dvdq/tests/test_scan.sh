#!/usr/bin/env bash
# tests/test_scan.sh — §6.2 scan + §8.3 raitapolitiikka + §7 rip. Työkalut STUBATTU (lsdvd/HandBrake/
# dvdbackup eivät ole dev-koneella; oikea DVD-polku todennetaan brainbinilla, §12/9).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../lib/common.sh"; source "$HERE/../lib/jobs.sh"
source "$HERE/../lib/commands.sh"; source "$HERE/../lib/verify.sh"; source "$HERE/../lib/cleanup.sh"
source "$HERE/../lib/scan.sh"; source "$HERE/../lib/rip.sh"

TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"
mkdir -p "$TESTROOT/work" "$TESTROOT/dest"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" \
  "AUDIO_POLICY=original+commentary" "SUB_POLICY=all" "RIP_MIN_FREE_GB=0" "READ_ERROR_MAX=20" > "$DVDQ_CONFIG"
config_load; state_init_dirs

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s  (%s)\n' "$1" "${2-}"; }

# stub: scan_title emittoi oman skeeman. title 1 = pää (6000s, 2 eng-ääntä), muut lyhyitä.
ST="$TESTROOT/stub_scantitle.sh"
cat > "$ST" <<'EOF'
#!/usr/bin/env bash
t=$2
case $t in
  1) dur=6000; a='["eng","eng","fin"]'; s='["fin","swe"]' ;;
  2) dur=300;  a='["eng"]';             s='[]' ;;
  *) dur=120;  a='["eng"]';             s='[]' ;;
esac
jq -cn --argjson t "$t" --argjson dur "$dur" --argjson a "$a" --argjson s "$s" \
  '{title:$t,status:"ok",duration_s:$dur,width:720,height:576,fps:25,interlaced:false,crop:"0:0:0:0",src_audio:$a,src_subs:$s,dar:"1.33",format:"PAL"}'
EOF
chmod +x "$ST"; export DVDQ_STUB_SCANTITLE="$ST"

echo "== scan_enumerate (stub) =="
printf '%s\n' 1 2 3 > "$TESTROOT/titles"; export DVDQ_STUB_LSDVD="$TESTROOT/titles"
[ "$(scan_enumerate x | tr '\n' ' ')" = "1 2 3 " ] && ok "enumerointi 1 2 3" || bad "enum" "$(scan_enumerate x)"

echo "== §8.3 raitapolitiikka =="
[ "$(derive_want_audio '["eng","eng","fin"]')" = '["eng","eng"]' ] && ok "original+commentary → eng,eng" || bad "wa oc" "$(derive_want_audio '["eng","eng","fin"]')"
CFG[AUDIO_POLICY]=original
[ "$(derive_want_audio '["eng","eng","fin"]')" = '["eng"]' ] && ok "original → eng" || bad "wa orig" "$(derive_want_audio '["eng","eng","fin"]')"
CFG[AUDIO_POLICY]=all
[ "$(derive_want_audio '["eng","fin"]')" = '["eng","fin"]' ] && ok "all → kaikki" || bad "wa all" "$(derive_want_audio '["eng","fin"]')"
CFG[AUDIO_POLICY]=original+commentary
[ "$(derive_want_subs '["fin","swe"]')" = '["fin","swe"]' ] && ok "SUB all → kaikki" || bad "ws all" "$(derive_want_subs '["fin","swe"]')"
CFG[SUB_POLICY]=none; [ "$(derive_want_subs '["fin","swe"]')" = '[]' ] && ok "SUB none → []" || bad "ws none" "$(derive_want_subs '["fin"]')"
CFG[SUB_POLICY]=fin;  [ "$(derive_want_subs '["fin","swe"]')" = '["fin"]' ] && ok "SUB fin → [fin]" || bad "ws fin" "$(derive_want_subs '["fin","swe"]')"
CFG[SUB_POLICY]=all

echo "== scan_pick_main =="
arr='[{"title":1,"status":"ok","duration_s":6000},{"title":2,"status":"ok","duration_s":300}]'
p=$(scan_pick_main "$arr"); [ "$(printf '%s' "$p"|jq -r .main)" = 1 ] && [ "$(printf '%s' "$p"|jq -r .confidence)" = high ] && ok "pisin=pää, confidence high" || bad "pick" "$p"
arr2='[{"title":1,"status":"ok","duration_s":6000},{"title":3,"status":"ok","duration_s":5800}]'
p2=$(scan_pick_main "$arr2"); [ "$(printf '%s' "$p2"|jq -r .confidence)" = low ] && ok "kaksi pitkää → confidence low" || bad "pick2" "$p2"

echo "== cmd_scan (kaksivaiheinen, persistointi, edistyminen) =="
dk="$TESTROOT/work/disc-001/VOL"; mkdir -p "$dk/VIDEO_TS"
out=$(cmd_scan "$dk" 2>/dev/null | tail -1)   # viimeinen rivi = ok-kuori
[ "$(printf '%s' "$out"|jq -r .ok)" = true ] && [ "$(printf '%s' "$out"|jq -r .main_suggestion)" = 1 ] && ok "cmd_scan ok + main=1" || bad "cmd_scan" "$out"
sf="$STATE/scans/$(_sha1_12 "$dk").json"
[ -f "$sf" ] && ok "scans/<sha1>.json persistoitu" || bad "persist" "puuttuu"
[ "$(jq '.titles|length' "$sf")" = 3 ] && ok "3 titteliä tallennettu" || bad "titles" "$(jq '.titles|length' "$sf")"
prog=$(cmd_scan "$dk" 2>/dev/null | grep -c '"scan"'); [ "$prog" = 3 ] && ok "JSONL-edistyminen 3 riviä" || bad "progress" "$prog"

echo "== cmd_scan enumerointi feilaa → disc:-broken =="
unset DVDQ_STUB_LSDVD; export DVDQ_STUB_LSDVD="$TESTROOT/ei-ole"
out=$(cmd_scan "$TESTROOT/work/disc-broken" 2>/dev/null)
[ "$(printf '%s' "$out"|jq -r .error)" = disc_broken ] && ok "enum fail → disc_broken virhe" || bad "discbroken" "$out"
did=$(disc_id "$TESTROOT/work/disc-broken")
[ "$(job_field "$did" .status)" = broken ] && ok "disc:-job broken problematic/:ssa" || bad "discjob" "$(job_field "$did" .status)"
export DVDQ_STUB_LSDVD="$TESTROOT/titles"

echo "== cmd_rip (stub-dvdbackup) =="
DB="$TESTROOT/stub_dvdbackup.sh"
cat > "$DB" <<'EOF'
#!/usr/bin/env bash
out=$2; mkdir -p "$out/MOVIEVOL/VIDEO_TS"; printf VOB > "$out/MOVIEVOL/VIDEO_TS/VTS_01_1.VOB"
echo "${STUB_READERR:-0}"
EOF
chmod +x "$DB"; export DVDQ_STUB_DVDBACKUP="$DB"
out=$(cmd_rip /dev/null 2>/dev/null | tail -1)
[ "$(printf '%s' "$out"|jq -r .ok)" = true ] && ok "rip → scan ok" || bad "rip" "$out"
ls -d "$TESTROOT/work/disc-"*/MOVIEVOL/VIDEO_TS >/dev/null 2>&1 && ok "VIDEO_TS ripattu disc-NNN:ään" || bad "ripdir" "puuttuu"

echo "== cmd_rip READ_ERROR > max → broken =="
STUB_READERR=99
out=$(STUB_READERR=99 cmd_rip /dev/null 2>/dev/null | tail -1)
[ "$(printf '%s' "$out"|jq -r .error)" = disc_broken ] && ok "READ_ERROR 99 > 20 → disc_broken" || bad "riperr" "$out"

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
