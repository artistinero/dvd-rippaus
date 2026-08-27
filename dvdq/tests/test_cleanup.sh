#!/usr/bin/env bash
# tests/test_cleanup.sh — §8.6 cleanup plan/execute (§15 B1), turvatarkistukset, orpo-tempit,
# retention, ack-quarantine (§4/§7), mittarit. Synkroninen. verify_structural ohitetaan koolla
# (verify itse testataan vaiheessa 6) jottei tarvita mediaa.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../lib/common.sh"; source "$HERE/../lib/jobs.sh"
source "$HERE/../lib/commands.sh"; source "$HERE/../lib/verify.sh"; source "$HERE/../lib/cleanup.sh"
verify_structural(){ VERIFY_REASON=stub; [ -s "$1" ]; }   # ohitus: kohde ok jos ei-tyhjä (rc viimeisenä!)

TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"
mkdir -p "$TESTROOT/work" "$TESTROOT/dest" "$TESTROOT/backup" "$TESTROOT/discs"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" "BACKUP_DIR=$TESTROOT/backup" \
  "BACKUP_RETENTION_DAYS=30" "SCAN_TTL_DAYS=14" > "$DVDQ_CONFIG"
config_load; state_init_dirs

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s  (%s)\n' "$1" "${2-}"; }
# luo levy + job. mkjob <disc-n> <title> <status> <dest-ok:1/0>
mkjob(){ local dn=$1 t=$2 st=$3 destok=${4:-1} id src
  mkdir -p "$TESTROOT/discs/$dn"; printf 'VOB' > "$TESTROOT/discs/$dn/data"
  src="$TESTROOT/discs/$dn/VIDEO_TS"
  id=$(cmd_enqueue --source "$src" --title "$t" --kind movie --name "N$dn$t" --duration 100 | jq -r .id)
  if [ "$st" = done ]; then
    local dd; dd=$(job_field "$id" .dest_dir); mkdir -p "$dd"
    [ "$destok" = 1 ] && printf DATA > "$dd/$(job_field "$id" .out_name)" || : > "$dd/$(job_field "$id" .out_name)"
  fi
  [ "$st" != pending ] && job_apply "$id" ".status=\"$st\"" >/dev/null
  printf '%s' "$id"
}

echo "== cleanup --dry-run: EI sivuvaikutuksia =="
mkjob d1 1 done 1 >/dev/null    # d1: kaikki done, dest ok → poistettavissa
out=$(cmd_cleanup --dry-run)
[ "$(printf '%s' "$out"|jq -r .ok)" = true ] && [ "$(printf '%s' "$out"|jq -r '.dry_run')" = true ] && ok "dry-run ok" || bad "dryrun" "$out"
[ "$(printf '%s' "$out"|jq -r '.plan.source_deletes[0].disc_key')" = "$TESTROOT/discs/d1" ] && ok "plan listaa d1 lähteen" || bad "plan d1" "$out"
[ -d "$TESTROOT/discs/d1" ] && ok "dry-run EI poistanut levyä" || bad "dryrun sideeffect" "poistettiin"

echo "== execute: poistaa poistettavan lähteen + audit =="
cmd_cleanup >/dev/null
[ ! -d "$TESTROOT/discs/d1" ] && ok "d1 lähde poistettu" || bad "d1 delete" "jäi"
grep -q '"op":"source_delete"' "$STATE/audit.jsonl" && ok "audit source_delete" || bad "audit" "puuttuu"

echo "== turvatarkistus: pending estää poiston =="
mkjob d2 1 done 1 >/dev/null; mkjob d2 2 pending >/dev/null   # d2: yksi done + yksi pending
cmd_cleanup >/dev/null
[ -d "$TESTROOT/discs/d2" ] && ok "d2 (pending mukana) EI poistettu" || bad "d2" "poistettiin"

echo "== turvatarkistus: rikkoutunut done-kohde estää poiston (§14 R1) =="
mkjob d3 1 done 0 >/dev/null    # dest tyhjä → verify_structural (stub [ -s ]) hylkää
cmd_cleanup >/dev/null
[ -d "$TESTROOT/discs/d3" ] && ok "d3 (rikki dest) EI poistettu" || bad "d3" "poistettiin"

