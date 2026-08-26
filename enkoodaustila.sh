#!/bin/bash
# enkoodaustila.sh — näytä enkoodausjonon tila. Aja: enkoodaustila.sh
# VAIN LUKU. Surfaa sen mitä rip-dvd.sh itse jo laskee (nykyinen kohde %+ETA, koko jonon
# Kokonais-ETA, sijainti X/Y) + listaa tulevat kohteet nimineen. Ei omaa haurasta laskentaa.
TMP="$HOME/dvd-rip-tmp"
CFG="$HOME/.config/rip-dvd/config"
FS=$'\x1f'

echo "══════════ ENKOODAUSTILA $(date '+%d.%m. %H:%M:%S') ══════════"
par=$(grep -oE '^PARALLEL=[0-9]+' "$CFG" 2>/dev/null | cut -d= -f2); par=${par:-1}
echo "Rinnakkaisuus: PARALLEL=$par (enintään $par yhtä aikaa)"

run=0
for es in $(tmux ls 2>/dev/null | grep '^enc' | cut -d: -f1); do
  pane=$(tmux capture-pane -p -t "$es" 2>/dev/null)
  # nykyinen kohde: [NIMI.mkv] XX.X% ETA HHhMMmSSs
  cur=$(printf '%s\n' "$pane" | grep -oE '\[[^][]+\.mkv\] [0-9.]+%[^)]*ETA [0-9hms]+' | tail -1)
  [ -z "$cur" ] && continue
  run=$((run+1))
  # sessioon liittyvä levy (session_XXX): irrota es:stä "enc-XXX-dNNN" -> session_XXX
  sid=$(echo "$es" | sed -E 's/^enc-([0-9_a-z]+)-d[0-9]+$/\1/')
  q="$TMP/session_${sid}/.queue"

  name=$(echo "$cur" | sed -E 's/^\[(.+)\.mkv\].*/\1/')
  pct=$(echo "$cur"  | grep -oE '[0-9.]+%' | tail -1)
  eta=$(echo "$cur"  | grep -oE 'ETA [0-9]+h[0-9]+m[0-9]+s' | sed -E 's/ETA 0*([0-9]+)h0*([0-9]+)m0*([0-9]+)s/\1h \2min \3s/; s/^0h //')
  pos=$(printf '%s\n' "$pane" | grep -oE 'Enkoodataan \([0-9]+/[0-9]+\)' | tail -1 | grep -oE '[0-9]+/[0-9]+')
  keta=$(printf '%s\n' "$pane" | grep -oE 'Kokonais-ETA: [^)]*\([0-9]+ jäljellä\)' | tail -1 | sed 's/Kokonais-ETA: //')

  echo
  echo "▶ ENKOODAUSSA nyt (erä session_${sid}, kohta ${pos:-?}):"
  echo "    ● $name"
  echo "        $pct valmis,  jäljellä n. ${eta:-?}"
  [ -n "$keta" ] && echo "    Koko erän loppuun: $keta"

  # tulevat kohteet: queue-rivit sijainnin jälkeen (järjestyksessä = luotettava).
  # Kesto luetaan levyn .titleinfo:sta jos on (uudet rippaukset); muuten vain nimi.
  curpos=$(echo "$pos" | cut -d/ -f1); tot=$(echo "$pos" | cut -d/ -f2)
  if [ -n "$curpos" ] && [ -f "$q" ]; then
    echo "    Seuraavaksi jonossa (video-kesto jos tallessa):"
    awk -F"$FS" -v s="$((curpos+1))" 'NR>=s{print $1"\t"$2"\t"$6}' "$q" | head -15 | \
    while IFS=$'\t' read -r src name title; do
      nm=${name%.mkv}
      ti="${src%/dvdbackup/*}/.titleinfo"
      dur=""
      [ -f "$ti" ] && dur=$(awk -v t="$title" '$1==t{print $2; exit}' "$ti" 2>/dev/null)
      if [ -n "$dur" ] && [ "$dur" -gt 0 ] 2>/dev/null; then
        printf "        • %-44s %3d min\n" "$nm" "$((dur/60))"
      else
        printf "        • %s\n" "$nm"
      fi
    done
    left=$(( tot - curpos ))
    [ "$left" -gt 15 ] && echo "        … (+$((left-15)) muuta)"
  fi
done
[ "$run" -eq 0 ] && echo && echo "▶ Ei enkoodausta käynnissä juuri nyt."
echo
echo "Käynnissä: $run/$par rinnakkain."

# rippaus + ympäristö
echo
rb=$(ps -eo etimes,args 2>/dev/null | awk '/dvdbackup -i \/dev\/sr/ && !/awk/ && $1<3600{print; exit}')
[ -n "$rb" ] && echo "▶ Uusi levy rippautuu parhaillaan." || echo "▶ Ei rippausta käynnissä."
temps=$(sensors -j 2>/dev/null | grep -oE '"temp[0-9]_input": [0-9]+' | grep -oE '[0-9]+$' | tr '\n' ' ')
echo "  Lämmöt: ${temps}°C  |  $(uptime | grep -oE 'load average: [0-9.,]+')  |  $(df -h "$HOME" | tail -1 | awk '{print $4" levytilaa vapaana ("$5" käytössä)"}')"
echo "══════════════════════════════════════════"
