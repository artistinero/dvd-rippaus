#!/bin/bash
# rip-dvd.sh — Interaktiivinen DVD-rippaus ja enkoodaus
set -uo pipefail
export TZ="Europe/Helsinki"

# Käynnistä automaattisesti tmux-sessiossa
_SESSION="dvd-rip"
if [[ -z "${TMUX:-}" ]]; then
    if tmux has-session -t "$_SESSION" 2>/dev/null; then
        echo "Sessio '$_SESSION' on jo käynnissä — liitytään."
        exec tmux attach -t "$_SESSION"
    else
        exec tmux new-session -s "$_SESSION" "$0" "$@"
    fi
fi

OUTBASE="/home/keitsi/dvd-rip-tmp"
DEST_ROOT="/mnt/terastation/dlna/vids"
LOGFILE="/home/keitsi/rip-dvd.log"
TEMP_WARN=85
TEMP_RESUME=65
MIN_DURATION=60  # sekuntia — lyhyemmät titleset ohitetaan

# ── Apufunktiot ───────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }
die() { log "VIRHE: $*"; exit 1; }

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

throttle_loop() {
    local paused=0
    while true; do
        sleep 20
        local hb_pid temp
        hb_pid=$(pgrep -x HandBrakeCLI 2>/dev/null || true)
        temp=$(get_temp)
        [[ -z "$hb_pid" ]] && { paused=0; continue; }
        if (( temp >= TEMP_WARN )) && (( paused == 0 )); then
            kill -STOP "$hb_pid" 2>/dev/null; paused=1
            log "  Throttle: paussi ${temp}°C"
        elif (( temp <= TEMP_RESUME )) && (( paused == 1 )); then
            kill -CONT "$hb_pid" 2>/dev/null; paused=0
            log "  Throttle: jatkuu ${temp}°C"
        fi
    done
}

run_hb() {
    # $1=input $2=output — suodattaa HandBraken \r-progress-spämin lokista
    HandBrakeCLI \
        --input "$1" --output "$2" \
        --encoder x265 --quality 21 \
        --comb-detect --decomb \
        --loose-anamorphic --crop-mode auto \
        --all-audio --aencoder copy --audio-fallback aac \
        --all-subtitles --markers \
        2>&1 | python3 -c '
import sys, re
last_pct = -5
buf = b""
stdin_b = sys.stdin.buffer
with open(sys.argv[1], "a") as lf:
    while True:
        ch = stdin_b.read(1)
        if not ch:
            if buf:
                line = buf.decode("utf-8", errors="replace")
                sys.stdout.write(line + "\n"); lf.write(line + "\n")
            break
        if ch == b"\r":
            line = buf.decode("utf-8", errors="replace")
            sys.stdout.write(line + "\r"); sys.stdout.flush()
            m = re.search(r"(\d+\.\d+) %", line)
            if m:
                pct = float(m.group(1))
                if pct - last_pct >= 5:
                    last_pct = pct
                    lf.write("  " + line.strip() + "\n"); lf.flush()
            buf = b""
        elif ch == b"\n":
            line = buf.decode("utf-8", errors="replace")
            sys.stdout.write(line + "\n"); sys.stdout.flush()
            lf.write(line + "\n"); lf.flush()
            buf = b""
        else:
            buf += ch
' "$LOGFILE"
    return "${PIPESTATUS[0]}"
}

wait_for_disc() {
    local info=""
    while [[ -z "$info" ]]; do
        info=$(makemkvcon -r info disc:9999 2>/dev/null | python3 -c "
import sys, re
for line in sys.stdin:
    m = re.match(r'^DRV:(\d+),\d+,\d+,\d+,\"[^\"]*\",\"([^\"]+)\",\"([^\"]+)\"', line.strip())
    if m:
        print(m.group(1))
        break
" 2>/dev/null || true)
        [[ -z "$info" ]] && sleep 10
    done
    echo "$info"
}

sorted_titles() {
    find "$1" -maxdepth 1 -name "*_t*.mkv" -printf '%f\t%p\n' | python3 -c "
import sys, re
files = []
for line in sys.stdin:
    parts = line.strip().split('\t', 1)
    if len(parts) != 2: continue
    m = re.search(r'_t(\d+)\.mkv$', parts[0])
    files.append((int(m.group(1)) if m else 999, parts[1]))
files.sort()
print('\n'.join(p for _, p in files))"
}

title_dur() {
    mediainfo --Inform="Video;%Duration%" "$1" 2>/dev/null | python3 -c "
import sys; v=sys.stdin.read().strip()
print(int(float(v)/1000) if v else 0)" 2>/dev/null || echo 0
}

dest_path() {
    local type="$1" name="$2" val="$3"
    case "$type" in
    series)  printf '%s/series/%s/Season %02d' "$DEST_ROOT" "$name" "$val" ;;
    movie)   printf '%s/movies/%s (%s)'        "$DEST_ROOT" "$name" "$val" ;;
    doc)     printf '%s/documentaries/%s (%s)' "$DEST_ROOT" "$name" "$val" ;;
    music)   printf '%s/Music videos/%s'       "$DEST_ROOT" "$name" ;;
    misc)    printf '%s/misc/%s'               "$DEST_ROOT" "$name" ;;
    esac
}

