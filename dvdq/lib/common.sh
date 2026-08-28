#!/usr/bin/env bash
# dvdq/lib/common.sh — perusprimitiivit (§2 atomisuus/lukot/kestävyys, §5.3/§5.4 config, §6.1 virhekuori).
# Sourcattava kirjasto; ei aja mitään itse. Ei `set -e` (§8.1: pääsilmukka ei set -e:n alla).
# Kaikki spec-viitteet ovat UUSI_ARKKITEHTUURI_suunnitelma.md:hen.

set -u

# Locale: C.UTF-8 = C-NUMERIIKKA (desimaali AINA piste → awk/printf/jq oikein; Suomen pilkku rikkoisi
# esim. num_gt "58.7" "58.2" ja jq --argjson) + UTF-8-MERKISTÖ (Unicode-nimet ä/ö/日 käsitellään
# merkkeinä, ei rikota). Fallback C jos C.UTF-8 puuttuu (nimet silti läpinäkyviä tavuja → toimivat).
# Asetetaan skriptissä (ei riipu käynnistysympäristöstä, esim. systemd-daemonin niukka env).
_dvdq_u=$(locale -a 2>/dev/null | grep -iE '^C\.utf-?8$' | head -1)
export LC_ALL="${_dvdq_u:-C}"; unset _dvdq_u

# --- polut -------------------------------------------------------------------
# $STATE = paikallinen tilahakemisto (§3). Oletus johdetaan WORK_DIR:istä (config).
: "${DVDQ_CONFIG:=$HOME/.config/rip-dvd/config}"

# =============================================================================
# §6.1  Tulos-/virhekuori (koneluettava; totuus GUI:lle on stdoutin kuori)
# =============================================================================
# Vakaa virhekoodijoukko (§6.1): config_invalid source_missing id_exists id_not_found
#   bad_state dest_unwritable scan_failed disc_broken lock_timeout durability_failed
# jq-riippumaton: kuoret rakennetaan käsin, jotta virhekuori toimii myös jos jq puuttuu.

_json_str() {  # sanitoi merkkijono JSON-arvoksi (lainausmerkit, kenoviivat, kontrollit)
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}

ok_out() {   # ok_out '<raakoja json-kenttiä>'  → {"ok":true, ...}
  local extra=${1-}
  if [ -n "$extra" ]; then printf '{"ok":true,%s}\n' "$extra"; else printf '{"ok":true}\n'; fi
}

# err_out <code> [key] [got] [expected] [msg]  → {"ok":false,...} stdoutiin, rc=1
err_out() {
  local code=$1 key=${2-} got=${3-} expected=${4-} msg=${5-}
  local detail="{}"
  if [ -n "$key$got$expected" ]; then
    detail=$(printf '{"key":%s,"got":%s,"expected":%s}' \
      "$(_json_str "$key")" "$(_json_str "$got")" "$(_json_str "$expected")")
  fi
  printf '{"ok":false,"error":%s,"detail":%s}\n' "$(_json_str "$code")" "$detail"
  [ -n "$msg" ] && printf '%s\n' "$msg" >&2   # ihmisluettava teksti stderriin
  return 1
}

# =============================================================================
# §2.4  Numeeriset vertailut ja yksikkömuunnokset (ei desimaalia paljaaseen [ ]:iin)
# =============================================================================
num_ge() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a>=b)}'; }  # a >= b
num_gt() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a>b)}'; }   # a >  b
gb_to_bytes() { awk -v g="${1:-0}" 'BEGIN{printf "%.0f", g*1073741824}'; }  # GB → tavut

is_uint() { case ${1-} in ''|*[!0-9]*) return 1;; *) return 0;; esac; }     # ei-negat. kokonaisl.

# =============================================================================
# §5.3 / §5.4  Config: parsinta, oletukset, validointi
# =============================================================================
# Oletusarvo jokaiselle avaimelle (§5.4). Puuttuva config → kaikki oletukset,
# turvallinen minimikäytös PARALLEL=1.
declare -gA CFG_DEFAULTS=(
  [PARALLEL]=1            [PARALLEL_MAX]=4
  [CRF]=21               [ENCODER]=x265
  [AUDIO_POLICY]=original+commentary  [AUDIO_CODEC]=copy
  [SUB_POLICY]=all       [DEINTERLACE]=auto
  [DEST_ROOT]=/mnt/terastation/dlna/vids
  [DIR_MOVIES]=movies    [DIR_SERIES]=series  [DIR_DOCS]=documentaries
  [DIR_MUSIC]=music      [DIR_MISC]=misc
  [WORK_DIR]="$HOME/dvd-rip-tmp"
  [BACKUP_DIR]=/mnt/terastation/dlna/desync-backups
  [BACKUP_RETENTION_DAYS]=30  [SCAN_TTL_DAYS]=14
  [TEMP_WARN]=85         [TEMP_KILL]=95
  [MIN_DURATION]=300     [READ_ERROR_MAX]=20  [SCAN_TIMEOUT]=600
  [RIP_MIN_FREE_GB]=40   [DEST_MIN_FREE_GB]=20
  [RIP_AHEAD_MAX_GB]=60  [QUARANTINE_MAX_GB]=100
  [LOOP_INTERVAL]=5
)
declare -gA CFG=()   # ladatut arvot

