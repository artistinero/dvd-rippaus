#!/usr/bin/env bash
# tests/test_verify.sh — §8.4 verifiointi oikeilla (pienillä ffmpeg-generoiduilla) mediatiedostoilla.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../lib/common.sh"; source "$HERE/../lib/jobs.sh"
source "$HERE/../lib/commands.sh"; source "$HERE/../lib/verify.sh"

command -v ffmpeg >/dev/null || { echo "ffmpeg puuttuu — ohitetaan verify-testit"; exit 0; }
TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"
mkdir -p "$TESTROOT/work" "$TESTROOT/dest" "$TESTROOT/src/disc-1"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" > "$DVDQ_CONFIG"
config_load; state_init_dirs

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s  (%s)\n' "$1" "${2-}"; }

echo "== generoidaan testimedia (mpeg4 + aac) =="
V="$TESTROOT/valid.mkv"; VNOAUD="$TESTROOT/noaudio.mkv"; SHORT="$TESTROOT/short.mkv"; TRUNC="$TESTROOT/trunc.mkv"
ffmpeg -v error -f lavfi -i "testsrc=duration=5:size=64x64:rate=10" -f lavfi -i "sine=frequency=440:duration=5" \
  -c:v mpeg4 -c:a aac -shortest -y "$V" 2>"$TESTROOT/ff.err" \
  && [ -s "$V" ] && ok "valid.mkv luotu (5s, v+a)" || { bad "media-gen" "$(cat "$TESTROOT/ff.err")"; echo "YHTEENVETO: $PASS ok, $((FAIL+1)) FAIL"; exit 1; }
ffmpeg -v error -f lavfi -i "testsrc=duration=5:size=64x64:rate=10" -c:v mpeg4 -y "$VNOAUD" 2>/dev/null
ffmpeg -v error -f lavfi -i "testsrc=duration=2:size=64x64:rate=10" -f lavfi -i "sine=duration=2" -c:v mpeg4 -c:a aac -shortest -y "$SHORT" 2>/dev/null
head -c "$(( $(stat -c%s "$V") / 2 ))" "$V" > "$TRUNC"

echo "== verify_structural =="
# accept: verify_structural onnistuu | refute: verify_structural hylkää (odotettu)
accept(){ if verify_structural "$@"; then ok "$AMSG"; else bad "$AMSG" "$VERIFY_REASON"; fi; }
refute(){ if verify_structural "$@"; then bad "$AMSG" "hyväksyi virheellisesti"; else ok "$AMSG ($VERIFY_REASON)"; fi; }
AMSG="kelvollinen (kesto 5, min_audio 1)→ok"; accept "$V" 5 1
AMSG="min_audio 0→ok";                        accept "$V" 5 0
AMSG="ei audiota + min_audio 1→hylätty";      refute "$VNOAUD" 5 1
AMSG="väärä kesto (2 vs 5)→hylätty";          refute "$SHORT" 5 1
AMSG="katkennut→hylätty";                     refute "$TRUNC" 5 1
AMSG="puuttuva tiedosto→hylätty";             refute "$TESTROOT/puuttuu.mkv" 5 1
AMSG="kesto tuntematon→rakenne silti ok";     accept "$V" "" 1

echo "== verify_file (JSON-tulos) =="
r=$(verify_file "$V" 5 1); [ "$(printf '%s' "$r"|jq -r .ok)" = true ] && ok "verify_file ok=true" || bad "vf ok" "$r"
r=$(verify_file "$TRUNC" 5 1); [ "$(printf '%s' "$r"|jq -r .ok)" = false ] && [ -n "$(printf '%s' "$r"|jq -r .reason)" ] && ok "verify_file ok=false + reason" || bad "vf fail" "$r"

echo "== cmd_verify <id> ja --all =="
id=$(cmd_enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 1 --kind movie --name Fargo --duration 5 | jq -r .id)
dd="$(job_field "$id" .dest_dir)"; mkdir -p "$dd"; cp "$V" "$dd/$(job_field "$id" .out_name)"
job_apply "$id" '.status="done"' >/dev/null
out=$(cmd_verify "$id"); [ "$(printf '%s' "$out"|jq -r .ok)" = true ] && ok "cmd_verify <id> → ok" || bad "cmd_verify id" "$out"
out=$(cmd_verify --all); [ "$(printf '%s' "$out"|jq -r .ok)" = true ] && ok "cmd_verify --all → ok" || bad "cmd_verify all" "$out"
# rikkoutunut kohde → --all ok=false
cp "$TRUNC" "$dd/$(job_field "$id" .out_name)"
out=$(cmd_verify --all); [ "$(printf '%s' "$out"|jq -r .ok)" = false ] && ok "--all havaitsee rikkoutuneen" || bad "all broken" "$out"
# kohteliaisuus: encoding käynnissä → --all kieltäytyy
id2=$(cmd_enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 2 --kind movie --name X | jq -r .id)
job_apply "$id2" '.status="encoding"' >/dev/null
out=$(cmd_verify --all 2>/dev/null); [ "$(printf '%s' "$out"|jq -r .ok)" = false ] && [ "$(printf '%s' "$out"|jq -r .error)" = bad_state ] && ok "--all kieltäytyy kun encoding käynnissä" || bad "all busy" "$out"

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
