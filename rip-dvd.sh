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
MIN_DURATION=60  # sekuntia — lyhyemmät raidat ohitetaan

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

fmt_time() {
    local s=$1
    local h=$(( s/3600 )) m=$(( (s%3600)/60 ))
    (( h > 0 )) && printf '%dh %dmin' "$h" "$m" || printf '%dmin' "$m"
}

run_hb() {
    # $1=input $2=output [$3=title number] [$4=label for progress e.g. "S03E01"]
    local title_arg=()
    [[ -n "${3:-}" ]] && title_arg=(--title "$3")
    local label="${4:-}"
    HandBrakeCLI \
        --input "$1" "${title_arg[@]}" --output "$2" \
        --encoder x265 --quality 21 \
        --comb-detect --decomb \
        --loose-anamorphic --crop-mode auto \
        --all-audio --aencoder copy --audio-fallback aac \
        --all-subtitles --markers \
        2>&1 | python3 -c '
import sys, re, time
label = sys.argv[2] if len(sys.argv) > 2 else ""
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
            sys.stdout.write("\r  " + line.strip()); sys.stdout.flush()
            m = re.search(r"(\d+\.\d+) %.*ETA\s+(\S+)", line)
            if m:
                pct = float(m.group(1))
                eta = m.group(2)
                if pct - last_pct >= 5:
                    last_pct = pct
                    msg = f"  [{label}] {pct:.1f}%  ETA {eta}"
                    lf.write(msg + "\n"); lf.flush()
            buf = b""
        elif ch == b"\n":
            line = buf.decode("utf-8", errors="replace")
            if "warning" not in line.lower() and line.strip():
                sys.stdout.write("\n" + line); sys.stdout.flush()
                lf.write(line); lf.flush()
            buf = b""
        else:
            buf += ch
' "$LOGFILE" "$label"
    return "${PIPESTATUS[0]}"
}

