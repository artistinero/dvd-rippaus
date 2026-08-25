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
SERIES="/mnt/terastation/dlna/vids/series"
BACKUPS="/mnt/terastation/dlna/desync-backups"     # varmuuskopiot KIRJASTON ULKOPUOLELLE
JF_KEY_FILE="/home/keitsi/.config/jellyfin-cc-api-key"
WORK="/home/keitsi/dvd-rip-tmp/tekstityskorjaus"
STALL_SECS=40         # jos suora luku ei tuota mitään näin monessa sekunnissa -> dvdbackup
# --------------------

die(){ echo "VIRHE: $*" >&2; exit 1; }
log(){ echo "[$(date +%H:%M:%S)] $*"; }

TARGET="${1:-}"
[ -n "$TARGET" ] || die "Anna nimi (osittainenkin käy): elokuva \"Lipton Cockton\" tai sarjan jakso \"Andromeda S01E01\""
# Etsi KOHDETIEDOSTO (.mkv) sekä movies- ETTÄ series-puusta (ekstrat pois). Sarjan jakso
# annetaan täsmällisesti (esim. "Andromeda S01E01"), jotta oikea jakso osuu.
mapfile -t FILES < <(find "$MOVIES" "$SERIES" -type f -iname "*$TARGET*.mkv" ! -iname '*-extra.mkv' 2>/dev/null | sort)
if [ "${#FILES[@]}" -eq 0 ]; then
  die "Tiedostoa ei löydy nimellä \"$TARGET\" (movies/series). Tarkista kirjoitusasu."
elif [ "${#FILES[@]}" -gt 1 ]; then
  # Jos kaikki osumat samassa kansiossa (elokuva + osat) -> valitse pisin (= pääelokuva).
  # Muuten (esim. sarjan useita jaksoja) -> pyydä tarkentamaan.
  d0="$(dirname "${FILES[0]}")"; samedir=1
  for f in "${FILES[@]}"; do [ "$(dirname "$f")" = "$d0" ] || samedir=0; done
  if [ "$samedir" -eq 1 ]; then
    LIB=""; _md=0
    for f in "${FILES[@]}"; do
      _d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)
      [ -n "$_d" ] && [ "$_d" -gt "$_md" ] && { _md=$_d; LIB=$f; }
    done
  else
    echo "Useita osumia nimellä \"$TARGET\" — tarkenna (esim. lisää jaksonumero S01E01):" >&2
    printf '  %s\n' "${FILES[@]#$MOVIES/}" >&2
    exit 1
  fi
else
  LIB="${FILES[0]}"
fi
DEST="$(dirname "$LIB")"
FOLDER="$(basename "$LIB" .mkv)"
log "Löydettiin: $(basename "$LIB")  (kansio: ${DEST##*/})"

[ -x "$FFMPEG_DVD" ] || die "dvdvideo-ffmpeg puuttuu: $FFMPEG_DVD"
command -v lsdvd >/dev/null || die "lsdvd puuttuu (sudo apt install lsdvd)"
command -v dvdbackup >/dev/null || die "dvdbackup puuttuu"
command -v mkvmerge >/dev/null || die "mkvmerge puuttuu (mkvtoolnix)"

mkdir -p "$WORK" "$BACKUPS"
SAFE=$(echo "$FOLDER" | tr -c 'A-Za-z0-9' '_')
JOB="$WORK/$SAFE"; rm -rf "$JOB"; mkdir -p "$JOB"; cd "$JOB" || die "cd $JOB"

