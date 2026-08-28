#!/usr/bin/env bash
# tests/test_commands.sh — §6.2 enqueue/skip/unskip/retry/status CLI-binäärin kautta.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DVDQ="$HERE/../dvdq"

TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"
mkdir -p "$TESTROOT/work" "$TESTROOT/dest" "$TESTROOT/src/disc-1"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" > "$DVDQ_CONFIG"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1  ($2)"; }
# run: aja dvdq, talleta stdout->$OUT ja rc->$RC
run(){ OUT=$("$DVDQ" "$@" 2>/dev/null); RC=$?; }
jqget(){ printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }

echo "== enqueue =="
run enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 11 --kind movie --name Fargo --year 1996 --duration 5640
[ "$RC" = 0 ] && [ "$(jqget .ok)" = true ] && ok "enqueue ok" || bad "enqueue ok" "$OUT"
ID=$(jqget .id); SEQ=$(jqget .seq)
[ -n "$ID" ] && ok "enqueue palauttaa id" || bad "enqueue palauttaa id" "$OUT"
[ "$SEQ" = 1 ] && ok "seq=1" || bad "seq=1" "$SEQ"
run status
[ "$(jqget .pending)" = 1 ] && ok "status pending=1" || bad "status pending=1" "$OUT"

echo "== enqueue idempotenssi =="
run enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 11 --kind movie --name Fargo
[ "$RC" != 0 ] && [ "$(jqget .error)" = id_exists ] && ok "sama id → id_exists" || bad "id_exists" "$OUT"
run enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 11 --kind movie --name Fargo --force
[ "$RC" = 0 ] && [ "$(jqget .seq)" = 1 ] && ok "--force säilyttää seq=1" || bad "--force seq" "$OUT"

echo "== skip / encoding-haara =="
run skip "$ID"
[ "$RC" = 0 ] && ok "skip pending ok" || bad "skip pending" "$OUT"
run status
[ "$(jqget .user_skip)" = 1 ] && [ "$(jqget .pending)" = 0 ] && ok "→ user_skip" || bad "user_skip" "$OUT"
# skip terminaalille → bad_state
run skip "$ID"
[ "$RC" != 0 ] && [ "$(jqget .error)" = bad_state ] && ok "skip user_skip → bad_state" || bad "skip terminaali" "$OUT"

echo "== unskip vaatii lähteen (§4) =="
run unskip "$ID"
[ "$RC" = 0 ] && ok "unskip (lähde olemassa) ok" || bad "unskip ok" "$OUT"
run status; [ "$(jqget .pending)" = 1 ] && ok "→ pending" || bad "pending" "$OUT"
# poista lähde → unskip epäonnistuu
run skip "$ID"
rm -rf "$TESTROOT/src/disc-1"
run unskip "$ID"
[ "$RC" != 0 ] && [ "$(jqget .error)" = source_missing ] && ok "lähde poissa → source_missing" || bad "source_missing" "$OUT"
mkdir -p "$TESTROOT/src/disc-1"   # palauta

echo "== retry vaatii lähteen =="
# tee failed-job käsin ei onnistu CLI:stä; simuloi enqueue + manuaalinen tila
run enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 12 --kind movie --name Brazil
ID2=$(jqget .id)
# aseta failed suoraan tiedostoon (dispatcher tekisi tämän) — käytä kirjastoa
( source "$HERE/../lib/common.sh"; source "$HERE/../lib/jobs.sh"; export DVDQ_CONFIG; config_load
  job_apply "$ID2" '.status="failed"|.fail_reason="testi"' >/dev/null 2>&1 )
run retry "$ID2"
[ "$RC" = 0 ] && ok "retry failed (lähde olemassa) ok" || bad "retry ok" "$OUT"
run status; [ "$(jqget .pending)" -ge 1 ] && ok "retry → pending" || bad "retry pending" "$OUT"

echo "== §5.4 lukukomento ei kaadu NAS-statiin (GUI-ystävällisyys) =="
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/ei-ole-nas" > "$DVDQ_CONFIG"
run status
[ "$RC" = 0 ] && ok "status toimii vaikka DEST_ROOT puuttuu" || bad "status readonly" "$OUT"
run enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 13 --kind movie --name X
[ "$RC" != 0 ] && [ "$(jqget .error)" = dest_unwritable ] && ok "kirjoittaja kieltäytyy DEST puuttuessa" || bad "writer dest_unwritable" "$OUT"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" > "$DVDQ_CONFIG"

