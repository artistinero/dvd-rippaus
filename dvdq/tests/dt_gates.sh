source "$(dirname "$0")/dt_common.sh"; dt_setup
touch "$STATE/paused"; may_open_slot && bad pause avasi || ok "pause→ei slottia"; rm -f "$STATE/paused"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" "RIP_MIN_FREE_GB=999999999" "DEST_MIN_FREE_GB=0" >"$DVDQ_CONFIG"; config_load
may_open_slot && bad tila avasi || ok "vähä WORK-tilaa→ei slottia"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" >"$DVDQ_CONFIG"; config_load
exec {DL}>>"$STATE/dispatch.pid"; flock -n "$DL"
out=$("$DT_HERE/../dvdq" dispatch --once 2>/dev/null)
[ "$(printf '%s' "$out"|jq -r .ok)" = false ] && ok "toinen dispatcher kieltäytyy" || bad single "$out"
exec {DL}>&-
dt_report GATES
