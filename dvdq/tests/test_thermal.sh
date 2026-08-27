#!/usr/bin/env bash
# tests/test_thermal.sh — §8.2 lämpövahdin logiikka SYNKRONISESTI (ei taustaprosesseja).
# thermal_pg_signal korvataan tallentimella → todennetaan mikä signaali lähtisi millekin pgid:lle.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../lib/common.sh"; source "$HERE/../lib/jobs.sh"
source "$HERE/../lib/commands.sh"; source "$HERE/../lib/thermal.sh"

TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"
mkdir -p "$TESTROOT/work" "$TESTROOT/dest" "$TESTROOT/src/disc-1"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" \
  "TEMP_WARN=85" "TEMP_KILL=95" "LOOP_INTERVAL=5" > "$DVDQ_CONFIG"
config_load; state_init_dirs

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s  (%s)\n' "$1" "${2-}"; }

# korvaa signalointi tallentimella
SIGLOG="$TESTROOT/sig"; : > "$SIGLOG"
thermal_pg_signal(){ printf '%s %s\n' "$1" "$2" >> "$SIGLOG"; }
sigreset(){ : > "$SIGLOG"; }
sigs(){ sort -u "$SIGLOG" | tr '\n' ' '; }

# luo encoding-job pgid:llä
mkenc(){ local id; id=$(cmd_enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title "$1" --kind movie --name "M$1" | jq -r .id)
  job_apply "$id" '.status="encoding"|.slot=1|.pgid=$pg' --argjson pg "$2" >/dev/null; printf '%s' "$id"; }

echo "== lämpötilan luku (stub) =="
DVDQ_STUB_TEMP=72.5 ; export DVDQ_STUB_TEMP
[ "$(thermal_read_temp)" = 72.5 ] && ok "stub-lämpö kiinteä" || bad "stub temp" "$(thermal_read_temp)"
printf '88\n' > "$TESTROOT/tf"; DVDQ_STUB_TEMP="$TESTROOT/tf"
[ "$(thermal_read_temp)" = 88 ] && ok "stub-lämpö tiedostosta" || bad "stub file" "$(thermal_read_temp)"

echo "== heartbeat + ikä =="
thermal_write_heartbeat
[ -f "$STATE/thermal.heartbeat" ] && ok "heartbeat kirjoitettu" || bad "hb" puuttuu
[ "$(thermal_heartbeat_age)" -le 2 ] && ok "ikä ~0" || bad "ikä" "$(thermal_heartbeat_age)"
rm -f "$STATE/thermal.heartbeat"
[ "$(thermal_heartbeat_age)" -ge 999999 ] && ok "puuttuva hb → suuri ikä" || bad "puuttuva hb" "$(thermal_heartbeat_age)"

echo "== HEARTBEAT LUKON ULKOPUOLELLA (ei lukkiumaa) =="
# pidä thermal.lockia testin shellissä; heartbeatin kirjoituksen on silti onnistuttava heti
exec {TL}>>"$(lock_dir)/thermal.lock"; flock -n "$TL"
thermal_write_heartbeat
[ -f "$STATE/thermal.heartbeat" ] && ok "heartbeat onnistuu vaikka thermal.lock varattu" || bad "hb-lukkiuma" "epäonnistui"
exec {TL}>&-

echo "== ohjaus: OK-alue (< WARN) ei signaloi =="
ida=$(mkenc 1 1000); idb=$(mkenc 2 2000)
sigreset; DVDQ_STUB_TEMP=70 thermal_control
[ -z "$(sigs)" ] && ok "70°C → ei signaalia" || bad "ok-alue" "$(sigs)"

echo "== ohjaus: TEMP_WARN → STOP kaikille ryhmille + stopped-lippu =="
sigreset; DVDQ_STUB_TEMP=86 thermal_control
[ "$(sigs)" = "STOP 1000 STOP 2000 " ] && ok "86°C → STOP 1000 & 2000" || bad "warn stop" "$(sigs)"
[ -f "$STATE/thermal.stopped" ] && ok "stopped-lippu asetettu" || bad "stopped-lippu" puuttuu

echo "== ohjaus: jäähtyi (< WARN) + stopped-lippu → CONT + lippu pois =="
sigreset; DVDQ_STUB_TEMP=70 thermal_control
[ "$(sigs)" = "CONT 1000 CONT 2000 " ] && ok "70°C stopped → CONT" || bad "cont" "$(sigs)"
[ ! -f "$STATE/thermal.stopped" ] && ok "stopped-lippu poistettu" || bad "lippu" jäi

echo "== ohjaus: TEMP_KILL → thermal_kill=true (vain encoding) + TERM =="
# lisää yksi ei-encoding job varmistamaan ettei sen lippua aseteta
idp=$(cmd_enqueue --source "$TESTROOT/src/disc-1/VIDEO_TS" --title 3 --kind movie --name P | jq -r .id)  # pending
sigreset; DVDQ_STUB_TEMP=96 thermal_control
[ "$(job_read "$ida" | jq -r .thermal_kill)" = true ] && ok "encoding-job thermal_kill=true" || bad "tk a" "$(job_read "$ida" | jq -r .thermal_kill)"
[ "$(job_read "$idp" | jq -r .thermal_kill)" = false ] && ok "pending-job EI thermal_kill" || bad "tk p" "$(job_read "$idp" | jq -r .thermal_kill)"
printf '%s' "$(sigs)" | grep -q "TERM 1000" && printf '%s' "$(sigs)" | grep -q "TERM 2000" && ok "TERM molemmille ryhmille" || bad "kill term" "$(sigs)"

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
