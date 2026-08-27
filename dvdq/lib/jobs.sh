#!/usr/bin/env bash
# dvdq/lib/jobs.sh — job-datamalli (§5.1), per-job-CAS (§2.6), dir-luokkasiirrot + reconcile (§3),
# counters.json + state_rev (§15 B3), index.jsonl (§8.6 A6). Sourcaa lib/common.sh ensin.
set -u

# --- id (§5.1) ---------------------------------------------------------------
_sha1_12() { printf '%s' "$1" | sha1sum | cut -c1-12; }
job_id()  { _sha1_12 "$1:$2"; }                 # job_id <source_abs> <title>
disc_id() { printf 'disc:%s' "$(_sha1_12 "$1")"; }  # disc_id <disc_key> (levytason vika, title=null)

# --- tilaluokka → hakemisto (§3/§4) ------------------------------------------
_dir_for_status() {
  case $1 in
    pending|encoding)          printf 'jobs' ;;
    failed|broken)             printf 'problematic' ;;
    done|user_skip|abandoned)  printf 'jobs/done' ;;
    *) return 1 ;;
  esac
}
_all_job_dirs() { printf '%s\n' jobs problematic jobs/done; }

# _job_find <id> → tulostaa recordin polun (etsii kolmesta hakemistosta). Jos monessa → reconcile-tapaus.
# Palauttaa TERMINAALISIMMAN oletuksena (jobs/done > problematic > jobs) jos duplikaatti; rev ratkaisee
# vasta reconcilessa. Yhden recordin normaalitilanne: yksi osuma.
_job_find() {
  local id=$1 d p
  for d in jobs/done problematic jobs; do
    p="$STATE/$d/$id.json"
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
job_read()  { local p; p=$(_job_find "$1") || return 1; cat "$p"; }
job_field() { local j; j=$(job_read "$1") || return 1; printf '%s' "$j" | jq -r "$2 // empty"; }
job_exists(){ _job_find "$1" >/dev/null 2>&1; }

# _job_max_rev <id> — suurin rev kaikista hakemistoista (rev-invariantti A1: ei koskaan laske).
_job_max_rev() {
  local id=$1 d p r max=0
  while read -r d; do
    p="$STATE/$d/$id.json"
    [ -f "$p" ] || continue
    r=$(jq -r '.rev // 0' "$p" 2>/dev/null); is_uint "$r" || r=0
    [ "$r" -gt "$max" ] && max=$r
  done < <(_all_job_dirs)
  printf '%s' "$max"
}

# =============================================================================
# §15 B3  counters.json + state_rev (counters.lock)
# =============================================================================
_counters_path() { printf '%s/counters.json' "$STATE"; }

counters_recompute() {   # reconcile: laske counters täydellä skannauksella (§3)
  _do() {
    local d p st
    declare -A c=( [pending]=0 [encoding]=0 [failed]=0 [broken]=0 [done]=0 [user_skip]=0 [abandoned]=0 )
    while read -r d; do
      for p in "$STATE/$d"/*.json; do
        [ -e "$p" ] || continue
        st=$(jq -r '.status // empty' "$p" 2>/dev/null)
        [ -n "$st" ] && [ -n "${c[$st]+x}" ] && c[$st]=$(( ${c[$st]} + 1 ))
      done
    done < <(_all_job_dirs)
    local prev sr
    prev=$(jq -r '.state_rev // 0' "$(_counters_path)" 2>/dev/null); is_uint "$prev" || prev=0
    sr=$((prev+1))
    jq -n --argjson p "${c[pending]}" --argjson e "${c[encoding]}" --argjson f "${c[failed]}" \
          --argjson b "${c[broken]}" --argjson d "${c[done]}" --argjson u "${c[user_skip]}" \
          --argjson a "${c[abandoned]}" --argjson sr "$sr" \
      '{pending:$p,encoding:$e,failed:$f,broken:$b,done:$d,user_skip:$u,abandoned:$a,state_rev:$sr}' \
      | write_json_atomic "$(_counters_path)"
  }
  with_lock "$(lock_dir)/counters.lock" _do
}

# counters_bump <from|-> <to|-> — säädä laskureita + kasvata state_rev. "-" = ei tilaluokan muutosta.
# Kutsutaan aina rev++:n yhteydessä (§15 B3: state_rev kasvaa JOKAISELLA rev++:lla, myös kun luvut ei muutu).
counters_bump() {
  local from=$1 to=$2
  _do() {
    local cp; cp=$(_counters_path)
    [ -f "$cp" ] || printf '{"pending":0,"encoding":0,"failed":0,"broken":0,"done":0,"user_skip":0,"abandoned":0,"state_rev":0}' | write_json_atomic "$cp"
    local filter='.state_rev += 1'
    [ "$from" != "-" ] && filter="$filter | .$from = ((.$from // 0) - 1 | if . < 0 then 0 else . end)"
    [ "$to" != "-" ]   && filter="$filter | .$to = ((.$to // 0) + 1)"
    jq "$filter" "$cp" | write_json_atomic "$cp"
  }
  with_lock "$(lock_dir)/counters.lock" _do
}

state_rev_get() { jq -r '.state_rev // 0' "$(_counters_path)" 2>/dev/null || echo 0; }

# =============================================================================
# §8.6 A6  index.jsonl (append-only arkistoindeksi; yksi write()/PIPE_BUF)
# =============================================================================
_index_path() { printf '%s/jobs/done/index.jsonl' "$STATE"; }
index_append() {   # index_append <id> <name> <dest> <finished> <status>
  local line; line=$(jq -cn --arg id "$1" --arg name "$2" --arg dest "$3" --arg fin "$4" --arg st "$5" \
    '{id:$id,name:$name,dest:$dest,finished:$fin,status:$st}')
  printf '%s\n' "$line" >> "$(_index_path)"   # yksi write(); rivi << PIPE_BUF (4096)
}
index_rebuild() {  # reconcile: rakenna index.jsonl uudelleen jobs/done/:sta
  local p; : > "$(_index_path).new"
  for p in "$STATE/jobs/done"/*.json; do
    [ -e "$p" ] || continue
    jq -c '{id,name,dest:.dest_dir,finished,status}' "$p" 2>/dev/null >> "$(_index_path).new"
  done
  mv -f "$(_index_path).new" "$(_index_path)"; sync_dir "$STATE/jobs/done"
}

# =============================================================================
# §2.6  Job-kirjoitus CAS-flockissa
# =============================================================================
# job_put <id> <json>  — luo/korvaa record. rev = max(löydetyt)+1 (A1). Sijoittaa oikeaan hakemistoon
# status-kentän mukaan, poistaa vanhan sijainnin jos luokka vaihtui. Päivittää counters + state_rev.
job_put() {
  local id=$1 json=$2
  _do() {
    local oldpath oldstatus newstatus newdir newpath maxrev newrev
    oldpath=$(_job_find "$id" 2>/dev/null) || oldpath=""
    oldstatus=""; [ -n "$oldpath" ] && oldstatus=$(jq -r '.status // empty' "$oldpath")
    maxrev=$(_job_max_rev "$id"); newrev=$((maxrev+1))
    newstatus=$(printf '%s' "$json" | jq -r '.status // empty')
    newdir=$(_dir_for_status "$newstatus") || { err_out bad_state status "$newstatus" "kelvollinen tila"; return 1; }
    newpath="$STATE/$newdir/$id.json"
    printf '%s' "$json" | jq --argjson r "$newrev" '.rev=$r' | write_json_atomic "$newpath"; local rc=$?
    [ "$rc" -ge 2 ] && { err_out durability_failed sync "$newpath" "rc=$rc"; return "$rc"; }
    [ "$rc" -ne 0 ] && return "$rc"
    # poista vanha sijainti jos eri tiedosto (luokkasiirto)
    [ -n "$oldpath" ] && [ "$oldpath" != "$newpath" ] && { rm -f "$oldpath"; sync_dir "$(dirname "$oldpath")"; }
    counters_bump "${oldstatus:--}" "${newstatus:--}"
    # arkistoi index jos siirtyi jobs/done:iin
    [ "$newdir" = jobs/done ] && index_append "$id" \
      "$(printf '%s' "$json" | jq -r '.name // ""')" \
      "$(printf '%s' "$json" | jq -r '.dest_dir // ""')" \
      "$(printf '%s' "$json" | jq -r '.finished // ""')" "$newstatus"
    return 0
  }
  with_lock "$(lock_dir)/job-$id.lock" _do
}

# job_apply <id> <jq_filter> [jq-args...] — CAS-muutos olemassa olevaan jobiin. Asettaa rev=max+1 itse.
job_apply() {
  local id=$1 filter=$2; shift 2
  _do() {
    local oldpath oldstatus newjson
    oldpath=$(_job_find "$id") || { err_out id_not_found id "$id" "olemassa oleva job"; return 1; }
    oldstatus=$(jq -r '.status // empty' "$oldpath")
    newjson=$(jq "$@" "$filter" "$oldpath") || { err_out bad_state filter "$filter" "kelvollinen jq"; return 1; }
    # job_put hoitaa rev/dir/counters — mutta olemme jo job-lukossa; kutsu sisälogiikka suoraan
    local newstatus newdir newpath maxrev newrev
    maxrev=$(_job_max_rev "$id"); newrev=$((maxrev+1))
    newstatus=$(printf '%s' "$newjson" | jq -r '.status // empty')
    newdir=$(_dir_for_status "$newstatus") || { err_out bad_state status "$newstatus" "kelvollinen tila"; return 1; }
    newpath="$STATE/$newdir/$id.json"
    printf '%s' "$newjson" | jq --argjson r "$newrev" '.rev=$r' | write_json_atomic "$newpath"; local rc=$?
    [ "$rc" -ge 2 ] && { err_out durability_failed sync "$newpath" "rc=$rc"; return "$rc"; }
    [ "$rc" -ne 0 ] && return "$rc"
    [ "$oldpath" != "$newpath" ] && { rm -f "$oldpath"; sync_dir "$(dirname "$oldpath")"; }
    counters_bump "$oldstatus" "$newstatus"
    [ "$newdir" = jobs/done ] && index_append "$id" \
      "$(printf '%s' "$newjson" | jq -r '.name // ""')" \
      "$(printf '%s' "$newjson" | jq -r '.dest_dir // ""')" \
      "$(printf '%s' "$newjson" | jq -r '.finished // ""')" "$newstatus"
    return 0
  }
  with_lock "$(lock_dir)/job-$id.lock" _do
}

# =============================================================================
# §3  Käynnistyksen reconcile — kaksoisrecord: suurin rev voittaa (prioriteetti vain tasapeli)
# =============================================================================
reconcile() {
  local id ids d p bestpath bestrev bestclass r cls
  # kerää kaikki id:t
  ids=$(for d in $(_all_job_dirs); do for p in "$STATE/$d"/*.json; do [ -e "$p" ] && basename "$p" .json; done; done | sort -u)
  local dupfixed=0
  while read -r id; do
    [ -n "$id" ] || continue
    # kerää sijainnit
    local paths=(); for d in $(_all_job_dirs); do p="$STATE/$d/$id.json"; [ -f "$p" ] && paths+=("$p"); done
    [ "${#paths[@]}" -le 1 ] && continue   # ei duplikaattia
    # valitse suurin rev; tasapeli → terminaalisin (jobs/done>problematic>jobs)
    bestpath=""; bestrev=-1; bestclass=-1
    for p in "${paths[@]}"; do
      r=$(jq -r '.rev // 0' "$p" 2>/dev/null); is_uint "$r" || r=0
      case $p in */jobs/done/*) cls=3;; */problematic/*) cls=2;; *) cls=1;; esac
      if [ "$r" -gt "$bestrev" ] || { [ "$r" -eq "$bestrev" ] && [ "$cls" -gt "$bestclass" ]; }; then
        bestrev=$r; bestclass=$cls; bestpath=$p
      fi
    done
    for p in "${paths[@]}"; do [ "$p" != "$bestpath" ] && { rm -f "$p"; dupfixed=$((dupfixed+1)); }; done
  done <<< "$ids"
  counters_recompute
  index_rebuild
  printf 'reconcile: %d duplikaattia ratkaistu\n' "$dupfixed" >&2
}
