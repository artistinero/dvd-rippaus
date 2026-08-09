#!/bin/bash
# rip-dvd.sh — Interaktiivinen DVD-rippaus ja enkoodaus
#
# Käyttö:
#   rip-dvd.sh                          Normaali rippaus + enkoodaus
#   rip-dvd.sh --encode-only <hakemisto> Enkoodaa olemassaoleva sessio uudelleen
#
# Vaatii: dvdbackup, HandBrakeCLI, lm-sensors, python3, flock (util-linux)

# -u  : viittaus asettamattomaan muuttujaan on virhe
# -o pipefail : putken viimeisin epäonnistumiskoodi näkyy — ei piilostu automaattisesti
# (ei -e koska monet komennot saavat palauttaa virheitä tarkoituksella, esim. pgrep)
set -uo pipefail
export TZ="Europe/Helsinki"

# ── Tmux-autostart ─────────────────────���──────────────────────────────────────
# Skripti vaatii tmux-session jotta prosessi jää eloon kun SSH-yhteys katkeaa.
# Jos tmux ei ole päällä, skripti käynnistää itsensä uudelleen tmux-session sisällä.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "--?" ]]; then
    OUTBASE="/home/keitsi/dvd-rip-tmp"
    cat <<'EOF'
Käyttö:
  rip-dvd.sh                           Normaali rippaus + enkoodaus
  rip-dvd.sh --encode-only <hakemisto>  Enkoodaa olemassaoleva sessio uudelleen
  rip-dvd.sh --help                    Tämä ohje

--encode-only on hyödyllinen kun bootti tai muu keskeytys katkaisee enkoodauksen.
Skripti ohittaa automaattisesti raidat jotka ovat jo terastationilla.

EOF
    echo "Olemassaolevat sessiot joissa on dvdbackup-dataa:"
    local_found=0
    for d in "$OUTBASE"/session_*/; do
        [[ -d "$d" ]] || continue
        if [[ -n "$(find "$d" -name "*.VOB" -size +10M 2>/dev/null | head -1)" ]]; then
            echo "  rip-dvd.sh --encode-only $d"
            local_found=1
        fi
    done
    (( local_found )) || echo "  (ei löydy)"
    exit 0
fi

_SESSION="dvd-rip"
[[ "${1:-}" == "--encode-only" ]] && _SESSION="dvd-encode"
if [[ -z "${TMUX:-}" ]]; then
    if tmux has-session -t "$_SESSION" 2>/dev/null; then
        # --encode-only-argumentit häviäisivät jos liityttäisiin olemassaolevaan sessioon
        if [[ "${1:-}" == "--encode-only" ]]; then
            echo "VIRHE: Sessio '$_SESSION' on jo käynnissä — --encode-only-argumentit häviäisivät."
            echo "Liity olemassaolevaan: tmux attach -t $_SESSION"
            echo "Tai tarkista: tmux ls"
            exit 1
        fi
        echo "Sessio '$_SESSION' on jo käynnissä — liitytään."
        exec tmux attach -t "$_SESSION"
    else
        exec tmux new-session -s "$_SESSION" "$0" "$@"
    fi
fi

# ── Globaalit muuttujat ───────────────────��───────────────────────────────────
OUTBASE="/home/keitsi/dvd-rip-tmp"          # Rippauksen väliaikaiset tiedostot
DEST_ROOT="/mnt/terastation/dlna/vids"       # Kohdehakemisto terastationilla
LOGFILE="/home/keitsi/logs/rip-dvd.log"       # Lokitiedosto (liitetään, ei ylikirjoiteta)
mkdir -p "$(dirname "$LOGFILE")"

# Lämpötilavalvonta (yksikkö: °C)
# TEMP_WARN:   HandBrakeCLI pysäytetään (SIGSTOP) kun tämä ylittyy
# TEMP_RESUME: HandBrakeCLI jatkaa (SIGCONT) kun lämpö on laskenut tähän
# TEMP_KILL:   HandBrakeCLI tapetaan välittömästi (SIGKILL) — CPU lähellä kriittistä 100°C
# Hystereeesi WARN→RESUME (85→50=35°C) estää nopean on/off-sykloinnin.
TEMP_WARN=85
TEMP_RESUME=50
TEMP_KILL=95

# Raidat alle tämän keston (sekunteina) ohitetaan enkoodauksessa.
# Tarkoitus: poistaa DVD:n menu-videot ja muut lyhyet "otsikot" jonosta.
MIN_DURATION=60

# Lukitustiedosto: varmistaa että vain yksi encode_session pyörii kerrallaan.
# flock-pohjainen lukitus on atominen ytimen tasolla — pgrep-tarkistus ei ole.
ENCODE_LOCKFILE="/tmp/rip-dvd-encode.lock"

# Aikakatkaisu dvdbackupille sekunteina. Normaali rippaus ~20 min — 2 h on ylikärsivällinen.
# Timeoutin jälkeen levy ohitetaan ja jatketaan seuraavaan tai enkoodaukseen.
RIP_TIMEOUT=7200
# Aikakatkaisu HandBrakelle per raita. 58 min jakso ~1 h, throttling voi pidentää 3–4 x.
ENC_TIMEOUT=14400
# Montako kertaa yritetään rippata uudelleen epäonnistumisen jälkeen (ei timeoutin jälkeen).
MAX_RIP_ATTEMPTS=2
# Minimitila brainbinillä enkoodauksen aikana — alle tämän pysäytetään.
ENC_SPACE_MIN_GB=3
# Enkoodausnopeusarvio jonon keston laskentaan: GB VOB-dataa tunnissa.
# 5 GB/h ≈ 58 min jakso (2 GB VOB) ~24 min — säädä jos todellisuus poikkeaa paljon.
ENCODE_SPEED_GB_PER_HOUR=5

# ── Apufunktiot ───────────────────────���───────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

NTFY_URL="http://127.0.0.1:4444/dvd-rippaus"

# Lähettää ntfy-ilmoituksen. Epäonnistuminen (esim. ntfy pois päältä) ei saa
# koskaan katkaista enkoodausta — siksi -m timeout ja || true.
notify() {
    local title="$1" msg="$2" prio="${3:-default}"
    curl -s -m 10 -d "$msg" \
        -H "Title: $title" \
        -H "Priority: $prio" \
        "$NTFY_URL" >/dev/null 2>&1 || log "  VAROITUS: ntfy-ilmoitus epäonnistui"
}
_wait_enter() {
    echo "" >&2
    echo "  Loki: $LOGFILE" >&2
    echo "  [Paina Enter sulkeaksesi — tai odota 60s]" >&2
    read -rt 60 < /dev/tty 2>/dev/null || true
}
die() {
    log "VIRHE: $*"
    _wait_enter
    exit 1
}
_exit_trap() {
    local rc=$?
    (( rc == 0 )) && return
    echo "" >&2
    echo "  *** Skripti kaatui odottamatta (exit $rc) ***" >&2
    _wait_enter
}
trap _exit_trap EXIT

