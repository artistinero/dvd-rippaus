#!/bin/bash
# korjaa-tekstitys.sh — korjaa yhden DVD-levyn tekstitysten desync-bugin ITSENÄISESTI.
#
# KÄYTTÖ:  korjaa-tekstitys.sh "Elokuvan kansio (vuosi)"
#   esim.  korjaa-tekstitys.sh "Freejack (1992)"
#
# Laita levy asemaan (/dev/sr1) ENNEN ajoa. Skripti:
#   1. tunnistaa levyn pisimmän tittelin (= pääelokuva)
#   2. irrottaa KAIKKI tekstitysraidat oikealla NAV-ajastuksella (ffmpeg dvdvideo-demukseri)
#      - jos suora luku jumittaa -> dvdbackup koko rakenne paikalliselle levylle, irrotus siitä
#   3. lisää pakollisen "size: 720x576" -rivin (muuten tekstit eivät näy rajatuilla videoilla)
#   4. remuxaa tekstitykset kirjaston tiedostoon (video/ääni koskematta)
#   5. varmuuskopioi vanhan version kirjaston ULKOPUOLELLE (ei jää Jellyfiniin haamuksi)
#   6. verifioi ja päivittää Jellyfinin
#
# Ei korvaa kirjastoa jos jokin menee pieleen — jättää *_TEST.mkv:n tarkistettavaksi.
set -u

# ---- asetukset ----
DRIVE="/dev/sr1"
FFMPEG_DVD="/opt/ffmpeg-dvdvideo/bin/ffmpeg"       # dvdvideo-demukserilla käännetty ffmpeg
MOVIES="/mnt/terastation/dlna/vids/movies"
BACKUPS="/mnt/terastation/dlna/desync-backups"     # varmuuskopiot KIRJASTON ULKOPUOLELLE
JF_KEY_FILE="/home/keitsi/.config/jellyfin-cc-api-key"
WORK="/home/keitsi/dvd-rip-tmp/tekstityskorjaus"
STALL_SECS=40         # jos suora luku ei tuota mitään näin monessa sekunnissa -> dvdbackup
# --------------------

die(){ echo "VIRHE: $*" >&2; exit 1; }
log(){ echo "[$(date +%H:%M:%S)] $*"; }

FOLDER="${1:-}"
[ -n "$FOLDER" ] || die "Anna elokuvan nimi (osittainenkin käy), esim: $0 \"Lipton Cockton\""
# Etsi kansio: ensin tarkka nimi, sitten osittainen (case-insensitive) haku koko movies-puusta.
if [ -d "$MOVIES/$FOLDER" ]; then
  DEST="$MOVIES/$FOLDER"
else
  mapfile -t MATCHES < <(find "$MOVIES" -maxdepth 2 -type d -iname "*$FOLDER*" 2>/dev/null)
  if [ "${#MATCHES[@]}" -eq 0 ]; then
    die "Kansiota ei löydy nimellä \"$FOLDER\". Tarkista kirjoitusasu."
  elif [ "${#MATCHES[@]}" -gt 1 ]; then
    echo "Useita osumia nimellä \"$FOLDER\" — tarkenna:" >&2
    printf '  %s\n' "${MATCHES[@]##*/}" >&2
    exit 1
  fi
  DEST="${MATCHES[0]}"
  FOLDER="${DEST##*/}"   # käytä täyttä kansionimeä tästä eteenpäin
  log "Löydettiin: $FOLDER"
fi

[ -x "$FFMPEG_DVD" ] || die "dvdvideo-ffmpeg puuttuu: $FFMPEG_DVD"
command -v lsdvd >/dev/null || die "lsdvd puuttuu (sudo apt install lsdvd)"
command -v dvdbackup >/dev/null || die "dvdbackup puuttuu"
command -v mkvmerge >/dev/null || die "mkvmerge puuttuu (mkvtoolnix)"

mkdir -p "$WORK" "$BACKUPS"
SAFE=$(echo "$FOLDER" | tr -c 'A-Za-z0-9' '_')
JOB="$WORK/$SAFE"; rm -rf "$JOB"; mkdir -p "$JOB"; cd "$JOB" || die "cd $JOB"