# ── Interaktiivinen kysely per levy ───────────────────────────────────────────

ask_meta() {
    local p_type="${1:-}" p_name="${2:-}" p_season="${3:-}" p_ep="${4:-}"
    echo ""

    local prompt="Tyyppi (series/movie/doc/music/misc)"
    [[ -n "$p_type" ]] && prompt+=" [$p_type]"
    local type=""
    while true; do
        read -rp "${prompt}: " type
        type="${type:-$p_type}"
        case "$type" in series|movie|doc|music|misc) break ;;
        *) echo "  → series, movie, doc, music tai misc" ;;
        esac
    done

    local name="" val="" ep=""

    case "$type" in
    series)
        local np="Sarja"
        [[ -n "$p_name" && "$p_type" == series ]] && np+=" [$p_name]"
        read -rp "${np}: " name; name="${name:-$p_name}"

        local sp="Kausi"
        [[ -n "$p_season" && "$p_type" == series ]] && sp+=" [$p_season]"
        read -rp "${sp}: " val; val="${val:-$p_season}"

        # Ehdota seuraavaa jaksoa: ensin session-laskuri, sitten terastation
        local suggest=1
        if [[ -n "$p_ep" && "$p_type" == series && "$p_season" == "$val" ]]; then
            suggest="$p_ep"
        else
            local dd; dd=$(dest_path series "$name" "$val")
            if [[ -d "$dd" ]]; then
                suggest=$(find "$dd" -maxdepth 1 -name "*.mkv" 2>/dev/null | python3 -c "
import sys, re
n = []
for line in sys.stdin:
    m = re.search(r'E(\d+)', line.strip())
    if m: n.append(int(m.group(1)))
print(max(n)+1 if n else 1)" 2>/dev/null || echo 1)
            fi
        fi
        read -rp "Ensimmäinen jakso tällä levyllä [$suggest]: " ep
        ep="${ep:-$suggest}"
        ;;

    movie|doc)
        local lbl; [[ "$type" == movie ]] && lbl="Elokuvan nimi" || lbl="Dokumentin nimi"
        [[ -n "$p_name" && "$p_type" == "$type" ]] && lbl+=" [$p_name]"
        read -rp "${lbl}: " name; name="${name:-$p_name}"
        read -rp "Vuosi: " val
        ep=""
        ;;

    music)
        local np="Nimi (artisti / keikka / kokoelma)"
        [[ -n "$p_name" && "$p_type" == music ]] && np+=" [$p_name]"
        read -rp "${np}: " name; name="${name:-$p_name}"
        val="" ep=""
        ;;

    misc)
        read -rp "Nimi: " name
        val="" ep=""
        ;;
    esac

    printf '%s|%s|%s|%s' "$type" "$name" "$val" "$ep"
}

# ── Enkoodausvaihe ────────────────────────────────────────────────────────────

