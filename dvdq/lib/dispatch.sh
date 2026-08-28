#!/usr/bin/env bash
# dvdq/lib/dispatch.sh — dispatcher + worker + kaatumistoipuminen (§8, §4).
# Worker pitää slot-lukkoa ITSE (fd auki koko elinajan) ja commitoi oman jobinsa.
# Enkooderi ajetaan omassa sessiossaan (setsid → oma pgid) lämpövahtia (vaihe 5) ja
# toipumisen kill-reapia varten. Testattavissa STUB-enkooderilla (DVDQ_STUB_ENCODER).
# EI set -e (§8.1). Sourcaa common.sh + jobs.sh + commands.sh ensin.
set -uo pipefail

# --- prosessin käynnistysaika (/proc/<pid>/stat kenttä 22) — (pid,starttime)-pari (§4) -------
proc_starttime() {
  local pid=$1 st
  st=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null) || return 1
  [ -n "$st" ] && printf '%s' "$st" || return 1
}
proc_alive_same() {  # proc_alive_same <pid> <starttime> → 0 jos sama prosessi yhä elossa
  local pid=$1 want=$2 now
  [ -n "$pid" ] && [ "$pid" != null ] || return 1
  now=$(proc_starttime "$pid") || return 1
  [ "$now" = "$want" ]
}

# --- slotit (§8.1) — slot-lukko on toipumisen totuus (§4) -------------------------------------
_slot_lock() { printf '%s/slot-%s.lock' "$(slots_dir)" "$1"; }
slot_held() {   # slot_held <N> → 0 jos jokin worker pitää lukkoa (emme saa sitä)
  local lf; lf=$(_slot_lock "$1")
  [ -e "$lf" ] || { : ; }   # olemassaolo ei riitä; ratkaisee flock
  if flock -n "$lf" -c true 2>/dev/null; then return 1; else return 0; fi
}
count_running() {  # pidettyjen slottien määrä (1..PARALLEL_MAX)
  local i n=0
  for i in $(seq 1 "${CFG[PARALLEL_MAX]}"); do slot_held "$i" && n=$((n+1)); done
  printf '%s' "$n"
}
free_slot() {  # ensimmäinen vapaa slot-indeksi, tai tyhjä
  local i
  for i in $(seq 1 "${CFG[PARALLEL_MAX]}"); do slot_held "$i" || { printf '%s' "$i"; return 0; }; done
  return 1
}

