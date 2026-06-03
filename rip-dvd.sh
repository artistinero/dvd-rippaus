#!/bin/bash
# rip-dvd.sh — MakeMKV + HandBrakeCLI työnkulku
set -uo pipefail
export TZ="Europe/Helsinki"

# Ajetaan automaattisesti tmux-sessiossa — SSH-katkos ei tapa prosessia
_SESSION="dvd-rip"
if [[ -z "${TMUX:-}" ]]; then
    if tmux has-session -t "$_SESSION" 2>/dev/null; then
        echo "  Sessio '$_SESSION' on jo käynnissä — liitytään."
        exec tmux attach -t "$_SESSION"
    else
        exec tmux new-session -s "$_SESSION" "$0" "$@"
    fi
fi

LOGFILE="/mnt/lacie2/vids/dvd-rip/rip.log"
OUTBASE="/home/keitsi/dvd-rip-tmp"

# Globaalit metatiedot (asetetaan collect_metadata:ssa)
CONTENT_TYPE=""
DEST_BASE=""
SERIES_NAME=""
SEASON_NUM=1
FIRST_EP=1
MOVIE_NAME=""
MOVIE_YEAR=""
ITEM_NAME=""

# ── Apufunktiot ───────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOGFILE"
}

banner() {
    log ""
    log "══════════════════════════════════════════════════════"
    log "  $*"
    log "══════════════════════════════════════════════════════"
}

run_logged() {
    "$@" 2>&1 | tee -a "$LOGFILE"
    return "${PIPESTATUS[0]}"
}

die() {
    log "VIRHE: $*"
    exit 1
}

elapsed() {
    # elapsed <sekunteja> → "1h 23m 45s"
    local s="$1"
    local h=$(( s / 3600 ))
    local m=$(( (s % 3600) / 60 ))
    local sec=$(( s % 60 ))
    (( h > 0 )) && printf '%dh %02dm %02ds' "$h" "$m" "$sec" || printf '%dm %02ds' "$m" "$sec"
}

ask() {
    # ask "Kysymys" [oletusarvo]
    local prompt="$1"
    local default="${2:-}"
    local answer
    if [[ -n "$default" ]]; then
        echo -n "  $prompt [$default]: " >/dev/tty
    else
        echo -n "  $prompt: " >/dev/tty
    fi
    read -r answer </dev/tty
    if [[ -z "$answer" && -n "$default" ]]; then
        echo "$default"
    else
        echo "$answer"
    fi
}

# Palauttaa titlen keston sekunteina mediainfolla
title_duration_sec() {
    local file="$1"
    mediainfo --Inform="Video;%Duration%" "$file" 2>/dev/null \
        | python3 -c "
import sys
v = sys.stdin.read().strip()
print(int(float(v) / 1000) if v else 0)
" 2>/dev/null || echo 0
}

# ── Asema-apufunktiot ─────────────────────────────────────────────────────────

list_drives() {
    ls /dev/sr* 2>/dev/null
}

# CDROM_DRIVE_STATUS: 1=NO_DISC  2=TRAY_OPEN  3=NOT_READY  4=DISC_OK
drive_status() {
    python3 -c "
import fcntl, os, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
    r = fcntl.ioctl(fd, 0x5326, 0)
    os.close(fd)
    print(r)
except:
    print(0)
" "$1" 2>/dev/null
}

find_disc() {
    # Kutsutaan vasta kun ioctl on vahvistanut levyn olevan sisällä
    timeout 120 makemkvcon -r info disc:9999 2>/dev/null | python3 -c "
import sys, re
for line in sys.stdin:
    m = re.match(r'^DRV:(\d+),\d+,\d+,\d+,\"[^\"]*\",\"([^\"]+)\",\"([^\"]+)\"', line.strip())
    if m:
        print(m.group(1), m.group(2), m.group(3))
        break
"
}

# ── Levyn latausdialoogi ──────────────────────────────────────────────────────

