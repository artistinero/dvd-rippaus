#!/bin/bash
# Lämpötilavahti — toinen puolustuslinja rip-dvd.sh:n oman throttle-loopin lisäksi.
# Tappaa HandBrakeCLI:n ulkoapäin jos lämpö ylittää KILL_TEMP kahdesti peräkkäin.

set -uo pipefail
export TZ="Europe/Helsinki"

KILL_TEMP=96        # Skriptin oma TEMP_KILL=95 — tämä toimii jos se epäonnistuu
CHECK_INTERVAL=20
LOG=~/dvd-rip-tmp/watchdog.log
CONSECUTIVE_REQUIRED=4  # 4 × 20s = 80s peräkkäistä ylitystä ennen toimintaa

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

get_temp() {
    sensors -j 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
vals=[v for chip,data in d.items() if 'coretemp' in chip
      for feat in data.values() if isinstance(feat,dict)
      for k,v in feat.items()
      if k.startswith('temp') and k.endswith('_input') and isinstance(v,(int,float))]
print(int(max(vals)) if vals else 0)
" 2>/dev/null || echo 0
}

log "Lämpötilavahti käynnistyi (raja: ${KILL_TEMP}°C, tarkistus ${CHECK_INTERVAL}s välein)"

consecutive=0
last_kill_time=0
last_periodic_log=0
PERIODIC_LOG_INTERVAL=300  # kirjaa lämpö joka 5 minuutti

while true; do
    temp=$(get_temp)

    now=$(date +%s)
    if (( now - last_periodic_log >= PERIODIC_LOG_INTERVAL )); then
        hb_count=$(pgrep -cx HandBrakeCLI 2>/dev/null || echo 0)
        if (( hb_count > 0 )); then
            log "LÄMPÖ: ${temp}°C (HandBrake käynnissä)"
        else
            log "LÄMPÖ: ${temp}°C (ei enkoodausta)"
        fi
        last_periodic_log=$now
    fi

    if (( temp >= KILL_TEMP )); then
        (( consecutive++ )) || true
        log "VAROITUS: lämpö ${temp}°C (${consecutive}/${CONSECUTIVE_REQUIRED} peräkkäistä ylitystä)"

        if (( consecutive >= CONSECUTIVE_REQUIRED )); then
            # Älä tapa uudelleen alle 5 minuutin sisällä
            if (( now - last_kill_time > 300 )); then
                mapfile -t pids < <(pgrep -x HandBrakeCLI 2>/dev/null)
                if (( ${#pids[@]} > 0 )); then
                    log "KRIITTINEN: Tapetaan HandBrakeCLI (PIDs: ${pids[*]}) — lämpö ${temp}°C"
                    kill -CONT "${pids[@]}" 2>/dev/null || true
                    kill -KILL "${pids[@]}" 2>/dev/null || true
                    last_kill_time=$now
                    log "HandBrakeCLI tapettu"
                else
                    log "Ei HandBrakeCLI-prosesseja — ei toimenpiteitä"
                fi
            else
                log "  (tappo jo tehty alle 5 min sitten — ohitetaan)"
            fi
            consecutive=0
        fi
    else
        if (( consecutive > 0 )); then
            log "Lämpö normalisoitunut: ${temp}°C"
        fi
        consecutive=0
    fi

    sleep "$CHECK_INTERVAL"
done
