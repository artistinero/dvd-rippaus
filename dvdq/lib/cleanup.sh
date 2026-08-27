#!/usr/bin/env bash
# dvdq/lib/cleanup.sh — cleanup (§8.6) plan/execute-parina (§15 B1) + ack-quarantine (§4/§7) +
# karanteeni-/velkamittarit (§7). Kaikki peruuttamattomat operaatiot: audit-rivi ENNEN (§15 B2).
# Sourcaa common.sh + jobs.sh + verify.sh ensin.
set -uo pipefail

# --- levykohtaiset apurit ----------------------------------------------------------------------
_all_disc_keys() {   # kaikki eri disc_key:t kaikista 3 hakemistosta
  local d p
  for d in $(_all_job_dirs); do
    for p in "$STATE/$d"/*.json; do [ -e "$p" ] && jq -r '.disc_key // empty' "$p"; done
  done | sort -u
}
_disc_statuses() {   # levyn kaikkien jobien tilat (yksi per rivi)
  local dk=$1 d p
  for d in $(_all_job_dirs); do
    for p in "$STATE/$d"/*.json; do
      [ -e "$p" ] || continue
      [ "$(jq -r '.disc_key // empty' "$p")" = "$dk" ] && jq -r '.status' "$p"
    done
  done
}
# _disc_cleanable <disc_key> — true jos KAIKKI levyn jobit ovat done|user_skip|abandoned (§4) JA
# levyhakemisto on olemassa. Yksikin muu tila estää.
_disc_cleanable() {
  local dk=$1 st any=0
  [ -d "$dk" ] || return 1
  while read -r st; do
    [ -n "$st" ] || continue; any=1
    case $st in done|user_skip|abandoned) ;; *) return 1;; esac
  done < <(_disc_statuses "$dk")
  [ "$any" = 1 ]
}
# _disc_done_verified <disc_key> — true jos jokaisen done-jobin kohdetiedosto läpäisee TUOREEN
# sisältötarkistuksen (§14 R1: älä poista lähdettä jos kohde ei ole luettavissa/verifioitavissa).
_disc_done_verified() {
  local dk=$1 d p f exp mina
  for d in $(_all_job_dirs); do
    for p in "$STATE/$d"/*.json; do
      [ -e "$p" ] || continue
      [ "$(jq -r '.disc_key // empty' "$p")" = "$dk" ] || continue
      [ "$(jq -r '.status' "$p")" = done ] || continue
      f="$(jq -r '.dest_dir' "$p")/$(jq -r '.out_name' "$p")"
      exp=$(jq -r '.duration_s // ""' "$p"); mina=$(jq -r 'if ((.want_audio//[])|length)>0 then 1 else 0 end' "$p")  # R8 alaraja
      verify_structural "$f" "$exp" "$mina" || return 1
    done
  done
  return 0
}
_du_bytes() { du -sb "$1" 2>/dev/null | cut -f1 | grep -E '^[0-9]+$' || printf 0; }

# --- §7 mittarit: velka vs karanteeni (uniikit disc_keyt statuksittain) ------------------------
# _debt_bytes <status...> — uniikkien disc_keyjen yhteiskoko joilla on JOKIN annetuista tiloista.
_debt_bytes() {
  local want=" $* " dk d p st match total=0 sz
  while read -r dk; do
    [ -n "$dk" ] && [ -d "$dk" ] || continue
    match=0
    while read -r st; do case "$want" in *" $st "*) match=1; break;; esac; done < <(_disc_statuses "$dk")
    [ "$match" = 1 ] && { sz=$(_du_bytes "$dk"); total=$((total+sz)); }
  done < <(_all_disc_keys)
  printf '%s' "$total"
}
encode_debt_bytes()  { _debt_bytes pending encoding; }   # rippaamaton enkoodausvelka (§7)
quarantine_bytes()   { _debt_bytes failed broken; }      # karanteeni (§7, erillään velasta)
abandoned_bytes()    { _debt_bytes abandoned; }          # kuitattu, odottaa cleanupia (§8.6)

# --- orpo-tempit ($DEST_ROOT/.tmp) -------------------------------------------------------------
_file_open() {   # onko jokin prosessi pitämässä tiedostoa auki (/proc/*/fd) — kova ehto (§8.6)
  local f=$1; ls -l /proc/*/fd/ 2>/dev/null | grep -qF -- "$f"
}
_orphan_temps() {   # tulosta poistettavat tempit: ei encoding-jobia ∧ ei avointa fd:tä ∧ mtime vanha
  local tmpdir; tmpdir="${CFG[DEST_ROOT]}/.tmp"; [ -d "$tmpdir" ] || return 0
  local f id now mt
  now=$(date +%s)
  for f in "$tmpdir"/*.mkv; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .mkv)
    [ "$(job_field "$id" .status 2>/dev/null)" = encoding ] && continue   # kuuluu elävälle workerille
    _file_open "$f" && continue                                          # joku pitää auki
    mt=$(stat -c%Y "$f" 2>/dev/null || echo "$now")
    [ $(( now - mt )) -ge 300 ] || continue                              # mtime-turvamarginaali 5 min
    printf '%s\n' "$f"
  done
}

# --- suunnitelma (plan) — EI sivuvaikutuksia (§15 B1) ------------------------------------------
cleanup_plan() {
  local dk sz sources="[]" temps="[]" backups="[]" scans="[]" f
  # 1) lähteen poisto: cleanable-levyt joiden done-kohteet verifioituvat
  local arr="[]"
  while read -r dk; do
    [ -n "$dk" ] || continue
    _disc_cleanable "$dk" || continue
    _disc_done_verified "$dk" || continue
    sz=$(_du_bytes "$dk")
    arr=$(printf '%s' "$arr" | jq -c --arg d "$dk" --argjson s "$sz" '. + [{disc_key:$d,size:$s}]')
  done < <(_all_disc_keys)
  sources=$arr
  # 2) orpo-tempit
  arr="[]"; while read -r f; do [ -n "$f" ] && arr=$(printf '%s' "$arr" | jq -c --arg f "$f" '. + [$f]'); done < <(_orphan_temps)
  temps=$arr
  # 3) BACKUP_DIR retention
  arr="[]"
  if [ -d "${CFG[BACKUP_DIR]}" ]; then
    while read -r f; do [ -n "$f" ] && arr=$(printf '%s' "$arr" | jq -c --arg f "$f" '. + [$f]'); done \
      < <(find "${CFG[BACKUP_DIR]}" -maxdepth 1 -type f -mtime +"${CFG[BACKUP_RETENTION_DAYS]}" 2>/dev/null)
  fi
  backups=$arr
  # 4) scans/ TTL
  arr="[]"
  while read -r f; do [ -n "$f" ] && arr=$(printf '%s' "$arr" | jq -c --arg f "$f" '. + [$f]'); done \
    < <(find "$STATE/scans" -maxdepth 1 -type f -mtime +"${CFG[SCAN_TTL_DAYS]}" 2>/dev/null)
  scans=$arr
  jq -cn --argjson s "$sources" --argjson t "$temps" --argjson b "$backups" --argjson c "$scans" \
    '{source_deletes:$s,orphan_temps:$t,backup_expired:$b,scans_expired:$c}'
}

# --- suoritus (apply) — peruuttamattomat operaatiot, audit ENNEN, per-disc-lukko+recheck ------
cleanup_apply() {
  local plan=$1 dk f
  # lähteet: per-disc-lukko + TUORE recheck (ei muuttunut unskip/retryllä) + verify + audit
  while read -r dk; do
    [ -n "$dk" ] || continue
    _cleanup_one_source() {
      _disc_cleanable "$dk" || return 0            # muuttui (esim. unskip) → älä poista
      _disc_done_verified "$dk" || return 0
      audit_append source_delete "$dk" "$(_du_bytes "$dk")" cleanup
      rm -rf "$dk"
    }
    with_lock "$(_disc_lock "$dk")" _cleanup_one_source
  done < <(printf '%s' "$plan" | jq -r '.source_deletes[].disc_key')
  # orpo-tempit
  while read -r f; do [ -n "$f" ] || continue
    audit_append orphan_temp_delete "$f" "$(stat -c%s "$f" 2>/dev/null)" cleanup; rm -f "$f"
  done < <(printf '%s' "$plan" | jq -r '.orphan_temps[]')
  # backup-retention + scans-TTL
  while read -r f; do [ -n "$f" ] || continue
    audit_append backup_expire "$f" "$(stat -c%s "$f" 2>/dev/null)" cleanup; rm -f "$f"
  done < <(printf '%s' "$plan" | jq -r '.backup_expired[]')
  while read -r f; do [ -n "$f" ] || continue; rm -f "$f"; done < <(printf '%s' "$plan" | jq -r '.scans_expired[]')
}
# _disc_lock on määritelty commands.sh:ssä (unskip/retry); cleanup jakaa saman lukon → ei kilpaile.

cmd_cleanup() {
  local dry=0; [ "${1-}" = --dry-run ] && dry=1
  local plan; plan=$(cleanup_plan)
  if [ "$dry" = 1 ]; then ok_out "$(printf '"dry_run":true,"plan":%s' "$plan")"; return 0; fi
  cleanup_apply "$plan"
  ok_out "$(printf '"plan":%s' "$plan")"
}

# --- ack-quarantine (§4/§7) --------------------------------------------------------------------
# Siirtää failed/broken-jobin abandoned-tilaan (sallii lähteen poiston, ESTÄÄ retryn). VAROITTAA
# peruuttamattomuudesta. Laukaisee cleanupin kyseiselle levylle (ei näkymätöntä lattiaa, §8.6).
cmd_ack_quarantine() {
  local id=${1-}; [ -n "$id" ] || { err_out bad_state args "" "id pakollinen"; return 1; }
  job_exists "$id" || { err_out id_not_found id "$id" "olemassa oleva job"; return 1; }
  local st; st=$(job_field "$id" .status)
  case $st in failed|broken) ;; *) err_out bad_state id "$id" "vain failed/broken (nyt: $st)"; return 1;; esac
  job_apply "$id" '.status="abandoned"|.finished=(now|todate)' || return $?
  # laukaise cleanup VAIN tälle levylle (ei globaali): rajaa suunnitelma disc_key:hen, ettei
  # ulkopuolisten levyjen lähteitä poisteta käyttäjän pyytämättä (tarkistuksen kohta 2).
  local dk; dk=$(job_field "$id" .disc_key)
  if _disc_cleanable "$dk" && _disc_done_verified "$dk"; then
    local pl; pl=$(cleanup_plan | jq -c --arg dk "$dk" \
      '{source_deletes:[.source_deletes[]|select(.disc_key==$dk)],orphan_temps:[],backup_expired:[],scans_expired:[]}')
    cleanup_apply "$pl"
  fi
  ok_out "$(printf '"id":"%s","status":"abandoned","warning":"peruuttamaton: retry ei enää mahdollinen"' "$id")"
}