load_disc() {
    # Etsitään asema jossa levy on sisällä; jos ei löydy, käytetään ensimmäistä
    local first_dev="/dev/sr0"
    local dev
    while IFS= read -r dev; do
        local s
        s=$(drive_status "$dev")
        if [[ "$s" == "4" ]]; then
            first_dev="$dev"
            break
        fi
        first_dev="$dev"   # fallback viimeiseen löydettyyn
    done < <(list_drives)

    local status
    status=$(drive_status "$first_dev")

    case "$status" in
        4)  # DISC_OK — levy valmiina
            ;;
        2)  # TRAY_OPEN
            echo "" >/dev/tty
            echo "  Kelkka on auki. Laita levy sisään." >/dev/tty
            echo -n "  Paina Enter niin suljetaan kelkka..." >/dev/tty
            read -r </dev/tty
            eject -t "$first_dev" 2>/dev/null && echo "  Kelkka suljettu." >/dev/tty || true
            ;;
        *)  # NO_DISC tai NOT_READY
            echo "" >/dev/tty
            echo "  Ei levyä asemassa ($first_dev)." >/dev/tty
            echo -n "  Avataan kelkka? [K/e]: " >/dev/tty
            read -r answer </dev/tty
            if [[ ! "$answer" =~ ^[Ee]$ ]]; then
                eject "$first_dev" 2>/dev/null \
                    && echo "  Kelkka avattu. Laita levy sisään." >/dev/tty \
                    || echo "  Varoitus: kelkkaa ei saatu auki." >/dev/tty
            else
                echo "Peruutettu." >/dev/tty
                exit 0
            fi
            echo -n "  Paina Enter niin suljetaan kelkka..." >/dev/tty
            read -r </dev/tty
            eject -t "$first_dev" 2>/dev/null && echo "  Kelkka suljettu." >/dev/tty || true
            ;;
    esac

    # Odotetaan DISC_OK:ta ennen makemkvcon-kutsua
    echo "" >/dev/tty
    echo -n "  Odotetaan aseman valmistumista" >/dev/tty
    local attempts=0
    while (( attempts < 30 )); do
        status=$(drive_status "$first_dev")
        if [[ "$status" == "4" ]]; then
            echo " OK" >/dev/tty
            break
        fi
        echo -n "." >/dev/tty
        sleep 2
        (( attempts++ )) || true
    done
    (( attempts < 30 )) || die "Asema ei vastannut. Tarkista levy ja yritä uudelleen."

    echo "  Tunnistetaan levy (voi kestää minuutin)..." >/dev/tty
    local disc_info
    disc_info=$(find_disc) || true

    if [[ -z "$disc_info" ]]; then
        die "MakeMKV ei tunnistanut levyä. Tarkista levy ja yritä uudelleen."
    fi

    local disc_idx disc_name device_path
    read -r disc_idx disc_name device_path <<< "$disc_info"
    echo "" >/dev/tty
    echo "  Levy: $disc_name  ($device_path)" >/dev/tty
    echo -n "  Ripataanko tämä levy? [K/e]: " >/dev/tty
    read -r answer </dev/tty
    [[ "$answer" =~ ^[Ee]$ ]] && { echo "Peruutettu." >/dev/tty; exit 0; }
    echo "$disc_info"
}

# ── Metatietojen keruu ────────────────────────────────────────────────────────