wait_for_disc() {
    # Returns "disc_index /dev/srN"
    local info=""
    while [[ -z "$info" ]]; do
        info=$(makemkvcon -r info disc:9999 2>/dev/null | python3 -c "
import sys, re
for line in sys.stdin:
    m = re.match(r'^DRV:(\d+),\d+,\d+,\d+,\"[^\"]*\",\"([^\"]+)\",\"([^\"]+)\"', line.strip())
    if m:
        print(m.group(1) + ' ' + m.group(3))
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

hb_scan_long_titles() {
    # Scan DVD directory and print title numbers that are >= MIN_DURATION seconds
    local dvd_dir="$1"
    HandBrakeCLI -i "$dvd_dir" -t 0 --scan 2>&1 | python3 -c "
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
    echo "" >&2

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
        [[ -z "$name" ]] && { echo "  Nimi ei voi olla tyhjä." >&2; return 1; }
        read -rp "Vuosi: " val
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

    # Käytä \x1F (ASCII unit separator) erottimena — ei esiinny nimissä
    printf '%s\x1f%s\x1f%s\x1f%s' "$type" "$name" "$val" "$ep"
}

# ── Enkoodausvaihe ────────────────────────────────────────────────────────────

encode_session() {
    local session_dir="$1"

    if pgrep -x HandBrakeCLI >/dev/null 2>&1; then
        log "HandBrake käynnissä muualla — odotetaan..."
        while pgrep -x HandBrakeCLI >/dev/null 2>&1; do sleep 30; done
        log "Edellinen enkoodaus valmis."
    fi
    log "═══ Enkoodausvaihe alkaa ═══"

    # ── Esiskannaus: rakennetaan enkoodausjono tiedostoon ────────────────────
    local queue="${session_dir}/.queue"
    > "$queue"
    log "Skannataan levyt..."
    local disc_seq=1
    while IFS= read -r mf; do
        local raw_dir; raw_dir=$(dirname "$mf")
        local type name season ep rip_mode
        type=$(grep    '^TYPE='     "$mf" | cut -d= -f2-)
        name=$(grep    '^NAME='     "$mf" | cut -d= -f2-)
        season=$(grep  '^SEASON='   "$mf" | cut -d= -f2-)
        ep=$(grep      '^START_EP=' "$mf" | cut -d= -f2-)
        rip_mode=$(grep '^RIP_MODE=' "$mf" | cut -d= -f2 || echo "makemkv")
        local expected_count; expected_count=$(grep '^TITLE_COUNT=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        local dest; dest=$(dest_path "$type" "$name" "$season")

        if [[ "$rip_mode" == "dvdbackup" ]]; then
            local dvd_dir
            dvd_dir=$(find "${raw_dir}/dvdbackup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
            [[ -z "$dvd_dir" ]] && { log "VIRHE: dvdbackup ei löydy — ${raw_dir##*/}"; continue; }
            local titles=()
            while IFS= read -r t; do titles+=("$t"); done < <(hb_scan_long_titles "$dvd_dir")
            (( ${#titles[@]} == 0 )) && { log "VAROITUS: ei raitoja — ${raw_dir##*/}"; continue; }
            if [[ -n "$expected_count" ]] && (( ${#titles[@]} != expected_count )); then
                log "VAROITUS: odotettiin ${expected_count} raitaa, löytyi ${#titles[@]} — ${raw_dir##*/}"
            fi
            local i=1 total=${#titles[@]}
            for t in "${titles[@]}"; do
                local out_name
                case "$type" in
                series) out_name="${name} S$(printf '%02d' "$season")E$(printf '%02d' "$ep").mkv" ;;
                *)  (( total==1 )) && out_name="${name}.mkv" \
                                   || out_name="${name} - Part $(printf '%02d' "$i").mkv" ;;
                esac
                # format: mode|src|out_name|dest|title_num|disc_label|disc_seq
                printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
                    "dvdbackup" "$dvd_dir" "$out_name" "$dest" "$t" "${raw_dir##*/}" "$disc_seq" >> "$queue"
                [[ "$type" == series ]] && (( ep++ )) || true
                (( i++ )) || true
            done
        else
            local filtered=()
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                local dur; dur=$(title_dur "$f")
                (( dur >= MIN_DURATION )) && filtered+=("$f") || { log "  Ohitetaan: ${f##*/} (${dur}s)"; rm -f "$f"; }
            done < <(sorted_titles "$raw_dir")
            local i=1 total=${#filtered[@]}
            for raw in "${filtered[@]}"; do
                local out_name
                case "$type" in
                series) out_name="${name} S$(printf '%02d' "$season")E$(printf '%02d' "$ep").mkv" ;;
                *)  (( total==1 )) && out_name="${name}.mkv" \
                                   || out_name="${name} - Part $(printf '%02d' "$i").mkv" ;;
                esac
                printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
                    "mkv" "$raw" "$out_name" "$dest" "" "${raw_dir##*/}" "$disc_seq" >> "$queue"
                [[ "$type" == series ]] && (( ep++ )) || true
                (( i++ )) || true
            done
        fi
        (( disc_seq++ )) || true
    done < <(find "$session_dir" -name "meta.conf" | sort)

    local total_titles; total_titles=$(wc -l < "$queue")
    local total_discs=$(( disc_seq - 1 ))
    log "Jonossa $total_titles raitaa / $total_discs levyä enkoodattavana."
    (( total_titles == 0 )) && { log "Ei enkoodattavaa."; return; }

    # ── Enkoodaussilmukka ─────────────────────────────────────────────────────
    throttle_loop &
    local tpid=$!
    trap "kill $tpid 2>/dev/null; exit" INT TERM

    local done_n=0 session_start; session_start=$(date +%s)
    local enc_dir="${session_dir}/encoded"
    mkdir -p "$enc_dir"

    while IFS=$'\x1f' read -r mode src out_name dest title_num disc_label disc_n; do
        (( done_n++ )) || true
        local remaining=$(( total_titles - done_n + 1 ))

        # ── Palautuminen: ohita jos jo terastationilla (>100MB) ──────────────
        if [[ -f "${dest}/${out_name}" ]] && \
           [[ $(stat -c%s "${dest}/${out_name}" 2>/dev/null || echo 0) -gt 104857600 ]]; then
            log "  Ohitetaan (jo valmis): ${out_name}"
            continue
        fi
        # Siivoa mahdollinen aiempi keskeytynyt tiedosto
        rm -f "${enc_dir}/${out_name}"

        # ── Edistymisraportti ─────────────────────────────────────────────────
        echo "" >&2
        printf '  ╔══════════════════════════════════════════╗\n' >&2
        printf '  ║  Levy %d / %d  |  Jakso %d / %d\n' "$disc_n" "$total_discs" "$done_n" "$total_titles" >&2
        printf '  ║  %s\n' "$out_name" >&2
        if (( done_n > 1 )); then
            local elapsed=$(( $(date +%s) - session_start ))
            local avg=$(( elapsed / (done_n - 1) ))
            local eta_secs=$(( avg * (total_titles - done_n + 1) ))
            printf '  ║  Kokonais-ETA: ~%s  (%d jäljellä)\n' "$(fmt_time "$eta_secs")" "$remaining" >&2
        fi
        printf '  ╚══════════════════════════════════════════╝\n' >&2
        log "Enkoodataan ($done_n/$total_titles): ${out_name} [${disc_label}]"

        # ── Enkoodaus ─────────────────────────────────────────────────────────
        local t_start; t_start=$(date +%s)
        local out="${enc_dir}/${out_name}"
        mkdir -p "$dest"

        if [[ "$mode" == "dvdbackup" ]]; then
            run_hb "$src" "$out" "$title_num" "$out_name"
        else
            run_hb "$src" "$out" "" "$out_name"
        fi
        local rc=$?

        local t_secs=$(( $(date +%s) - t_start ))
        if (( rc == 0 )) && [[ -s "$out" ]]; then
            local sz; sz=$(du -sh "$out" | cut -f1)
            mv "$out" "${dest}/"
            [[ "$mode" == "mkv" ]] && rm -f "$src"
            log "  ✓ ${out_name} (${sz}, $(fmt_time "$t_secs"))"
        else
            rm -f "$out"
            log "  VIRHE: enkoodaus epäonnistui — ${out_name} ($(fmt_time "$t_secs"))"
        fi

    done < "$queue"

    # Siivoa dvdbackup-lähteet vasta kun kaikki raidat on varmistettu terastationilla
    local -A _src_ok
    local _m _src _out _dest _t _l _n
    while IFS=$'\x1f' read -r _m _src _out _dest _t _l _n; do
        [[ "$_m" != "dvdbackup" ]] && continue
        [[ -z "${_src_ok[$_src]+x}" ]] && _src_ok["$_src"]="yes"
        if ! [[ -f "${_dest}/${_out}" ]] || \
           (( $(stat -c%s "${_dest}/${_out}" 2>/dev/null || echo 0) <= 104857600 )); then
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
    local hb; hb=$(pgrep -x HandBrakeCLI 2>/dev/null || true)
    [[ -n "$hb" ]] && kill -CONT "$hb" 2>/dev/null || true
    kill "$tpid" 2>/dev/null || true
    trap - INT TERM
    log "═══ Enkoodaus valmis — yhteensä $(fmt_time "$total_secs") ═══"
}

# ── Pääohjelma ────────────────────────────────────────────────────────────────

main() {
    mkdir -p "$OUTBASE"
    log "═══ DVD-rippaus käynnistyy ═══"

    mountpoint -q /mnt/terastation/dlna \
        || die "Terastation ei ole mountattu — tarkista verkkoasema"
    command -v HandBrakeCLI &>/dev/null || die "HandBrakeCLI ei löydy"
    command -v mediainfo   &>/dev/null || die "mediainfo ei löydy"
    command -v dvdbackup   &>/dev/null || die "dvdbackup ei löydy — asenna: apt install dvdbackup"

    check_space() {
        local local_gb tera_gb
        local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
        tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
        log "Tilaa: brainbin ${local_gb} GB vapaana, terastation ${tera_gb} GB vapaana"
        # Yksi levy vie ~7GB rippaus + enkoodauksen väliaikaiset tiedostot.
        # Varoitus jos tilaa alle 2 levylle (14GB), pysäytys jos alle 1 levylle (8GB).
        (( local_gb < 14 )) && log "VAROITUS: Brainbinillä vain ${local_gb} GB — tilaa ehkä vain yhdelle levylle"
        (( local_gb <  8 )) && die "Brainbinillä ei riitä tilaa seuraavalle levylle (${local_gb} GB) — pysäytetään"
        # Terastationilla enkoodattu jakso ~600MB, varoitus alle 20GB, pysäytys alle 5GB
        (( tera_gb  < 20 )) && log "VAROITUS: Terastationilla vain ${tera_gb} GB — enkoodaus voi epäonnistua"
        (( tera_gb  <  5 )) && die "Terastationilla kriittisen vähän tilaa (${tera_gb} GB) — pysäytetään"
    }

    check_space

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
        IFS=$'\x1f' read -r p_type p_name p_season p_ep <<< "$meta_str"

        echo ""
        case "$p_type" in
        series) printf '  → %s S%02d alkaen E%02d\n' "$p_name" "$p_season" "$p_ep" ;;
        movie)  printf '  → Elokuva: %s (%s)\n'      "$p_name" "$p_season" ;;
        doc)    printf '  → Dokumentti: %s (%s)\n'   "$p_name" "$p_season" ;;
        music)  printf '  → Musiikki: %s\n'          "$p_name" ;;
        misc)   printf '  → Misc: %s\n'              "$p_name" ;;
        esac

        [[ -z "$p_name" ]] && continue  # ask_meta palautti virhe

        check_space
        log "Levy $((disc_num+1)): $p_type | $p_name | $p_season | ep=$p_ep"
        echo "  Odotetaan levyasemaa..."
        local disc_info; disc_info=$(wait_for_disc)
        local disc_idx="${disc_info%% *}"
        local disc_dev="${disc_info##* }"

        (( disc_num++ ))
        local raw_dir="${session_dir}/disc-$(printf '%03d' "$disc_num")"
        mkdir -p "$raw_dir"

        {
            echo "TYPE=${p_type}"
            echo "NAME=${p_name}"
            echo "SEASON=${p_season}"
            echo "START_EP=${p_ep}"
        } > "${raw_dir}/meta.conf"

        log "Ripataan disc ${disc_num} dvdbackupilla (${disc_dev})..."
        local mkv_log="${raw_dir}/makemkv.log"
        local dv_dir="${raw_dir}/dvdbackup"
        mkdir -p "$dv_dir"

        # Levyn kokonaiskoko edistymispalkia varten
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

        # Taustaprosessi näyttää edistymisen 10s välein
        ( while true; do
            sleep 10
            local sz; sz=$(du -sh "$dv_dir" 2>/dev/null | cut -f1)
            if [[ -n "$disc_total_hr" ]]; then
                printf '\r  [rippaus] %s / %s kopioitu...' "$sz" "$disc_total_hr" >&2
            else
                printf '\r  [rippaus] %s kopioitu...' "$sz" >&2
            fi
          done ) &
        local progress_pid=$!

        dvdbackup -i "$disc_dev" -o "$dv_dir" -M 2>&1 \
            | tee -a "$LOGFILE" | tee "$mkv_log"

        kill "$progress_pid" 2>/dev/null; wait "$progress_pid" 2>/dev/null || true
        printf '\n' >&2

        local vob_count
        vob_count=$(find "$dv_dir" -name "VTS_*_[1-9].VOB" -size +10M 2>/dev/null | wc -l)
        if (( vob_count == 0 )); then
            log "VIRHE: dvdbackup epäonnistui — levy ${disc_num} ohitetaan"
            eject "$disc_dev" 2>/dev/null || true
            rm -rf "$raw_dir"
            (( disc_num-- )) || true
            continue
        fi
        echo "RIP_MODE=dvdbackup" >> "${raw_dir}/meta.conf"
        log "dvdbackup onnistui (${vob_count} VOB). Skannataan raidat..."
        local dvd_inner; dvd_inner=$(find "$dv_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
        local title_count
        title_count=$(hb_scan_long_titles "$dvd_inner" | wc -l)
        log "Levy ${disc_num} ripattuna (${title_count} raitaa)."
        echo "TITLE_COUNT=${title_count}" >> "${raw_dir}/meta.conf"

        eject "$disc_dev" 2>/dev/null || true

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