echo "== §5.4 kelvoton config → kaikki kieltäytyy =="
printf '%s\n' "PARALLEL=0" > "$DVDQ_CONFIG"
run status
[ "$RC" != 0 ] && [ "$(jqget .error)" = config_invalid ] && ok "PARALLEL=0 → config_invalid" || bad "config_invalid" "$OUT"

echo "== §11 Unicode-nimet säilyvät (ä/ö/日 + erikoismerkit), myös pilkku-localessa =="
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" > "$DVDQ_CONFIG"
UNAME='Amélie — 日本語 & Ääkköset (Motörhead)'
oletko=$(locale -a 2>/dev/null | grep -iE 'fi_FI.utf8|de_DE.utf8' | head -1)   # ulompi pilkku-locale jos on
oid=$(LC_ALL="${oletko:-C}" "$DVDQ" enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 77 --kind movie --name "$UNAME" 2>/dev/null | jq -r .id)
[ -n "$oid" ] && [ "$(cat "$TESTROOT/work/state/jobs/$oid.json" | jq -r .name)" = "$UNAME" ] && ok "Unicode-nimi säilyi enqueuessa (ulompi: ${oletko:-C})" || bad "unicode" "$(cat "$TESTROOT/work/state/jobs/$oid.json" 2>/dev/null | jq -r .name)"
[ "$(cat "$TESTROOT/work/state/jobs/$oid.json" | jq -r .dest_dir)" = "$TESTROOT/dest/movies/$UNAME" ] && ok "Unicode dest_dir oikein" || bad "unicode dest" "$(cat "$TESTROOT/work/state/jobs/$oid.json" 2>/dev/null | jq -r .dest_dir)"

echo "== §11 tiedostonimien sanitointi (SMB-kielletyt merkit) =="
( source "$HERE/../lib/common.sh"; source "$HERE/../lib/commands.sh"
  [ "$(sanitize_name 'Blade Runner: The Final Cut')" = 'Blade Runner - The Final Cut' ] && echo OK1 || echo "FAIL1 [$(sanitize_name 'Blade Runner: The Final Cut')]"
  [ "$(sanitize_name 'a/b\c?d*e"f<g>h|i')" = "a-b-cde'f(g)h-i" ] && echo OK2 || echo "FAIL2 [$(sanitize_name 'a/b\c?d*e"f<g>h|i')]"
  [ "$(sanitize_name 'Ääkköset 日本 : x')" = 'Ääkköset 日本 - x' ] && echo OK3 || echo "FAIL3 [$(sanitize_name 'Ääkköset 日本 : x')]"
  [ "$(sanitize_name '  ...trimmi.  ')" = 'trimmi' ] && echo OK4 || echo "FAIL4 [$(sanitize_name '  ...trimmi.  ')]" ) > "$TESTROOT/san.out" 2>&1
grep -q OK1 "$TESTROOT/san.out" && ok "kaksoispiste → ' -'" || bad "san :" "$(grep FAIL1 "$TESTROOT/san.out")"
grep -q OK2 "$TESTROOT/san.out" && ok "/\\?*\"<>| sanitoitu" || bad "san merkit" "$(grep FAIL2 "$TESTROOT/san.out")"
grep -q OK3 "$TESTROOT/san.out" && ok "Unicode säilyy sanitoinnissa" || bad "san unicode" "$(grep FAIL3 "$TESTROOT/san.out")"
grep -q OK4 "$TESTROOT/san.out" && ok "loppupisteet/-välit trimmataan" || bad "san trim" "$(grep FAIL4 "$TESTROOT/san.out")"
# enqueue: dest_dir sanitoitu mutta .name raaka
SNAME='X: Y/Z?'
sid=$("$DVDQ" enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 78 --kind movie --name "$SNAME" 2>/dev/null | jq -r .id)
[ "$(cat "$TESTROOT/work/state/jobs/$sid.json"|jq -r .name)" = "$SNAME" ] && ok ".name säilyy raakana (näyttö)" || bad "raw name" "$(cat "$TESTROOT/work/state/jobs/$sid.json"|jq -r .name)"
[ "$(cat "$TESTROOT/work/state/jobs/$sid.json"|jq -r .dest_dir)" = "$TESTROOT/dest/movies/X - Y-Z" ] && ok "dest_dir sanitoitu" || bad "san dest" "$(cat "$TESTROOT/work/state/jobs/$sid.json"|jq -r .dest_dir)"

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
