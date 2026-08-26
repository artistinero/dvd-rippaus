#!/bin/bash
# enkoodaustila.sh — näytä enkoodausjonon tila. Aja: enkoodaustila.sh
# Kertoo montako enkoodausta pyörii, mitkä, jono, lämmöt. Ei muuta mitään (vain luku).

CFG="$HOME/.config/rip-dvd/config"
TMP="$HOME/dvd-rip-tmp"

echo "══════════ ENKOODAUSTILA $(date '+%H:%M:%S') ══════════"

# Rinnakkaisuusasetus
par=$(grep -oE '^PARALLEL=[0-9]+' "$CFG" 2>/dev/null | cut -d= -f2)
echo "Rinnakkaisuusasetus: PARALLEL=${par:-1}"

# Käynnissä olevat HandBrake-enkoodaukset
mapfile -t hb < <(pgrep -x HandBrakeCLI)
echo
echo "KÄYNNISSÄ NYT: ${#hb[@]} enkoodausta $([ "${#hb[@]}" -ge 2 ] && echo '(RINNAKKAIN)' || echo '')"
for p in "${hb[@]}"; do
  et=$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')
  out=$(ps -o args= -p "$p" 2>/dev/null | grep -oE 'output [^ ]+/[^/]+\.tmp\.mkv' | sed 's#.*/##; s/\.tmp\.mkv//')
  pct=$(ls -t "$TMP"/*/enc-*.log 2>/dev/null | head -1) # ei aina saatavilla
  echo "  • ${out:-?}  (kesto $et)"
done

# Jonossa: montako raitaa odottaa per session-hakemisto
echo
echo "JONOSSA (odottavat raidat per erä):"
tot=0
for q in "$TMP"/session_*/.queue; do
  [ -f "$q" ] || continue
  sess=$(basename "$(dirname "$q")")
  # rivejä joita ei ole vielä merkitty valmiiksi report:ssa — karkea: queue-rivit yhteensä
  n=$(grep -c . "$q" 2>/dev/null)
  rep="$(dirname "$q")/.encode-report"
  done_n=$(grep -cE '^(OK|FAIL|SKIP)=' "$rep" 2>/dev/null)
  left=$(( n - done_n )); [ "$left" -lt 0 ] && left=0
  [ "$left" -gt 0 ] && { echo "  • $sess: ~$left odottaa"; tot=$((tot+left)); }
done
echo "  YHTEENSÄ n. $tot raitaa jonossa"

# encode-only-prosessit + tmux-sessiot
echo
echo "Enkoodaus-sessioita käynnissä/odottamassa: $(pgrep -fc 'rip-dvd.sh --encode-only') prosessia, $(tmux ls 2>/dev/null | grep -c '^enc') tmux-sessiota"

# Onko uutta rippausta käynnissä (päärippaus)
if pgrep -f 'dvdbackup -i /dev/sr' >/dev/null; then
  echo "Uusi levy rippautuu parhaillaan (dvdbackup /dev/sr)."
fi

# Lämmöt + kuorma
echo
temps=$(sensors -j 2>/dev/null | grep -oE '"temp[0-9]_input": [0-9]+' | grep -oE '[0-9]+$' | tr '\n' ' ')
echo "CPU-ytimet: ${temps}°C   |   Kuorma: $(uptime | grep -oE 'load average: [0-9.,]+' )"
echo "Levytila: $(df -h "$HOME" | tail -1 | awk '{print $4" vapaana ("$5" käytössä)"}')"
echo "══════════════════════════════════════════"
[ "${#hb[@]}" -lt 2 ] && [ "${par:-1}" -ge 2 ] && \
  echo "HUOM: vain ${#hb[@]} rinnakkain vaikka PARALLEL=$par — todennäköisesti kaikki jäljellä oleva työ on samassa erässä (session-hakemistossa), jota ajetaan yksi kerrallaan. Uudet rippaukset (omat erät) ajavat rinnakkain."
