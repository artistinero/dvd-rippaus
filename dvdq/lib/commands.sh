#!/usr/bin/env bash
# dvdq/lib/commands.sh — ydinkomennot (§6.2): enqueue, skip, unskip, retry, status.
# Sourcaa common.sh + jobs.sh ensin. Kaikki tulos §6.1 kuorella.
set -u

# --- dest_dir / out_name johtaminen (perus; ekstranumerointi §8.6/vaihe 7) -------------------
_kind_dir() {
  case $1 in
    movie) printf '%s' "${CFG[DIR_MOVIES]}" ;;
    series) printf '%s' "${CFG[DIR_SERIES]}" ;;
    doc|documentary) printf '%s' "${CFG[DIR_DOCS]}" ;;
    music) printf '%s' "${CFG[DIR_MUSIC]}" ;;
    *) printf '%s' "${CFG[DIR_MISC]}" ;;
  esac
}
# _dest_for <kind> <name> <year> <season> <episode> <role> → "dest_dir\tout_name"
# role=extra → out_name jätetään tyhjäksi (numerointi ratkaistaan §8.6/vaihe 7 kirjoitushetkellä).
_dest_for() {
  local kind=$1 name=$2 year=$3 season=$4 episode=$5 role=$6
  local base="${CFG[DEST_ROOT]}/$(_kind_dir "$kind")" dd on
  case $kind in
    movie)
      local disp="$name"; [ -n "$year" ] && disp="$name ($year)"
      dd="$base/$disp"; on="$name.mkv" ;;
    series)
      local ss ee; ss=$(printf '%02d' "${season:-0}" 2>/dev/null || echo 00)
      ee=$(printf '%02d' "${episode:-0}" 2>/dev/null || echo 00)
      dd="$base/$name/Season $ss"; on="$name S${ss}E${ee}.mkv" ;;
    *) dd="$base/$name"; on="$name.mkv" ;;
  esac
  [ "$role" = extra ] && on=""    # ekstran numero vasta kirjoitushetkellä
  printf '%s\t%s' "$dd" "$on"
}

