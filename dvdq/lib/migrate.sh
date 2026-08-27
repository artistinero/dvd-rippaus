#!/usr/bin/env bash
# dvdq/lib/migrate.sh — migraatio (§9) plan/execute-parina (§15 B1). AINOA PERUUTTAMATON HETKI
# (§C): saa ajaa vasta kun B1 (dry-run), B2 (audit) ja B4 (verify) ovat valmiita+testattuja.
# Tuo vanhat jonorivit (JSONL-manifesti) → enqueue; merkitsee done VAIN §8.4-verifioinnin läpäisseille
# (EI pelkän olemassaolon perusteella, §9 kohta 2); muut → pending (lähde säilyy). Lähteen poisto
# tehdään erikseen cleanupilla (§9 kohta 4). Duplikaatit = eksplisiittinen rajoite (§14 R4).
# Sourcaa common.sh + jobs.sh + verify.sh ensin.
set -uo pipefail

# Manifestirivi (JSON): {source,title,kind,name,[year,season,episode,role],dest_dir,out_name,
#   [duration_s,src_audio,want_audio]}. Vanha rip-dvd.sh .queue → tämä muunnetaan erillisellä
# adapterilla (viimeistellään brainbinilla oikeaa dataa vasten).

# _migrate_build_job <entry_json> <id> <status> — rakenna job-JSON manifestin kentistä (KÄYTTÄÄ
# manifestin dest_dir/out_name:a sellaisenaan → migraatio osuu vanhan kirjaston tiedostoihin).
_migrate_build_job() {
  local e=$1 id=$2 st=$3
  local fin=null; [ "$st" = done ] && fin="\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  printf '%s' "$e" | jq -c --arg id "$id" --arg st "$st" --argjson fin "$fin" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {id:$id,seq:0,rev:0,created:$created,
     source:.source, disc_key:((.source|sub("/VIDEO_TS$";""))|sub("/$";"")),
     title:.title, kind:(.kind//"misc"), role:(.role//"main"), name:.name,
     year:(.year//null), season:(.season//null), episode:(.episode//null),
     dest_dir:.dest_dir, out_name:.out_name,
     duration_s:(.duration_s//null), width:null,height:null,dar:null,fps:null,format:null,
     interlaced:false,crop:null,
     src_subs:(.src_subs//[]),src_audio:(.src_audio//[]),
     want_subs:(.want_subs // .src_subs // []), want_audio:(.want_audio // .src_audio // []),
     read_errors:0,status:$st,slot:null,pid:null,pgid:null,pgid_starttime:null,starttime:null,
     skip_requested:false,thermal_kill:false,quality:21,encoder:"x265",audio_codec:"copy",
     deinterlace:"auto",started:null,finished:$fin,fail_reason:null,warnings:[],
     confidence:"high",alt_main_titles:[]}'
}

# _migrate_decide <entry_json> → tulostaa "action id" jokaista riviä kohti (plan-vaihe, EI sivuvaik.
# paitsi ettei kirjoita jobeja — päätös perustuu id-olemassaoloon + kohteen verifiointiin).
# action: skip (id jo olemassa) | done (kohde verifioituu) | pending (ei kohdetta/verify hylkää).
_migrate_action() {
  local e=$1 src t id dest exp mina
  src=$(printf '%s' "$e" | jq -r '.source'); t=$(printf '%s' "$e" | jq -r '.title')
  id=$(job_id "$src" "$t")
  if job_exists "$id"; then printf 'skip %s' "$id"; return; fi
  dest="$(printf '%s' "$e" | jq -r '.dest_dir')/$(printf '%s' "$e" | jq -r '.out_name')"
  exp=$(printf '%s' "$e" | jq -r '.duration_s // ""')
  mina=$(printf '%s' "$e" | jq -r 'if ((.want_audio // .src_audio // [])|length)>0 then 1 else 0 end')
  if [ -f "$dest" ] && verify_structural "$dest" "$exp" "$mina"; then printf 'done %s' "$id"
  else printf 'pending %s' "$id"; fi
}

# migrate_plan <manifest_file> → JSON-suunnitelma (EI sivuvaikutuksia).
migrate_plan() {
  local mf=$1 e act id entries="[]"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    read -r act id < <(_migrate_action "$e")
    entries=$(printf '%s' "$entries" | jq -c --argjson e "$e" --arg act "$act" --arg id "$id" \
      '. + [{id:$id, action:$act, name:$e.name, dest:($e.dest_dir+"/"+$e.out_name)}]')
  done < "$mf"
  jq -cn --argjson en "$entries" \
    '{total:($en|length),
      done:([$en[]|select(.action=="done")]|length),
      pending:([$en[]|select(.action=="pending")]|length),
      skip:([$en[]|select(.action=="skip")]|length),
      entries:$en}'
}

# migrate_apply <manifest_file> <plan> — suorita SUUNNITELMAN mukaan (§15 B1: apply tekee sen mitä
# plan lupasi, EI laske päätöksiä uudelleen → dry-run on aito lupaus). Action luetaan planista id:llä.
# Record luodaan SUORAAN done/pending-tilaan (ei pending→done-ikkunaa jossa dispatcher voisi napata).
migrate_apply() {
  local mf=$1 plan=$2 e id act
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    id=$(job_id "$(printf '%s' "$e" | jq -r '.source')" "$(printf '%s' "$e" | jq -r '.title')")
    act=$(printf '%s' "$plan" | jq -r --arg id "$id" '.entries[]|select(.id==$id)|.action' | head -1)
    case $act in
      done|pending) job_put "$id" "$(_migrate_build_job "$e" "$id" "$act")" >/dev/null 2>&1 ;;
      *) ;;                                                # skip / tuntematon → ei kirjoiteta
    esac
  done < "$mf"
}

# cmd_migrate --manifest FILE [--dry-run]
cmd_migrate() {
  local mf="" dry=0
  while [ $# -gt 0 ]; do case $1 in --manifest) mf=$2; shift 2;; --dry-run) dry=1; shift;; *) shift;; esac; done
  [ -n "$mf" ] && [ -f "$mf" ] || { err_out bad_state manifest "$mf" "--manifest FILE pakollinen"; return 1; }
  local plan; plan=$(migrate_plan "$mf")
  if [ "$dry" = 1 ]; then ok_out "$(printf '"dry_run":true,"plan":%s' "$plan")"; return 0; fi
  migrate_apply "$mf" "$plan"     # suorita SAMA suunnitelma (ei uudelleenlaskentaa)
  ok_out "$(printf '"plan":%s' "$plan")"
}
