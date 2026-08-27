source "$(dirname "$0")/dt_common.sh"; dt_setup
[ "$(count_running)" = 0 ] && ok "count_running=0 alussa" || bad "count_running" "$(count_running)"
exec {H1}>>"$(_slot_lock 1)"; flock -n "$H1"
[ "$(count_running)" = 1 ] && ok "slot1 pidossa→count=1" || bad "count=1" "$(count_running)"
slot_held 1 && ok "slot_held 1=true" || bad "slot_held1" f
slot_held 2 && bad "slot_held2" t || ok "slot_held 2=false"
[ "$(free_slot)" = 2 ] && ok "free_slot=2" || bad "free_slot" "$(free_slot)"
exec {H1}>&-
_launch_worker(){ :; }
mkq 1 >/dev/null; mkq 2 >/dev/null; mkq 3 >/dev/null
dispatch_pass
[ "$(enc_n)" = 2 ] && ok "tasan 2 encoding" || bad "2enc" "$(enc_n)"
[ "$(pend_n)" = 1 ] && ok "1 pending" || bad "1pend" "$(pend_n)"
s=$(for p in "$STATE/jobs"/*.json; do jq -r 'select(.status=="encoding").slot' "$p"; done|sort -u|tr '\n' ' ')
[ "$s" = "1 2 " ] && ok "eri slotit 1&2" || bad "slotit" "$s"
dt_report SLOTS