# config_get KEY — lue yksi arvo tiedostosta (§5.3): sed-poiminta + sed-trailing-strip (ei extglob).
config_get() {
  local key=$1 val
  val=$(sed -n "s/^${key}=//p" "$DVDQ_CONFIG" 2>/dev/null | head -1)
  # trailing-whitespace + CR ankkuroituna perästä; alun välit säilyvät (esim. "DIR=/mnt/my movies")
  val=$(printf '%s' "$val" | sed 's/[[:space:]]*$//; s/\r$//')
  printf '%s' "$val"
}

# config_load — täytä CFG[] tiedostosta + oletuksista. Ei suorita tiedostoa (ei source).
config_load() {
  local key file_val
  for key in "${!CFG_DEFAULTS[@]}"; do
    if [ -f "$DVDQ_CONFIG" ]; then
      file_val=$(config_get "$key")
    else
      file_val=""
    fi
    if [ -n "$file_val" ]; then CFG[$key]=$file_val; else CFG[$key]=${CFG_DEFAULTS[$key]}; fi
  done
  # STATE johdetaan WORK_DIR:istä, aina paikallinen (§3)
  STATE="${CFG[WORK_DIR]}/state"
}

# --- validoinnin apurit ---
_in_set() { local v=$1; shift; local x; for x in "$@"; do [ "$v" = "$x" ] && return 0; done; return 1; }