collect_metadata() {
    echo ""
    echo "  ┌─────────────────────────────────┐"
    echo "  │  Sisältötyyppi                  │"
    echo "  ├─────────────────────────────────┤"
    echo "  │  1) series       TV-sarja       │"
    echo "  │  2) movies       Elokuva        │"
    echo "  │  3) music        Musiikki       │"
    echo "  │  4) documentary  Dokumentti     │"
    echo "  │  5) misc         Muu            │"
    echo "  └─────────────────────────────────┘"
    echo -n "  Valinta [1-5]: "
    read -r choice

    echo ""
    case "$choice" in
        1)
            CONTENT_TYPE="series"
            SERIES_NAME=$(ask "Sarjan nimi (esim. The Wire)")
            [[ -n "$SERIES_NAME" ]] || die "Sarjan nimi ei voi olla tyhjä."
            SEASON_NUM=$(ask "Kausi" "1")
            SEASON_NUM=$(( 10#$SEASON_NUM ))
            DEST_BASE="/mnt/lacie2/vids/series/${SERIES_NAME}/$(printf 'Season %02d' "$SEASON_NUM")"
            local season_fmt next_ep=1
            season_fmt=$(printf '%02d' "$SEASON_NUM")
            if [[ -d "$DEST_BASE" ]]; then
                local max_ep
                max_ep=$(find "$DEST_BASE" -maxdepth 1 -name "*.mkv" -printf '%f\n' 2>/dev/null | python3 -c "
import sys, re
pat = re.compile(r'[Ss]${season_fmt}[Ee](\d+)')
eps = [int(m.group(1)) for line in sys.stdin for m in [pat.search(line.strip())] if m]
print(max(eps) if eps else 0)
")
                if (( max_ep > 0 )); then
                    next_ep=$(( max_ep + 1 ))
                    echo "  Löydettiin jakso E$(printf '%02d' "$max_ep") — ehdotetaan E$(printf '%02d' "$next_ep") aloitukseksi."
                fi
            fi
            FIRST_EP=$(ask "Ensimmäinen jaksonumero tällä levyllä" "$next_ep")
            FIRST_EP=$(( 10#$FIRST_EP ))
            ;;
        2)
            CONTENT_TYPE="movies"
            MOVIE_NAME=$(ask "Elokuvan nimi (esim. The Godfather)")
            [[ -n "$MOVIE_NAME" ]] || die "Elokuvan nimi ei voi olla tyhjä."
            MOVIE_YEAR=$(ask "Julkaisuvuosi")
            DEST_BASE="/mnt/lacie2/vids/movies/${MOVIE_NAME} (${MOVIE_YEAR})"
            ;;
        3)
            CONTENT_TYPE="music"
            ITEM_NAME=$(ask "Artisti / albumin nimi")
            [[ -n "$ITEM_NAME" ]] || die "Nimi ei voi olla tyhjä."
            DEST_BASE="/mnt/lacie2/vids/music/${ITEM_NAME}"
            ;;
        4)
            CONTENT_TYPE="documentary"
            ITEM_NAME=$(ask "Dokumentin nimi")
            [[ -n "$ITEM_NAME" ]] || die "Nimi ei voi olla tyhjä."
            MOVIE_YEAR=$(ask "Julkaisuvuosi")
            DEST_BASE="/mnt/lacie2/vids/documentary/${ITEM_NAME} (${MOVIE_YEAR})"
            ;;
        5)
            CONTENT_TYPE="misc"
            ITEM_NAME=$(ask "Nimi")
            [[ -n "$ITEM_NAME" ]] || die "Nimi ei voi olla tyhjä."
            DEST_BASE="/mnt/lacie2/vids/misc/${ITEM_NAME}"
            ;;
        *)
            die "Virheellinen valinta: '$choice'"
            ;;
    esac

    echo "  Kohde: $DEST_BASE"
}

# Palauttaa tiedostonimen (ilman hakemistoa) annetulle titlenumerolle
dest_filename() {
    local title_idx="$1"   # 0-pohjainen indeksi enkoodattujen joukossa
    local total="$2"

    case "$CONTENT_TYPE" in
        series)
            local ep=$(( FIRST_EP + title_idx ))
            printf "%s S%02dE%02d.mkv" "$SERIES_NAME" "$SEASON_NUM" "$ep"
            ;;
        movies|documentary)
            local label
            if [[ "$CONTENT_TYPE" == "movies" ]]; then
                label="${MOVIE_NAME} (${MOVIE_YEAR})"
            else
                label="${ITEM_NAME} (${MOVIE_YEAR})"
            fi
            if (( total == 1 )); then
                printf "%s.mkv" "$label"
            else
                printf "%s - Part %d.mkv" "$label" "$(( title_idx + 1 ))"
            fi
            ;;
        music|misc)
            # Käytetään MakeMKV:n nimestä johdettua titlenumerointia
            printf "%s - t%02d.mkv" "$ITEM_NAME" "$title_idx"
            ;;
    esac
}

# ── Pääohjelma ────────────────────────────────────────────────────────────────