# --- 1. lue levy + valitse titteli KOHDETIEDOSTON KESTON mukaan ---
# Sulje kelkka ensin (skripti avaa sen lopuksi, joten levynvaihdon jälkeen se on auki).
eject -t "$DRIVE" 2>/dev/null && sleep 12
LIBDUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$LIB" 2>/dev/null | cut -d. -f1)
[ -n "$LIBDUR" ] && [ "$LIBDUR" -gt 0 ] || die "Kohdetiedoston kestoa ei saatu: $LIB"
log "Kohdetiedosto: $(basename "$LIB") ($((LIBDUR/60)) min)"
log "Luen levyn rakenteen ($DRIVE)..."
LSD=""
for _try in 1 2 3; do
  LSD=$(lsdvd "$DRIVE" 2>/dev/null | grep '^Title:')
  [ -n "$LSD" ] && break
  sleep 8
done
[ -n "$LSD" ] || die "Levyä ei voi lukea. Onko levy asemassa ja ehjä? Kokeile kelkan avaus/sulku."
# Jos titteli annettu käsin 2. argumenttina, käytä sitä (esim. sarjan jaksoille joissa kesto
# ei erottele tittelöitä luotettavasti: korjaa-tekstitys.sh "Andromeda S01E02" 2).
if [ -n "${2:-}" ]; then
  TITLE=$((10#$2)); _best=0
  log "Titteli annettu käsin: $TITLE"
else
# Valitse titteli jonka kesto on lähinnä kohdetiedostoa (moniosaisella levyllä kaksi pitkää
# titteliä -> pisin ei riitä, pitää täsmätä oikea jakso keston perusteella).
TITLE=""; _best=999999
while IFS= read -r line; do
  tn=$(echo "$line"  | sed -E 's/^Title: 0*([0-9]+),.*/\1/')
  hh=$(echo "$line" | sed -E 's/.*Length: ([0-9]+):([0-9]+):([0-9]+).*/\1/')
  mm=$(echo "$line" | sed -E 's/.*Length: ([0-9]+):([0-9]+):([0-9]+).*/\2/')
  ss=$(echo "$line" | sed -E 's/.*Length: ([0-9]+):([0-9]+):([0-9]+).*/\3/')
  [ -n "$tn" ] && [ -n "$hh" ] || continue
  secs=$((10#$hh*3600 + 10#$mm*60 + 10#$ss))
  diff=$(( secs>LIBDUR ? secs-LIBDUR : LIBDUR-secs ))
  [ "$diff" -lt "$_best" ] && { _best=$diff; TITLE=$tn; }
done <<< "$LSD"
[ -n "$TITLE" ] || die "Levyltä ei löytynyt sopivaa titteliä."
if [ "$_best" -gt 180 ]; then
  log "VAROITUS: lähin levyn titteli poikkeaa kohteesta ${_best}s — tarkista tulos erityisen huolella."
fi
log "Valittu levyn titteli $TITLE (kestoero ${_best}s kohteeseen)."
fi

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
  # Odota kunnes KOHDE-VTS on KOKONAAN kopioitu. TÄRKEÄ: älä tapa heti kun ensimmäinen VOB-osa
  # ilmestyy — iso titteli on useassa VOB-osassa, ja liian aikainen tappo jättää kopion vajaaksi
  # -> irrotus saa vain osan tekstityksistä (Easy Rider -bugi 2026-08-25). Seuraa VOB-osien
  # yhteiskokoa: kun se ei enää kasva (30s vakaa), kohde-VTS on valmis -> tapa dvdbackup.
  VTS=$(printf 'VTS_%02d' "$TITLE")
  prev=-1; stable=0
  while kill -0 $bpid 2>/dev/null; do
    sleep 15
    V=$(find "$JOB" -iname VIDEO_TS -type d 2>/dev/null | head -1)
    [ -n "$V" ] && [ -f "$V/${VTS}_0.IFO" ] && [ -f "$V/VIDEO_TS.IFO" ] || continue
    cur=$(du -sb "$V/${VTS}"_[1-9]*.VOB 2>/dev/null | awk '{s+=$1} END{print s+0}')
    if [ "$cur" -gt 0 ] && [ "$cur" -eq "$prev" ]; then
      stable=$((stable+1))
      [ "$stable" -ge 2 ] && { kill $bpid 2>/dev/null; break; }   # 2×15s = 30s ei kasvua = valmis
    else
      stable=0
    fi
    prev=$cur
  done
  V=$(find "$JOB" -iname VIDEO_TS -type d 2>/dev/null | head -1)
  D=$(dirname "$V")
  [ -f "$V/VIDEO_TS.IFO" ] || die "dvdbackup ei tuottanut VIDEO_TS.IFO:a. Levy voi olla liian vaikea; kokeile toista asemaa tai puhdista levy."
  log "Paikallinen kopio valmis, irrotan siitä..."
  extract "$D" || die "Irrotus paikallisesta kopiostakaan ei onnistunut. Ks. $JOB/extract.log"
fi

NSUB=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 subs.mkv 2>/dev/null | wc -l)
log "Irrotettu $NSUB tekstitysraitaa."

# SISÄLLÖN TARKISTUS: laske suurin tekstityspakettimäärä raitojen yli. Jos KAIKKI raidat ovat
# lähes tyhjiä (esim. ~30 pakettia täyspitkälle elokuvalle), irrotus/kopio meni vajaaksi
# (Easy Rider -bugi 2026-08-25). Kynnys: väh. 100 pakettia jollain raidalla, tai 1/min elokuvaa.
MAXPK=0
for _i in $(seq 0 $((NSUB-1))); do
  _c=$(ffprobe -v error -select_streams s:$_i -show_entries packet=pts_time -of csv=p=0 subs.mkv 2>/dev/null | wc -l)
  [ "$_c" -gt "$MAXPK" ] && MAXPK=$_c
done
MINEXPECT=$(( LIBDUR/60 ))   # karkea: väh. ~1 tekstitys per minuutti elokuvaa
[ "$MINEXPECT" -lt 100 ] && MINEXPECT=100
if [ "$MAXPK" -lt "$MINEXPECT" ]; then
  die "Tekstitysraidat epäilyttävän tyhjiä (suurin vain $MAXPK pakettia, odotus ~$MINEXPECT). Kopio jäi todennäköisesti vajaaksi — KIRJASTOA EI MUUTETTU. Tulos: $JOB/subs.mkv"
fi
log "Sisältötarkistus OK (suurin raita $MAXPK pakettia)."

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
# HUOM: EI verrata format-kestoa — se heijastaa tekstitysraidan pituutta, ei videota (vanhat
# desync-tekstitykset voivat venyä videon yli -> väärä hälytys, Andromeda-tapaus 2026-08-25).
# mkvmerge --no-subtitles LIB kopioi videon+äänen sellaisenaan, joten sisältö säilyy varmasti;
# tarkistetaan että video+ääni-raidat säilyivät ja tekstitysmäärä täsmää.
RN=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$JOB/RESULT.mkv" 2>/dev/null | wc -l)
RVA=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$JOB/RESULT.mkv" 2>/dev/null | wc -l)
LVA=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$LIB" 2>/dev/null | wc -l)
RAU=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$JOB/RESULT.mkv" 2>/dev/null | wc -l)
LAU=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$LIB" 2>/dev/null | wc -l)
[ "$RN" -eq "$NSUB" ]  || die "Tekstitysmäärä ei täsmää ($RN vs $NSUB) — kirjastoa EI muutettu. Tulos: $JOB/RESULT.mkv"
[ "$RVA" -ge 1 ] && [ "$RVA" -eq "$LVA" ] || die "Videoraita katosi/muuttui — kirjastoa EI muutettu. Tulos: $JOB/RESULT.mkv"
[ "$RAU" -eq "$LAU" ] || die "Ääniraitojen määrä muuttui ($RAU vs $LAU) — kirjastoa EI muutettu. Tulos: $JOB/RESULT.mkv"
log "Verifiointi OK: $RVA video + $RAU ääni + $RN tekstitystä (video/ääni säilyivät)."

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