# config_validate_common — AINA pakolliset (§5.4): tyypit, välit, ristiriidat. Ei NAS-statia.
# Palauttaa err_out + rc≠0 ensimmäisestä virheestä.
config_validate_common() {
  local k v
  # ei-negatiiviset kokonaisluvut
  for k in PARALLEL PARALLEL_MAX CRF BACKUP_RETENTION_DAYS SCAN_TTL_DAYS TEMP_WARN TEMP_KILL \
           MIN_DURATION READ_ERROR_MAX SCAN_TIMEOUT RIP_MIN_FREE_GB DEST_MIN_FREE_GB \
           RIP_AHEAD_MAX_GB QUARANTINE_MAX_GB LOOP_INTERVAL; do
    v=${CFG[$k]}
    is_uint "$v" || { err_out config_invalid "$k" "$v" "ei-negatiivinen kokonaisluku"; return 1; }
  done
  # PARALLEL_MAX >= 1
  is_uint "${CFG[PARALLEL_MAX]}" && [ "${CFG[PARALLEL_MAX]}" -ge 1 ] || {
    err_out config_invalid PARALLEL_MAX "${CFG[PARALLEL_MAX]}" ">=1"; return 1; }
  # PARALLEL 1..PARALLEL_MAX
  if [ "${CFG[PARALLEL]}" -lt 1 ] || [ "${CFG[PARALLEL]}" -gt "${CFG[PARALLEL_MAX]}" ]; then
    err_out config_invalid PARALLEL "${CFG[PARALLEL]}" "1..${CFG[PARALLEL_MAX]}"; return 1
  fi
  # CRF 0..51
  if [ "${CFG[CRF]}" -gt 51 ]; then
    err_out config_invalid CRF "${CFG[CRF]}" "0..51"; return 1
  fi
  # TEMP_WARN < TEMP_KILL, järkevä väli 40..110
  if [ "${CFG[TEMP_WARN]}" -lt 40 ] || [ "${CFG[TEMP_KILL]}" -gt 110 ] \
     || [ "${CFG[TEMP_WARN]}" -ge "${CFG[TEMP_KILL]}" ]; then
    err_out config_invalid TEMP_WARN "${CFG[TEMP_WARN]}/${CFG[TEMP_KILL]}" \
      "40<=TEMP_WARN<TEMP_KILL<=110"; return 1
  fi
  # enum-kentät
  _in_set "${CFG[ENCODER]}"      x265 x264            || { err_out config_invalid ENCODER "${CFG[ENCODER]}" "x265|x264"; return 1; }
  _in_set "${CFG[AUDIO_POLICY]}" original original+commentary all || { err_out config_invalid AUDIO_POLICY "${CFG[AUDIO_POLICY]}" "original|original+commentary|all"; return 1; }
  _in_set "${CFG[SUB_POLICY]}"   all none             || _sub_is_langlist "${CFG[SUB_POLICY]}" || { err_out config_invalid SUB_POLICY "${CFG[SUB_POLICY]}" "all|none|kielilista"; return 1; }
  _in_set "${CFG[DEINTERLACE]}"  auto off on          || { err_out config_invalid DEINTERLACE "${CFG[DEINTERLACE]}" "auto|off|on"; return 1; }
  # DIR_* suhteellisia (ei absoluuttisia) — halpa syntaksitarkistus, aina (§5.4)
  for k in DIR_MOVIES DIR_SERIES DIR_DOCS DIR_MUSIC DIR_MISC; do
    case ${CFG[$k]} in /*) err_out config_invalid "$k" "${CFG[$k]}" "suhteellinen polku"; return 1;; esac
  done
  return 0
}
_sub_is_langlist() { case ${1-} in ''|*[!a-z,]*) return 1;; *) return 0;; esac; }  # esim. fin,swe

# config_validate_writable — OPERAATIOKOHTAINEN (§5.4): vain kirjoittaville komennoille.
# Tekee NAS-statin → lukukomennot EIVÄT kutsu tätä (GUI-ystävällisyys).
config_validate_writable() {
  local d
  for d in "${CFG[WORK_DIR]}" "${CFG[DEST_ROOT]}"; do
    [ -d "$d" ] || { err_out dest_unwritable DIR "$d" "olemassa oleva hakemisto"; return 1; }
    [ -w "$d" ] || { err_out dest_unwritable DIR "$d" "kirjoitettavissa"; return 1; }
  done
  return 0
}

# =============================================================================
# §2.3  Lukot vain lokaalilla levyllä
# =============================================================================
lock_dir()  { printf '%s/locks'  "$STATE"; }
slots_dir() { printf '%s/slots'  "$STATE"; }

state_init_dirs() {   # luo paikalliset tilahakemistot (§3)
  local d
  for d in jobs jobs/done problematic scans locks slots; do
    mkdir -p "$STATE/$d" || return 1
  done
}

# with_lock <lockfile> <cmd...> — aja komento flockin sisällä (§2.3). Palauttaa cmd:n rc:n.
# __lfd on LOCAL: sisäkkäinen lukitus (esim. job-lukko → counters-lukko) ei saa ylikirjoittaa
# ulomman lukon fd-numeroa, muuten ulompi lukko jäisi vapauttamatta (→ lock_timeout).
with_lock() {
  local lf=$1; shift
  local __lfd   # tyhjä → bash allokoi uuden fd:n; local → ei sotke sisäkkäisiä kutsuja
  mkdir -p "$(dirname "$lf")" 2>/dev/null
  exec {__lfd}>>"$lf" || return 70
  if ! flock -w 30 "$__lfd"; then exec {__lfd}>&-; err_out lock_timeout LOCK "$lf" "vapautuu 30s"; return 75; fi
  "$@"; local rc=$?
  exec {__lfd}>&-   # sulkeminen vapauttaa flockin
  return $rc
}

# =============================================================================
# §2.2 / §2.5  Kanoninen guardattu + kestävä JSON-kirjoitus (fsync sisällä)
# =============================================================================
# sync-apurit (A4: tiedostolle `sync -d`, hakemistolle `sync` ilman -d).
sync_file() { sync -d "$1"; }
sync_dir()  { sync "$1"; }

# write_json_atomic <target>   (JSON tulee stdinistä)
# rc: 0 ok | 1 jq/tuottaja-virhe (target koskematon) | 2 data ei kestynyt (ennen mv, koskematon)
#     3 rename/dir ei kestynyt (target paikallaan mutta ei varmistettu)
write_json_atomic() {
  local target=$1 dir tmp
  dir=$(dirname "$target")
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  # validoi että syöte on ei-tyhjää ja kelvollista JSONia (jq jos on, muuten python3)
  if _json_validate >"$tmp" && [ -s "$tmp" ]; then
    sync_file "$tmp" || { rm -f "$tmp"; return 2; }   # data ei kestävä → EI mv:tä
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    sync_dir "$dir" || return 3                        # rename ei varmistettu → target paikallaan, rc=3
    return 0
  else
    rm -f "$tmp"; return 1
  fi
}
# _json_validate: lue stdin, kirjoita validoitu JSON stdoutiin, rc≠0 jos virheellinen.
_json_validate() {
  if command -v jq >/dev/null 2>&1; then jq -e . 2>/dev/null
  else python3 -c 'import sys,json; json.dump(json.load(sys.stdin),sys.stdout)' 2>/dev/null; fi
}

# =============================================================================
# §5.1  seqfile — flock-suojattu monotoninen jonojärjestysnumero
# =============================================================================
next_seq() {   # tulostaa seuraavan seq-numeron, atomisesti
  local sf="$STATE/seqfile"
  _seq_bump() {
    local cur; cur=$(cat "$sf" 2>/dev/null); is_uint "$cur" || cur=0
    local nxt=$((cur+1))
    printf '%s' "$nxt" > "$sf.t" && sync_file "$sf.t" && mv -f "$sf.t" "$sf" && sync_dir "$(dirname "$sf")"
    printf '%s\n' "$nxt"
  }
  with_lock "$(lock_dir)/seqfile.lock" _seq_bump
}