main() {
    mkdir -p "$OUTBASE"
    : >> "$LOGFILE"

    banner "DVD-rippaus aloitettu — $(date '+%Y-%m-%d %H:%M:%S')"

    # 1. Levy
    log "Tarkistetaan levyasema..."
    local disc_info
    disc_info=$(load_disc) || die "Levyaseman tarkistus epäonnistui."

    local disc_idx disc_name device_path
    read -r disc_idx disc_name device_path <<< "$disc_info"
    log "Levy:  disc:${disc_idx}  /  ${disc_name}  /  ${device_path}"

    # 2. Metatiedot
    collect_metadata
    log "Tyyppi: $CONTENT_TYPE  →  $DEST_BASE"

    # 3. Vahvistus
    echo ""
    echo "  Levyn nimi:  $disc_name"
    echo "  Tyyppi:      $CONTENT_TYPE"
    echo "  Kohde:       $DEST_BASE"
    echo ""
    echo -n "  Aloitetaan rippaus? [K/e]: "
    read -r answer
    [[ "$answer" =~ ^[Ee]$ ]] && { echo "Peruutettu."; exit 0; }

    local outdir="${OUTBASE}/${disc_name}"
    local encodedir="${outdir}/encoded"
    # Poistetaan vanhat raakatiedostot ettei MakeMKV kysy ylikirjoituksesta
    if [[ -d "$outdir" ]]; then
        find "$outdir" -maxdepth 1 -name "*.mkv" -delete
    fi
    mkdir -p "$outdir" "$encodedir"
    local t_total_start
    t_total_start=$(date +%s)

    # ── Vaihe 1: MakeMKV ──────────────────────────────────────────────────────
    banner "Vaihe 1/3 — MakeMKV: häviötön raakakopiointi"
    log "Ripataaan kaikki titleset levyltä '${disc_name}'..."
    local t_mkv_start
    t_mkv_start=$(date +%s)

    ( while true; do
          sleep 15
          local written
          written=$(du -sh "$outdir" 2>/dev/null | cut -f1) || true
          [[ -n "$written" ]] && log "  MakeMKV: kirjoitettu ${written}..."
      done ) &
    local monitor_pid=$!

    run_logged makemkvcon mkv "disc:${disc_idx}" all "${outdir}/" \
        || { kill "$monitor_pid" 2>/dev/null; wait "$monitor_pid" 2>/dev/null; die "MakeMKV epäonnistui."; }

    kill "$monitor_pid" 2>/dev/null; wait "$monitor_pid" 2>/dev/null || true

    log "MakeMKV valmis — kesto: $(elapsed $(( $(date +%s) - t_mkv_start )))"

    # Lajittelu _tNN-numeron mukaan (ei aakkosjärjestyksessä, joka olisi väärin)
    mapfile -t all_raw_files < <(
        find "$outdir" -maxdepth 1 -name "*_t*.mkv" -printf '%f\t%p\n' | \
        python3 -c "
import sys, re
files = []
for line in sys.stdin:
    fname, path = line.strip().split('\t', 1)
    m = re.search(r'_t(\d+)\.mkv$', fname)
    files.append((int(m.group(1)) if m else 999, path))
files.sort()
print('\n'.join(p for _, p in files))
"
    )
    (( ${#all_raw_files[@]} > 0 )) || die "MakeMKV ei tuottanut yhtään tiedostoa."

    # Saniteettitarkistus: varmista että tiedostot eivät ole tyhjiä
    for f in "${all_raw_files[@]}"; do
        local sz
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        (( sz > 1048576 )) || die "MakeMKV tuotti vajavaisen tiedoston: ${f##*/} (${sz} tavua) — rippaus epäonnistui."
    done

    log "Ripattiin ${#all_raw_files[@]} title(a) — tarkistetaan kestot..."

    # Suodatetaan alle 60 sekunnin titleset pois ennen enkoodausta
    local raw_files=()
    for f in "${all_raw_files[@]}"; do
        local dur
        dur=$(title_duration_sec "$f")
        local fps
        fps=$(mediainfo --Inform="Video;%FrameRate%" "$f" 2>/dev/null || echo "?")
        if (( dur < 60 )); then
            log "  Ohitetaan: ${f##*/} (kesto ${dur}s < 60s)"
            rm -f "$f"
        else
            # PAL speedup -tunnistus ei ole automatisoitavissa pelkän fps-arvon
            # perusteella: eurooppalainen tv-sisältö on aidosti 25fps. Jos epäilet
            # PAL speedup -ongelmaa (audio sävelkorkeus väärä, nopeutettu liike),
            # lisää käsin: --rate 23.976 --cfr
            log "  Mukaan: ${f##*/} (kesto ${dur}s, fps ${fps})"
            raw_files+=("$f")
        fi
    done

    (( ${#raw_files[@]} > 0 )) || die "Kaikki titleset suodatettiin pois (alle 60s) — tarkista levy."
    log "Enkoodataan ${#raw_files[@]} title(a)."

    local total=${#raw_files[@]}

    # ── Vaihe 2: HandBrakeCLI ─────────────────────────────────────────────────
    banner "Vaihe 2/3 — HandBrakeCLI: H.265-pakkaus"
    log "Ääni:         kaikki raidat, copy pass-through (fallback aac)"
    log "Tekstitykset: kaikki raidat"
    log "Video:        x265 CRF 21, anamorphic loose, crop auto"
    local t_mkv_elapsed=$(( $(date +%s) - t_mkv_start ))
    local t_hb_start
    t_hb_start=$(date +%s)

    local i=0
    for raw_file in "${raw_files[@]}"; do
        local fname="${raw_file##*/}"
        local dest_name
        dest_name=$(dest_filename "$i" "$total")
        local encoded_file="${encodedir}/${dest_name}"
        local raw_size
        raw_size=$(du -sh "$raw_file" | cut -f1)
        local t_title_start
        t_title_start=$(date +%s)

        log "Title $(( i+1 ))/${total}: $fname ($raw_size) → $dest_name"

        run_logged HandBrakeCLI \
            --input  "$raw_file" \
            --output "$encoded_file" \
            --encoder x265 \
            --quality 21 \
            --comb-detect \
            --decomb \
            --anamorphic-mode loose \
            --crop-mode auto \
            --all-audio \
            --aencoder copy \
            --audio-fallback aac \
            --all-subtitles \
            --markers \
            || die "HandBrakeCLI epäonnistui: $fname"

        local encoded_size
        encoded_size=$(du -sh "$encoded_file" | cut -f1)
        log "Koko: $raw_size → $encoded_size  (kesto: $(elapsed $(( $(date +%s) - t_title_start ))))"
        rm -f "$raw_file"
        log "Raaka poistettu: $fname"
        (( i++ )) || true
    done
    local t_hb_elapsed=$(( $(date +%s) - t_hb_start ))
    log "HandBrakeCLI valmis — kesto: $(elapsed $t_hb_elapsed)"

    # ── Vaihe 3: Siirrä kohteeseen ────────────────────────────────────────────
    banner "Vaihe 3/3 — Siirto kohteeseen"

    mkdir -p "$DEST_BASE"
    log "Kohde: $DEST_BASE"

    local moved=0
    while IFS= read -r enc_file; do
        local fname="${enc_file##*/}"
        local dest_file="${DEST_BASE}/${fname}"
        mv "$enc_file" "$dest_file"
        log "Siirretty: $dest_file"
        (( moved++ )) || true
    done < <(find "$encodedir" -maxdepth 1 -name "*.mkv" | sort)

    rmdir "$encodedir" 2>/dev/null || true
    rmdir "$outdir"   2>/dev/null || true
    (( moved > 0 )) || die "Ei siirrettyjä tiedostoja."

    # Ejektointi ja kelkan sulkeminen
    log "Ejektoidaan levy ($device_path)..."
    if eject "$device_path" 2>/dev/null; then
        log "Levy ejektoitu — suljetaan kelkka 15 sekunnin kuluttua..."
        sleep 15
        eject -t "$device_path" 2>/dev/null \
            && log "Kelkka suljettu." \
            || log "Varoitus: kelkan sulkeminen epäonnistui."
    else
        log "Varoitus: ejektointi epäonnistui — poista levy käsin."
    fi

    local t_total=$(( $(date +%s) - t_total_start ))
    banner "Kaikki valmis! — $(date '+%Y-%m-%d %H:%M:%S')"
    log "Ajat:"
    log "  MakeMKV rippaus:    $(elapsed $t_mkv_elapsed)"
    log "  HandBrakeCLI enc.:  $(elapsed $t_hb_elapsed)"
    log "  Yhteensä:           $(elapsed $t_total)"
    log "Tiedostot Jellyfinissä: $DEST_BASE"
    log ""
    log "Käynnistä Jellyfin-skannaus: Dashboard → Libraries → Scan All Libraries"
}

main "$@"