echo "== recheck: plan→muutos→apply skippaa (cleanup↔unskip) =="
id4=$(mkjob d4 1 done 1); plan=$(cleanup_plan)     # d4 poistettavissa suunnitelmassa
printf '%s' "$plan" | jq -e '.source_deletes[]|select(.disc_key=="'"$TESTROOT/discs/d4"'")' >/dev/null && ok "d4 suunnitelmassa" || bad "d4 plan" ""
job_apply "$id4" '.status="pending"' >/dev/null     # muuttui apply:n alla
cleanup_apply "$plan"
[ -d "$TESTROOT/discs/d4" ] && ok "recheck esti poiston (muuttui pendingiksi)" || bad "recheck" "poisti silti"

echo "== orpo-tempit =="
mkdir -p "$TESTROOT/dest/.tmp"
touch -d '10 minutes ago' "$TESTROOT/dest/.tmp/orphan.mkv"       # ei jobia, vanha → poistetaan
ide=$(mkjob d5 1 pending); job_apply "$ide" '.status="encoding"' >/dev/null
touch "$TESTROOT/dest/.tmp/$ide.mkv"                             # encoding-jobin tmp → EI poisteta
cmd_cleanup >/dev/null
[ ! -e "$TESTROOT/dest/.tmp/orphan.mkv" ] && ok "orpo-temp poistettu" || bad "orphan" "jäi"
[ -e "$TESTROOT/dest/.tmp/$ide.mkv" ] && ok "encoding-jobin tmp säilyi" || bad "livetmp" "poistettiin"

echo "== BACKUP_DIR retention + scans TTL =="
touch -d '40 days ago' "$TESTROOT/backup/vanha.mkv.20260101"
touch -d '2 days ago'  "$TESTROOT/backup/uusi.mkv.20260827"
touch -d '20 days ago' "$STATE/scans/vanha.json"
cmd_cleanup >/dev/null
[ ! -e "$TESTROOT/backup/vanha.mkv.20260101" ] && ok "vanha varmuuskopio poistettu" || bad "backupret" "jäi"
[ -e "$TESTROOT/backup/uusi.mkv.20260827" ] && ok "uusi varmuuskopio säilyi" || bad "backupnew" "poistettiin"
[ ! -e "$STATE/scans/vanha.json" ] && ok "vanha scan poistettu (TTL)" || bad "scanttl" "jäi"

echo "== §7 mittarit: velka vs karanteeni =="
idf=$(mkjob d6 1 failed)     # karanteeni
idp=$(mkjob d7 1 pending)    # velka
[ "$(quarantine_bytes)" -gt 0 ] && ok "quarantine_bytes > 0 (failed)" || bad "qb" "$(quarantine_bytes)"
[ "$(encode_debt_bytes)" -gt 0 ] && ok "encode_debt_bytes > 0 (pending)" || bad "edb" "$(encode_debt_bytes)"

echo "== ack-quarantine → abandoned, retry estetty, lähde poistettavissa =="
# ULKOPUOLINEN levy B (valmis, siivottavissa) — ack (levy d6) EI SAA poistaa sen lähdettä (bug #2)
mkjob dB 1 done 1 >/dev/null
out=$(cmd_ack_quarantine "$idf")
[ "$(job_field "$idf" .status)" = abandoned ] && ok "failed → abandoned" || bad "ack" "$(job_field "$idf" .status)"
printf '%s' "$out" | jq -e '.warning' >/dev/null && ok "ack varoittaa peruuttamattomuudesta" || bad "ackwarn" "$out"
rout=$(cmd_retry "$idf" 2>/dev/null); [ "$(printf '%s' "$rout"|jq -r .error)" = bad_state ] && ok "retry estetty abandonedille" || bad "retryblock" "$rout"
[ ! -d "$TESTROOT/discs/d6" ] && ok "abandoned-levyn lähde siivottu (ack laukaisi cleanupin)" || bad "ackcleanup" "jäi"
[ -d "$TESTROOT/discs/dB" ] && ok "ULKOPUOLISEN levyn B lähde SÄILYI (ack ei ole globaali)" || bad "ackscope" "B poistettiin!"

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
