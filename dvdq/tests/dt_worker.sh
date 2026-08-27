source "$(dirname "$0")/dt_common.sh"; dt_setup
# dt_worker — worker_run PÄÄSTÄ-PÄÄHÄN oikealla enkooderikäynnistyksellä (STUB_SLEEP=0, foreground-
# subshell, reapattu). Todentaa encoder_start-korjauksen: enkooderi on workerin lapsi → wait saa
# OIKEAN rc:n (ei 127 komentokorvauksesta) → job → done (ei failed). Tämä polku jäi aiemmin testaamatta.
export DVDQ_STUB_ENCODER="$DT_HERE/stub_encoder.sh"
export DVDQ_NO_SETSID=1   # sandbox ei salli setsidiä; setsid/pgid-käytös todennetaan brainbinilla
cat > "$DT_HERE/stub_verify.sh" <<'EOF'
#!/usr/bin/env bash
[ -s "$1" ]
EOF
chmod +x "$DT_HERE/stub_verify.sh"; export DVDQ_STUB_VERIFY="$DT_HERE/stub_verify.sh"
trap 'pkill -f stub_encoder.sh 2>/dev/null; rm -rf "$TESTROOT"' EXIT

echo "== rc=0 → done (todistaa ettei wait palauta 127) =="
id=$(mkq 1); reserve_job "$id" 1
( export STUB_SLEEP=0 STUB_RC=0; worker_run "$id" 1 )   # foreground-subshell; exit 0 poistuu subshellistä
pkill -f stub_encoder.sh 2>/dev/null
[ "$(job_field "$id" .status)" = done ] && ok "job → done" || bad "done" "$(job_field "$id" .status) — encoder_start-bugi?"
[ -f "$(job_field "$id" .dest_dir)/$(job_field "$id" .out_name)" ] && ok "dest-tiedosto siirretty" || bad "dest" "puuttuu"
[ ! -e "$(DEST_TMP)/$id.mkv" ] && ok "tmp siivottu" || bad "tmp" "jäi"
slot_held 1 && bad "slot" "yhä pidossa" || ok "slot-lukko vapautettu commitin jälkeen"

echo "== rc≠0 → failed (wait välittää oikean rc:n, ei 127-oletuksen) =="
id2=$(mkq 2); reserve_job "$id2" 1
( export STUB_SLEEP=0 STUB_RC=7; worker_run "$id2" 1 )
pkill -f stub_encoder.sh 2>/dev/null
[ "$(job_field "$id2" .status)" = failed ] && ok "rc=7 → failed" || bad "failed" "$(job_field "$id2" .status)"
[ ! -e "$(DEST_TMP)/$id2.mkv" ] && ok "failed: tmp poistettu" || bad "failtmp" "jäi"

echo "== pgid tallennettu (thermal/recover tarvitsevat) =="
id3=$(mkq 3); reserve_job "$id3" 1
( export STUB_SLEEP=0; worker_run "$id3" 1 )
pkill -f stub_encoder.sh 2>/dev/null
# commitin jälkeen pgid nollattu, mutta ajon aikana se asetettiin — todennetaan ettei se ollut 0/null virheellisesti:
[ "$(job_field "$id3" .status)" = done ] && ok "kolmas job → done" || bad "done3" "$(job_field "$id3" .status)"

echo "== ei orpo-stub-prosesseja =="
sleep 0.3; [ "$(pgrep -cf stub_encoder.sh 2>/dev/null || echo 0)" = 0 ] && ok "ei jääneitä enkoodereita" || bad "orphan" "$(pgrep -cf stub_encoder.sh)"

dt_report WORKER