# --- levytila & lämpö (§8.1 may_open_slot) ----------------------------------------------------
_free_bytes() { df --output=avail -B1 "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
_thermal_ok() {
  # Heartbeat puuttuu = lämpövahtia ei ole otettu käyttöön (dev/test) → salli.
  # Heartbeat olemassa mutta vanhentunut = vahti kuollut → fail-closed (§8.2).
  local hb="$STATE/thermal.heartbeat" age now ts
  [ -f "$hb" ] || return 0
  ts=$(cat "$hb" 2>/dev/null); is_uint "$ts" || return 0
  now=$(date +%s); age=$((now - ts))
  [ "$age" -le $(( ${CFG[LOOP_INTERVAL]} * 3 )) ]
}
may_open_slot() {   # §8.1: kaikki neljä ehtoa yhtenä predikaattina
  [ -f "$STATE/paused" ] && return 1                                   # (4) pause
  [ "$(count_running)" -lt "${CFG[PARALLEL]}" ] || return 1            # (1) pidetyt < PARALLEL
  num_ge "$(_free_bytes "${CFG[WORK_DIR]}")"  "$(gb_to_bytes "${CFG[RIP_MIN_FREE_GB]}")"  || return 1
  num_ge "$(_free_bytes "${CFG[DEST_ROOT]}")" "$(gb_to_bytes "${CFG[DEST_MIN_FREE_GB]}")" || return 1  # (2) tila
  _thermal_ok || return 1                                             # (3) lämpö
  return 0
}

# --- enkooderi (stub-injektoitava; oikea HandBrake vaiheessa 7) --------------------------------
DEST_TMP() { printf '%s/.tmp' "${CFG[DEST_ROOT]}"; }
# encoder_start <slotfd> <id> <source> <title> <out_tmp> → tulostaa enkooderin pgid:n (setsid-leader).
# <slotfd> suljetaan enkooderilta ({fd}>&-) ettei se peri slot-lukkoa (muuten "slot held" valehtelisi
# workerin kuoltua). Enkooderi omassa sessiossaan (setsid → oma pgid) lämpövahtia/reapia varten.
# KRIITTINEN: enkooderi käynnistetään workerin SUORANA lapsena, EI $()-komentokorvauksessa.
# Komentokorvaus ajaisi setsidin aliprosessissa → enkooderi reparentoituisi initille → workerin
# `wait` epäonnistuisi (rc 127) → JOKAINEN job failed + temp poistettu kesken kirjoituksen + slot
# vapautuisi vaikka enkooderi jatkaa. Siksi funktio ASETTAA globaalin ENCODER_PID:n, ei tulosta.
# Non-interactive daemon: setsid execaa (ei forkkaa) → $! = enkooderin pid = pgid (session leader).
ENCODER_PID=0
encoder_start() {
  local sfd=$1 id=$2 src=$3 title=$4 tmp=$5
  mkdir -p "$(DEST_TMP)"
  # setsid → oma sessio/pgid (lämpö-STOP/reap). DVDQ_NO_SETSID: TESTIHOOK — ilman setsidiä (sandbox
  # ei salli setsid-prosesseja); tuotannossa setsid aina päällä. Komento kootaan taulukkoon ja
  # käynnistetään KERRAN taustalle → $! = enkooderi (=pgid), workerin suora lapsi (wait toimii).
  local -a pre=(setsid); [ -n "${DVDQ_NO_SETSID:-}" ] && pre=()
  # HandBraken stderr → per-job-loki, jotta live-fps/% saadaan oikeasta progress-rivistä (eta.sh).
  local hblog=/dev/null; command -v _hb_log >/dev/null 2>&1 && hblog=$(_hb_log "$id")
  local -a cmd
  if [ -n "${DVDQ_STUB_ENCODER:-}" ]; then
    cmd=("${pre[@]}" "$DVDQ_STUB_ENCODER" "$id" "$src" "$title" "$tmp")
  else
    local -a hb; _hb_build hb "$id" "$src" "$title" "$tmp"
    cmd=("${pre[@]}" HandBrakeCLI "${hb[@]}")
  fi
  "${cmd[@]}" >/dev/null 2>"$hblog" {sfd}>&- &
  ENCODER_PID=$!
}

# _hb_build <arrayname> <id> <src> <title> <tmp> — kokoa HandBrakeCLI-argumentit jobin metadatasta
# (§8.3 raitapolitiikka, CRF/ENCODER, crop, deinterlace). VALIDOITAVA brainbinilla oikealla levyllä
# (mm. tekstitysten synkka; HandBrake hoitaa DVD-VobSubin NAV-ajastuksen libdvdread/nav-pohjaisesti).
_hb_build() {
  local -n _out=$1; local id=$2 src=$3 title=$4 tmp=$5 j
  j=$(job_read "$id")
  local crf enc crop deint wa ws
  crf=$(printf '%s' "$j" | jq -r '.quality // 21')
  enc=$(printf '%s' "$j" | jq -r '.encoder // "x265"')
  crop=$(printf '%s' "$j" | jq -r '.crop // empty')
  deint=$(printf '%s' "$j" | jq -r '.deinterlace // "auto"')
  wa=$(printf '%s' "$j" | jq -r '(.want_audio // []) | join(",")')
  ws=$(printf '%s' "$j" | jq -r '(.want_subs  // []) | join(",")')
  _out=( -i "$src" --title "$title" -o "$tmp" -f av_mkv -e "$enc" -q "$crf" )
  [ -n "$wa" ] && _out+=( --audio-lang-list "$wa" --all-audio ) || _out+=( -a 1 )
  [ -n "$ws" ] && _out+=( --subtitle-lang-list "$ws" --all-subtitles )
  [ -n "$crop" ] && _out+=( --crop "$crop" )
  case $deint in auto) _out+=( --comb-detect --decomb );; on) _out+=( --deinterlace );; esac
}
verify_output() {  # <tmp> <id> → 0 ok. §8.4 rakenteellinen verifiointi (verify.sh).
  if [ -n "${DVDQ_STUB_VERIFY:-}" ]; then "$DVDQ_STUB_VERIFY" "$@"; return $?; fi
  command -v verify_structural >/dev/null 2>&1 || { [ -s "$1" ]; return $?; }   # verify.sh ei sourcattu
  local tmp=$1 id=$2 exp mina
  exp=$(job_field "$id" .duration_s)
  # R8: verifioinnin alaraja = 1 jos ääntä odotetaan (ei want_audio-pituus, ettei kommenttiheuristiikan
  # väärinarvio hylkää jobia). §8.4a.
  mina=$(job_read "$id" | jq -r 'if ((.want_audio // [])|length)>0 then 1 else 0 end')
  verify_structural "$tmp" "${exp:-}" "${mina:-0}"
}