# Palauttaa kaikkien lämpötila-antureiden maksimilukeman celsiusasteina.
# Jos sensors ei ole asennettu tai epäonnistuu, palauttaa 0 (= ei throttlausta).
# Käyttää sensors -j (JSON-muoto) ja käy rekursiivisesti läpi kaikki avain-arvoparit
# joiden avain alkaa "temp" ja loppuu "_input" — nämä ovat anturien nykyarvot.
get_temp() {
    command -v sensors &>/dev/null || { echo 0; return; }
    sensors -j 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
t = []
def w(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k.startswith('temp') and k.endswith('_input') and isinstance(v, float):
                t.append(v)
            else:
                w(v)
w(data); print(int(max(t)) if t else 0)"
}

# Taustaprosessi joka valvoo CPU-lämpötilaa enkoodauksen aikana.
# Pysäyttää HandBrakeCLI:n (SIGSTOP) kun lämpö ylittää TEMP_WARN.
# Jatkaa (SIGCONT) kun lämpö on laskenut TEMP_RESUME:n alle.
# Tappaa (SIGKILL) jos lämpö ylittää TEMP_KILL — tämä on viimeinen keino ennen
# CPU:n omaa suojasammutusta 100°C:ssa.
#
# KRIITTINEN HUOMIO: käyttää mapfile-taulukkoa pgrep:n tulokselle koska
# HandBrakeCLI saattaa pyöriä useampana prosessina. kill "$pid" ei toimi
# kun $pid sisältää useita rivejä — se epäonnistuu hiljaa. kill "${pids[@]}" toimii.
throttle_loop() {
    local paused=0
    while true; do
        sleep 10  # Tarkistusväli: 10s on riittävän nopea reagoimaan lämpöpiikkeihin
        local -a hb_pids
        mapfile -t hb_pids < <(pgrep -x HandBrakeCLI 2>/dev/null)
        local temp
        temp=$(get_temp)

        # Ei HandBrakeCLI-prosesseja — nollaa paussi-tila ja odota
        if (( ${#hb_pids[@]} == 0 )); then
            paused=0
            continue
        fi

        if (( temp >= TEMP_KILL )); then
            # Hätätilanne: lämpö kriittisen lähellä, tapa kaikki HandBrakeCLI-prosessit
            # SIGKILL ei voi olla estettynä eikä sitä voi sivuuttaa — prosessi kuolee välittömästi.
            # Tämä on parempi kuin koneen sammuminen ylikuumenemiseen.
            kill -KILL "${hb_pids[@]}" 2>/dev/null || true
            log "  HÄTÄSAMMUTUS: ${temp}°C ylittää TEMP_KILL=${TEMP_KILL}°C — HandBrakeCLI tapettu!"
            paused=0
        elif (( temp >= TEMP_WARN )) && (( paused == 0 )); then
            # Pysäytä kaikki HandBrakeCLI-prosessit — SIGSTOP ei voi olla estettynä
            kill -STOP "${hb_pids[@]}" 2>/dev/null || true
            paused=1
            log "  Throttle: paussi ${temp}°C (raja: ${TEMP_WARN}°C)"
        elif (( temp <= TEMP_RESUME )) && (( paused == 1 )); then
            # Jatka kaikki pysäytetyt HandBrakeCLI-prosessit
            kill -CONT "${hb_pids[@]}" 2>/dev/null || true
            paused=0
            log "  Throttle: jatkuu ${temp}°C (raja: ${TEMP_RESUME}°C)"
        fi
    done
}

# Muotoilee sekunnit ihmisluettavaan muotoon: "2h 35min" tai "47min"
fmt_time() {
    local s=$1
    local h=$(( s/3600 )) m=$(( (s%3600)/60 ))
    (( h > 0 )) && printf '%dh %dmin' "$h" "$m" || printf '%dmin' "$m"
}

# Varmistaa terastationin saatavuuden — yrittää mountata jos ei ole mountattu.
# Palauttaa 0 jos onnistui, 1 jos kaikki yritykset epäonnistuivat.
# Kutsuja päättää onko epäonnistuminen kohtalokas (die) vai ohitettava (continue/log).
ensure_terastation() {
    local mountpt="/mnt/terastation/dlna"
    mountpoint -q "$mountpt" && return 0
    local tries=5 try mount_out
    for (( try=1; try<=tries; try++ )); do
        log "Terastation ei mountattu — yritetään ($try/$tries)..."
        if ! mount_out=$(sudo mount "$mountpt" 2>&1); then
            mount_out=$(mount "$mountpt" 2>&1) || true
        fi
        if mountpoint -q "$mountpt"; then
            log "  Terastation mountattu."
            return 0
        fi
        [[ -n "$mount_out" ]] && log "  mount-virhe: ${mount_out}"
        (( try < tries )) && sleep 10
    done
    log "VIRHE: terastation ei saatu mountattua ${tries} yrityksellä"
    return 1
}

# Odottaa terastationia enintään max_secs sekuntia, yrittäen mountata 30s välein.
# Käytetään boottauksen jälkeen kun verkko tai NAS ei ole vielä valmis.
wait_for_terastation() {
    local max_secs="${1:-300}"
    local interval=30
    local elapsed=0
    ensure_terastation && return 0
    log "Terastation ei vielä saatavilla — odotetaan enintään $(( max_secs/60 )) min..."
    while (( elapsed < max_secs )); do
        sleep "$interval"
        (( elapsed += interval )) || true
        log "  Yritetään terastationia uudelleen (${elapsed}/${max_secs}s)..."
        ensure_terastation && return 0
    done
    return 1
}

# Ajaa HandBrakeCLI:n ja näyttää reaaliaikaisen edistymisprosentin.
# Parametrit:
#   $1 = lähde (dvdbackup-hakemisto tai MKV-tiedosto)
#   $2 = kohdetiedosto (.mkv)
#   $3 = otsikkonumero (tyhjä = automaattinen valinta)
#   $4 = tunniste edistymispalkkia varten (esim. "S03E01")
#
# Enkoodausasetukset:
#   x265 CRF 21  — hyvä laatu, kohtuullinen tiedostokoko
#   --all-audio copy  — kopioi kaikki ääniraidat sellaisenaan (ei transkooda)
#   --audio-fallback aac  — jos kopiointi ei onnistu, käytä AAC
#   --all-subtitles  — kopioi kaikki tekstitysraidat
#   --comb-detect --decomb  — älykkäs lomituksen poisto DVD-materiaalille
#   --loose-anamorphic --crop-mode auto  — säilyttää DVD:n kuvasuhteen oikein
#   </dev/null  — KRIITTINEN: estää HandBrakeCLI:tä lukemasta while-silmukan stdinistä
#                 (bash-bugi: silmukan sisällä ajetut ohjelmat perivät silmukan fd 0:n)
#
# Paluuarvo: HandBrakeCLI:n exit-koodi (PIPESTATUS[0]).
# Python3-prosessi lukee HandBrakeCLI:n stdout/stderr ja kirjoittaa lokiin.
# Jos python3 kaatuu, HandBrakeCLI saa SIGPIPE ja sen exit-koodi on epänolla.
run_hb() {
    local title_arg=()
    [[ -n "${3:-}" ]] && title_arg=(--title "$3")
    local label="${4:-}"

    # HandBrake kirjoittaa väliaikaistiedostoon — ei putkea, ei SIGPIPE-riskiä.
    # Python3 seuraa tiedostoa tail -f:llä erillisenä prosessina.
    # Python3:n kuolema ei vaikuta HandBrakeen millään tavalla.
    local tmpout; tmpout=$(mktemp --tmpdir "rip-dvd-hb-XXXXXX.log")

    HandBrakeCLI \
        --input "$1" "${title_arg[@]}" --output "$2" \
        --encoder x265 --quality 21 \
        --comb-detect --decomb \
        --loose-anamorphic --crop-mode auto \
        --all-audio --aencoder copy --audio-fallback aac \
        --all-subtitles --markers \
        </dev/null >"$tmpout" 2>&1 &
    local hb_pid=$!

    # Edistymispalkki — erillinen prosessi, ei riippuvainen HandBrakesta
    python3 -c '
import sys, re, subprocess
label, tmpout = sys.argv[1], sys.argv[2]
last_pct = -5.0
proc = subprocess.Popen(["tail", "-f", "-n", "0", tmpout],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
try:
    for raw in proc.stdout:
        m = re.search(rb"(\d+\.\d+) %.*ETA\s+(\S+)", raw)
        if m:
            pct = float(m.group(1))
            eta = m.group(2).decode("utf-8", errors="replace")
            if pct - last_pct >= 5.0:
                last_pct = pct
                sys.stdout.write(f"\r  [{label}] {pct:.1f}%  ETA {eta}")
                sys.stdout.flush()
except Exception:
    pass
finally:
    try: proc.terminate(); proc.wait()
    except Exception: pass
' "$label" "$tmpout" &
    local py_pid=$!

    local hb_waited=0 hb_timed_out=0
    while kill -0 "$hb_pid" 2>/dev/null; do
        sleep 10
        (( hb_waited += 10 )) || true
        if (( hb_waited >= ENC_TIMEOUT )); then
            kill -KILL "$hb_pid" 2>/dev/null || true
            hb_timed_out=1
            break
        fi
    done
    wait "$hb_pid" 2>/dev/null
    local rc=$?
    (( hb_timed_out )) && rc=124

    kill "$py_pid" 2>/dev/null
    wait "$py_pid" 2>/dev/null
    echo >&2

    # Lisää HandBraken output päälokiin: muunna \r → \n, poista tyhjät rivit ja
    # toistuvat prosenttirivit (kirjoitetaan lokiin vain 5% välein python3:lla aiemmin,
    # nyt pelkät \n-rivit riittävät — progress näkyy terminaalissa reaaliajassa).
    sed $'s/\r/\n/g' "$tmpout" | grep -v ' ETA ' | grep -v '^$' >> "$LOGFILE" || true
    rm -f "$tmpout"

    return "$rc"
}

# Odottaa kunnes /dev/sr1-asemassa on luettava levy.
# Käyttää dd:tä koska se on luotettavin tapa testata levyn luettavuus —
# toimii myös CSS-salatuilla levyillä (libdvdcss2 purkaa lennossa).
# Aseman osoite on kovakoodattu /dev/sr1 koska brainbinissä on kaksi asemaa
# ja FREECOM DVD+/-RW on aina sr1 (sr0 on sisäinen, ei käytetä).
wait_for_disc() {
    local dev="/dev/sr1"
    while ! dd if="$dev" count=1 bs=2048 of=/dev/null status=none 2>/dev/null; do
        sleep 10
    done
    echo "$dev"
}

# Skannaa DVD-hakemiston ja tulostaa niiden otsikoiden (title) numerot
# joiden kesto on vähintään MIN_DURATION sekuntia.
# Käytetään sekä rippausvaiheessa (TITLE_COUNT:n laskemiseen meta.conf:iin)
# että enkoodausvaiheen jonon rakentamisessa.
# HandBrake-skannaus kestää yleensä 5–15 sekuntia per levy.
hb_scan_long_titles() {
    local dvd_dir="$1"
    HandBrakeCLI -i "$dvd_dir" -t 0 --scan </dev/null 2>&1 | python3 -c "
import sys, re
min_dur = $MIN_DURATION
cur = None
for line in sys.stdin.buffer:
    line = line.decode('utf-8', errors='replace')
    m = re.search(r'scan: scanning title (\d+)', line)
    if m:
        cur = int(m.group(1))
    m2 = re.search(r'scan: duration is (\d+):(\d+):(\d+)', line)
    if m2 and cur is not None:
        h,mn,s = int(m2.group(1)), int(m2.group(2)), int(m2.group(3))
        dur = h*3600 + mn*60 + s
        if dur >= min_dur:
            print(cur)
        cur = None
"
}

# Rakentaa kohdepolun tiedostotyypistä riippuen.
# Terastationin hakemistorakenne:
#   series/       → Sarjat kausikohtaisiin kansioihin (Jellyfin tunnistaa automaattisesti)
#   movies/       → Elokuvat (nimi + vuosi)
#   documentaries/→ Dokumentit (nimi + vuosi)
#   Music videos/ → Musiikkivideot ja konsertit (nimi ilman vuotta)
#   misc/         → Muu materiaali
# Huom: "Music videos" isolla M:llä ja välilyönnillä — terastationilla olemassaoleva kansio.
dest_path() {
    local type="$1" name="$2" val="$3"
    case "$type" in
    series)  printf '%s/series/%s/Season %02d' "$DEST_ROOT" "$name" "$val" ;;
    movie)   [[ -n "$val" ]] && printf '%s/movies/%s (%s)'        "$DEST_ROOT" "$name" "$val" \
                             || printf '%s/movies/%s'             "$DEST_ROOT" "$name" ;;
    doc)     [[ -n "$val" ]] && printf '%s/documentaries/%s (%s)' "$DEST_ROOT" "$name" "$val" \
                             || printf '%s/documentaries/%s'      "$DEST_ROOT" "$name" ;;
    music)   printf '%s/music/%s'              "$DEST_ROOT" "$name" ;;
    misc)    printf '%s/movies/%s'             "$DEST_ROOT" "$name" ;;
    esac
}

# Korvaa tiedostojärjestelmissä kiellettyjä merkkejä viivalla.
# / on kriittisin (rikkoo polurakenteen), mutta SMB-levyllä myös muut merkit ovat kiellettyjä.
sanitize_name() {
    local n="$1"
    n="${n//\//-}"
    n="${n//\\/-}"
    n="${n//:/-}"
    n="${n//\*/-}"
    n="${n//\?/-}"
    n="${n//\"/-}"
    n="${n//</-}"
    n="${n//>/-}"
    n="${n//|/-}"
    printf '%s' "$n"
}

