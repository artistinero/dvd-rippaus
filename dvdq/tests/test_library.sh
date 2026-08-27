#!/usr/bin/env bash
# tests/test_library.sh — §8.6 ekstranumerointi (deterministinen, race-vapaa, retry-stabiili),
# §10 varmuuskopio + §15 B2 audit. Synkroninen (ei taustaprosesseja).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../lib/common.sh"; source "$HERE/../lib/jobs.sh"
source "$HERE/../lib/commands.sh"; source "$HERE/../lib/verify.sh"; source "$HERE/../lib/dispatch.sh"

TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"
mkdir -p "$TESTROOT/work" "$TESTROOT/dest" "$TESTROOT/backup" "$TESTROOT/src/disc-1"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" "BACKUP_DIR=$TESTROOT/backup" > "$DVDQ_CONFIG"
config_load; state_init_dirs

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s  (%s)\n' "$1" "${2-}"; }
enq(){ cmd_enqueue "$@"; }
extraq(){ enq --source "$TESTROOT/src/disc-1/VIDEO_TS" --title "$1" --kind movie --name Fargo --year 1996 --role extra | jq -r .id; }

echo "== ekstranumerointi peräkkäin (sama teos → extras/) =="
e1=$(extraq 20); on1=$(job_field "$e1" .out_name); dd=$(job_field "$e1" .dest_dir)
[ "$on1" = "Extra 1.mkv" ] && ok "1. ekstra → Extra 1.mkv" || bad "extra1" "$on1"
[[ "$dd" == */Fargo\ \(1996\)/extras ]] && ok "dest_dir → .../extras" || bad "extrasdir" "$dd"
e2=$(extraq 21); on2=$(job_field "$e2" .out_name)
[ "$on2" = "Extra 2.mkv" ] && ok "2. ekstra → Extra 2.mkv" || bad "extra2" "$on2"

echo "== numerointi huomioi levyllä olevat tiedostot =="
mkdir -p "$dd"; : > "$dd/Extra 5.mkv"
e3=$(extraq 22); on3=$(job_field "$e3" .out_name)
[ "$on3" = "Extra 6.mkv" ] && ok "levyn Extra 5 → seuraava Extra 6" || bad "diskmax" "$on3"

echo "== numerointi huomioi varaukset kaikista 3 hakemistosta =="
# siirrä e2 problematic/:iin (failed) — sen varaus (Extra 2) pitää yhä huomioida
job_apply "$e2" '.status="failed"' >/dev/null
e4=$(extraq 23); on4=$(job_field "$e4" .out_name)
[ "$on4" = "Extra 7.mkv" ] && ok "failed-ekstran varaus huomioidaan (→ 7)" || bad "reserved3" "$on4"

echo "== retry/--force säilyttää numeron =="
before=$(job_field "$e1" .out_name)
enq --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 20 --kind movie --name Fargo --year 1996 --role extra --force >/dev/null
after=$(job_field "$e1" .out_name)
[ "$before" = "$after" ] && [ "$after" = "Extra 1.mkv" ] && ok "--force säilyttää Extra 1.mkv" || bad "forcekeep" "$before→$after"

echo "== §10 varmuuskopio + §15 B2 audit =="
dfile="$TESTROOT/dest/movies/X/X.mkv"; mkdir -p "$(dirname "$dfile")"; printf OLDDATA > "$dfile"
_backup_existing_dest "$dfile" && ok "_backup_existing_dest rc=0" || bad "backup rc" ""
[ ! -e "$dfile" ] && ok "vanha kohde siirretty pois" || bad "moved" "jäi"
ls "$TESTROOT/backup"/X.mkv.* >/dev/null 2>&1 && ok "varmuuskopio BACKUP_DIR:ssä" || bad "backupfile" "puuttuu"
[ -f "$STATE/audit.jsonl" ] && grep -q '"op":"library_replace"' "$STATE/audit.jsonl" && ok "audit-rivi library_replace" || bad "audit" "puuttuu"
au=$(tail -1 "$STATE/audit.jsonl"); [ "$(printf '%s' "$au"|jq -r .target)" = "$dfile" ] && ok "audit target oikea" || bad "audittarget" "$au"
# ei kohdetta → backup no-op rc=0
_backup_existing_dest "$TESTROOT/dest/movies/X/eiole.mkv" && ok "ei kohdetta → no-op ok" || bad "noop" ""

echo "== audit_append muoto (yksi rivi, jäsentyy) =="
audit_append source_delete /abs/disc-9 123456 cleanup
tail -1 "$STATE/audit.jsonl" | jq -e '.op=="source_delete" and .size==123456 and .trigger=="cleanup"' >/dev/null && ok "audit_append kentät" || bad "auditfields" "$(tail -1 "$STATE/audit.jsonl")"

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