encode_session() {
    local session_dir="$1"
    log "═══ Enkoodausvaihe alkaa ═══"

    throttle_loop &
    local tpid=$!
    trap "kill $tpid 2>/dev/null; exit" INT TERM

    while IFS= read -r mf; do
        local raw_dir; raw_dir=$(dirname "$mf")
        local type name season ep
        type=$(grep   '^TYPE='     "$mf" | cut -d= -f2-)
        name=$(grep   '^NAME='     "$mf" | cut -d= -f2-)
        season=$(grep '^SEASON='   "$mf" | cut -d= -f2-)
        ep=$(grep     '^START_EP=' "$mf" | cut -d= -f2-)

        # Suodata titleset keston mukaan
        local filtered=()
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            local dur; dur=$(title_dur "$f")
            if (( dur >= MIN_DURATION )); then
                filtered+=("$f")
            else
                log "  Ohitetaan: ${f##*/} (${dur}s)"; rm -f "$f"
            fi
        done < <(sorted_titles "$raw_dir")

        if (( ${#filtered[@]} == 0 )); then
            log "VAROITUS: Ei enkoodattavia — ${raw_dir##*/}"; continue
        fi

        local dest; dest=$(dest_path "$type" "$name" "$season")
        mkdir -p "$dest"
        local enc_dir="${raw_dir}/encoded"
        mkdir -p "$enc_dir"

        local total=${#filtered[@]} i=1
        for raw in "${filtered[@]}"; do
            local out_name
            case "$type" in
            series)
                out_name="${name} S$(printf '%02d' "$season")E$(printf '%02d' "$ep").mkv"
                ;;
            *)
                if (( total == 1 )); then
                    out_name="${name}.mkv"
                else
                    out_name="${name} - Part $(printf '%02d' "$i").mkv"
                fi
                ;;
            esac

            local out="${enc_dir}/${out_name}"
            log "Enkoodataan (${i}/${total}): ${raw##*/} → ${out_name}"
            run_hb "$raw" "$out"
            local rc=$?

            if (( rc == 0 )) && [[ -s "$out" ]]; then
                local sz; sz=$(du -sh "$out" | cut -f1)
                mv "$out" "${dest}/"
                rm -f "$raw"
                log "  ✓ ${out_name} (${sz})"
            else
                log "  VIRHE: enkoodaus epäonnistui — ${raw##*/} (raakadata jää ${raw_dir}/)"
            fi

            [[ "$type" == series ]] && (( ep++ )) || true
            (( i++ )) || true
        done

    done < <(find "$session_dir" -name "meta.conf" | sort)

    kill "$tpid" 2>/dev/null || true
    trap - INT TERM
    log "═══ Enkoodaus valmis ═══"
}

# ── Pääohjelma ────────────────────────────────────────────────────────────────

main() {
    mkdir -p "$OUTBASE"
    log "═══ DVD-rippaus käynnistyy ═══"

    mountpoint -q /mnt/terastation/dlna \
        || die "Terastation ei ole mountattu — tarkista verkkoasema"
    command -v makemkvcon  &>/dev/null || die "makemkvcon ei löydy"
    command -v HandBrakeCLI &>/dev/null || die "HandBrakeCLI ei löydy"
    command -v mediainfo   &>/dev/null || die "mediainfo ei löydy"

    local free_gb
    free_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    (( free_gb < 10 )) \
        && log "VAROITUS: Vapaata tilaa vain ${free_gb} GB — levytila voi loppua kesken"
    log "Valmis. Vapaata tilaa: ${free_gb} GB"

    local session_dir="${OUTBASE}/session_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$session_dir"

    local p_type="" p_name="" p_season="" p_ep=""
    local disc_num=0

    while true; do
        echo ""
        echo "══════════════════════════════════════════════"
        printf '  Levyjä ripattuna tässä sessiossa: %d\n' "$disc_num"
        echo "══════════════════════════════════════════════"
        local cmd=""
        read -rp "  Lisää levy ja paina Enter  (q = aloita enkoodaus): " cmd
        [[ "${cmd,,}" == "q" ]] && break

        local meta_str
        meta_str=$(ask_meta "$p_type" "$p_name" "$p_season" "$p_ep")
        IFS='|' read -r p_type p_name p_season p_ep <<< "$meta_str"

        echo ""
        case "$p_type" in
        series) printf '  → %s S%02d alkaen E%02d\n' "$p_name" "$p_season" "$p_ep" ;;
        movie)  printf '  → Elokuva: %s (%s)\n'      "$p_name" "$p_season" ;;
        doc)    printf '  → Dokumentti: %s (%s)\n'   "$p_name" "$p_season" ;;
        music)  printf '  → Musiikki: %s\n'          "$p_name" ;;
        misc)   printf '  → Misc: %s\n'              "$p_name" ;;
        esac

        log "Levy $((disc_num+1)): $p_type | $p_name | $p_season | ep=$p_ep"
        echo "  Odotetaan levyasemaa..."
        local disc_idx; disc_idx=$(wait_for_disc)

        (( disc_num++ ))
        local raw_dir="${session_dir}/disc-$(printf '%03d' "$disc_num")"
        mkdir -p "$raw_dir"

        {
            echo "TYPE=${p_type}"
            echo "NAME=${p_name}"
            echo "SEASON=${p_season}"
            echo "START_EP=${p_ep}"
        } > "${raw_dir}/meta.conf"

        log "MakeMKV rippaa disc ${disc_num}..."
        local mkv_log="${raw_dir}/makemkv.log"
        makemkvcon mkv "disc:${disc_idx}" all "${raw_dir}/" 2>&1 \
            | tee -a "$LOGFILE" | tee "$mkv_log"

        eject 2>/dev/null || true

        local title_count
        title_count=$(grep -c "was added" "$mkv_log" 2>/dev/null || echo 0)
        log "Levy ${disc_num} ripattuna (${title_count} titletä). Levy ejectattu."

        # Päivitä jaksonumero seuraavaa levyä varten
        if [[ "$p_type" == series ]] && (( title_count > 0 )); then
            p_ep=$(( p_ep + title_count ))
        fi
    done

    if (( disc_num == 0 )); then
        log "Ei levyjä ripattuna."; exit 0
    fi

    echo ""
    echo "══════════════════════════════════════════════"
    printf '  %d levy/levyä ripattuna. Aloitetaan enkoodaus...\n' "$disc_num"
    echo "══════════════════════════════════════════════"
    echo ""

    encode_session "$session_dir"

    log "═══ Kaikki valmis! ═══"
}

main "$@"