# --- worker (§4) ------------------------------------------------------------------------------
# worker_run <id> <slot> — job on JO varattu encoding-tilaan dispatcherissa (reserve_job).
# Worker pitää slot-lukkoa fd:n kautta koko elinajan; enkooderi ei peri sitä ({WFD}>&-).
worker_run() {
  local id=$1 slot=$2
  local lf; lf=$(_slot_lock "$slot")
  exec {WFD}>>"$lf" || { _release_reservation "$id"; exit 0; }
  if ! flock -n "$WFD"; then _release_reservation "$id"; exit 0; fi   # ristikäytäntö-race: vapauta varaus
  local src title tmp epid starttime
  src=$(job_field "$id" .source); title=$(job_field "$id" .title); tmp="$(DEST_TMP)/$id.mkv"
  encoder_start "$WFD" "$id" "$src" "$title" "$tmp"   # asettaa ENCODER_PID (ei $()-korvausta!)
  epid=$ENCODER_PID
  starttime=$(proc_starttime "$BASHPID")
  local pgst; pgst=$(proc_starttime "$epid")          # enkooderi(=pgid-leader)n käynnistysaika reapin identiteettitarkistukseen
  job_apply "$id" \
    '.pid=$pid|.pgid=$pgid|.pgid_starttime=$pgst|.starttime=$stt|.started=(now|todate)' \
    --argjson pid "$BASHPID" --argjson pgid "$epid" --arg pgst "$pgst" --arg stt "$starttime" >/dev/null 2>&1
  wait "$epid"; local erc=$?
  _worker_commit "$id" "$tmp" "$erc"
  exit 0
}
_release_reservation() {  # varaus (encoding, ei workeria) → takaisin pendingiksi
  job_apply "$1" '.status="pending"|.slot=null|.pid=null|.pgid=null|.starttime=null|.started=null' >/dev/null 2>&1
}

# _backup_existing_dest <dest> — jos kohde on jo olemassa, siirrä vanha versio BACKUP_DIR:iin
# (kirjaston ULKOPUOLELLA, §10) aikaleimatulla nimellä. Audit-rivi ENNEN siirtoa (§15 B2). Rc≠0 jos
# backup epäonnistuu → kutsuja EI ylikirjoita (datahävikin esto). Ei kohdetta → rc 0 (ei tehtävää).
_backup_existing_dest() {
  local dest=$1 bdir="${CFG[BACKUP_DIR]}" base ts bak
  [ -e "$dest" ] || return 0
  mkdir -p "$bdir" 2>/dev/null || return 1
  base=$(basename "$dest"); ts=$(date +%Y%m%d-%H%M%S); bak="$bdir/$base.$ts"
  audit_append library_replace "$dest" "$(stat -c%s "$dest" 2>/dev/null)" "worker-commit"
  mv -f "$dest" "$bak" && sync_dir "$bdir"
}

