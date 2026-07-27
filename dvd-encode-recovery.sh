#!/bin/bash
# Käynnistystoipuminen: käynnistää watchdogin ja enkoodaussessiot automaattisesti
# bootin jälkeen. Ajettava @reboot cronista tai systemd-servicenä.
set -uo pipefail
export TZ="Europe/Helsinki"

OUTBASE="/home/keitsi/dvd-rip-tmp"
LOGFILE="$OUTBASE/recovery.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

mkdir -p "$OUTBASE"
log "Käynnistystoipuminen alkaa"

# Watchdog
if tmux has-session -t watchdog 2>/dev/null; then
    log "Watchdog oli jo käynnissä"
else
    tmux new-session -d -s watchdog "bash /usr/local/bin/watchdog.sh"
    log "Watchdog käynnistetty"
fi

# Enkoodaussessiot
started=0
for d in "$OUTBASE"/session_*/; do
    [[ -d "$d" ]] || continue
    vob=$(find "$d" -name "*.VOB" -size +10M 2>/dev/null | head -1)
    [[ -z "$vob" ]] && continue
    pgrep -f "encode-only.*$(basename "$d")" > /dev/null 2>&1 && continue
    sname="autoenc-$(basename "$d" | sed 's/session_//')"
    tmux has-session -t "$sname" 2>/dev/null && continue
    tmux new-session -d -s "$sname" "bash /usr/local/bin/rip-dvd.sh --encode-only '$d'"
    log "Enkoodaussessio käynnistetty: $sname"
    (( started++ )) || true
done

(( started > 0 )) && log "$started sessio(ta) käynnistetty" || log "Ei enkoodattavia sessioita"
