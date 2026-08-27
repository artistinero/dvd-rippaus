source "$(dirname "$0")/dt_common.sh"; dt_setup
IDA=$(mkq 10); job_apply "$IDA" '.status="encoding"|.slot=1' >/dev/null
exec {HA}>>"$(_slot_lock 1)"; flock -n "$HA"
recover
[ "$(job_field "$IDA" .status)" = encoding ] && ok "A: slot varattu→jää" || bad "A" "$(job_field "$IDA" .status)"
exec {HA}>&-
recover   # nyt slot1 vapaa → IDA reclaim
[ "$(job_field "$IDA" .status)" = pending ] && ok "A→vapautunut→pending" || bad "A2" "$(job_field "$IDA" .status)"
IDB=$(mkq 11); mkdir -p "$(DEST_TMP)"; printf x > "$(DEST_TMP)/$IDB.mkv"
job_apply "$IDB" '.status="encoding"|.slot=2|.pgid=999999' >/dev/null
recover
[ "$(job_field "$IDB" .status)" = pending ] && ok "B: slot vapaa→pending" || bad "B" "$(job_field "$IDB" .status)"
[ ! -e "$(DEST_TMP)/$IDB.mkv" ] && ok "B: tmp poistettu" || bad "Btmp" jäi
[ -z "$(job_field "$IDB" .pgid)" ] && ok "B: pgid nollattu" || bad "Bpgid" "$(job_field "$IDB" .pgid)"
dt_report RECOVER