_worker_commit() {  # <id> <tmp> <erc>  — commitoi tulos (§2.5 rc-käsittely, §4 thermal/skip)
  local id=$1 tmp=$2 erc=$3
  command -v _hb_log >/dev/null 2>&1 && rm -f "$(_hb_log "$id")" 2>/dev/null   # enkooderi valmis → poista live-loki
  local skip tk; skip=$(job_field "$id" .skip_requested); tk=$(job_field "$id" .thermal_kill)
  if [ "$erc" = 0 ]; then
    if [ "$skip" = true ]; then rm -f "$tmp"; job_apply "$id" '.status="user_skip"|.finished=(now|todate)|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1; return; fi
    if verify_output "$tmp" "$id"; then
      local dest_dir out_name dest
      dest_dir=$(job_field "$id" .dest_dir); out_name=$(job_field "$id" .out_name)
      dest="$dest_dir/$out_name"; mkdir -p "$dest_dir"
      # §2.5 kestävyysjärjestys VAIHEITTAIN — rc erottaa kolme eri virhettä (EI &&-niputusta):
      if ! _backup_existing_dest "$dest"; then                     # vanhaa ei saa ylikirjoittaa
        job_apply "$id" '.status="failed"|.fail_reason="backup"|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
      elif ! sync_file "$tmp"; then                                # vaihe 1: data ei kestävä (ennen mv)
        rm -f "$tmp"; job_apply "$id" '.status="failed"|.fail_reason="sync_tmp"|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
      else
        sync_dir "$(DEST_TMP)"                                     # vaihe 2: temp-hakemisto pysyväksi
        if ! mv -f "$tmp" "$dest"; then                           # vaihe 3: rename
          rm -f "$tmp"; job_apply "$id" '.status="failed"|.fail_reason="mv"|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
        elif ! sync_dir "$dest_dir"; then
          # vaihe 4 (renamen JÄLKEEN) epäonnistui: tiedosto on paikallaan mutta ei varmistettu →
          # ÄLÄ kirjoita done'ia → pending, uudelleenajo korvaa saman tiedoston idempotentisti (§2.5).
          job_apply "$id" '.status="pending"|.slot=null|.pid=null|.pgid=null|.starttime=null|.started=null' >/dev/null 2>&1
        else
          job_apply "$id" '.status="done"|.finished=(now|todate)|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
        fi
      fi
    else
      rm -f "$tmp"; job_apply "$id" '.status="failed"|.fail_reason="verify"|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
    fi
  else
    rm -f "$tmp"
    if [ "$tk" = true ]; then
      job_apply "$id" '.status="pending"|.thermal_kill=false|.slot=null|.pid=null|.pgid=null|.started=null' >/dev/null 2>&1   # lämpötappo → pending, ei failed (§8.2)
    elif [ "$skip" = true ]; then
      job_apply "$id" '.status="user_skip"|.finished=(now|todate)|.slot=null|.pid=null|.pgid=null' >/dev/null 2>&1
    else
      job_apply "$id" '.status="failed"|.fail_reason=$r|.slot=null|.pid=null|.pgid=null' --arg r "rc=$erc" >/dev/null 2>&1
    fi
  fi
}