# ── Interaktiivinen metatietokysely per levy ──────────────────��───────────────
# Kysyy levyn tiedot (tyyppi, nimi, kausi/vuosi, jaksonumero) interaktiivisesti.
# Edellisen levyn arvot tarjotaan oletuksina hakasulkeissa.
# Palauttaa tuloksen \x1F-eroteltuna merkkijonona (ASCII unit separator).
# \x1F valittiin koska se ei esiinny laillisissa tiedostonimissä.
ask_meta() {
    local p_type="${1:-}" p_name="${2:-}" p_season="${3:-}" p_ep="${4:-}"
    echo "" >&2

    # Tyyppivalidointi silmukalla — hyväksyy vain tunnetut arvot
    local prompt="Tyyppi (series/movie/doc/music/misc)"
    [[ -n "$p_type" ]] && prompt+=" [$p_type]"
    local type=""
    while true; do
        read -rp "${prompt}: " type
        type="${type:-$p_type}"
        case "$type" in series|movie|doc|music|misc) break ;;
        *) echo "  → series, movie, doc, music tai misc" >&2 ;;
        esac
    done

    local name="" val="" ep=""

    case "$type" in
    series)
        local np="Sarja"
        [[ -n "$p_name" && "$p_type" == series ]] && np+=" [$p_name]"
        read -rp "${np}: " name; name="${name:-$p_name}"
        [[ -z "$name" ]] && { echo "  Nimi ei voi olla tyhjä." >&2; return 1; }

        local sp="Kausi"
        [[ -n "$p_season" && "$p_type" == series ]] && sp+=" [$p_season]"
        read -rp "${sp}: " val; val="${val:-$p_season}"
        [[ "$val" =~ ^[0-9]+$ ]] || { echo "  Kausiluku ei kelpaa: '$val'" >&2; return 1; }

        # Ehdota seuraavaa jaksoa: jos kausi vaihtui, katso terastation + jono.
        # Jos sama kausi kuin edellinen levy tässä sessiossa, käytä session-laskuria.
        local suggest=1
        if [[ -n "$p_ep" && "$p_type" == series && "$p_season" == "$val" ]]; then
            suggest="$p_ep"
        else
            # Terastation: suurin olemassaoleva jaksonumero + 1
            local _dd; _dd=$(dest_path series "$name" "$val")
            local _suggest_tera=0
            if [[ -d "$_dd" ]]; then
                _suggest_tera=$(find "$_dd" -maxdepth 1 -name "*.mkv" 2>/dev/null | python3 -c "
import sys, re
n = []
for line in sys.stdin:
    m = re.search(r'E(\d+)', line.strip())
    if m: n.append(int(m.group(1)))
print(max(n)+1 if n else 0)" 2>/dev/null || echo 0)
            fi
            # Jono: sessiot joita ei vielä terastationilla
            local _suggest_queue=0
            local _qmf
            for _qmf in "$OUTBASE"/session_*/disc-*/meta.conf; do
                [[ -f "$_qmf" ]] || continue
                local _qname _qseas _qep _qcount _qmax
                _qname=$(grep '^NAME='   "$_qmf" | cut -d= -f2-)
                _qseas=$(grep '^SEASON=' "$_qmf" | cut -d= -f2)
                [[ "$_qname" == "$name" && "$_qseas" == "$val" ]] || continue
                _qep=$(grep '^START_EP='    "$_qmf" | cut -d= -f2)
                _qcount=$(grep '^TITLE_COUNT=' "$_qmf" 2>/dev/null | cut -d= -f2 || echo 0)
                _qmax=$(grep '^MAX_EPISODES=' "$_qmf" 2>/dev/null | cut -d= -f2 || echo 0)
                (( _qmax > 0 && _qmax < _qcount )) && _qcount=$_qmax
                local _qend=$(( _qep + _qcount ))
                (( _qend > _suggest_queue )) && _suggest_queue=$_qend
            done
            suggest=$(( _suggest_tera > _suggest_queue ? _suggest_tera : _suggest_queue ))
            (( suggest < 1 )) && suggest=1
        fi
        read -rp "Ensimmäinen jakso tällä levyllä [$suggest]: " ep
        ep="${ep:-$suggest}"
        [[ "$ep" =~ ^[0-9]+$ ]] || { echo "  Jaksonumero ei kelpaa: '$ep'" >&2; return 1; }
        local max_ep=""
        read -rp "Montako jaksoa levyllä (Enter = kysy rippauksen jälkeen): " max_ep
        if [[ -n "$max_ep" ]]; then
            [[ "$max_ep" =~ ^[0-9]+$ ]] || { echo "  Ei kelpaa: '$max_ep'" >&2; return 1; }
        fi
        ;;

    movie|doc)
        local lbl; [[ "$type" == movie ]] && lbl="Elokuvan nimi" || lbl="Dokumentin nimi"
        [[ -n "$p_name" && "$p_type" == "$type" ]] && lbl+=" [$p_name]"
        read -rp "${lbl}: " name; name="${name:-$p_name}"
        [[ -z "$name" ]] && { echo "  Nimi ei voi olla tyhjä." >&2; return 1; }
        read -rp "Vuosi (Enter = tuntematon): " val
        if [[ -n "$val" ]] && ! [[ "$val" =~ ^[0-9]{4}$ ]]; then
            echo "  Vuosi ei kelpaa (4 numeroa, esim. 1977): '$val'" >&2; return 1
        fi
        ep=""
        ;;

    music)
        local np="Nimi (artisti / keikka / kokoelma)"
        [[ -n "$p_name" && "$p_type" == music ]] && np+=" [$p_name]"
        read -rp "${np}: " name; name="${name:-$p_name}"
        [[ -z "$name" ]] && { echo "  Nimi ei voi olla tyhjä." >&2; return 1; }
        val="" ep=""
        ;;

    misc)
        read -rp "Nimi: " name
        [[ -z "$name" ]] && { echo "  Nimi ei voi olla tyhjä." >&2; return 1; }
        val="" ep=""
        ;;
    esac

    name=$(sanitize_name "$name")
    [[ -z "$name" ]] && { echo "  Nimi tyhjeni sanitoinnin jälkeen — tarkista erikoismerkit" >&2; return 1; }
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s' "$type" "$name" "$val" "$ep" "${max_ep:-}"
}

