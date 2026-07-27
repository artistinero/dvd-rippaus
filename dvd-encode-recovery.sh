#!/bin/bash
# Käynnistystoipuminen: käynnistää watchdogin ja enkoodaussessiot automaattisesti
# bootin jälkeen. Ajetaan systemd-servicenä (dvd-encode-recovery.service).
set -uo pipefail
export TZ="Europe/Helsinki"

OUTBASE="/home/keitsi/dvd-rip-tmp"
LOGFILE="$OUTBASE/recovery.log"
TERASTATION_MOUNTPT="/mnt/terastation/dlna"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

mkdir -p "$OUTBASE"
log "═══ Käynnistystoipuminen alkaa ═══"

# Odota terastationia — NAS voi boottauksen jälkeen vaatia useita minuutteja
wait_secs=0
max_wait=600  # 10 minuuttia
while ! mountpoint -q "$TERASTATION_MOUNTPT"; do
    if (( wait_secs == 0 )); then
        log "Terastation ei vielä mountattu — odotetaan enintään $((max_wait/60)) min..."
    fi
    if (( wait_secs >= max_wait )); then
        log "VAROITUS: terastation ei saatu mountattua ${max_wait}s — käynnistetään silti (encode odottaa itse)"
        break
    fi
    # Yritä mount aktiivisesti joka kierros
    sudo mount "$TERASTATION_MOUNTPT" 2>/dev/null || mount "$TERASTATION_MOUNTPT" 2>/dev/null || true
    sleep 30
    (( wait_secs += 30 )) || true
    log "  Terastation-odotus: ${wait_secs}s..."
done
mountpoint -q "$TERASTATION_MOUNTPT" && log "Terastation mountattu." || true

# Watchdog
if tmux has-session -t watchdog 2>/dev/null; then
    log "Watchdog oli jo käynnissä"
else
    tmux new-session -d -s watchdog "bash /usr/local/bin/watchdog.sh"
    log "Watchdog käynnistetty"
fi

# Enkoodaussessiot: käynnistä kaikki sessiot joissa on VOB-dataa
started=0
skipped=0
for d in "$OUTBASE"/session_*/; do
    [[ -d "$d" ]] || continue
    vob=$(find "$d" -name "*.VOB" -size +10M 2>/dev/null | head -1)
    [[ -z "$vob" ]] && continue
    if pgrep -f "encode-only.*$(basename "$d")" > /dev/null 2>&1; then
        (( skipped++ )) || true
        continue
    fi
    sname="autoenc-$(basename "$d" | sed 's/session_//')"
    if tmux has-session -t "$sname" 2>/dev/null; then
        (( skipped++ )) || true
        continue
    fi
    tmux new-session -d -s "$sname" "bash /usr/local/bin/rip-dvd.sh --encode-only '$d'"
    log "Enkoodaussessio käynnistetty: $sname"
    (( started++ )) || true
done

log "$started sessiota käynnistetty, $skipped jo käynnissä"
log "═══ Toipuminen valmis ═══"