# --- toipuminen (§4: neljä tapausta, slot-lukko totuutena) -------------------------------------
recover() {
  local p id slot pgid pgst
  for p in "$STATE/jobs"/*.json; do
    [ -e "$p" ] || continue
    [ "$(jq -r '.status' "$p")" = encoding ] || continue
    id=$(jq -r '.id' "$p"); slot=$(jq -r '.slot // empty' "$p")
    if [ -n "$slot" ] && slot_held "$slot"; then
      continue   # A: slot-lukko varattu → worker elää → älä koske
    fi
    # B/C/D: slot vapaa → worker kuollut. Reap orpo-enkooderi VAIN jos (pgid,starttime) yhä täsmää
    # (§4 identiteettitarkistus proc_alive_same) — muuten pgid-numero on voitu uudelleenkäyttää
    # (reboot/PID-reuse) ja tappaisi ulkopuolisen prosessin.
    pgid=$(jq -r '.pgid // empty' "$p"); pgst=$(jq -r '.pgid_starttime // empty' "$p")
    if [ -n "$pgid" ] && [ "$pgid" != null ] && proc_alive_same "$pgid" "$pgst"; then
      kill -TERM -"$pgid" 2>/dev/null
    fi
    rm -f "$(DEST_TMP)/$id.mkv"
    job_apply "$id" '.status="pending"|.slot=null|.pid=null|.pgid=null|.pgid_starttime=null|.starttime=null|.started=null' >/dev/null 2>&1
  done
}

# --- dispatch-pass & daemon -------------------------------------------------------------------
_next_pending_id() {  # pienin seq pending ensin (§8.1 sivuhuomio)
  local p; for p in "$STATE/jobs"/*.json; do [ -e "$p" ] || continue;
    jq -r 'select(.status=="pending")|"\(.seq) \(.id)"' "$p" 2>/dev/null; done | sort -n | head -1 | awk '{print $2}'
}
write_status() { _status_json --fast > "$STATE/status.json.t" 2>/dev/null && mv -f "$STATE/status.json.t" "$STATE/status.json"; }

# reserve_job <id> <slot> — atominen pending→encoding varaus (§2.6). Estää saman jobin
# kaksoiskäytön: kun tila on encoding, _next_pending_id ei enää palauta sitä.
reserve_job() {
  local id=$1 slot=$2
  job_apply "$id" \
    'if .status=="pending" then .status="encoding"|.slot=$slot else error("not_pending") end' \
    --argjson slot "$slot" >/dev/null 2>&1
}
_free_slot_excl() {  # ensimmäinen slot joka ei ole held EIKÄ used[] (this-pass) → tyhjä jos ei
  local -n _used=$1; local i
  for i in $(seq 1 "${CFG[PARALLEL_MAX]}"); do
    [ -n "${_used[$i]:-}" ] && continue
    slot_held "$i" && continue
    printf '%s' "$i"; return 0
  done
  return 1
}
dispatch_pass() {   # yksi täyttökierros: varaa jobeja + käynnistä workereita
  local -A used=(); local base assigned=0 id slot guard=0
  base=$(count_running)               # cross-pass käynnissä olevat (slot-lukot)
  while :; do
    guard=$((guard+1)); [ "$guard" -gt $(( ${CFG[PARALLEL_MAX]} * 4 + 4 )) ] && break  # turvakatto (ei fork-bombia)
    [ $(( base + assigned )) -lt "${CFG[PARALLEL]}" ] || break   # (1) < PARALLEL
    [ -f "$STATE/paused" ] && break                              # (4) pause
    _thermal_ok || break                                        # (3) lämpö
    num_ge "$(_free_bytes "${CFG[WORK_DIR]}")"  "$(gb_to_bytes "${CFG[RIP_MIN_FREE_GB]}")"  || break
    num_ge "$(_free_bytes "${CFG[DEST_ROOT]}")" "$(gb_to_bytes "${CFG[DEST_MIN_FREE_GB]}")" || break  # (2) tila
    id=$(_next_pending_id); [ -n "$id" ] || break
    slot=$(_free_slot_excl used) || break
    reserve_job "$id" "$slot" || continue        # ei enää pending (race) → seuraava
    used[$slot]=1; assigned=$((assigned+1))
    _launch_worker "$id" "$slot"
  done
  write_status
}
# _launch_worker <id> <slot> — käynnistä worker taustalle (stdio /dev/null: ei pidä kutsujan putkea).
# Erillinen funktio jotta testit voivat korvata sen (synkroninen/no-op) ilman taustaprosesseja.
_launch_worker() { ( worker_run "$1" "$2" ) >/dev/null 2>&1 & disown; }

cmd_dispatch() {
  local once=0; [ "${1-}" = --once ] && once=1
  # single-instance (§8.1)
  local pf="$STATE/dispatch.pid"
  exec {DFD}>>"$pf" || { err_out lock_timeout DISPATCH "$pf" "avattavissa"; return 1; }
  if ! flock -n "$DFD"; then err_out bad_state dispatch running "toinen dispatcher käynnissä jo"; return 1; fi
  recover
  if [ "$once" = 1 ]; then dispatch_pass; exec {DFD}>&-; return 0; fi
  trap 'exec {DFD}>&- 2>/dev/null; exit 0' TERM INT
  while true; do dispatch_pass; _ensure_backup_watchdog; sleep "${CFG[LOOP_INTERVAL]}"; done
}

# _ensure_backup_watchdog — §8.2 fail-safe (>6× vanhentuma): jos lämpövahdin heartbeat on ollut
# pysähdyksissä yli 6× pollausvälin (= erillinen vahti kuollut) JA heartbeat-tiedosto on olemassa
# (= vahti oli käytössä, ei pelkkä "ei koskaan otettu käyttöön"), dispatcher käynnistää MINIMAALISEN
# erillisen VARAVAHTIPROSESSIN — EI ota pollausta omaan silmukkaansa (§8.2 kohta 7). Fail-closed
# (uusia slotteja ei avata, may_open_slot) pysyy voimassa; varavahti hoitaa aktiivisen suojan
# käynnissä oleville. Vain tuotanto-daemonissa; brainbin-integraatiossa todennettava.
_ensure_backup_watchdog() {
  command -v thermal_heartbeat_age >/dev/null 2>&1 || return 0    # thermal.sh ei sourcattu (esim. testit)
  [ -f "$STATE/thermal.heartbeat" ] || return 0                   # vahtia ei otettu käyttöön → ei varaa
  [ "$(thermal_heartbeat_age)" -gt $(( ${CFG[LOOP_INTERVAL]} * 6 )) ] || return 0
  [ -n "${DVDQ_HOME:-}" ] || return 0                            # binäärin polku (dvdq-entry asettaa)
  # Varavahti on erillinen prosessi (oma sessio), joka RE-SOURCAA kirjastot (dvdq-binääri) ja pitää
  # thermal-backup.lockia koko elinaikansa. flock -n takaa yksikäsitteisyyden: jos varavahti jo elää,
  # lukko on varattu → uutta ei käynnisty. Poistuu itse kun päävahdin heartbeat tuoreutuu.
  setsid flock -n "$STATE/thermal-backup.lock" "$DVDQ_HOME/dvdq" thermal --backup >/dev/null 2>&1 & disown
}