# ── Enkoodausvaihe ───────────────────────���──────────────────────────��─────────
# Skannaa kaikki session-hakemiston levyt, rakentaa enkoodausjonon ja ajaa
# HandBrakeCLI:n jokaiselle raidalle.
# Siirtää valmiit tiedostot terastationille ja poistaa dvdbackup-lähteet
# VASTA kun kaikki raidat on varmistettu terastationilla (palautumisturva).
encode_session() {
    local session_dir="$1"

    # ── Yksittäisyyslukko ───���─────────────────────────────────────────────────
    # flock on atominen ytimen tasolla — pgrep-tarkistus ei ole.
    # Vanha pgrep-tarkistus epäonnistui kilpaehdon (race condition) takia:
    # molemmat sessiot saattoivat tarkistaa yhtä aikaa lyhyen välin aikana
    # jolloin HandBrakeCLI ei ollut käynnissä (siirtymä raidan vaihdossa).
    # Tulos: kaksi HandBrakeCLI-instanssia yhtä aikaa → CPU 100°C.
    exec 9>"$ENCODE_LOCKFILE"
    if ! flock -n 9; then
        log "  Enkoodausvuoro jonossa — odotetaan edellisen session valmistumista..."
        flock 9
        log "  Lukko saatu — aloitetaan enkoodaus"
    fi
    # fd 9 pysyy auki koko encode_session:n ajan. Lukko vapautuu automaattisesti
    # kun skripti päättyy (normaalisti tai virheeseen) koska fd sulkeutuu.

    log "═══ Enkoodausvaihe alkaa ═══"

    # Poista kesken jääneet .tmp-tiedostot — virransyötön tai kaatumisen jäänne.
    # Ilman tätä ne jäisivät ikuisesti enc_dir:iin tilaa viemään.
    find "$session_dir" -name "*.mkv.tmp" -delete 2>/dev/null || true

    # ── Levytilan tarkistus enkoodauksen alussa ──────────��────────────────────
    # Enkoodaus voi kestää tunteja — varmista ennen aloitusta että tilaa riittää.
    # df antaa väärän tuloksen jos terastation ei ole mountattu — varmista ensin.
    wait_for_terastation 600 || die "Terastation ei saatu mountattua 10 minuutin odotuksessa"
    local local_gb tera_gb
    local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    log "Tilaa: brainbin ${local_gb} GB vapaana, terastation ${tera_gb} GB vapaana"
    (( tera_gb < 5 )) && die "Terastationilla kriittisen vähän tilaa (${tera_gb} GB) — pysäytetään"
    (( tera_gb < 20 )) && log "VAROITUS: Terastationilla vain ${tera_gb} GB vapaana"

    # ── Esiskannaus: rakennetaan enkoodausjono tiedostoon ────────────────────
    # Jono tallennetaan tiedostoon (ei putkeen) koska sitä luetaan useaan kertaan:
    # 1) enkoodaussilmukassa, 2) lähdesiivousvaiheessa.
    # Erotin: \x1F (ASCII unit separator) koska se ei esiinny tiedostonimissä.
    # Kentät: dvd_dir|out_name|dest|title_num|disc_label|disc_seq
    local queue="${session_dir}/.queue"
    > "$queue"
    log "Skannataan levyt..."
    local disc_seq=1

    while IFS= read -r mf; do
        local raw_dir; raw_dir=$(dirname "$mf")
        local type name season ep rip_mode

        # Lue metatiedot — grep+cut siksi koska tiedoston rakenne on yksinkertainen
        # avain=arvo-muoto ilman lainausmerkkejä (ei turvallista sourcettavaksi)
        type=$(grep    '^TYPE='     "$mf" | cut -d= -f2-)
        name=$(grep    '^NAME='     "$mf" | cut -d= -f2-)
        season=$(grep  '^SEASON='   "$mf" | cut -d= -f2-)
        ep=$(grep      '^START_EP=' "$mf" | cut -d= -f2-)

        # TITLE_COUNT tallennettiin rippausvaiheessa — vertailua varten
        local expected_count; expected_count=$(grep '^TITLE_COUNT=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        # MAX_EPISODES: valinnainen, rajoittaa montako titteliä enkoodataan jaksoiksi.
        # Käytetään kun levy sisältää ekstroja jotka muuten saisivat väärän jaksonumeron.
        local max_episodes; max_episodes=$(grep '^MAX_EPISODES=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        local dest; dest=$(dest_path "$type" "$name" "$season")

        # Tarkista että dvdbackup-hakemisto on olemassa.
        # Jos ei ole, levy on joko ripattu epäonnistuneesti tai tämä on tyhjä sessio.
        local dvd_dir
        dvd_dir=$(find "${raw_dir}/dvdbackup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
        if [[ -z "$dvd_dir" ]]; then
            log "VIRHE: dvdbackup-hakemisto ei löydy — ${raw_dir##*/} (ohitetaan)"
            continue
        fi

        # Varoita jos tällä levyllä oli lukuvirheitä rippausvaiheessa
        local read_errors_stored; read_errors_stored=$(grep '^READ_ERRORS=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        [[ -n "$read_errors_stored" ]] && log "!!! HUONO LEVY: ${read_errors_stored} lukuvirhettä rippauksen aikana — tarkista lopputulos: ${raw_dir##*/} !!!"

        # Skannaa pitkät raidat HandBrakella (>=MIN_DURATION sekuntia)
        # Tämä on toinen skannaus — ensimmäinen tehtiin rippausvaiheessa TITLE_COUNT:lle.
        # Uusi skannaus tehdään jotta saadaan tarkat raita-numerot enkoodausta varten.
        local titles=()
        while IFS= read -r t; do titles+=("$t"); done < <(hb_scan_long_titles "$dvd_dir")
        (( ${#titles[@]} == 0 )) && { log "VAROITUS: ei enkoodattavia raitoja — ${raw_dir##*/}"; continue; }

        # Jaa raidat jaksoihin ja ekstraan MAX_EPISODES:in perusteella
        local ep_titles=() extra_titles=()
        if [[ -n "$max_episodes" ]] && (( max_episodes > 0 )) && (( ${#titles[@]} > max_episodes )); then
            ep_titles=("${titles[@]:0:$max_episodes}")
            extra_titles=("${titles[@]:$max_episodes}")
            log "  MAX_EPISODES=${max_episodes}: ${#ep_titles[@]} jaksoa + ${#extra_titles[@]} ekstraa (${raw_dir##*/})"
        else
            ep_titles=("${titles[@]}")
        fi

        # Vertaa skannauksen tulosta rippausvaiheessa tallennettuun arvoon
        local total_found=$(( ${#ep_titles[@]} + ${#extra_titles[@]} ))
        if [[ -n "$expected_count" ]] && (( total_found != expected_count )); then
            log "VAROITUS: odotettiin ${expected_count} raitaa, löytyi ${total_found} — ${raw_dir##*/}"
        fi

        # Rakenna jonorivi jaksoraidoille
        local i=1 total=${#ep_titles[@]}
        for t in "${ep_titles[@]}"; do
            local out_name
            case "$type" in
            series)
                out_name="${name} S$(printf '%02d' "$season")E$(printf '%02d' "$ep").mkv"
                ;;
            *)
                (( total==1 )) && out_name="${name}.mkv" \
                               || out_name="${name} - Part $(printf '%02d' "$i").mkv"
                ;;
            esac
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
                "$dvd_dir" "$out_name" "$dest" "$t" "${raw_dir##*/}" "$disc_seq" >> "$queue"
            [[ "$type" == series ]] && (( ep++ )) || true
            (( i++ )) || true
        done

        # Rakenna jonorivi ekstraraidoille
        # extra_num lasketaan terastationin olemassa olevista + jo jonossa olevista,
        # jotta extrat numeroituvat oikein eri sessioiden välillä.
        local _epat _n_tera _n_queue extra_num
        if [[ "$type" == series ]]; then
            _epat="${name} S$(printf '%02d' "$season") Extra"
        else
            _epat="${name} - Extra"
        fi
        _n_tera=$(find "$dest" -maxdepth 1 -name "${_epat} [0-9]*.mkv" 2>/dev/null | wc -l)
        _n_queue=$(grep -cF "${_epat}" "$queue" 2>/dev/null || true)
        extra_num=$(( _n_tera + _n_queue + 1 ))
        for t in "${extra_titles[@]}"; do
            local out_name
            case "$type" in
            series) out_name="${name} S$(printf '%02d' "$season") Extra $(printf '%02d' "$extra_num").mkv" ;;
            *)      out_name="${name} - Extra $(printf '%02d' "$extra_num").mkv" ;;
            esac
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
                "$dvd_dir" "$out_name" "$dest" "$t" "${raw_dir##*/}" "$disc_seq" >> "$queue"
            (( extra_num++ )) || true
        done
        (( disc_seq++ )) || true

    done < <(find "$session_dir" -name "meta.conf" | sort)

    local total_titles; total_titles=$(wc -l < "$queue")
    local total_discs=$(( disc_seq - 1 ))
    log "Jonossa $total_titles raitaa / $total_discs levyä enkoodattavana."
    (( total_titles == 0 )) && { log "Ei enkoodattavaa."; return; }

    # Pre-laskenta: montako raitaa per dvd_dir — levykohtaista siivousta varten
    declare -A _src_total=()
    local _qs="" _qo="" _qd="" _qt="" _ql="" _qn=""
    while IFS=$'\x1f' read -r _qs _qo _qd _qt _ql _qn; do
        _src_total["$_qs"]=$(( ${_src_total["$_qs"]:-0} + 1 ))
    done < "$queue"
    declare -A _src_done=()
    local _rep_ok=0 _rep_fail=()
    local _rep_start; _rep_start=$(date '+%Y-%m-%d %H:%M:%S')

    # Vapauta dvdbackup-hakemisto heti kun kaikki levyn raidat ovat terastationilla.
    # Näin tila vapautuu levykohtaisesti eikä vasta koko session lopussa.
    _cleanup_disc_if_done() {
        local _s="$1"
        _src_done["$_s"]=$(( ${_src_done["$_s"]:-0} + 1 ))
        if (( ${_src_done["$_s"]:-0} >= ${_src_total["$_s"]:-9999} )) && [[ -d "$_s" ]]; then
            rm -rf "$_s"
            log "  Siivottu lähde: ${_s##*/}"
        fi
    }

    # ── Enkoodaussilmukka ─────────────────────────────────────────────────────

    # Käynnistä lämpötilavalvonta taustalle
    throttle_loop &
    local tpid=$!

    # Siivoustoiminto jota kutsutaan sekä normaalissa poistumisessa että signaaleissa.
    # KRIITTINEN: jos throttle_loop on pysäyttänyt HandBrakeCLI:n (SIGSTOP) ja
    # skripti saa SIGINT/SIGTERM, HandBrakeCLI jäisi ikuisesti pysähtyneeksi ilman tätä.
    # SIGCONT on lähetettävä ennen skriptin poistumista.
    _encode_cleanup() {
        local -a _hb
        mapfile -t _hb < <(pgrep -x HandBrakeCLI 2>/dev/null)
        if (( ${#_hb[@]} > 0 )); then
            kill -CONT "${_hb[@]}" 2>/dev/null || true
            kill -TERM "${_hb[@]}" 2>/dev/null || true
        fi
        kill "$tpid" 2>/dev/null || true
        wait "$tpid" 2>/dev/null || true
        trap - INT TERM
    }
    trap "_encode_cleanup; exit 1" INT TERM

    local done_n=0 session_start; session_start=$(date +%s)
    local last_notify_ts=$session_start
    local enc_dir="${session_dir}/encoded"
    mkdir -p "$enc_dir"

    # Jonon muoto (6 kenttää, \x1F-erotettu):
    # dvd_dir | out_name | dest | title_num | disc_label | disc_seq
    while IFS=$'\x1f' read -r src out_name dest title_num disc_label disc_n; do
        (( done_n++ )) || true

        # Levytilan tarkistus ennen enkoodausta — parempi pysähtyä selkeästi kuin antaa
        # HandBraken epäonnistua myöhemmin ilman selkeää virheviestiä.
        local enc_free_gb
        enc_free_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
        if (( enc_free_gb < ENC_SPACE_MIN_GB )); then
            log "VIRHE: Brainbinillä kriittisen vähän tilaa (${enc_free_gb} GB < ${ENC_SPACE_MIN_GB} GB) — pysäytetään enkoodaus"
            break
        fi

        # ── Palautuminen ─────────────────────────────────────────────────────
        ensure_terastation || log "  VAROITUS: terastation ei saatavilla tarkistushetkellä — jatketaan"

        # Tarkistus 1: tiedosto on jo terastationilla — ohita
        if [[ -f "${dest}/${out_name}" ]] && \
           [[ $(stat -c%s "${dest}/${out_name}" 2>/dev/null || echo 0) -gt 1048576 ]]; then
            log "  Ohitetaan (jo valmis): ${out_name}"
            (( _rep_ok++ )) || true
            _cleanup_disc_if_done "$src"
            continue
        fi

        # Tarkistus 2: valmis tiedosto enc_dir:ssä edellisestä epäonnistuneesta siirrosta —
        # yritetään siirtoa ennen uudelleenenkoodausta (säästää tunnin työn).
        local _enc_out="${enc_dir}/${out_name}"
        if [[ -f "$_enc_out" ]] && \
           [[ $(stat -c%s "$_enc_out" 2>/dev/null || echo 0) -gt 1048576 ]]; then
            log "  Löytyi enc_dir:stä edelliseltä yritykseltä — yritetään siirtoa"
            mkdir -p "$dest" 2>/dev/null || true
            if mv "$_enc_out" "${dest}/"; then
                local _sz; _sz=$(du -sh "${dest}/${out_name}" 2>/dev/null | cut -f1 || echo "?")
                log "  ✓ ${out_name} (${_sz}) [siirretty uudelleenyrityksestä]"
                (( _rep_ok++ )) || true
                _cleanup_disc_if_done "$src"
                continue
            fi
            log "  Siirto epäonnistui edelleen — enkoodataan uudelleen"
            rm -f "$_enc_out"
        else
            # Siivoa mahdollinen vajaa/vioittunut enc_dir-tiedosto
            rm -f "${enc_dir}/${out_name}" "${enc_dir}/${out_name}.tmp"
        fi

        # ── Edistymisraportti ─────────────────────────────────────────────────
        echo "" >&2
        printf '  ╔══════════════════════════════════════════╗\n' >&2
        printf '  ║  Levy %d / %d  |  Raita %d / %d\n' "$disc_n" "$total_discs" "$done_n" "$total_titles" >&2
        printf '  ║  %s\n' "$out_name" >&2
        if (( done_n > 1 )); then
            local elapsed=$(( $(date +%s) - session_start ))
            # Keskiarvo perustuu VALMISTUNEISIIN raitoihin (done_n-1).
            # Ensimmäistä raitaa enkoodatessa ei näytetä ETAa koska näyte on liian pieni.
            local avg=$(( elapsed / (done_n - 1) ))
            local remaining=$(( total_titles - done_n + 1 ))
            local eta_secs=$(( avg * remaining ))
            printf '  ║  Kokonais-ETA: ~%s  (%d jäljellä)\n' "$(fmt_time "$eta_secs")" "$remaining" >&2
        fi
        printf '  ╚══════════════════════════════════════════╝\n' >&2
        log "Enkoodataan ($done_n/$total_titles): ${out_name} [${disc_label}]"

        # ── Enkoodaus ─────────────────────────────────────────────────────────
        local t_start; t_start=$(date +%s)
        local out="${enc_dir}/${out_name}.tmp"
        local src_sz; src_sz=$(du -sh "$src" 2>/dev/null | cut -f1 || echo "?")

        # Luo kohdepolku terastationilla — retry jos verkko katkaisi
        if ! mkdir -p "$dest"; then
            log "  Kohdepolun luonti epäonnistui — yritetään remountata..."
            ensure_terastation || { log "  VIRHE: terastation ei saatu mountattua — ohitetaan: ${out_name}"; continue; }
            mkdir -p "$dest" || { log "  VIRHE: kohdepolun luonti epäonnistui yrityksistä huolimatta: ${dest}"; continue; }
        fi

        # Odota viilentymistä ennen enkoodauksen aloitusta.
        # Kriittistä SIGKILL-tilanteen jälkeen: ilman tätä seuraava raita käynnistyisi
        # välittömästi vaikka CPU on edelleen ylikuumentunut.
        local _pre_temp; _pre_temp=$(get_temp)
        if (( _pre_temp > TEMP_RESUME )); then
            log "  Odotetaan viilentymistä ennen seuraavaa raitaa (${_pre_temp}°C > ${TEMP_RESUME}°C)..."
            while (( $(get_temp) > TEMP_RESUME )); do sleep 15; done
            log "  Lämpö laskenut ($(get_temp)°C) — aloitetaan enkoodaus"
        fi

        run_hb "$src" "$out" "$title_num" "$out_name"
        local rc=$?

        local t_secs=$(( $(date +%s) - t_start ))
        if (( rc == 0 )) && [[ -s "$out" ]]; then
            local sz; sz=$(du -sh "$out" | cut -f1)
            local final="${enc_dir}/${out_name}"
            # Atominen .tmp→final: varmistaa että kesken jäänyt enkoodaus ei jää
            # terastationille osittaisena tiedostona virransyötön tai kaatumisen jälkeen.
            mv "$out" "$final"
            if mv "$final" "${dest}/"; then
                log "  ✓ ${out_name} (${sz}, $(fmt_time "$t_secs"), lähde: ${src_sz})"
                (( _rep_ok++ )) || true
                _cleanup_disc_if_done "$src"
            else
                log "  Siirto epäonnistui — yritetään remountata..."
                if ensure_terastation && mkdir -p "$dest" && mv "$final" "${dest}/"; then
                    log "  ✓ ${out_name} (${sz}, $(fmt_time "$t_secs"), lähde: ${src_sz}) [siirto onnistui remountin jälkeen]"
                    (( _rep_ok++ )) || true
                    _cleanup_disc_if_done "$src"
                else
                    log "  VIRHE: siirto terastationille epäonnistui — ${out_name} jäi: ${final}"
                    log "         Aja --encode-only kun terastation on taas saatavilla (tiedosto enkoodataan uudelleen)"
                fi
            fi
        else
            rm -f "$out"
            local rc_note=""
            case "$rc" in
                124) rc_note=" (aikakatkaisu — HandBrake jumissa yli $(fmt_time "$ENC_TIMEOUT"))" ;;
                137) rc_note=" (SIGKILL — ylikuumeneminen)" ;;
                139) rc_note=" (SIGSEGV — HandBrake kaatui muistivirheeseen)" ;;
                141) rc_note=" (SIGPIPE)" ;;
                130) rc_note=" (SIGINT — keskeytys)" ;;
                  2) rc_note=" (HandBrake: ei löydettyä titteliä — korruptoitunut lähde?)" ;;
            esac
            log "  VIRHE: enkoodaus epäonnistui — ${out_name} (rc=${rc}${rc_note}, $(fmt_time "$t_secs"))"
            _rep_fail+=("${out_name}|rc=${rc}${rc_note}")
        fi

        # ── Määräaikaisraportti ntfy:hen (30 min välein) ────────────────────
        local _now_ts; _now_ts=$(date +%s)
        if (( _now_ts - last_notify_ts >= 1800 )); then
            local _elapsed=$(( _now_ts - session_start ))

            local _local_gb _tera_gb
            _local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
            _tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
            local _temp; _temp=$(get_temp)

            # ETA: keskiarvo tähän mennessä valmistuneista raidoista × jäljellä olevat
            local _remaining_n=$(( total_titles - done_n ))
            local _eta_line=""
            if (( done_n > 0 && _remaining_n > 0 )); then
                local _avg=$(( _elapsed / done_n ))
                _eta_line=$'\n'"ETA: ~$(fmt_time "$(( _avg * _remaining_n ))")"
            fi

            # Loppujono: kaikkien odottavien raitojen nimet
            local _queue_list="" _qname
            while IFS= read -r _qname; do
                [[ -z "$_qname" ]] && continue
                _queue_list+=$'\n- '"$_qname"
            done < <(tail -n +$((done_n + 1)) "$queue" | cut -d $'\x1f' -f2)
            [[ -z "$_queue_list" ]] && _queue_list=$'\n(jono tyhjä tämän raidan jälkeen)'

            notify "DVD-enkoodus käynnissä" \
"Levy ${disc_n}/${total_discs} — raita ${done_n}/${total_titles}
Nyt: ${out_name}
Kulunut: $(fmt_time "$_elapsed") — valmiit: ${_rep_ok}, virheet: ${#_rep_fail[@]}${_eta_line}
Tila: brainbin ${_local_gb} GB, terastation ${_tera_gb} GB — lämpötila ${_temp}°C
Jonossa (${_remaining_n}):${_queue_list}"
            last_notify_ts=$_now_ts
        fi

    done < "$queue"

    # ── Lähdesiivous: turvaverkko ─────────────────────────────────────────────
    # Normaalitilanteessa _cleanup_disc_if_done() on jo siivonnut levyt yksi kerrallaan.
    # Tämä lohko hoitaa mahdolliset jäänteet (esim. enkoodausvirheet joissa osa raidoista
    # puuttuu). Jos KAIKKI levyn raidat löytyvät terastationilta (> 0 tavua), lähde
    # poistetaan. Jos yksikin puuttuu, lähde säilytetään ja lokiin tulee varoitus.
    local -A _src_ok
    local _src _out _dest _t _l _n
    while IFS=$'\x1f' read -r _src _out _dest _t _l _n; do
        # Alusta avain "yes" ensimmäisellä kohdauksella
        [[ -z "${_src_ok[$_src]+x}" ]] && _src_ok["$_src"]="yes"
        # Jos raita puuttuu tai on täysin tyhjä, merkitse lähde säilytettäväksi
        if ! [[ -f "${_dest}/${_out}" ]] || \
           (( $(stat -c%s "${_dest}/${_out}" 2>/dev/null || echo 0) == 0 )); then
            _src_ok["$_src"]="no"
        fi
    done < "$queue"
    for _src in "${!_src_ok[@]}"; do
        if [[ "${_src_ok[$_src]}" == "yes" && -d "$_src" ]]; then
            rm -rf "$_src"
            log "  Siivottu lähde: ${_src##*/}"
        elif [[ "${_src_ok[$_src]}" == "no" ]]; then
            log "  VAROITUS: lähde säilytetään — raita(oja) puuttuu terastationilta: ${_src##*/}"
        fi
    done

    local total_secs=$(( $(date +%s) - session_start ))
    _encode_cleanup

    # Kirjoita enkoodausraportti — luetaan seuraavalla käynnistyskerralla
    {
        echo "STARTED=${_rep_start}"
        echo "FINISHED=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "OK=${_rep_ok}"
        echo "FAIL=${#_rep_fail[@]}"
        local _rf
        for _rf in "${_rep_fail[@]}"; do echo "FAIL_TITLE=${_rf}"; done
    } > "${session_dir}/.encode-report"

    # ── Loppuraportti ntfy:hen ────────────────────────────────────────────────
    local _fail_lines="" _rf
    for _rf in "${_rep_fail[@]}"; do _fail_lines+=$'\n'"- ${_rf}"; done
    local _prio="default"
    (( ${#_rep_fail[@]} > 0 )) && _prio="high"
    notify "DVD-enkoodausjono tyhjä ✓" \
"${_rep_ok} onnistui, ${#_rep_fail[@]} epäonnistui — $(fmt_time "$total_secs")${_fail_lines}" \
        "$_prio"

    log "═══ Enkoodaus valmis — yhteensä $(fmt_time "$total_secs") ═══"

    # Muistuta lukuvirhelevyistä session lopussa
    while IFS= read -r mf; do
        local errs; errs=$(grep '^READ_ERRORS=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        [[ -n "$errs" ]] && log "!!! TARKISTA LOPPUTULOS: $(grep '^NAME=' "$mf" | cut -d= -f2-) — ${errs} lukuvirhettä rippauksen aikana !!!"
    done < <(find "$session_dir" -name "meta.conf" | sort)
}

show_enc_status() {
    local _now; _now=$(date +%s)
    local _total_eta_secs=0

    # Kerää kaikki sessiot joissa on VOB-dataa
    local _sessions=()
    for _d in "$OUTBASE"/session_*/; do
        [[ -d "$_d" ]] || continue
        [[ -n "$(find "$_d" -name "*.VOB" -size +10M 2>/dev/null | head -1)" ]] || continue
        _sessions+=("$_d")
    done
    echo ""
    echo "  Enkoodausjono:"
    echo ""
    if (( ${#_sessions[@]} == 0 )); then
        echo "    (ei jonossa)"
        echo ""
        return
    fi

    # Kartta: tmux-panen vanhempi-PID → session-nimi
    declare -A _ps
    while IFS=' ' read -r _s _p; do
        [[ "$_s" == "dvd-rip" || "$_s" == "watchdog" ]] && continue
        _ps["$_p"]="$_s"
    done < <(tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null)

    for _d in "${_sessions[@]}"; do
        local _pid; _pid=$(pgrep -f "encode-only.*$(basename "$_d")" 2>/dev/null | head -1)
        local _is_running=0; [[ -n "$_pid" ]] && _is_running=1

        # Kerää kaikki uniikit nimet + sarjatiedot kaikista levyistä sessiossa
        local _all_names=() _season="" _ep_start="" _ep_end="" _disc_count=0 _is_series=0
        for _dmf in "$_d"disc-*/meta.conf; do
            [[ -f "$_dmf" ]] || continue
            local _dt; _dt=$(grep '^TYPE='   "$_dmf" 2>/dev/null | cut -d= -f2)
            local _dn; _dn=$(grep '^NAME='   "$_dmf" 2>/dev/null | cut -d= -f2-)
            if [[ -n "$_dn" ]]; then
                local _dup=0
                for _ex in "${_all_names[@]}"; do [[ "$_ex" == "$_dn" ]] && { _dup=1; break; }; done
                (( _dup )) || _all_names+=("$_dn")
            fi
            [[ "$_dt" == "series" ]] || continue
            _is_series=1
            (( _disc_count++ )) || true
            local _ds; _ds=$(grep '^SEASON='      "$_dmf" 2>/dev/null | cut -d= -f2)
            [[ -z "$_season" ]] && _season="$_ds"
            local _dep;  _dep=$(grep '^START_EP='    "$_dmf" 2>/dev/null | cut -d= -f2)
            local _dcnt; _dcnt=$(grep '^TITLE_COUNT=' "$_dmf" 2>/dev/null | cut -d= -f2)
            local _dmax; _dmax=$(grep '^MAX_EPISODES=' "$_dmf" 2>/dev/null | cut -d= -f2)
            [[ -n "$_dmax" && -n "$_dcnt" ]] && (( _dmax > 0 && _dcnt > _dmax )) && _dcnt=$_dmax
            [[ -z "$_dep" || -z "$_dcnt" ]] && continue
            [[ -z "$_ep_start" || "$_dep" -lt "$_ep_start" ]] && _ep_start=$_dep
            local _dend=$(( _dep + _dcnt - 1 ))
            [[ -z "$_ep_end" || "$_dend" -gt "$_ep_end" ]] && _ep_end=$_dend
        done

        # Rakenna sisältöotsikko
        local _content_lbl
        if (( ${#_all_names[@]} > 1 )); then
            # Useita eri teoksia — lista kaikki
            _content_lbl="${_all_names[0]}"
            for (( _i=1; _i<${#_all_names[@]}; _i++ )); do
                _content_lbl+=" / ${_all_names[$_i]}"
            done
        elif (( ${#_all_names[@]} == 1 )); then
            _content_lbl="${_all_names[0]}"
            if (( _is_series )); then
                [[ -n "$_season" ]] && _content_lbl+=" S${_season}"
                if [[ -n "$_ep_start" && -n "$_ep_end" ]]; then
                    if (( _ep_start == _ep_end )); then
                        _content_lbl+=" E$(printf '%02d' "$_ep_start")"
                    else
                        _content_lbl+=" E$(printf '%02d' "$_ep_start")-E$(printf '%02d' "$_ep_end")"
                    fi
                    (( _disc_count > 1 )) && _content_lbl+=" (${_disc_count} levyä)"
                fi
            fi
        else
            _content_lbl="$(basename "$_d")"
        fi

        # VOB-koko GB (keston arviointi)
        local _vob_bytes; _vob_bytes=$(du -sb "$_d"disc-*/dvdbackup/ 2>/dev/null \
            | awk '{s+=$1} END {print (s ? s : 0)}')
        local _vob_gb; _vob_gb=$(awk "BEGIN {printf \"%.3f\", ${_vob_bytes}/1073741824}")

        # Laske arvioitu jäljellä oleva aika tälle sessiolle
        local _session_eta=0 _hb_status="" _hb_eta_secs=0

        if (( _is_running )); then
            # Lue HandBraken nykyinen edistyminen tmux-panesta
            local _pp; _pp=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
            local _tsess="${_ps[$_pp]:-}"
            if [[ -n "$_tsess" ]]; then
                _hb_status=$(tmux capture-pane -t "$_tsess" -p 2>/dev/null \
                    | grep -oE '\[.+\] [0-9]+\.[0-9]+%.*ETA [0-9hms]+' \
                    | tail -1 | sed 's/^[[:space:]]*//')
            fi
            # Jäsennetään ETA muotoa "ETA 1h23m45s" / "ETA 23m45s" / "ETA 45s"
            if [[ "$_hb_status" =~ ETA[[:space:]]+([0-9]+h)?([0-9]+m)?([0-9]+s)? ]]; then
                local _hv="${BASH_REMATCH[1]%h}" _mv="${BASH_REMATCH[2]%m}" _sv="${BASH_REMATCH[3]%s}"
                _hb_eta_secs=$(( ${_hv:-0}*3600 + ${_mv:-0}*60 + ${_sv:-0} ))
            fi

            # Laske jäljellä olevat raidat .queue-tiedostosta
            local _q="${_d}.queue"
            local _total_q=0 _done_q=0
            local _qsrc="" _qoname="" _qdst="" _qtnum="" _qdlbl="" _qdseq=""
            if [[ -f "$_q" ]]; then
                _total_q=$(wc -l < "$_q")
                while IFS=$'\x1f' read -r _qsrc _qoname _qdst _qtnum _qdlbl _qdseq; do
                    [[ -f "${_qdst}/${_qoname}" ]] && \
                    [[ $(stat -c%s "${_qdst}/${_qoname}" 2>/dev/null || echo 0) -gt 1048576 ]] && \
                    (( _done_q++ )) || true
                done < "$_q"
            fi
            local _remaining=$(( _total_q > _done_q ? _total_q - _done_q : 0 ))

            # Per-raita-arvio VOB-koosta
            local _per_secs=0
            if (( _total_q > 0 )); then
                _per_secs=$(awk "BEGIN {print int(${_vob_gb}/${ENCODE_SPEED_GB_PER_HOUR}*3600/${_total_q})}")
            fi

            if (( _hb_eta_secs > 0 && _remaining > 1 )); then
                _session_eta=$(( _hb_eta_secs + (_remaining - 1) * _per_secs ))
            elif (( _hb_eta_secs > 0 )); then
                _session_eta=$_hb_eta_secs
            elif (( _remaining > 0 && _per_secs > 0 )); then
                _session_eta=$(( _remaining * _per_secs ))
            else
                # .queue ei vielä olemassa (odottaa flock-lukkoa) — laske VOB-koosta
                _session_eta=$(awk "BEGIN {print int(${_vob_gb}/${ENCODE_SPEED_GB_PER_HOUR}*3600)}")
            fi
        else
            # Jonossa: arvio pelkästä VOB-koosta
            _session_eta=$(awk "BEGIN {print int(${_vob_gb}/${ENCODE_SPEED_GB_PER_HOUR}*3600)}")
        fi

        (( _session_eta < 0 )) && _session_eta=0
        _total_eta_secs=$(( _total_eta_secs + _session_eta ))

        # Tulosta rivi
        local _pfx
        if (( _is_running )); then _pfx="▶ enkoodataan"; else _pfx="  jonossa   "; fi
        printf '    %s  %s\n' "$_pfx" "$_content_lbl"
        [[ -n "$_hb_status" ]] && printf '                 %s\n' "$_hb_status"
        if (( _session_eta > 0 )); then
            printf '                 Arvio: ~%s\n' "$(fmt_time "$_session_eta")"
        fi
    done

    unset _ps

    # Yhteenveto
    if (( _total_eta_secs > 0 )); then
        local _finish=$(( _now + _total_eta_secs ))
        local _fin_str; _fin_str=$(date -d "@${_finish}" '+%a %-d.%-m. klo %H:%M')
        echo ""
        printf '  Kokonaisaika: ~%s  |  Valmis arviolta: %s\n' \
            "$(fmt_time "$_total_eta_secs")" "$_fin_str"
    fi
    echo ""
}

show_recent_reports() {
    local _any=0
    for _d in "$OUTBASE"/session_*/; do
        local _r="${_d}.encode-report"
        [[ -f "$_r" ]] || continue
        local _ok _fail _finished
        _ok=$(grep '^OK='       "$_r" 2>/dev/null | cut -d= -f2)
        _fail=$(grep '^FAIL='   "$_r" 2>/dev/null | cut -d= -f2)
        _finished=$(grep '^FINISHED=' "$_r" 2>/dev/null | cut -d= -f2-)

        # Kerää uniikit nimet sessiosta
        local _names=()
        for _mf in "${_d}"disc-*/meta.conf; do
            [[ -f "$_mf" ]] || continue
            local _n; _n=$(grep '^NAME=' "$_mf" 2>/dev/null | cut -d= -f2-)
            [[ -z "$_n" ]] && continue
            local _dup=0
            for _e in "${_names[@]}"; do [[ "$_e" == "$_n" ]] && { _dup=1; break; }; done
            (( _dup )) || _names+=("$_n")
        done
        local _lbl
        if (( ${#_names[@]} == 0 )); then
            _lbl="$(basename "$_d")"
        elif (( ${#_names[@]} == 1 )); then
            _lbl="${_names[0]}"
        else
            _lbl="${_names[0]} + $((${#_names[@]}-1)) muuta"
        fi

        (( _any++ )) || true
        local _total=$(( ${_ok:-0} + ${_fail:-0} ))
        local _date="${_finished%% *}"

        if [[ "${_fail:-0}" == "0" ]]; then
            printf '  ✓ %-42s %d/%d OK  [%s]\n' "$_lbl" "$_total" "$_total" "$_date"
        else
            printf '  ✗ %-42s %d/%d OK, %d epäonnistui  [%s]\n' \
                "$_lbl" "${_ok:-0}" "$_total" "${_fail:-0}" "$_date"
            local _ft _title _reason
            while IFS='|' read -r _title _reason; do
                printf '      ✗ %s\n' "$_title"
                [[ -n "$_reason" ]] && printf '        %s\n' "${_reason# }"
            done < <(grep '^FAIL_TITLE=' "$_r" | sed 's/^FAIL_TITLE=//')
        fi
    done
    if (( _any > 0 )); then
        echo ""
    fi
}

# ── Pääohjelma ──────────��─────────────────────────────────────────────────────

main() {
    # --encode-only: ohita rippausvaihe, enkoodaa olemassaoleva session-hakemisto.
    # Hyödyllinen palautumiseen: jos enkoodaus katkesi (virta, ylikuumeneminen),
    # aloita enkoodaus uudelleen ilman uudelleenrippaamista.
    # Palautumislogiikka (encode_session) ohittaa raidat jotka ovat jo terastationilla.
    if [[ "${1:-}" == "--encode-only" ]]; then
        local enc_dir="${2:-}"
        [[ -z "$enc_dir" ]] && die "--encode-only vaatii session-hakemiston polun"
        [[ -d "$enc_dir" ]]  || die "Hakemisto ei löydy: $enc_dir"
        ensure_terastation || die "Terastation ei saatu mountattua"
        command -v HandBrakeCLI &>/dev/null || die "HandBrakeCLI ei löydy"
        log "═══ Enkoodaus-only: ${enc_dir##*/} ═══"
        encode_session "$enc_dir"
        log "═══ Kaikki valmis! ═══"
        return
    fi

    mkdir -p "$OUTBASE"
    log "═══ DVD-rippaus käynnistyy ═══"

    # Tarkista onko sessioita — käynnissä tai odottavia
    local running_enc=() pending=()
    for d in "$OUTBASE"/session_*/; do
        [[ -d "$d" ]] || continue
        [[ -n "$(find "$d" -name "*.VOB" -size +10M 2>/dev/null | head -1)" ]] || continue
        if pgrep -f "encode-only.*$(basename "$d")" > /dev/null 2>&1; then
            running_enc+=("$d")
        else
            pending+=("$d")
        fi
    done
    show_recent_reports
    show_enc_status
    if (( ${#pending[@]} > 0 )); then
        echo ""
        echo "  Löytyi ${#pending[@]} sessio(ta) enkoodaamattomalla datalla:"
        for d in "${pending[@]}"; do echo "    ${d##*/}"; done
        echo ""
        local enc_ok=""
        read -rp "  Käynnistetäänkö enkoodaus taustalle? (k/e): " enc_ok </dev/tty
        if [[ "$enc_ok" == "k" ]]; then
            for d in "${pending[@]}"; do
                local sname; sname="enc-$(basename "$d" | sed 's/session_//')"
                if pgrep -f "encode-only.*$(basename "$d")" > /dev/null 2>&1; then
                    log "  $(basename "$d") enkoodataan jo — ohitetaan"
                elif tmux has-session -t "$sname" 2>/dev/null; then
                    log "  $sname on jo käynnissä — ohitetaan"
                else
                    tmux new-session -d -s "$sname" "bash /usr/local/bin/rip-dvd.sh --encode-only '$d'"
                    log "  Käynnistettiin enkoodaussessio: $sname"
                fi
            done
            echo ""
        fi
    fi

    # Varmista riippuvuudet ja levytila — vasta enkoodaustilanteen näyttämisen jälkeen
    ensure_terastation || die "Terastation ei saatu mountattua"
    command -v HandBrakeCLI &>/dev/null || die "HandBrakeCLI ei löydy"
    command -v dvdbackup   &>/dev/null || die "dvdbackup ei löydy — asenna: apt install dvdbackup"

    local local_gb tera_gb
    local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    log "Tilaa: brainbin ${local_gb} GB vapaana, terastation ${tera_gb} GB vapaana"
    (( local_gb < 14 )) && log "VAROITUS: Brainbinillä vain ${local_gb} GB — tilaa ehkä vain yhdelle levylle"
    (( local_gb <  8 )) && die "Brainbinillä ei riitä tilaa (${local_gb} GB) — pysäytetään"
    (( tera_gb  < 20 )) && log "VAROITUS: Terastationilla vain ${tera_gb} GB vapaana"
    (( tera_gb  <  5 )) && die "Terastationilla kriittisen vähän tilaa (${tera_gb} GB) — pysäytetään"

    # Session-hakemisto: yksi sessio = yksi käyttökerta (useita levyjä)
    local session_dir="${OUTBASE}/session_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$session_dir"

    # Edellisen levyn metatiedot oletuksina seuraavalle — käyttäjän ei tarvitse
    # kirjoittaa sarjan nimeä ja kautta uudelleen joka levylle
    local p_type="" p_name="" p_season="" p_ep="" p_max_ep=""
    local disc_num=0

    # ── Rippaussilmukka: lisää levyjä kunnes käyttäjä kirjoittaa 'q' ─────────
    while true; do
        echo ""
        echo "══════════════���═══════════════════════════════"
        printf '  Levyjä ripattuna tässä sessiossa: %d\n' "$disc_num"
        echo "══════════════════════════════════════════════"
        local cmd=""
        read -rp "  Lisää levy ja paina Enter  (q = lopeta rippaus): " cmd
        [[ "${cmd,,}" == "q" ]] && break

        # Kysy levyn metatiedot — palaa \x1F-eroteltuna merkkijonona
        local meta_str
        meta_str=$(ask_meta "$p_type" "$p_name" "$p_season" "$p_ep")
        IFS=$'\x1f' read -r p_type p_name p_season p_ep p_max_ep <<< "$meta_str"
        [[ -z "$p_name" ]] && continue  # ask_meta palautti virhe (esim. tyhjä nimi)

        # Näytä yhteenveto ja pyydä vahvistus
        echo ""
        case "$p_type" in
        series) printf '  → %s S%02d alkaen E%02d\n' "$p_name" "$p_season" "$p_ep" ;;
        movie)  printf '  → Elokuva: %s (%s)\n'      "$p_name" "$p_season" ;;
        doc)    printf '  → Dokumentti: %s (%s)\n'   "$p_name" "$p_season" ;;
        music)  printf '  → Musiikki: %s\n'          "$p_name" ;;
        misc)   printf '  → Misc: %s\n'              "$p_name" ;;
        esac

        local ok=""
        read -rp "  Oikein? (k/e=peruuta): " ok
        if [[ "${ok,,}" == "e" ]]; then p_name=""; continue; fi

        # ── Terastationin päällekkäisyystarkistus ────────────────────────────
        # Varoittaa jos kohdepolulla on jo tiedostoja — ehkäisee vahingollisen ylikirjoituksen.
        # Sarjoille tarkistetaan enintään 50 seuraavaa jaksoa.
        local tera_dest
        tera_dest=$(dest_path "$p_type" "$p_name" "${p_season:-}")
        if [[ -d "$tera_dest" ]]; then
            local tera_existing=()
            if [[ "$p_type" == series ]]; then
                local _ce; _ce="$p_ep"
                while (( _ce < p_ep + 50 )); do
                    local _fn="${p_name} S$(printf '%02d' "$p_season")E$(printf '%02d' "$_ce").mkv"
                    [[ -f "${tera_dest}/${_fn}" ]] && tera_existing+=("$_fn")
                    (( _ce++ ))
                done
            else
                while IFS= read -r _f; do tera_existing+=("${_f##*/}"); done \
                    < <(find "$tera_dest" -maxdepth 1 -name "*.mkv" 2>/dev/null | sort)
            fi
            if (( ${#tera_existing[@]} > 0 )); then
                echo "" >&2
                echo "  HUOMIO: Terastationilla on jo tiedostoja:" >&2
                for _ef in "${tera_existing[@]}"; do echo "    ${_ef}" >&2; done
                local over_ok=""
                read -rp "  Ripataanko silti? (k/e): " over_ok
                [[ "${over_ok,,}" != "k" ]] && continue
            fi
        fi

        # ── Päällekkäisyystarkistus: tämä sessio + kaikki jonossa olevat ────────
        # Varoittaa jos jokin aiempi levy (tässä tai toisessa sessiossa) kattaa
        # samat jaksot — myös jos ne ovat vain jonossa eivätkä vielä terastationilla.
        if [[ "$p_type" == series ]]; then
            local prev_mf
            for prev_mf in "${session_dir}"/disc-*/meta.conf \
                           "$OUTBASE"/session_*/disc-*/meta.conf; do
                [[ -f "$prev_mf" ]] || continue
                local prev_name prev_season prev_ep prev_count
                prev_name=$(grep '^NAME=' "$prev_mf" | cut -d= -f2-)
                prev_season=$(grep '^SEASON=' "$prev_mf" | cut -d= -f2-)
                prev_ep=$(grep '^START_EP=' "$prev_mf" | cut -d= -f2-)
                prev_count=$(grep '^TITLE_COUNT=' "$prev_mf" 2>/dev/null | cut -d= -f2 || echo 0)
                local prev_max_ep; prev_max_ep=$(grep '^MAX_EPISODES=' "$prev_mf" 2>/dev/null | cut -d= -f2 || echo 0)
                (( prev_max_ep > 0 && prev_max_ep < prev_count )) && prev_count=$prev_max_ep
                if [[ "$prev_name" == "$p_name" && "$prev_season" == "$p_season" ]] \
                   && (( p_ep < prev_ep + prev_count )); then
                    echo "" >&2
                    echo "  VAROITUS: Päällekkäisyys! Aiempi levy alkaa E${prev_ep} ja kattaa ${prev_count} raitaa." >&2
                    echo "  Tämä levy alkaa E${p_ep} — E$(( prev_ep + prev_count - 1 )) tulee kahdesti." >&2
                    local confirm=""
                    read -rp "  Jatketaanko silti? (k/e): " confirm
                    [[ "${confirm,,}" != "k" ]] && continue 2
                fi
            done
        fi

        # Levytilan tarkistus ennen jokaista levyä
        local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
        tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
        (( local_gb <  8 )) && die "Brainbinillä ei riitä tilaa (${local_gb} GB) — pysäytetään"
        (( tera_gb  <  5 )) && die "Terastationilla kriittisen vähän tilaa (${tera_gb} GB) — pysäytetään"
        log "Levy $((disc_num+1)): $p_type | $p_name | $p_season | ep=$p_ep"

        echo "  Odotetaan levyasemaa..."
        local disc_dev; disc_dev=$(wait_for_disc)

        (( disc_num++ ))
        local raw_dir="${session_dir}/disc-$(printf '%03d' "$disc_num")"
        mkdir -p "$raw_dir"

        # Kirjoita meta.conf heti kaikilla tunnetuilla kentillä.
        # RIP_MODE kirjoitetaan tässä (ei vasta onnistuneen rippauksen jälkeen)
        # koska skripti käyttää nyt AINA dvdbackup-tilaa. Aiempi ratkaisu (RIP_MODE
        # lisättiin myöhemmin) rikkoi recover-tilanteen: jos skripti kaatui rippauksen
        # aikana, meta.conf:ssa ei ollut RIP_MODE:a ja encode_session ei löytänyt dvdbackup-hakemistoa.
        {
            echo "TYPE=${p_type}"
            echo "NAME=${p_name}"
            echo "SEASON=${p_season}"
            echo "START_EP=${p_ep}"
            echo "RIP_MODE=dvdbackup"
            [[ -n "$p_max_ep" ]] && echo "MAX_EPISODES=${p_max_ep}"
        } > "${raw_dir}/meta.conf"

        log "Ripataan disc ${disc_num} dvdbackupilla (${disc_dev})..."
        local rip_log="${raw_dir}/rip.log"
        local dv_dir="${raw_dir}/dvdbackup"
        mkdir -p "$dv_dir"

        # Levyn kokonaiskoko edistymispalkkia varten — ensin isosize, sitten blockdev
        local disc_total_hr=""
        disc_total_hr=$(python3 -c "
import subprocess, sys
try:
    b = int(subprocess.check_output(['isosize', sys.argv[1]], stderr=subprocess.DEVNULL))
except Exception:
    try:
        b = int(subprocess.check_output(['blockdev','--getsize64',sys.argv[1]], stderr=subprocess.DEVNULL))
    except Exception:
        sys.exit(0)
for u, d in [('G', 1024**3), ('M', 1024**2)]:
    if b >= d: print(f'{b/d:.1f}{u}'); break
" "$disc_dev" 2>/dev/null || true)

        # Rippaa DVD taustalla — mahdollistaa aikakatkaisu- ja uudelleenyrityslogiikan.
        # Edistyminen päivitetään odotussilmukassa suoraan, ei erillisessä taustaprosessissa.
        local read_errors=0 dv_rc=0 timed_out=0
        local rip_attempt
        for (( rip_attempt=1; rip_attempt<=MAX_RIP_ATTEMPTS; rip_attempt++ )); do
            if (( rip_attempt > 1 )); then
                log "  Uudelleenyritetään rippaus (yritys ${rip_attempt}/${MAX_RIP_ATTEMPTS})..."
                find "$dv_dir" -mindepth 1 -delete 2>/dev/null || true
            fi

            local rip_tmplog; rip_tmplog=$(mktemp --tmpdir "rip-dvd-rip-XXXXXX.log")
            dvdbackup -i "$disc_dev" -o "$dv_dir" -M >"$rip_tmplog" 2>&1 &
            local dv_pid=$!
            timed_out=0

            local rip_waited=0
            while kill -0 "$dv_pid" 2>/dev/null; do
                sleep 10
                (( rip_waited += 10 )) || true
                local sz; sz=$(du -sh "$dv_dir" 2>/dev/null | cut -f1)
                if [[ -n "$disc_total_hr" ]]; then
                    printf '\r  [rippaus] %s / %s  (%s kulunut)' "$sz" "$disc_total_hr" "$(fmt_time "$rip_waited")" >&2
                else
                    printf '\r  [rippaus] %s  (%s kulunut)' "$sz" "$(fmt_time "$rip_waited")" >&2
                fi
                if (( rip_waited >= RIP_TIMEOUT )); then
                    kill -KILL "$dv_pid" 2>/dev/null || true
                    timed_out=1
                    break
                fi
            done
            wait "$dv_pid" 2>/dev/null; dv_rc=$?
            printf '\n' >&2

            cat "$rip_tmplog" >> "$LOGFILE" || true
            cp "$rip_tmplog" "$rip_log" 2>/dev/null || true
            read_errors=$(grep -c 'Error reading' "$rip_tmplog" 2>/dev/null | head -1 || echo 0)
            read_errors="${read_errors//[^0-9]/}"
            read_errors="${read_errors:-0}"
            rm -f "$rip_tmplog"

            if (( timed_out )); then
                log "VIRHE: dvdbackup aikakatkaisu ($(fmt_time "$RIP_TIMEOUT")) — ei yritetä uudelleen"
                break
            fi

            # Onnistui jos VOB-tiedostoja löytyi ja exit-koodi 0
            local vob_check
            vob_check=$(find "$dv_dir" -name "VTS_*_[1-9].VOB" -size +10M 2>/dev/null | wc -l)
            if (( vob_check > 0 && dv_rc == 0 )); then
                break
            fi
            log "  Rippaus epäonnistui (exit ${dv_rc}, VOB-tiedostoja ${vob_check}) — yritys ${rip_attempt}/${MAX_RIP_ATTEMPTS}"
        done

        local vob_count
        vob_count=$(find "$dv_dir" -name "VTS_*_[1-9].VOB" -size +10M 2>/dev/null | wc -l)
        if (( timed_out )) || (( vob_count == 0 )); then
            local fail_reason="exit ${dv_rc}, ei VOB-tiedostoja"
            (( timed_out )) && fail_reason="aikakatkaisu ${RIP_TIMEOUT}s"
            log "VIRHE: dvdbackup epäonnistui (${fail_reason}) — levy ${disc_num} ohitetaan"
            eject "$disc_dev" 2>/dev/null || true
            rm -rf "$raw_dir"
            (( disc_num-- )) || true
            continue
        fi
        if (( dv_rc != 0 )); then
            log "VAROITUS: dvdbackup exit ${dv_rc} (ei nolla) — VOB-tiedostoja löytyi silti, jatketaan"
        fi

        if (( read_errors > 0 )); then
            log "VAROITUS: ${read_errors} lukuvirhettä rippauksen aikana — tarkista lopputulos!"
            echo "READ_ERRORS=${read_errors}" >> "${raw_dir}/meta.conf"
        fi

        # Skannaa raidat HandBrakella — näytä kestot ja kysy MAX_EPISODES jos ei vielä tiedetä.
        log "dvdbackup onnistui (${vob_count} VOB). Skannataan raidat..."
        local dvd_inner; dvd_inner=$(find "$dv_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
        local scan_result
        scan_result=$(HandBrakeCLI -i "$dvd_inner" -t 0 --scan </dev/null 2>&1 | python3 -c "
import sys, re
min_dur = $MIN_DURATION
cur = None
for line in sys.stdin.buffer:
    line = line.decode('utf-8', errors='replace')
    m = re.search(r'scan: scanning title (\d+)', line)
    if m: cur = int(m.group(1))
    m2 = re.search(r'scan: duration is (\d+):(\d+):(\d+)', line)
    if m2 and cur is not None:
        h,mn,s = int(m2.group(1)), int(m2.group(2)), int(m2.group(3))
        if h*3600 + mn*60 + s >= min_dur:
            print(f'{cur}\t{h:02d}:{mn:02d}:{s:02d}')
        cur = None
")
        local title_count; title_count=$(echo "$scan_result" | grep -c . || echo 0)

        echo ""
        echo "  Raidat levyllä:"
        while IFS=$'\t' read -r tnum tdur; do
            printf '    Raita %s: %s\n' "$tnum" "$tdur"
        done <<< "$scan_result"
        echo ""

        # Jos MAX_EPISODES ei ole vielä asetettu, kysy nyt kun tiedot näkyvissä
        if [[ -z "$p_max_ep" ]] && (( title_count > 0 )); then
            local asked_max=""
            read -rp "  Montako jaksoa (Enter = kaikki ${title_count}): " asked_max </dev/tty
            if [[ -n "$asked_max" ]]; then
                if [[ "$asked_max" =~ ^[0-9]+$ ]]; then
                    p_max_ep="$asked_max"
                    echo "MAX_EPISODES=${p_max_ep}" >> "${raw_dir}/meta.conf"
                else
                    echo "  Ei kelpaa, ohitetaan" >&2
                fi
            fi
        fi

        log "Levy ${disc_num} ripattuna (${title_count} raitaa${p_max_ep:+, MAX_EPISODES=${p_max_ep}})."
        echo "TITLE_COUNT=${title_count}" >> "${raw_dir}/meta.conf"

        eject "$disc_dev" 2>/dev/null || true

        # Päivitä jaksonumero seuraavaa levyä varten: käytä efektiivistä jaksomäärää
        if [[ "$p_type" == series ]] && (( title_count > 0 )); then
            local effective_count=$title_count
            if [[ -n "$p_max_ep" ]] && (( p_max_ep > 0 && p_max_ep < title_count )); then
                effective_count=$p_max_ep
            fi
            p_ep=$(( p_ep + effective_count ))
            p_max_ep=""  # Nollaa seuraavaa levyä varten
        fi

        # Käynnistä enkoodaus taustalle heti kun levy on ripattuna
        local _enc_d_sname="enc-$(basename "$session_dir" | sed 's/session_//')-d$(printf '%03d' "$disc_num")"
        if tmux new-session -d -s "$_enc_d_sname" \
            "bash /usr/local/bin/rip-dvd.sh --encode-only '$session_dir'" 2>/dev/null; then
            printf '  Enkoodaus käynnistetty taustalle (levy %d).\n' "$disc_num"
            log "  Enkoodaussessio käynnistetty: $_enc_d_sname"
        fi
    done

    if (( disc_num == 0 )); then
        log "Ei levyjä ripattuna."; exit 0
    fi

    printf '  %d levy/levyä ripattuna — enkoodaus käynnissä taustalla.\n' "$disc_num"
    local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    printf '  Levytilaa: brainbin %d GB vapaana, terastation %d GB vapaana\n' "$local_gb" "$tera_gb"
    sleep 1
    show_enc_status
    local enc_sname="enc-$(basename "$session_dir" | sed 's/session_//')-d$(printf '%03d' "$disc_num")"
    echo "  Seuraa: tmux attach -t $enc_sname"
    echo ""
    log "═══ Kaikki valmis! ═══"
}

main "$@"
