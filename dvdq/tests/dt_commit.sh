source "$(dirname "$0")/dt_common.sh"; dt_setup
mkcommit(){ local id; id=$(mkq "$1"); job_apply "$id" "$2" >/dev/null; mkdir -p "$(DEST_TMP)"; printf DATA >"$(DEST_TMP)/$id.mkv"; printf '%s' "$id"; }
idt=$(mkcommit 21 '.status="encoding"|.thermal_kill=true'); _worker_commit "$idt" "$(DEST_TMP)/$idt.mkv" 1
[ "$(job_field "$idt" .status)" = pending ] && ok "thermal+rc≠0→pending" || bad thermal "$(job_field "$idt" .status)"
[ "$(job_read "$idt" | jq -r .thermal_kill)" = false ] && ok "thermal_kill nollattu" || bad reset ?
idd=$(mkcommit 22 '.status="encoding"|.thermal_kill=true'); _worker_commit "$idd" "$(DEST_TMP)/$idd.mkv" 0
[ "$(job_field "$idd" .status)" = done ] && ok "rc=0+thermal→done" || bad rc0done "$(job_field "$idd" .status)"
ids=$(mkcommit 23 '.status="encoding"|.skip_requested=true'); _worker_commit "$ids" "$(DEST_TMP)/$ids.mkv" 0
[ "$(job_field "$ids" .status)" = user_skip ] && ok "skip→user_skip" || bad skip "$(job_field "$ids" .status)"
idf=$(mkcommit 24 '.status="encoding"'); _worker_commit "$idf" "$(DEST_TMP)/$idf.mkv" 3
[ "$(job_field "$idf" .status)" = failed ] && ok "rc≠0→failed" || bad failed "$(job_field "$idf" .status)"
idv=$(mkcommit 25 '.status="encoding"'); : >"$(DEST_TMP)/$idv.mkv"; _worker_commit "$idv" "$(DEST_TMP)/$idv.mkv" 0
[ "$(job_field "$idv" .status)" = failed ] && ok "verify tyhjä→failed" || bad verifyfail "$(job_field "$idv" .status)"
idg=$(mkcommit 26 '.status="encoding"'); _worker_commit "$idg" "$(DEST_TMP)/$idg.mkv" 0
[ "$(job_field "$idg" .status)" = done ] && ok "verify ok→done" || bad done "$(job_field "$idg" .status)"
[ -f "$(job_field "$idg" .dest_dir)/$(job_field "$idg" .out_name)" ] && ok "dest-tiedosto siirretty" || bad dest puuttuu
[ ! -e "$(DEST_TMP)/$idg.mkv" ] && ok "tmp siivottu" || bad tmp jäi
dt_report COMMIT