# --- 1. tunnista pisin titteli levyltä ---
# Sulje kelkka ensin (skripti avaa sen lopuksi, joten levynvaihdon jälkeen se on auki).
# Odota levyn pyörähtämistä käyntiin ennen lukua.
eject -t "$DRIVE" 2>/dev/null && sleep 12
log "Luen levyn rakenteen ($DRIVE)..."
TITLE=""
for _try in 1 2 3; do
  TITLE=$(lsdvd "$DRIVE" 2>/dev/null | awk '/^Title:/{gsub(",","",$2); t=$2} /Longest track:/{print $3}' | tail -1)
  [ -n "$TITLE" ] || TITLE=$(lsdvd "$DRIVE" 2>/dev/null | awk -F',' '/^Title:/{print $1}' | sed 's/Title: //' | head -1)
  [ -n "$TITLE" ] && break
  sleep 8
done
[ -n "$TITLE" ] || die "Levyä ei voi lukea. Onko levy asemassa ja ehjä? Kokeile kelkan avaus/sulku."
TITLE=$((10#$TITLE))
log "Pääelokuva = titteli $TITLE"

# --- kohde kirjastossa: pisin .mkv kansiossa ---
LIB=""; LIBDUR=0
while IFS= read -r f; do
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)
  [ -n "$d" ] && [ "$d" -gt "$LIBDUR" ] && { LIBDUR=$d; LIB=$f; }
done < <(find "$DEST" -maxdepth 1 -iname '*.mkv' ! -iname '*-extra.mkv')
[ -n "$LIB" ] || die "Kirjaston .mkv:tä ei löydy kansiosta $DEST"
log "Kohdetiedosto: $(basename "$LIB") ($((LIBDUR/60)) min)"

# --- 2. irrota tekstitykset: yritä suoraa dvdvideo-lukua, jumittaessa dvdbackup ---
extract(){ # $1 = lähde (levy tai VIDEO_TS-kansio)
  "$FFMPEG_DVD" -y -f dvdvideo -title "$TITLE" -i "$1" -map 0:s -c:s copy subs.mkv \
    > extract.log 2>&1 < /dev/null &
  local pid=$! t=0
  while kill -0 $pid 2>/dev/null; do
    sleep 5; t=$((t+5))
    local sz=$(stat -c%s subs.mkv 2>/dev/null || echo 0)
    [ "$t" -ge "$STALL_SECS" ] && [ "${sz:-0}" -eq 0 ] && { kill -9 $pid 2>/dev/null; return 2; }
  done
  local n=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 subs.mkv 2>/dev/null | wc -l)
  [ "$n" -ge 1 ] && return 0 || return 1
}

log "Irrotan tekstitykset suoraan levyltä..."
if extract "$DRIVE"; then
  log "Suora irrotus onnistui."
else
  log "Suora luku ei tuota tulosta -> kopioidaan levy paikallisesti (dvdbackup -M)..."
  rm -f subs.mkv
  # dvdbackup -M = KOKO rakenne (tarvitaan VIDEO_TS.IFO + VTS_NN_0.IFO, muuten dvdvideo ei navigoi)
  dvdbackup -i "$DRIVE" -o "$JOB" -M > dvdbackup.log 2>&1 < /dev/null &
  bpid=$!
  # odota kunnes VTS-rakenne valmis TAI prosessi loppuu (dvdbackup jää joskus roikkumaan lopetukseen)
  VTS=$(printf 'VTS_%02d' "$TITLE")
  while kill -0 $bpid 2>/dev/null; do
    sleep 15
    V=$(find "$JOB" -iname VIDEO_TS -type d 2>/dev/null | head -1)
    [ -n "$V" ] && [ -f "$V/${VTS}_0.IFO" ] && [ -f "$V/VIDEO_TS.IFO" ] && \
      ls "$V/${VTS}_"[1-9]*.VOB >/dev/null 2>&1 && { sleep 30; kill $bpid 2>/dev/null; break; }
  done
  V=$(find "$JOB" -iname VIDEO_TS -type d 2>/dev/null | head -1)
  D=$(dirname "$V")
  [ -f "$V/VIDEO_TS.IFO" ] || die "dvdbackup ei tuottanut VIDEO_TS.IFO:a. Levy voi olla liian vaikea; kokeile toista asemaa tai puhdista levy."
  log "Paikallinen kopio valmis, irrotan siitä..."
  extract "$D" || die "Irrotus paikallisesta kopiostakaan ei onnistunut. Ks. $JOB/extract.log"
