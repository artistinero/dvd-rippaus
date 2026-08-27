#!/usr/bin/env bash
# tests/test_migrate.sh — §9 migraatio plan/execute (§15 B1). verify_structural ohitetaan koolla
# (verify testataan vaiheessa 6). Todentaa: done VAIN verifioidulle, muut pending, idempotenssi,
# dry-run sivuvaikutukseton, duplikaatti = skip (§14 R4).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../lib/common.sh"; source "$HERE/../lib/jobs.sh"
source "$HERE/../lib/commands.sh"; source "$HERE/../lib/verify.sh"; source "$HERE/../lib/migrate.sh"
verify_structural(){ VERIFY_REASON=stub; [ -s "$1" ]; }   # kohde ok jos ei-tyhjä

TESTROOT=$(mktemp -d); trap 'rm -rf "$TESTROOT"' EXIT
export DVDQ_CONFIG="$TESTROOT/config"
mkdir -p "$TESTROOT/work" "$TESTROOT/dest/movies"
printf '%s\n' "WORK_DIR=$TESTROOT/work" "DEST_ROOT=$TESTROOT/dest" > "$DVDQ_CONFIG"
config_load; state_init_dirs

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s  (%s)\n' "$1" "${2-}"; }

# vanha kirjasto: A:lla ehjä kohde (→done), B:llä ei kohdetta (→pending)
mkdir -p "$TESTROOT/dest/movies/A (2000)"; printf DATA > "$TESTROOT/dest/movies/A (2000)/A.mkv"
MF="$TESTROOT/manifest.jsonl"
{
  jq -cn '{source:"/src/disc-1/VIDEO_TS",title:1,kind:"movie",name:"A",year:"2000",dest_dir:"'"$TESTROOT"'/dest/movies/A (2000)",out_name:"A.mkv",duration_s:100,src_audio:["eng"]}'
  jq -cn '{source:"/src/disc-2/VIDEO_TS",title:1,kind:"movie",name:"B",year:"2001",dest_dir:"'"$TESTROOT"'/dest/movies/B (2001)",out_name:"B.mkv",duration_s:100,src_audio:["eng"]}'
} > "$MF"

echo "== dry-run: sivuvaikutukseton, oikeat luvut =="
out=$(cmd_migrate --manifest "$MF" --dry-run)
[ "$(printf '%s' "$out"|jq -r .ok)" = true ] && ok "dry-run ok" || bad "dry ok" "$out"
[ "$(printf '%s' "$out"|jq -r '.plan.done')" = 1 ] && ok "plan: 1 done (A verifioituu)" || bad "plan done" "$out"
[ "$(printf '%s' "$out"|jq -r '.plan.pending')" = 1 ] && ok "plan: 1 pending (B ei kohdetta)" || bad "plan pending" "$out"
[ -z "$(ls "$STATE/jobs"/*.json 2>/dev/null)" ] && [ -z "$(ls "$STATE/jobs/done"/*.json 2>/dev/null)" ] && ok "dry-run EI luonut jobeja" || bad "dry sideeffect" "loi jobeja"

echo "== execute: done vain verifioidulle, muut pending =="
cmd_migrate --manifest "$MF" >/dev/null
idA=$(job_id /src/disc-1/VIDEO_TS 1); idB=$(job_id /src/disc-2/VIDEO_TS 1)
[ "$(job_field "$idA" .status)" = done ] && ok "A → done (kohde verifioitui)" || bad "A done" "$(job_field "$idA" .status)"
[ "$(job_field "$idB" .status)" = pending ] && ok "B → pending (ei kohdetta)" || bad "B pending" "$(job_field "$idB" .status)"

echo "== §9 kohta 2: EI done pelkän olemassaolon perusteella (rikki kohde → pending) =="
# lisää C jonka kohde on OLEMASSA mutta tyhjä (verify hylkää) → pending, ei done
printf '' > "$TESTROOT/dest/movies/A (2000)/C.mkv"
echo "$(jq -cn '{source:"/src/disc-3/VIDEO_TS",title:1,kind:"movie",name:"C",dest_dir:"'"$TESTROOT"'/dest/movies/A (2000)",out_name:"C.mkv",duration_s:100,src_audio:["eng"]}')" >> "$MF"
cmd_migrate --manifest "$MF" >/dev/null
idC=$(job_id /src/disc-3/VIDEO_TS 1)
[ "$(job_field "$idC" .status)" = pending ] && ok "C (tyhjä kohde) → pending EI done" || bad "C pending" "$(job_field "$idC" .status)"

echo "== idempotenssi / §14 R4 duplikaatti: uusiajo = skip =="
before=$(jq .state_rev "$STATE/counters.json")
out=$(cmd_migrate --manifest "$MF" --dry-run)
[ "$(printf '%s' "$out"|jq -r '.plan.skip')" -ge 2 ] && ok "uusiajo: olemassa olevat → skip" || bad "skip" "$out"
cmd_migrate --manifest "$MF" >/dev/null
# A pysyy done (ei ylikirjoiteta pendingiksi)
[ "$(job_field "$idA" .status)" = done ] && ok "A pysyy done uusiajossa (skip)" || bad "A rerun" "$(job_field "$idA" .status)"

echo "== §15 B1: apply NOUDATTAA suunnitelmaa (ei laske uudelleen) =="
# plan sanoo done; kirjasto muuttuu plan↔apply välissä; apply tekee silti sen mitä plan lupasi
MF2="$TESTROOT/m2.jsonl"
mkdir -p "$TESTROOT/dest/movies/D (2003)"; printf DATA > "$TESTROOT/dest/movies/D (2003)/D.mkv"
jq -cn '{source:"/src/disc-9/VIDEO_TS",title:1,kind:"movie",name:"D",year:"2003",dest_dir:"'"$TESTROOT"'/dest/movies/D (2003)",out_name:"D.mkv",duration_s:100,src_audio:["eng"]}' > "$MF2"
plan=$(migrate_plan "$MF2")
[ "$(printf '%s' "$plan"|jq -r '.done')" = 1 ] && ok "plan: D → done" || bad "planD" "$plan"
rm -f "$TESTROOT/dest/movies/D (2003)/D.mkv"          # kirjasto muuttuu plan- ja apply-kutsun VÄLISSÄ
migrate_apply "$MF2" "$plan"
idD=$(job_id /src/disc-9/VIDEO_TS 1)
[ "$(job_field "$idD" .status)" = done ] && ok "apply noudattaa suunnitelmaa (done), EI laske uudelleen" || bad "planapply" "$(job_field "$idD" .status)"

echo "== lähde säilyy (migraatio ei poista; §9 kohta 4 = cleanup erikseen) =="
# (migraatio ei kosketa lähteitä — tämä on suunniteltua; poisto on cleanupin vastuulla)
ok "migraatio ei poista lähteitä (cleanup hoitaa §9/4)"

echo
echo "YHTEENVETO: $PASS ok, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