# =============================================================================
# enqueue (§6.2) — idempotenssi 3 hakemiston yli, --force rev=max+1 & seq säilyy
# =============================================================================
cmd_enqueue() {
  local source="" title="" kind="" name="" year="" season="" episode="" role="main" force=0
  local duration="" width="" height="" dar="" fps="" format="" crop="" interlaced="false"
  local src_subs="[]" src_audio="[]" want_subs="" want_audio=""
  while [ $# -gt 0 ]; do
    case $1 in
      --source) source=$2; shift 2;; --title) title=$2; shift 2;;
      --kind) kind=$2; shift 2;; --name) name=$2; shift 2;;
      --year) year=$2; shift 2;; --season) season=$2; shift 2;; --episode) episode=$2; shift 2;;
      --role) role=$2; shift 2;; --force) force=1; shift;;
      --duration) duration=$2; shift 2;; --width) width=$2; shift 2;; --height) height=$2; shift 2;;
      --dar) dar=$2; shift 2;; --fps) fps=$2; shift 2;; --format) format=$2; shift 2;;
      --crop) crop=$2; shift 2;; --interlaced) interlaced=$2; shift 2;;
      --src-subs) src_subs=$2; shift 2;; --src-audio) src_audio=$2; shift 2;;
      --want-subs) want_subs=$2; shift 2;; --want-audio) want_audio=$2; shift 2;;
      *) err_out bad_state arg "$1" "tunnettu lippu"; return 1;;
    esac
  done
  [ -n "$source" ] && [ -n "$title" ] && [ -n "$kind" ] && [ -n "$name" ] || {
    err_out bad_state args "" "--source --title --kind --name pakollisia"; return 1; }
  local id seq; id=$(job_id "$source" "$title")
  local disc_key="${source%/VIDEO_TS}"; disc_key="${disc_key%/}"
  # idempotenssi (§5.1)
  if job_exists "$id"; then
    if [ "$force" -ne 1 ]; then err_out id_exists id "$id" "olemassa (käytä --force)"; return 1; fi
    seq=$(job_field "$id" .seq); is_uint "$seq" || seq=$(next_seq)   # --force säilyttää seq:n
  else
    seq=$(next_seq)
  fi
  # want_* oletus src_*:sta jos ei annettu (varsinainen politiikka §8.3/myöh.)
  [ -z "$want_subs" ]  && want_subs=$src_subs
  [ -z "$want_audio" ] && want_audio=$src_audio
  local dd on; IFS=$'\t' read -r dd on < <(_dest_for "$kind" "$name" "$year" "$season" "$episode" "$role")
  local created; created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local json
  json=$(jq -cn \
    --arg id "$id" --argjson seq "$seq" --arg created "$created" \
    --arg source "$source" --arg disc_key "$disc_key" --argjson title "$title" \
    --arg kind "$kind" --arg role "$role" --arg name "$name" \
    --arg year "$year" --arg season "$season" --arg episode "$episode" \
    --arg dest_dir "$dd" --arg out_name "$on" \
    --arg duration "$duration" --arg width "$width" --arg height "$height" \
    --arg dar "$dar" --arg fps "$fps" --arg format "$format" --arg crop "$crop" \
    --argjson interlaced "${interlaced:-false}" \
    --argjson src_subs "$src_subs" --argjson src_audio "$src_audio" \
    --argjson want_subs "$want_subs" --argjson want_audio "$want_audio" \
    --argjson crf "${CFG[CRF]}" --arg encoder "${CFG[ENCODER]}" \
    '{id:$id,seq:$seq,rev:0,created:$created,source:$source,disc_key:$disc_key,
      title:$title,kind:$kind,role:$role,name:$name,
      year:(($year|select(.!="")) // null),
      season:(($season|select(.!="")|tonumber?) // null),
      episode:(($episode|select(.!="")|tonumber?) // null),
      dest_dir:$dest_dir,out_name:$out_name,
      duration_s:(($duration|select(.!="")|tonumber?) // null),
      width:(($width|select(.!="")|tonumber?) // null),
      height:(($height|select(.!="")|tonumber?) // null),
      dar:(($dar|select(.!="")) // null),
      fps:(($fps|select(.!="")|tonumber?) // null),
      format:(($format|select(.!="")) // null),
      interlaced:$interlaced,crop:(($crop|select(.!="")) // null),
      src_subs:$src_subs,src_audio:$src_audio,want_subs:$want_subs,want_audio:$want_audio,
      read_errors:0,status:"pending",slot:null,pid:null,pgid:null,starttime:null,
      skip_requested:false,thermal_kill:false,quality:$crf,encoder:$encoder,audio_codec:"copy",
      deinterlace:"auto",started:null,finished:null,fail_reason:null,warnings:[],
      confidence:"high",alt_main_titles:[]}')
  job_put "$id" "$json" || return $?
  ok_out "$(printf '"id":"%s","seq":%s' "$id" "$seq")"
}

# =============================================================================
# skip / unskip / retry (§2.6, §4)
# =============================================================================
# skip: pending→user_skip suoraan; encoding→skip_requested; terminaali→bad_state (jq error).
cmd_skip() {
  local id=${1-}; [ -n "$id" ] || { err_out bad_state args "" "id pakollinen"; return 1; }
  job_exists "$id" || { err_out id_not_found id "$id" "olemassa oleva job"; return 1; }
  # Esitarkistus (ei jq error() → ei kaksoiskuorta). Pieni TOCTOU: haarafiltteri on turvallinen
  # kummallekin tilalle, ja terminaalitilan skip on joka tapauksessa merkityksetön.
  local st; st=$(job_field "$id" .status)
  case $st in
    pending)  job_apply "$id" '.status="user_skip" | .finished=(now|todate)' || return $? ;;
    encoding) job_apply "$id" '.skip_requested=true' || return $? ;;
    *) err_out bad_state id "$id" "vain pending/encoding voi skipata (nyt: $st)"; return 1 ;;
  esac
  ok_out "$(printf '"id":"%s"' "$id")"
}

# _require_source <id> — §4: unskip/retry vaativat lähteen olemassaolon.
_require_source() {
  local id=$1 dk; dk=$(job_field "$id" .disc_key)
  [ -n "$dk" ] && [ -d "$dk" ]
}
_disc_lock() { printf '%s/disc-%s.lock' "$(lock_dir)" "$(_sha1_12 "$1")"; }

cmd_unskip() {
  local id=${1-}; [ -n "$id" ] || { err_out bad_state args "" "id pakollinen"; return 1; }
  job_exists "$id" || { err_out id_not_found id "$id" "olemassa oleva job"; return 1; }
  local dk; dk=$(job_field "$id" .disc_key)
  _do() {
    [ "$(job_field "$id" .status)" = user_skip ] || { err_out bad_state id "$id" "vain user_skip"; return 1; }
    _require_source "$id" || { err_out source_missing disc_key "$dk" "lähde olemassa (retry/unskip vaatii)"; return 1; }
    job_apply "$id" '.status="pending" | .finished=null'
  }
  with_lock "$(_disc_lock "$dk")" _do || return $?
  ok_out "$(printf '"id":"%s"' "$id")"
}

cmd_retry() {
  local id=${1-}; [ -n "$id" ] || { err_out bad_state args "" "id pakollinen"; return 1; }
  job_exists "$id" || { err_out id_not_found id "$id" "olemassa oleva job"; return 1; }
  local dk; dk=$(job_field "$id" .disc_key)
  _do() {
    local st; st=$(job_field "$id" .status)
    [ "$st" = failed ] || [ "$st" = broken ] || { err_out bad_state id "$id" "vain failed/broken"; return 1; }
    _require_source "$id" || { err_out source_missing disc_key "$dk" "lähde olemassa (retry vaatii)"; return 1; }
    job_apply "$id" '.status="pending" | .fail_reason=null | .thermal_kill=false'
  }
  with_lock "$(_disc_lock "$dk")" _do || return $?
  ok_out "$(printf '"id":"%s"' "$id")"
}

# =============================================================================
# status (§5.2) — LUKUKOMENTO (ei writable-validointia, ei NAS-statia)
# =============================================================================
dispatcher_alive() {   # true jos dispatch.pid-flock on jonkun hallussa
  local pf="$STATE/dispatch.pid"
  if flock -n "$pf" -c true 2>/dev/null; then printf false; else printf true; fi
}
cmd_status() {
  local cp; cp=$(_counters_path)
  local counters='{"pending":0,"encoding":0,"failed":0,"broken":0,"done":0,"user_skip":0,"abandoned":0,"state_rev":0}'
  [ -f "$cp" ] && counters=$(cat "$cp")
  # encoding-jobit (kevyt lista)
  local enc="[]" p
  enc=$(for p in "$STATE/jobs"/*.json; do [ -e "$p" ] || continue;
        jq -c 'select(.status=="encoding")|{id,name,slot,pid}' "$p" 2>/dev/null; done | jq -cs '.')
  local paused=false; [ -f "$STATE/paused" ] && paused=true
  local alive; alive=$(dispatcher_alive)
  local updated; updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -cn --argjson c "$counters" --argjson enc "$enc" --argjson paused "$paused" \
        --argjson alive "$alive" --arg updated "$updated" --argjson parallel "${CFG[PARALLEL]}" \
    '$c + {updated:$updated,parallel:$parallel,dispatcher_alive:$alive,paused:$paused,encoding:$enc}'
}