fi

NSUB=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 subs.mkv 2>/dev/null | wc -l)
log "Irrotettu $NSUB tekstitysraitaa."

# Levyä ei enää tarvita (loppu on paikallista remuxia) -> avaa kelkka merkiksi että
# levyn voi ottaa/vaihtaa. Skripti jatkaa taustalla remuxiin ja korvaukseen.
eject "$DRIVE" 2>/dev/null && log "Kelkka avattu — levyn voi ottaa. Skripti viimeistelee taustalla."

# --- 3. lisää PAKOLLINEN size-rivi + kielet, rakenna mkvmerge-argumentit ---
python3 - "$JOB" << 'PY'
import json, subprocess, sys, os
job=sys.argv[1]; os.chdir(job)
j=json.loads(subprocess.check_output(["mkvmerge","-J","subs.mkv"]))
subs=[t for t in j["tracks"] if t["type"]=="subtitles"]
hdr=("size: 720x576\norg: 0, 0\nscale: 100%, 100%\nalpha: 100%\n"
     "smooth: OFF\nfadein/out: 50, 50\nalign: OFF at LEFT TOP\ntime offset: 0\nforced subs: OFF\n")
args=[]
for i,t in enumerate(subs):
    b="s%d"%i
    subprocess.run(["mkvextract","tracks","subs.mkv","%d:%s.idx"%(t["id"],b)],
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    s=open(b+".idx").read()
    if "size:" not in s:
        s=s.replace("palette:",hdr+"palette:",1); open(b+".idx","w").write(s)
    args+=["--language","0:"+t["properties"].get("language","und"),b+".idx"]
open("ma.txt","w").write("\x00".join(args))
PY

# --- 4. remux kirjaston tiedostoon (video/ääni koskematta) ---
log "Remuxaan tekstitykset kirjaston tiedostoon..."
mapfile -d "" -t MA < ma.txt
mkvmerge -o "$JOB/RESULT.mkv" --no-subtitles "$LIB" "${MA[@]}" > mux.log 2>&1 || die "mkvmerge epäonnistui, ks. $JOB/mux.log"

# --- 5. verifiointi ---
RN=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$JOB/RESULT.mkv" 2>/dev/null | wc -l)
RDUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$JOB/RESULT.mkv" 2>/dev/null | cut -d. -f1)
[ "$RN" -eq "$NSUB" ] || die "Raitamäärä ei täsmää ($RN vs $NSUB) — kirjastoa EI muutettu. Tulos: $JOB/RESULT.mkv"
[ "$RDUR" -gt $((LIBDUR-5)) ] || die "Kesto muuttui epäilyttävästi — kirjastoa EI muutettu. Tulos: $JOB/RESULT.mkv"
log "Verifiointi OK: $RN raitaa, $((RDUR/60)) min."

# --- 6. atominen korvaus + varmuuskopio kirjaston ULKOPUOLELLE ---
BN=$(basename "$LIB")
mv "$LIB" "$BACKUPS/${FOLDER} — ${BN%.mkv}.desync-bak.mkv"
cp "$JOB/RESULT.mkv" "$DEST/$BN.tmp" && mv "$DEST/$BN.tmp" "$LIB"
log "Kirjaston tiedosto korvattu. Vanha versio: $BACKUPS/"

# --- 7. Jellyfin-päivitys ---
[ -f "$JF_KEY_FILE" ] && curl -s -o /dev/null -X POST "http://localhost:8096/Library/Refresh" \
  -H "X-Emby-Token: $(cat "$JF_KEY_FILE")" && log "Jellyfin-skannaus käynnistetty."

echo
log "VALMIS: $FOLDER — $NSUB tekstitysraitaa korjattu. Tarkista VLC:ssä (tekstitykset pitää valita käsin, DVD-VobSub ei käynnisty automaattisesti)."
log "Työkansio (voit poistaa kun tyytyväinen): $JOB"
