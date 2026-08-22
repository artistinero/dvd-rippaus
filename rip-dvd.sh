#!/bin/bash
# rip-dvd.sh — Interaktiivinen DVD-rippaus ja enkoodaus
#
# Käyttö:
#   rip-dvd.sh                          Normaali rippaus + enkoodaus
#   rip-dvd.sh --encode-only <hakemisto> Enkoodaa olemassaoleva sessio uudelleen
#   rip-dvd.sh --skip   <hakemisto> "<tiedostonimi>" Luovu raidasta pysyvästi
#   rip-dvd.sh --unskip <hakemisto> "<tiedostonimi>" Peru luovutus, yritä uudelleen
#
# Vaatii: dvdbackup, HandBrakeCLI, lm-sensors, python3, flock (util-linux)

# Nämä kaksi riviä tekevät skriptistä tiukemman virheiden suhteen, jotta
# hiljaiset kirjoitusvirheet eivät jää huomaamatta:
# -u  : jos koodissa käytetään muuttujaa jota ei ole koskaan asetettu, skripti
#       pysähtyy heti virheeseen sen sijaan että jatkaisi tyhjällä arvolla.
# -o pipefail : kun useampi komento on ketjutettu putkella (komento1 | komento2),
#       koko ketjun tulos lasketaan epäonnistuneeksi jos MIKÄ TAHANSA osa siitä
#       epäonnistuu — ei vain viimeinen komento.
# (Tarkoituksella EI ole -e:tä, joka pysäyttäisi skriptin heti minkä tahansa
# komennon epäonnistuessa — moni komento tässä skriptissä saa epäonnistua
# tarkoituksella, esim. tarkistus "onko tällainen prosessi käynnissä".)
set -uo pipefail
export TZ="Europe/Helsinki"  # Aikaleimat lokissa Suomen aikaa, ei palvelimen omaa

# ── Tmux-autostart ─────────────────────���──────────────────────────────────────
# Skripti vaatii tmux-session jotta prosessi jää eloon kun SSH-yhteys katkeaa.
# Jos tmux ei ole päällä, skripti käynnistää itsensä uudelleen tmux-session sisällä.
# Jos käyttäjä pyysi ohjeen (--help tai -h), näytetään se ja lopetetaan heti —
# tätä osaa ei suoriteta normaalin rippauksen yhteydessä.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "--?" ]]; then
    OUTBASE="/home/keitsi/dvd-rip-tmp"
    cat <<'EOF'
Käyttö:
  rip-dvd.sh                           Normaali rippaus + enkoodaus
  rip-dvd.sh --encode-only <hakemisto>  Enkoodaa olemassaoleva sessio uudelleen
  rip-dvd.sh --skip   <hakemisto> "<tiedostonimi>"  Luovu raidasta pysyvästi
  rip-dvd.sh --unskip <hakemisto> "<tiedostonimi>"  Peru luovutus
  rip-dvd.sh --help                    Tämä ohje

--encode-only on hyödyllinen kun bootti tai muu keskeytys katkaisee enkoodauksen.
Skripti ohittaa automaattisesti raidat jotka ovat jo terastationilla.

--skip on tarkoitettu raidalle joka epäonnistuu toistuvasti samasta syystä
(esim. levyvaurio) eikä sitä enää kannata yrittää. Ohitettu raita ei enää
laukaise "enkoodaamattomia sessioita" -kysymystä, mutta lähde-VOB säilyy
levyllä koskemattomana — muut saman levyn raidat yritetään silti normaalisti.
Tiedostonimi on sama kuin FAIL_TITLE-riveillä epäonnistumisraportissa, esim:
  rip-dvd.sh --skip ~/dvd-rip-tmp/session_20260813_212344 "Bender's Big Score - Part 01.mkv"

EOF
    echo "Olemassaolevat sessiot joissa on dvdbackup-dataa:"
    local_found=0
    for d in "$OUTBASE"/session_*/; do
        [[ -d "$d" ]] || continue
        if [[ -n "$(find "$d" -name "*.VOB" -size +10M 2>/dev/null | head -1)" ]]; then
            echo "  rip-dvd.sh --encode-only $d"
            local_found=1
        fi
    done
    (( local_found )) || echo "  (ei löydy)"
    exit 0
fi

# ── --skip / --unskip: nopea synkroninen komento, ei vaadi tmux-istuntoa ────
# Nämä vain lisäävät/poistavat rivin sessio-hakemiston .skip-titles-tiedostoon
# — ei rippausta eikä enkoodausta, joten ei tarvetta pysyä hengissä SSH:n
# katkettua. Käsitellään tässä ennen tmux-käynnistystä, jotta komento ei jää
# jumiin odottamaan tmux-istuntoa tai liity vahingossa väärään sessioon.
if [[ "${1:-}" == "--skip" || "${1:-}" == "--unskip" ]]; then
    _action="$1"; _sdir="${2:-}"; _title="${3:-}"
    if [[ -z "$_sdir" || -z "$_title" ]]; then
        echo "Käyttö: rip-dvd.sh ${_action} <session-hakemisto> \"<tiedostonimi>\"" >&2
        exit 1
    fi
    if [[ ! -d "$_sdir" ]]; then
        echo "VIRHE: Hakemisto ei löydy: $_sdir" >&2
        exit 1
    fi
    _sf="${_sdir%/}/.skip-titles"
    if [[ "$_action" == "--skip" ]]; then
        if grep -qFx "$_title" "$_sf" 2>/dev/null; then
            echo "Jo merkitty pysyvästi ohitetuksi: $_title"
        else
            echo "$_title" >> "$_sf"
            echo "Merkitty pysyvästi ohitetuksi: $_title"
            echo "(Lähde-VOB säilyy koskemattomana — poista se itse jos haluat vapauttaa tilaa.)"
        fi
    else
        if [[ -f "$_sf" ]] && grep -qFx "$_title" "$_sf"; then
            # HUOM: grep -v palauttaa exit 1 (ei "virhe", vaan "ei jäänyt yhtään
            # riviä") kun poistettava rivi oli tiedoston AINOA rivi — "&&" tässä
            # olisi silloin estänyt mv:n suorittumisen kokonaan ja rivi olisi
            # jäänyt tiedostoon näennäisesti poistetun näköisenä. Siksi mv
            # ajetaan aina, riippumatta grepin exit-koodista.
            grep -vFx "$_title" "$_sf" > "${_sf}.tmp"
            mv "${_sf}.tmp" "$_sf"
            echo "Poistettu ohituslistalta — yritetään uudelleen seuraavalla enkoodauksella: $_title"
        else
            echo "Ei ollut ohituslistalla: $_title"
        fi
    fi
    exit 0
fi

# Tmux on ohjelma joka pitää istunnon (ja siinä käynnissä olevat ohjelmat)
# hengissä vaikka SSH-yhteys katkeaisi tai läppäri suljettaisiin. Tämän
# skriptin nimi vaihtelee sen mukaan onko kyseessä normaali rippaus
# ("dvd-rip") vai pelkkä enkoodauksen uudelleenkäynnistys ("dvd-encode"),
# jotta molemmat voivat olla käynnissä yhtä aikaa törmäämättä toisiinsa.
_SESSION="dvd-rip"
[[ "${1:-}" == "--encode-only" ]] && _SESSION="dvd-encode"
# ${TMUX:-} on tyhjä jos skripti EI vielä pyöri tmux-istunnon sisällä.
# Tässä tapauksessa käynnistetään tmux ja siirrytään sen sisään, jotta
# rippaus/enkoodaus jatkuu vaikka käyttäjä katkaisee yhteyden.
if [[ -z "${TMUX:-}" ]]; then
    if tmux has-session -t "$_SESSION" 2>/dev/null; then
        # Sama-niminen istunto on jo käynnissä. --encode-only-tilassa siihen
        # EI liitytä suoraan, koska silloin tämän kutsun oma hakemistopolku-
        # argumentti unohtuisi — käyttäjää pyydetään liittymään käsin.
        if [[ "${1:-}" == "--encode-only" ]]; then
            echo "VIRHE: Sessio '$_SESSION' on jo käynnissä — --encode-only-argumentit häviäisivät."
            echo "Liity olemassaolevaan: tmux attach -t $_SESSION"
            echo "Tai tarkista: tmux ls"
            exit 1
        fi
        echo "Sessio '$_SESSION' on jo käynnissä — liitytään."
        exec tmux attach -t "$_SESSION"
    else
        # Ei vielä käynnissä olevaa istuntoa — luodaan uusi ja käynnistetään
        # tämä sama skripti sen sisällä samoilla argumenteilla ("$0" "$@").
        exec tmux new-session -s "$_SESSION" "$0" "$@"
    fi
fi

# ── Globaalit muuttujat ───────────────────��───────────────────────────────────
OUTBASE="/home/keitsi/dvd-rip-tmp"          # Rippauksen väliaikaiset tiedostot
DEST_ROOT="/mnt/terastation/dlna/vids"       # Kohdehakemisto terastationilla
LOGFILE="/home/keitsi/logs/rip-dvd.log"       # Lokitiedosto (liitetään, ei ylikirjoiteta)
mkdir -p "$(dirname "$LOGFILE")"

# Lämpötilavalvonta (yksikkö: °C) — estää tietokonetta ylikuumenemasta pitkän
# enkoodauksen aikana. Kolme rajaa toimivat yhdessä kuin termostaatti:
# TEMP_WARN:   kun lämpötila nousee tämän yli, enkoodausohjelma laitetaan
#              hetkeksi tauolle (kuin pause-nappi) kunnes kone jäähtyy.
# TEMP_RESUME: kun lämpötila on laskenut tämän alle, tauolla oleva ohjelma
#              jatkaa siitä mihin jäi.
# TEMP_KILL:   jos lämpötila nousee silti tähän asti (tauko ei riittänyt),
#              enkoodausohjelma sammutetaan kokonaan hätätilanteena — tämä on
#              parempi vaihtoehto kuin antaa koneen sammua itsestään 100°C:ssa.
# Ero WARN:n ja RESUME:n välillä (85→50=35°C) on tarkoituksella iso, jotta
# kone ei jää nykimään tauolle-ja-jatkoon-ja-taas-tauolle nopeasti peräkkäin.
TEMP_WARN=85
TEMP_RESUME=50
TEMP_KILL=95

# Raidat alle tämän keston (sekunteina) ohitetaan enkoodauksessa.
# Tarkoitus: poistaa DVD:n menu-videot ja muut lyhyet "otsikot" jonosta.
MIN_DURATION=60

# Lukitustiedosto: varmistaa että vain yksi enkoodaus pyörii kerrallaan, vaikka
# useampi rippaussessio yrittäisi käynnistää sen samaan aikaan. Toimii kuin
# vessan ovilukko — se joka saa lukon ensin, pääsee sisään, muut jonottavat
# ulkopuolella kunnes lukko vapautuu. Tämä tapa (flock) on luotettavampi kuin
# pelkkä "tarkista onko toinen jo käynnissä" -kysely, koska kaksi prosessia ei
# voi koskaan saada lukkoa täsmälleen samalla hetkellä.
ENCODE_LOCKFILE="/tmp/rip-dvd-encode.lock"

# Aikakatkaisu dvdbackupille sekunteina. Normaali rippaus ~20 min — 2 h on ylikärsivällinen.
# Timeoutin jälkeen levy ohitetaan ja jatketaan seuraavaan tai enkoodaukseen.
RIP_TIMEOUT=7200
# Aikakatkaisu HandBrakelle per raita. 58 min jakso ~1 h, throttling voi pidentää 3–4 x.
ENC_TIMEOUT=14400
# Montako kertaa yritetään rippata uudelleen epäonnistumisen jälkeen (ei timeoutin jälkeen).
MAX_RIP_ATTEMPTS=2

# Aikakatkaisu HandBraken --scan-komennolle sekunteina. Normaali skannaus kestää muutaman
# sekunnin — 3 min on ylikärsivällinen. Lisätty 2026-08-20 sen jälkeen kun havaittiin että
# vaurioituneella levyllä ("American Beauty") --scan voi jäädä loputtomasti yrittämään yhden
# esikatselukehyksen hakemista eikä koskaan palaa itsestään — ilman tätä aikakatkaisua koko
# rip-dvd.sh jäisi ikuisesti jumiin eikä pääsisi koskaan kysymään seuraavaa levyä.
SCAN_TIMEOUT=180
# Minimitila brainbinillä enkoodauksen aikana — alle tämän pysäytetään.
ENC_SPACE_MIN_GB=3
# Enkoodausnopeusarvio jonon keston laskentaan: GB VOB-dataa tunnissa.
# 5 GB/h ≈ 58 min jakso (2 GB VOB) ~24 min — säädä jos todellisuus poikkeaa paljon.
ENCODE_SPEED_GB_PER_HOUR=5

# ── Apufunktiot ───────────────────────���───────────────────────────────────────

# Kirjoittaa viestin sekä näytölle että lokitiedostoon aikaleiman kanssa.
# Käytetään kaikkialla skriptissä normaalin echo:n sijaan, jotta kaikki
# tapahtumat jäävät talteen lokiin myöhempää tarkastelua varten.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

NTFY_URL="http://127.0.0.1:4444/dvd-rippaus"

# Lähettää ntfy-ilmoituksen. Epäonnistuminen (esim. ntfy pois päältä) ei saa
# koskaan katkaista enkoodausta — siksi -m timeout ja || true.
notify() {
    local title="$1" msg="$2" prio="${3:-default}"
    curl -s -m 10 -d "$msg" \
        -H "Title: $title" \
        -H "Priority: $prio" \
        "$NTFY_URL" >/dev/null 2>&1 || log "  VAROITUS: ntfy-ilmoitus epäonnistui"
}
_wait_enter() {
    echo "" >&2
    echo "  Loki: $LOGFILE" >&2
    echo "  [Paina VÄLILYÖNTIÄ sulkeaksesi]" >&2
    # Välilyönti eikä Enter tahallaan: 'q'-komennon perässä tuleva Enter
    # (tai muu nopea näppäily) ei saa vahingossa sulkea juuri auennutta raporttia.
    [[ -e /dev/tty ]] || return
    local _key="" _deadline=$(( $(date +%s) + 180 ))
    while (( $(date +%s) < _deadline )); do
        # IFS= pakollinen: muuten read karsii välilyönnin pois muuttujasta
        # vaikka -n1 lukisi sen onnistuneesti (exit 0, ei aikakatkaisu) —
        # ilman tätä _key jää aina tyhjäksi eikä välilyönti koskaan täsmää.
        IFS= read -rsn1 -t 5 _key < /dev/tty 2>/dev/null
        [[ "$_key" == " " ]] && return
    done
}
# Kirjoittaa virheilmoituksen lokiin ja lopettaa koko skriptin suorituksen.
# Käytetään tilanteissa joista ei voi jatkaa (esim. terastation ei löydy).
die() {
    log "VIRHE: $*"
    _wait_enter
    exit 1
}
# Tämä ajetaan AINA kun skripti lopettaa toimintansa, tapahtuipa se hallitusti
# vai odottamattoman virheen takia (esim. ohjelmointivirhe jota ei osattu
# ennakoida). Jos lopetus oli siisti (exit-koodi 0), tämä ei tee mitään.
# Jos jokin meni pieleen, näytetään selkeä viesti ennen kuin ikkuna sulkeutuu,
# jotta käyttäjä ehtii lukea mitä tapahtui ennen kuin tmux-ikkuna katoaa.
_exit_trap() {
    local rc=$?
    (( rc == 0 )) && return
    echo "" >&2
    echo "  *** Skripti kaatui odottamatta (exit $rc) ***" >&2
    _wait_enter
}
trap _exit_trap EXIT

# Kysyy tietokoneen lämpötila-antureilta niiden nykyiset lukemat ja palauttaa
# näistä korkeimman celsiusasteina (esim. jos yksi antureista näyttää 60 ja
# toinen 75, palautetaan 75). Jos lämpötilaa ei syystä tai toisesta saada
# selville, palautetaan 0 — tällöin lämpötilavalvonta ei tee mitään erikoista,
# eli tämä on turvallinen "ei tietoa" -arvo eikä väärä hälytys.
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

# Tämä funktio pyörii jatkuvasti taustalla koko enkoodauksen ajan ja tarkkailee
# tietokoneen lämpötilaa 10 sekunnin välein. Se toimii kolmiportaisesti:
#   - lämpö nousee liikaa → laittaa enkoodausohjelman tauolle
#   - lämpö laskee riittävästi → antaa sen jatkaa
#   - lämpö nousee silti vaarallisen korkeaksi → sammuttaa sen kokonaan
#
# HUOM koodin rakenteesta: enkoodausohjelma (HandBrakeCLI) voi joskus pyöriä
# useampana erillisenä prosessina yhtä aikaa, ei vain yhtenä. Siksi kaikkien
# käynnissä olevien kappaleiden tunnistenumerot (PID) kerätään ensin listaksi
# (`hb_pids`), ja tauolle-laitto/jatko/sammutus tehdään kaikille listan
# jäsenille kerralla. Jos tämä tehtäisiin vain yhdelle tunnistenumerolle
# kerrallaan, osa prosesseista voisi jäädä vahingossa huomiotta.
throttle_loop() {
    local paused=0
    while true; do
        sleep 10  # Tarkistusväli: 10s on riittävän nopea reagoimaan lämpöpiikkeihin
        local -a hb_pids
        mapfile -t hb_pids < <(pgrep -x HandBrakeCLI 2>/dev/null)
        local temp
        temp=$(get_temp)

        # Ei HandBrakeCLI-prosesseja — nollaa paussi-tila ja odota
        if (( ${#hb_pids[@]} == 0 )); then
            paused=0
            continue
        fi

        if (( temp >= TEMP_KILL )); then
            # Hätätilanne — lämpö on vaarallisen korkealla. Sammutetaan
            # enkoodausohjelma väkisin ja välittömästi (tätä komentoa ei voi
            # jättää huomiotta, toisin kuin tavallista "sulje siististi"
            # -pyyntöä). Tämä on parempi vaihtoehto kuin antaa koneen itsensä
            # sammua yllättäen ylikuumenemisen takia.
            kill -KILL "${hb_pids[@]}" 2>/dev/null || true
            log "  HÄTÄSAMMUTUS: ${temp}°C ylittää TEMP_KILL=${TEMP_KILL}°C — HandBrakeCLI tapettu!"
            paused=0
        elif (( temp >= TEMP_WARN )); then
            # Lämpötila liian korkea — laitetaan enkoodausohjelma tauolle.
            # Tauolle laitettu ohjelma säilyy muistissa ja jatkaa täsmälleen
            # samasta kohdasta kun sen annetaan myöhemmin jatkaa.
            #
            # HUOM (löydetty ja korjattu 2026-08-21 koodikatselmoinnissa):
            # kill -STOP lähetetään AINA kun lämpö on yhä liian korkea, EI
            # vain silloin kun paused vasta muuttuu 0→1. Ilman tätä uusi
            # HandBrakeCLI-prosessi joka käynnistyy KESKEN kuumuuspaussin
            # (esim. manuaalisesti flockin ohi ajettu, kuten tässä projektissa
            # on tehty) jäisi kokonaan suojaamattomaksi TEMP_KILL-hätärajaan
            # asti, koska hb_pids luetaan uudelleen joka kierroksella mutta
            # paused==0-ehto esti STOP:in uusintalähetyksen. kill -STOP jo
            # pysäytetylle prosessille on harmiton no-op, joten tämä on
            # turvallista tehdä joka kierros ilman sivuvaikutuksia.
            kill -STOP "${hb_pids[@]}" 2>/dev/null || true
            if (( paused == 0 )); then
                paused=1
                log "  Throttle: paussi ${temp}°C (raja: ${TEMP_WARN}°C)"
            fi
        elif (( temp <= TEMP_RESUME )) && (( paused == 1 )); then
            # Lämpötila on jäähtynyt riittävästi — annetaan tauolla olevan
            # ohjelman jatkaa työtään.
            kill -CONT "${hb_pids[@]}" 2>/dev/null || true
            paused=0
            log "  Throttle: jatkuu ${temp}°C (raja: ${TEMP_RESUME}°C)"
        fi
    done
}

# Muotoilee sekunnit ihmisluettavaan muotoon: "2h 35min" tai "47min"
fmt_time() {
    local s=$1
    local h=$(( s/3600 )) m=$(( (s%3600)/60 ))
    (( h > 0 )) && printf '%dh %dmin' "$h" "$m" || printf '%dmin' "$m"
}

# Varmistaa terastationin saatavuuden — yrittää mountata jos ei ole mountattu.
# Palauttaa 0 jos onnistui, 1 jos kaikki yritykset epäonnistuivat.
# Kutsuja päättää onko epäonnistuminen kohtalokas (die) vai ohitettava (continue/log).
ensure_terastation() {
    local mountpt="/mnt/terastation/dlna"
    mountpoint -q "$mountpt" && return 0
    local tries=5 try mount_out
    for (( try=1; try<=tries; try++ )); do
        log "Terastation ei mountattu — yritetään ($try/$tries)..."
        if ! mount_out=$(sudo mount "$mountpt" 2>&1); then
            mount_out=$(mount "$mountpt" 2>&1) || true
        fi
        if mountpoint -q "$mountpt"; then
            log "  Terastation mountattu."
            return 0
        fi
        [[ -n "$mount_out" ]] && log "  mount-virhe: ${mount_out}"
        (( try < tries )) && sleep 10
    done
    log "VIRHE: terastation ei saatu mountattua ${tries} yrityksellä"
    return 1
}

# Odottaa terastationia enintään max_secs sekuntia, yrittäen mountata 30s välein.
# Käytetään boottauksen jälkeen kun verkko tai NAS ei ole vielä valmis.
wait_for_terastation() {
    local max_secs="${1:-300}"
    local interval=30
    local elapsed=0
    ensure_terastation && return 0
    log "Terastation ei vielä saatavilla — odotetaan enintään $(( max_secs/60 )) min..."
    while (( elapsed < max_secs )); do
        sleep "$interval"
        (( elapsed += interval )) || true
        log "  Yritetään terastationia uudelleen (${elapsed}/${max_secs}s)..."
        ensure_terastation && return 0
    done
    return 1
}

# Muuntaa yhden DVD-raidan MKV-videotiedostoksi HandBrake-ohjelmalla ja
# näyttää samalla reaaliaikaisen edistymisprosentin ruudulla.
#
# Parametrit (annetaan järjestyksessä funktiota kutsuttaessa):
#   $1 = lähde (dvdbackup-hakemisto tai MKV-tiedosto)
#   $2 = minne valmis tiedosto kirjoitetaan
#   $3 = DVD:n raidan numero (tyhjä = HandBrake valitsee itse)
#   $4 = pelkkä nimilappu edistymispalkkia varten (esim. "S03E01"),
#        ei vaikuta itse muunnokseen
#
# Käytetyt muunnosasetukset selkokielellä:
#   x265, laatuaste 21  — videopakkaustapa joka tuottaa hyvälaatuisen mutta
#                          silti kohtuukokoisen tiedoston
#   kaikki ääniraidat kopioidaan sellaisenaan (ei pakata uudelleen), paitsi
#   jos kopiointi ei jostain syystä onnistu, jolloin käytetään AAC-pakkausta
#   kaikki tekstitysraidat kopioidaan mukaan
#   lomituksen poisto ("comb detect / decomb") — vanhoilla DVD-levyillä kuva on
#   usein tallennettu tekniikalla joka näkyy raidoituksena liikkeessä; tämä
#   asetus tunnistaa ja korjaa sen automaattisesti
#   kuvasuhde ja reunojen rajaus säädetään automaattisesti alkuperäisen
#   DVD:n mukaiseksi
#
# Minimi ylärajaus pikseleinä. The Wire -levyiltä (ja mahdollisesti muilta
# samantyyppisiltä lähteiltä) löytyi 2026-08-19 n. 4 pikselin rivi kohinaa/
# VBI-jäännöstä kuvan aivan yläreunassa (mitattu suoraan pikseliarvoista:
# rivit 0-2 keskikirkkaus ~26, rivi 3 siirtymä ~19, rivi 4+ normaali kuva
# ~12) — se ei ole tarpeeksi tummaa jotta HandBraken automaattinen
# --crop-mode auto tunnistaisi sen mustaksi reunaksi ja poistaisi sen. Tämä
# on se rajausmäärä jota käytetään SILLOIN KUN _detect_top_artifact() alla
# mittaa häiriön oikeasti olevan läsnä (ks. seuraava kommentti — EI koskaan
# sokeasti kaikille levyille). 6px on häviävän pieni osa kuvan korkeudesta
# (alle 1% PAL:n 576 pikselistä) eikä siis leikkaa havaittavasti oikeaa
# kuvasisältöä levyillä joilla tätä häiriötä ei ole.
readonly MIN_TOP_CROP_PX=6

# TÄRKEÄ KORJAUS 2026-08-19: alkuperäinen versio pakotti MIN_TOP_CROP_PX:n
# SOKEASTI kaikille levyille joiden automaattitunnistus antoi vähemmän —
# tämä olisi leikannut oikeaa kuvasisältöä pois levyiltä joilla ei ole
# mitään häiriötä ja joilla kuva aidosti ulottuu ylimpään riviin asti
# (esim. reunaton 4:3-lähde). Käyttäjä huomautti tästä aiheellisesti.
# Nyt EI pakoteta mitään ilman mittausta — ks. _detect_top_artifact()
# alla, joka oikeasti tarkistaa pikselikirkkauden ennen päätöstä.

# Ottaa yhden esikatselukehyksen annetusta otsikosta ja mittaa onko sen
# ylimmissä MIN_TOP_CROP_PX riveissä poikkeavaa kirkkautta verrattuna niitä
# heti seuraaviin riveihin (sama menetelmä jolla häiriö alunperin todistettiin
# The Wire S01E01:stä käsin: rivit 0-2 keskikirkkaus ~26, normaali kuva ~12
# eli suhde >2×). Palauttaa "1" vain jos ero on selvä (>1.5×) — muuten "0",
# jolloin automaattitunnistuksen arvoa EI muuteta.
_detect_top_artifact() {
    local input="$1" title_num="$2"
    local title_arg=()
    [[ -n "$title_num" ]] && title_arg=(--title "$title_num")
    local tmpframe; tmpframe=$(mktemp --tmpdir "rip-dvd-cropcheck-XXXXXX.mkv")
    HandBrakeCLI --input "$input" "${title_arg[@]}" --no-dvdnav \
        --start-at duration:5 --stop-at duration:1 \
        --encoder x264 --encoder-preset ultrafast --quality 40 \
        --crop-mode none \
        --output "$tmpframe" </dev/null >/dev/null 2>&1
    if [[ ! -s "$tmpframe" ]]; then
        rm -f "$tmpframe"
        echo 0
        return
    fi
    local result
    result=$(python3 -c "
import subprocess, sys
MIN_TOP = $MIN_TOP_CROP_PX
wh = subprocess.run(['ffprobe','-v','error','-select_streams','v:0',
    '-show_entries','stream=width,height','-of','csv=p=0','$tmpframe'],
    capture_output=True, text=True).stdout.strip()
try:
    w, h = map(int, wh.split(','))
except Exception:
    print(0); sys.exit()
raw = subprocess.run(['ffmpeg','-v','error','-i','$tmpframe','-vframes','1',
    '-pix_fmt','rgb24','-f','rawvideo','-'], capture_output=True).stdout
need_rows = MIN_TOP + 15
if len(raw) < w*need_rows*3:
    print(0); sys.exit()
def row_avg(y):
    row = raw[y*w*3:(y+1)*w*3]
    return sum(row)/len(row) if row else 0
top_avg = sum(row_avg(y) for y in range(0, MIN_TOP)) / MIN_TOP
below_avg = sum(row_avg(y) for y in range(MIN_TOP, MIN_TOP+15)) / 15
print(1 if (below_avg > 2 and top_avg > below_avg * 1.5) else 0)
" 2>/dev/null)
    rm -f "$tmpframe"
    [[ "$result" == "1" ]] && echo 1 || echo 0
}

# Selvittää HandBraken automaattisesti laskeman rajausarvon skannaamalla
# annetun otsikon, ja nostaa yläraajan MIN_TOP_CROP_PX:ään VAIN jos
# _detect_top_artifact() oikeasti mittaa häiriön olevan läsnä — ei koskaan
# sokeasti. Muut reunat (ala, vasen, oikea) jäävät aina täysin
# automaattitunnistuksen varaan, koska ne vaihtelevat oikeutetusti levyn
# kuvasuhteen mukaan eikä niissä ole havaittu vastaavaa häiriötä. Jos
# skannaus epäonnistuu (esim. vioittunut levy), palataan turvallisesti
# tavalliseen automaattitilaan sen sijaan että koko rippaus kaatuisi tähän.
_get_crop_args() {
    local input="$1" title_num="$2"
    local title_arg=()
    [[ -n "$title_num" ]] && title_arg=(--title "$title_num")
    local scan_out
    scan_out=$(timeout "$SCAN_TIMEOUT" HandBrakeCLI --input "$input" "${title_arg[@]}" --no-dvdnav --scan 2>&1 </dev/null)
    local line
    line=$(grep -o 'autocrop: [0-9]*/[0-9]*/[0-9]*/[0-9]*' <<<"$scan_out" | head -1)
    if [[ -z "$line" ]]; then
        echo "--crop-mode auto"
        return
    fi
    local vals="${line#autocrop: }"
    local top="${vals%%/*}"; vals="${vals#*/}"
    local bottom="${vals%%/*}"; vals="${vals#*/}"
    local left="${vals%%/*}"; vals="${vals#*/}"
    local right="$vals"
    if (( top < MIN_TOP_CROP_PX )); then
        if [[ "$(_detect_top_artifact "$input" "$title_num")" == "1" ]]; then
            top=$MIN_TOP_CROP_PX
        fi
    fi
    echo "--crop-mode custom --crop ${top}:${bottom}:${left}:${right}"
}

# Paluuarvo: kertoo onnistuiko muunnos (0 = onnistui, muu luku = jokin meni
# pieleen — tarkempi selitys eri lukujen merkityksestä löytyy kutsuvasta
# koodista jossa näitä lukuja tulkitaan).
run_hb() {
    local title_arg=()
    [[ -n "${3:-}" ]] && title_arg=(--title "$3")
    local label="${4:-}"

    # HandBrake kirjoittaa oman etenemistietonsa väliaikaiseen tiedostoon sen
    # sijaan että se lähetettäisiin suoraan toiselle ohjelmalle. Näin edistymis-
    # palkkia piirtävä ohjelma (alempana) voi lukea tiedostoa omaan tahtiinsa,
    # eikä sen mahdollinen kaatuminen voi missään tilanteessa vaikuttaa itse
    # videomuunnokseen — ne ovat täysin toisistaan riippumattomia.
    local tmpout; tmpout=$(mktemp --tmpdir "rip-dvd-hb-XXXXXX.log")

    local crop_args; read -ra crop_args <<< "$(_get_crop_args "$1" "${3:-}")"

    # --no-dvdnav: käyttää libdvdread-kirjastoa HandBraken oletuksena olevan
    # libdvdnav:in sijaan. Lisätty 2026-08-18 epäillyn tekstitys-synkkabugin
    # takia (ks. muistiinpanot) — libdvdnav on yleisesti luotettavampi mutta
    # tunnetusti epäluotettavampi juuri monikerroslevyillä/solunavigoinnissa,
    # mikä sopii havaittuun oireeseen (tekstitysraidan ajastus hyppää kesken
    # tiedoston, kuva ei). EI VIELÄ VARMISTETTU korjaavan itse ongelmaa —
    # perustuu dokumentoituun HandBraken tunnettuun eroon näiden kirjastojen
    # välillä, ei suoraan testattuun todisteeseen että tämä juuri korjaa sen.
    HandBrakeCLI \
        --input "$1" "${title_arg[@]}" --output "$2" \
        --encoder x265 --quality 21 \
        --comb-detect --decomb \
        --loose-anamorphic "${crop_args[@]}" \
        --all-audio --aencoder copy --audio-fallback aac \
        --all-subtitles --markers \
        --no-dvdnav \
        </dev/null >"$tmpout" 2>&1 &
    # </dev/null on tärkeä yksityiskohta: tämä funktio kutsutaan aina jonkin
    # silmukan (esim. "käy läpi kaikki raidat") sisältä. Ilman tätä HandBrake
    # saattaisi vahingossa alkaa lukea samaa syötettä kuin ympäröivä silmukka,
    # mikä sekoittaisi silmukan kulun täysin. </dev/null varmistaa ettei
    # HandBrakella ole mitään luettavaa syötettä, joten se ei voi häiritä.
    local hb_pid=$!

    # Näyttää käyttäjälle etenemisprosentin ruudulla. Tämä on täysin oma
    # erillinen ohjelmansa (kirjoitettu Pythonilla), joka vain lukee HandBraken
    # kirjoittamaa väliaikaistiedostoa eikä vaikuta itse muunnokseen millään tavalla.
    python3 -c '
import sys, re, subprocess
label, tmpout = sys.argv[1], sys.argv[2]
last_pct = -5.0
proc = subprocess.Popen(["tail", "-f", "-n", "0", tmpout],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
try:
    for raw in proc.stdout:
        m = re.search(rb"(\d+\.\d+) %.*ETA\s+(\S+)", raw)
        if m:
            pct = float(m.group(1))
            eta = m.group(2).decode("utf-8", errors="replace")
            if pct - last_pct >= 5.0:
                last_pct = pct
                sys.stdout.write(f"\r  [{label}] {pct:.1f}%  ETA {eta}")
                sys.stdout.flush()
except Exception:
    pass
finally:
    try: proc.terminate(); proc.wait()
    except Exception: pass
' "$label" "$tmpout" &
    local py_pid=$!

    # Odotetaan että HandBrake saa muunnoksen valmiiksi, tarkistaen 10 sekunnin
    # välein onko se vielä käynnissä. Jos se on jumissa liian kauan (esim.
    # vioittunut lähdetiedosto saa sen jäämään ikuisesti paikoilleen), se
    # sammutetaan väkisin sen sijaan että jäätäisiin odottamaan loputtomiin.
    local hb_waited=0 hb_timed_out=0
    while kill -0 "$hb_pid" 2>/dev/null; do
        sleep 10
        (( hb_waited += 10 )) || true
        if (( hb_waited >= ENC_TIMEOUT )); then
            kill -KILL "$hb_pid" 2>/dev/null || true
            hb_timed_out=1
            break
        fi
    done
    wait "$hb_pid" 2>/dev/null
    local rc=$?
    (( hb_timed_out )) && rc=124  # 124 on vakiintunut merkki "aikakatkaisu tapahtui"

    # Lopetetaan myös edistymispalkin näyttävä ohjelma, koska sillä ei ole
    # enää mitään näytettävää kun itse muunnos on jo päättynyt.
    kill "$py_pid" 2>/dev/null
    wait "$py_pid" 2>/dev/null
    echo >&2

    # Kopioidaan HandBraken tuottama loki päälokitiedostoon siistittynä:
    # poistetaan tyhjät rivit ja jatkuvasti päivittyvät prosenttirivit
    # (nämä olisivat vain roskaa lokitiedostossa, koska ne on tarkoitettu
    # näytölle reaaliaikaisesti vilkkuviksi, ei pysyväksi tallenteeksi).
    sed $'s/\r/\n/g' "$tmpout" | grep -v ' ETA ' | grep -v '^$' >> "$LOGFILE" || true
    rm -f "$tmpout"

    return "$rc"
}

# Odottaa siihen asti kunnes DVD-asemassa on levy jota pystyy lukemaan —
# eli jää käytännössä odottamaan käyttäjää, joka työntää levyn asemaan.
# Testaa luettavuutta yrittämällä lukea levyn aivan ensimmäisen palan; jos
# tämä onnistuu, levy on paikallaan ja valmis käytettäväksi (toimii myös
# kopiosuojatuilla levyillä, koska suojauksen purku tapahtuu automaattisesti
# taustalla). Asemapolku on kirjoitettu suoraan koodiin ("kovakoodattu")
# koska brainbin-tietokoneessa on kaksi DVD-asemaa, joista vain toinen
# (ulkoinen USB-asema, tunnus sr1) toimii — sisäinen asema (sr0) on rikki.
wait_for_disc() {
    local dev="/dev/sr1"
    while ! dd if="$dev" count=1 bs=2048 of=/dev/null status=none 2>/dev/null; do
        sleep 10
    done
    echo "$dev"
}

# ── Pysyvästi luovutetut raidat (--skip) ────────────────────────────────────
# Jos jokin raita epäonnistuu toistuvasti samasta syystä (esim. levyvaurio),
# käyttäjä voi merkitä sen pysyvästi ohitetuksi ilman että lähde-VOB poistetaan
# (ks. --skip/--unskip komentorivillä). Näin skripti lakkaa kysymästä samaa
# rataa uudelleen joka käynnistyksellä, mutta muut saman levyn/session raidat
# yritetään silti normaalisti. Yksi sessio = yksi lista, tiedostonimiä
# (out_name, sama muoto kuin FAIL_TITLE-riveillä) yksi per rivi.
_skip_file() {
    printf '%s/.skip-titles' "${1%/}"
}

_title_is_skipped() {
    local _sdir="$1" _title="$2" _sf
    _sf=$(_skip_file "$_sdir")
    [[ -f "$_sf" ]] || return 1
    grep -qFx "$_title" "$_sf"
}

# Tulostaa yhden enkoodausraportin FAIL_TITLE-rivit yhtenäisessä muodossa:
# pysyvästi ohitetut (--skip) omalla merkillään ("⊘"), muut syyllä ("✗") ja
# valinnaisesti vinkillä miten raidasta voi luopua. Yhteinen apufunktio, jota
# käyttävät sekä show_recent_reports() että main() pending-kehotteessaan —
# näin molemmat näyttävät aina saman tiedon samalla tavalla eikä korjaus
# unohdu toisesta kohdasta jos jompaakumpaa muutetaan.
_print_fail_titles() {
    local _sdir="$1" _rep="$2" _show_hint="${3:-0}"
    local _title _reason
    while IFS='|' read -r _title _reason; do
        if _title_is_skipped "$_sdir" "$_title"; then
            printf '      ⊘ %s  (ohitettu pysyvästi, ei yritetä)\n' "$_title"
        else
            printf '      ✗ %s\n' "$_title"
            [[ -n "$_reason" ]] && printf '        %s\n' "${_reason# }"
            if (( _show_hint )); then
                printf '        → luovutus: rip-dvd.sh --skip '"'"'%s'"'"' "%s"\n' "$_sdir" "$_title"
            fi
        fi
    done < <(grep '^FAIL_TITLE=' "$_rep" | sed 's/^FAIL_TITLE=//')
}

# Palauttaa tosi (exit 0) jos session-hakemistolla on OIKEASTI vielä
# enkoodusta odottavaa dataa. Kaksi erillistä tarkistusta, kumpikin voi yksin
# päättää että mitään ei ole jäljellä:
#   (1) Jos viimeisin enkoodausraportti kertoo epäonnistumisia, ainakin yhden
#       niistä on OLTAVA edelleen ratkaisematta (ei --skipattu).
#   (2) KORJATTU 2026-08-20: pelkkä "FAIL=0 raportissa" EI riitä todisteeksi
#       että kaikki on valmista — raportin OK-luku voi olla PIENEMPI kuin
#       levyn TITLE_COUNT jos osa raidoista on --skipattu vasta raportin
#       kirjoittamisen JÄLKEEN (--skip ei kirjoita uutta raporttia). Havaittu
#       käytännössä: District 9:llä OK=4, 6 raitaa --skipattu, TITLE_COUNT=10
#       (4+6=10, kaikki ratkaistu) mutta funktio palautti silti "pending"
#       koska FAIL=0 ohitti koko tarkistuksen. Korjaus: lasketaan TITLE_COUNT
#       yhteen kaikista session_dirin disc-*/meta.conf-tiedostoista, verrataan
#       raportin OK-lukuun + tämänhetkiseen --skip-määrään (jo-olemassa-olevat
#       tiedostot terastationilla LASKETAAN "OK":ksi encode_session():ssa,
#       ks. rivi ~1241, joten OK-luku on aina ajantasainen kokonaismäärä eikä
#       vain "tämän ajon uudet onnistumiset").
#   (lähde-VOB:eja EI poisteta automaattisesti pelkän --skipin takia, joten
#   niiden olemassaolo yksinään ei riitä todisteeksi kesken olevasta työstä).
_session_has_pending_work() {
    local _sdir="${1%/}/"
    [[ -n "$(find "$_sdir" -name "*.VOB" -size +10M 2>/dev/null | head -1)" ]] || return 1

    local _rep="${_sdir}.encode-report"
    if [[ -f "$_rep" ]]; then
        local _fail_n; _fail_n=$(grep '^FAIL=' "$_rep" 2>/dev/null | cut -d= -f2)
        if [[ -n "$_fail_n" && "$_fail_n" != "0" ]]; then
            local _ft _unresolved=0
            while IFS= read -r _ft; do
                [[ -z "$_ft" ]] && continue
                _title_is_skipped "$_sdir" "$_ft" || _unresolved=1
            done < <(grep '^FAIL_TITLE=' "$_rep" | sed 's/^FAIL_TITLE=//' | cut -d'|' -f1)
            (( _unresolved == 0 )) && return 1
        fi

        # HUOM 2026-08-20: harkittiin lisäystä joka vertaisi raportin OK-lukua
        # session-dirin TITLE_COUNT-summaan, mutta PERUTTU heti kun havaittiin
        # vaarallisempi tapaus kuin alkuperäinen ongelma: kun session käsitellään
        # USEANA ERILLISENÄ --encode-only-ajona levy kerrallaan (tavallista ison
        # session pilkkoutuessa d001/d002/d003/d004-tmux-sessioihin), JAETTU
        # .encode-report YLIKIRJOITTUU jokaisen erillisen ajon lopussa eikä
        # koskaan kerro KOKO session-dirin kumulatiivista totuutta. Havaittu
        # käytännössä: raportti näytti OK=2 (vain levyt 1-2 valmiit klo 04:50)
        # vaikka levy 3 (Gandhi) oli sillä hetkellä AKTIIVISESTI kesken ja levy 4
        # ei ollut edes alkanut — OK+skip-vertailu olisi silti voinut väittää
        # session valmiiksi jos levyjen TITLE_COUNT-summa olisi sattunut
        # täsmäämään. Väärä "kaikki valmis" on paljon vaarallisempi kuin väärä
        # "vielä jonossa" (voisi johtaa siihen että joku siivoaa raakalähteitä
        # luullen työn valmiiksi vaikka enkoodaus on yhä kesken). EI TOTEUTETTU.
    fi
    return 0
}

# Palauttaa (stdout, yksi per rivi) session-hakemiston levyt joilla on sekä
# meta.conf että vähintään yksi >10M VOB dvdbackup-kansiossa — eli oikeasti
# enkoodattavissa olevaa dataa. Levy jolta meta.conf puuttuu (esim. rippaus
# kaatui ennen sen kirjoittamista) ei voi koskaan päätyä encode_session:iin,
# joten sen jäljelle jäänyt VOB-roska ei saa laukaista "jonossa"-tilaa eikä
# vääristää session-otsikon nimeä jo valmiiksi enkoodatuilla levyillä.
_session_pending_discs() {
    # Normalisoidaan aina täsmälleen yhteen perässä olevaan "/" — ilman tätä
    # kutsu ilman kauttaviivaa lopussa (esim. --skip/--encode-only saavat
    # polun suoraan käyttäjältä) tuottaisi rikkinäisen globin
    # "session_XXXdisc-*/meta.conf" ja palauttaisi hiljaa tyhjän tuloksen
    # vaikka dataa oikeasti olisi.
    local _sdir="${1%/}/" _dmf _ddir
    _session_has_pending_work "$_sdir" || return 0
    for _dmf in "$_sdir"disc-*/meta.conf; do
        [[ -f "$_dmf" ]] || continue
        _ddir="$(dirname "$_dmf")/dvdbackup"
        [[ -n "$(find "$_ddir" -name "*.VOB" -size +10M 2>/dev/null | head -1)" ]] && echo "$_dmf"
    done
}

# Tutkii kopioidun DVD-kansion sisällön ja listaa sieltä löytyvien "otsikoiden"
# (title = yksi yhtenäinen video- ja äänipätkä DVD-rakenteessa, esimerkiksi
# yksi jakso tai yksi ekstra) numerot — mutta VAIN ne jotka kestävät vähintään
# MIN_DURATION-muuttujan verran. Tämä suodattaa pois DVD:n omat valikkoanimaatiot
# ja muut lyhyet pätkät jotka eivät ole oikeaa sisältöä. Käytetään sekä levyn
# rippauksen aikana (selvitetään montako oikeaa jaksoa/ekstraa levyllä on)
# että myöhemmin enkoodausvaiheessa (selvitetään mitkä otsikkonumerot pitää
# muuntaa). Tämä tutkiminen kestää yleensä 5–15 sekuntia per levy.
hb_scan_long_titles() {
    local dvd_dir="$1"
    # --no-dvdnav: sama kirjastovalinta kuin run_hb():ssa (ks. sen kommentti) —
    # skannaus ja enkoodaus käyttävät aina samaa DVD-lukukirjastoa keskenään,
    # ettei niiden tulkinta levyn rakenteesta pääse eroamaan toisistaan.
    timeout "$SCAN_TIMEOUT" HandBrakeCLI -i "$dvd_dir" -t 0 --scan --no-dvdnav </dev/null 2>&1 | python3 -c "
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

# Rakentaa kohdepolun tiedostotyypistä riippuen.
# Terastationin hakemistorakenne:
#   series/       → Sarjat kausikohtaisiin kansioihin (Jellyfin tunnistaa automaattisesti)
#   movies/       → Elokuvat (nimi + vuosi)
#   documentaries/→ Dokumentit (nimi + vuosi)
#   music/        → Musiikkivideot ja konsertit (nimi ilman vuotta)
#   misc/         → Muu materiaali, oma kansionsa (käyttäjän vaatimuksesta 2026-08-15
#                    palautettu — välissä oli hetken aikaa reititetty movies/-kansioon)
dest_path() {
    local type="$1" name="$2" val="$3"
    case "$type" in
    series)  printf '%s/series/%s/Season %02d' "$DEST_ROOT" "$name" "$val" ;;
    movie)   [[ -n "$val" ]] && printf '%s/movies/%s (%s)'        "$DEST_ROOT" "$name" "$val" \
                             || printf '%s/movies/%s'             "$DEST_ROOT" "$name" ;;
    doc)     [[ -n "$val" ]] && printf '%s/documentaries/%s (%s)' "$DEST_ROOT" "$name" "$val" \
                             || printf '%s/documentaries/%s'      "$DEST_ROOT" "$name" ;;
    music)   printf '%s/music/%s'              "$DEST_ROOT" "$name" ;;
    misc)    printf '%s/misc/%s'               "$DEST_ROOT" "$name" ;;
    esac
}

# ── Rinnakkaisenkoodauksen Taso B: per-kohdekansio-varaus ───────────────────
# Estää kahta ERI session-hakemistoa laskemasta ekstranumeroita SAMALLE
# kohdekansiolle yhtä aikaa (mikä voisi johtaa siihen että molemmat päätyvät
# samaan numeroon, koska molemmat lukisivat saman — vielä päivittämättömän —
# tiedostomäärän). Käyttäjän 2026-08-23 yksinkertaistus: sen sijaan että
# numeron laskenta siirrettäisiin monimutkaisesti kirjoitushetkeen asti, koko
# kyseisen kohdekansion käsittely (numerointi mukaan lukien) vain jätetään
# tekemättä TÄLLÄ kierroksella jos toinen käynnissä oleva session on jo
# varannut saman kohdekansion — se käsitellään seuraavalla --encode-only-
# kierroksella kun kohdekansio on taas vapaa.
#
# Yksi varaus pysyy voimassa koko encode_session()-kutsun loppuun asti (ei
# vapauteta heti numeroinnin jälkeen) — tämä on tarkoituksella varovainen
# valinta: kun sessio on kerran ottanut kohdekansion "omakseen", se pitää sen
# loppuun asti eikä anna toisen session vuorotella sen kanssa kesken kaiken.
declare -A _DEST_LOCK_FDS=()

# Palauttaa 0 (onnistui) jos kohdekansio saatiin varattua, 1 jos joku toinen
# käynnissä oleva session pitää sitä jo hallussaan. Ei-blokkaava.
dest_lock_try_acquire() {
    local dest="$1"
    [[ -n "${_DEST_LOCK_FDS[$dest]:-}" ]] && return 0  # jo omassa hallussa
    local hash lockdir="/tmp/rip-dvd-dest-locks" lockpath fd
    mkdir -p "$lockdir"
    hash=$(printf '%s' "$dest" | md5sum | cut -d' ' -f1)
    lockpath="${lockdir}/${hash}.lock"
    exec {fd}>"$lockpath"
    if flock -n "$fd"; then
        _DEST_LOCK_FDS["$dest"]="$fd"
        return 0
    else
        eval "exec ${fd}>&-"
        return 1
    fi
}

# Vapauttaa KAIKKI tämän encode_session()-kutsun hallussa olevat kohdekansio-
# varaukset. Kutsutaan _encode_cleanup()-funktiosta (ajetaan sekä normaalissa
# että keskeytyneessä lopetuksessa).
dest_lock_release_all() {
    local d
    for d in "${!_DEST_LOCK_FDS[@]}"; do
        eval "exec ${_DEST_LOCK_FDS[$d]}>&-"
        unset '_DEST_LOCK_FDS[$d]'
    done
}

# BLOKKAAVA versio dest_lock_try_acquire:sta — käytetään vain "sooloputki"-
# tilanteessa: kun kaikki muu tämän session-hakemiston työ on jo tehty eikä
# rinnakkaisuudesta ole enää mitään hyötyä, on turvallista ja ilmaista vain
# odottaa siihen asti kunnes toinen session vapauttaa kohdekansion — ei
# kuluta mitään ylimääräisiä resursseja odottamiseen (`flock` nukkuu ytimessä).
dest_lock_acquire_blocking() {
    local dest="$1"
    [[ -n "${_DEST_LOCK_FDS[$dest]:-}" ]] && return 0
    local hash lockdir="/tmp/rip-dvd-dest-locks" lockpath fd
    mkdir -p "$lockdir"
    hash=$(printf '%s' "$dest" | md5sum | cut -d' ' -f1)
    lockpath="${lockdir}/${hash}.lock"
    exec {fd}>"$lockpath"
    flock "$fd"   # blokkaa kunnes vapautuu
    _DEST_LOCK_FDS["$dest"]="$fd"
}

# ── Rinnakkaisenkoodauksen Taso C: globaali N-paikkainen semafori ───────────
# PARALLEL-asetus luetaan TUOREENA config-tiedostosta JOKA KERTA kun paikkaa
# yritetään varata — EI kerran välimuistiin skriptin käynnistyessä. Tämä on
# tarkoituksellista: sama virhe kuin tämän illan (2026-08-22) 50°C-tarkistus-
# bugissa (vanha käynnissä oleva prosessi käytti muistiin ladattua vanhaa
# arvoa) EI SAA TOISTUA TÄSSÄ. Tuore luku joka kerta tarkoittaa että asetuksen
# muuttaminen kesken ajon vaikuttaa jo käynnissä olevien encode_session()-
# kutsujen SEURAAVAAN dispatch-yritykseen ilman uudelleenkäynnistystä.
RIP_DVD_CONFIG_FILE="${RIP_DVD_CONFIG_FILE:-$HOME/.config/rip-dvd/config}"
GLOBAL_SLOT_DIR="${GLOBAL_SLOT_DIR:-/tmp/rip-dvd-slots}"

# Ensimmäinen versio (2026-08-23): hyväksyy vain 1 tai 2. Vaikka Tasot A/B/C
# ovat rakenteeltaan jo N-yleisiä, itse rinnakkaisajoa ei ole testattu yli
# kahdella tällä raudalla — tiukempi raja on turvallisempi kuin sallia
# testaamaton alue oletuksena. Nostetaan myöhemmin kun on mitattu.
read_max_parallel() {
    local val
    val=$(grep -m1 '^PARALLEL=' "$RIP_DVD_CONFIG_FILE" 2>/dev/null | cut -d= -f2)
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= 2 )); then
        echo "$val"
    else
        echo 1   # turvallinen oletus jos tiedostoa/riviä ei ole tai arvo virheellinen
    fi
}

# Yrittää saada minkä tahansa vapaan paikan 1..N. Palauttaa saadun paikan
# numeron stdoutiin ja exit 0, tai exit 1 jos kaikki varattuja. Ei-blokkaava.
# HUOM: paikan FD EI säily kutsujan hallussa tämän funktion palattua (se on
# oma paikallinen muuttujansa) — vapautus tehdään tiedoston POISTOLLA
# (global_slot_release), ei FD:n sulkemisella, koska paikka pitää pystyä
# vapauttamaan TOISESTA prosessista/aliprosessista kuin joka sen varasi
# (taustalle haarautunut raidan käsittelijä).
#
# Kuolleen prosessin siivous: paikkatiedostoon kirjoitetaan sen prosessin PID
# joka sen varasi. Jos toinen prosessi yrittää varata jo-varatun paikan,
# tarkistetaan ELÄÄKÖ tallennettu PID vielä ennen kuin luovutetaan — jos
# prosessi on kuollut (esim. kaatunut, tapettu, virrankatkos) ilman että
# ehti vapauttaa paikkansa siististi, paikka vapautetaan automaattisesti
# eikä jää ikuisesti "haamuvarattuna". Tämä puuttuu tavallisesta noclobber-
# tiedostolukosta, mutta on tärkeä koska tämä paikka voi pysyä varattuna
# tuntikausia (koko raidan enkoodauksen ajan).
#
# TÄRKEÄÄ (testauksessa löytynyt oikea bugi 2026-08-23): tämän funktion
# STDOUT ON sen paluuarvokanava (kutsutaan aina muodossa `slot=$(...)`).
# `log()`-funktio kirjoittaa `tee`:n kautta MYÖS stdoutiin, ei vain
# lokitiedostoon — jos sitä kutsuttaisiin tässä funktiossa ilman `>&2`,
# lokiviesti sotkeutuisi paluuarvon sekaan ja kutsuja saisi paikkanumeron
# sijaan tekstiä. Siksi KAIKKI log()-kutsut tässä funktiossa ohjataan
# eksplisiittisesti stderr:iin.
global_slot_try_acquire() {
    mkdir -p "$GLOBAL_SLOT_DIR"
    local n; n=$(read_max_parallel)
    local i
    for (( i=1; i<=n; i++ )); do
        local lockpath="${GLOBAL_SLOT_DIR}/slot-${i}.lock"
        if ( set -o noclobber; echo "$$" > "$lockpath" ) 2>/dev/null; then
            echo "$i"
            return 0
        fi
        # Paikka näyttää varatulta — tarkista onko sen varannut prosessi yhä elossa.
        local _owner_pid; _owner_pid=$(cat "$lockpath" 2>/dev/null)
        if [[ -n "$_owner_pid" ]] && ! kill -0 "$_owner_pid" 2>/dev/null; then
            log "  VAROITUS: paikka ${i} oli jäänyt varatuksi kuolleelta prosessilta (PID ${_owner_pid}) — vapautetaan" >&2
            rm -f "$lockpath"
            if ( set -o noclobber; echo "$$" > "$lockpath" ) 2>/dev/null; then
                echo "$i"
                return 0
            fi
        fi
    done
    return 1
}

global_slot_release() {
    local slot="$1"
    rm -f "${GLOBAL_SLOT_DIR}/slot-${slot}.lock"
}

# Korvaa tiedostojärjestelmissä kiellettyjä merkkejä viivalla.
# / on kriittisin (rikkoo polurakenteen), mutta SMB-levyllä myös muut merkit ovat kiellettyjä.
sanitize_name() {
    local n="$1"
    n="${n//\//-}"
    n="${n//\\/-}"
    n="${n//:/-}"
    n="${n//\*/-}"
    n="${n//\?/-}"
    n="${n//\"/-}"
    n="${n//</-}"
    n="${n//>/-}"
    n="${n//|/-}"
    printf '%s' "$n"
}

# ── Levyn tietojen kysyminen käyttäjältä ────────────────────────────────────
# Kysyy näytöllä levyn tiedot (onko se sarja, elokuva, dokumentti, musiikkia
# vai jotain muuta; nimi; kausi tai vuosi; jaksonumero) yksi kysymys kerrallaan.
# Jos käyttäjä on juuri äsken syöttänyt tiedot edelliselle levylle, ne
# näytetään valmiina ehdotuksina hakasulkeissa — pelkkä Enter-näppäimen
# painallus hyväksyy ehdotuksen sellaisenaan.
#
# Tulos palautetaan yhtenä tekstirivinä, jossa eri tiedot (tyyppi, nimi, kausi,
# jakso, jaksomäärä) on eroteltu toisistaan erikoismerkillä joka ei koskaan
# voi esiintyä itse tiedoissa (tiedostonimissä tms.) — näin kutsuva koodi voi
# jälkikäteen pilkkoa rivin takaisin erillisiksi tiedoiksi luotettavasti.
ask_meta() {
    local p_type="${1:-}" p_name="${2:-}" p_season="${3:-}" p_ep="${4:-}" p_max_ep="${5:-}"
    echo "" >&2

    # Tyyppivalidointi silmukalla — hyväksyy vain tunnetut arvot
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
        [[ "$val" =~ ^[0-9]+$ ]] || { echo "  Kausiluku ei kelpaa: '$val'" >&2; return 1; }

        # Ehdotetaan käyttäjälle valmiiksi mikä jaksonumero tällä levyllä
        # todennäköisesti alkaa, jotta sitä ei tarvitse laskea itse.
        # Kaksi tapaa: jos ollaan yhä samalla kaudella kuin edellinen tässä
        # istunnossa ripattu levy, jatketaan suoraan siitä mihin edellinen
        # levy jäi. Jos kausi on eri (tai tämä on session ensimmäinen levy),
        # katsotaan sekä mitä on jo tallennettu terastationille että mitä on
        # jonossa odottamassa, ja ehdotetaan seuraavaa vapaata numeroa.
        local suggest=1
        if [[ -n "$p_ep" && "$p_type" == series && "$p_season" == "$val" ]]; then
            suggest="$p_ep"
        else
            # Etsitään terastationilta jo olemassa olevista jaksotiedostoista
            # suurin jaksonumero, ja ehdotetaan seuraavaksi sitä yhtä isompaa.
            local _dd; _dd=$(dest_path series "$name" "$val")
            local _suggest_tera=0
            if [[ -d "$_dd" ]]; then
                _suggest_tera=$(find "$_dd" -maxdepth 1 -name "*.mkv" 2>/dev/null | python3 -c "
import sys, re
n = []
for line in sys.stdin:
    m = re.search(r'E(\d+)', line.strip())
    if m: n.append(int(m.group(1)))
print(max(n)+1 if n else 0)" 2>/dev/null || echo 0)
            fi
            # Käydään lisäksi läpi kaikki tähän mennessä ripatut mutta ei
            # vielä terastationille siirretyt levyt (esim. odottavat
            # enkoodausta), jotta ehdotus ei vahingossa osu jaksoon joka on
            # jo ripattu mutta ei vielä näy terastationin tiedostolistassa.
            local _suggest_queue=0
            local _qmf
            for _qmf in "$OUTBASE"/session_*/disc-*/meta.conf; do
                [[ -f "$_qmf" ]] || continue
                local _qname _qseas _qep _qcount _qmax
                _qname=$(grep '^NAME='   "$_qmf" | cut -d= -f2-)
                _qseas=$(grep '^SEASON=' "$_qmf" | cut -d= -f2)
                [[ "$_qname" == "$name" && "$_qseas" == "$val" ]] || continue
                _qep=$(grep '^START_EP='    "$_qmf" | cut -d= -f2)
                _qcount=$(grep '^TITLE_COUNT=' "$_qmf" 2>/dev/null | cut -d= -f2 || echo 0)
                _qmax=$(grep '^MAX_EPISODES=' "$_qmf" 2>/dev/null | cut -d= -f2 || echo 0)
                (( _qmax > 0 && _qmax < _qcount )) && _qcount=$_qmax
                local _qend=$(( _qep + _qcount ))
                (( _qend > _suggest_queue )) && _suggest_queue=$_qend
            done
            suggest=$(( _suggest_tera > _suggest_queue ? _suggest_tera : _suggest_queue ))
            (( suggest < 1 )) && suggest=1
        fi
        read -rp "Ensimmäinen jakso tällä levyllä [$suggest]: " ep
        ep="${ep:-$suggest}"
        [[ "$ep" =~ ^[0-9]+$ ]] || { echo "  Jaksonumero ei kelpaa: '$ep'" >&2; return 1; }
        local max_ep=""
        local mp="Montako jaksoa levyllä (Enter = kysy rippauksen jälkeen)"
        # Jos edellisellä saman sarjan/kauden levyllä oli jo annettu MAX_EPISODES,
        # ehdotetaan samaa lukua — useimmilla sarjoilla levyrakenne (jaksoja +
        # ekstroja) on sama koko kauden ajan, joten sama luku toistuu levystä
        # toiseen (ks. muistiinpanot esim. The Wire S04:stä).
        if [[ -n "$p_max_ep" && "$p_type" == series && "$p_season" == "$val" ]]; then
            mp="Montako jaksoa levyllä (Enter = ${p_max_ep}, kuten edellisellä levyllä)"
        fi
        read -rp "${mp}: " max_ep
        [[ -z "$max_ep" && -n "$p_max_ep" && "$p_type" == series && "$p_season" == "$val" ]] \
            && max_ep="$p_max_ep"
        if [[ -n "$max_ep" ]]; then
            [[ "$max_ep" =~ ^[0-9]+$ ]] || { echo "  Ei kelpaa: '$max_ep'" >&2; return 1; }
        fi
        ;;

    movie|doc)
        local lbl; [[ "$type" == movie ]] && lbl="Elokuvan nimi" || lbl="Dokumentin nimi"
        [[ -n "$p_name" && "$p_type" == "$type" ]] && lbl+=" [$p_name]"
        read -rp "${lbl}: " name; name="${name:-$p_name}"
        [[ -z "$name" ]] && { echo "  Nimi ei voi olla tyhjä." >&2; return 1; }
        read -rp "Vuosi (Enter = tuntematon): " val
        if [[ -n "$val" ]] && ! [[ "$val" =~ ^[0-9]{4}$ ]]; then
            echo "  Vuosi ei kelpaa (4 numeroa, esim. 1977): '$val'" >&2; return 1
        fi
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

    name=$(sanitize_name "$name")
    [[ -z "$name" ]] && { echo "  Nimi tyhjeni sanitoinnin jälkeen — tarkista erikoismerkit" >&2; return 1; }
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s' "$type" "$name" "$val" "$ep" "${max_ep:-}"
}

# ── Enkoodausvaihe ────────────────────────────────────────────────────────
# Tästä eteenpäin skripti käy läpi kaikki yhden rippaus-istunnon levyt,
# kokoaa niistä muunnettavien raitojen jonon ja muuntaa ne yksi kerrallaan
# HandBrakella MKV-tiedostoiksi. Valmiit tiedostot siirretään terastationille,
# ja alkuperäinen kopioitu DVD-data poistetaan väliaikaishakemistosta, mutta
# VASTA sitten kun on täysin varmistettu että kaikki kyseisen levyn raidat
# ovat todella tallella terastationilla — näin mikään ei häviä matkalla
# vaikka jokin menisi pieleen kesken kaiken.

# Tarkistaa onko MUILLA (ei tämän kutsun omalla) rippaus-istunnolla vielä
# muunnosta odottavaa sisältöä. Tätä tarvitaan, koska vain yksi muunnos voi
# olla käynnissä kerrallaan (ks. alempana oleva selitys lukituksesta) — jos
# useampi istunto odottaa vuoroaan, käyttäjän saama ilmoitus ei saa
# virheellisesti väittää että "kaikki on nyt valmista", kun todellisuudessa
# toinen istunto istuu täynnä odottavaa työtä. (Tämä bugi havaittiin kerran
# käytännössä: 32 raidan kokoinen työjono odotti vuoroaan lähes 12 tuntia,
# mutta ilmoitus väitti koko jonon olevan tyhjä koska se katsoi vain omaa
# istuntoaan eikä muita.) Raitamäärä on tässä vain arvio, ei tarkka luku —
# tarkka määrä selviää vasta kun kyseinen istunto pääsee vuoroon.
_other_sessions_pending() {
    local _self="${1%/}"
    local _n_sessions=0 _n_titles=0
    local -a _labels=()
    local _d
    for _d in "$OUTBASE"/session_*/; do
        [[ -d "$_d" ]] || continue
        [[ "${_d%/}" == "$_self" ]] && continue
        _session_has_pending_work "$_d" || continue

        local _sess_titles=0 _name="" _dmf
        for _dmf in "$_d"disc-*/meta.conf; do
            [[ -f "$_dmf" ]] || continue
            local _dn; _dn=$(grep '^NAME=' "$_dmf" 2>/dev/null | cut -d= -f2-)
            [[ -z "$_name" && -n "$_dn" ]] && _name="$_dn"
            local _dcnt; _dcnt=$(grep '^TITLE_COUNT=' "$_dmf" 2>/dev/null | cut -d= -f2)
            local _dmax; _dmax=$(grep '^MAX_EPISODES=' "$_dmf" 2>/dev/null | cut -d= -f2)
            [[ -n "$_dmax" && -n "$_dcnt" ]] && (( _dmax > 0 && _dcnt > _dmax )) && _dcnt=$_dmax
            _sess_titles=$(( _sess_titles + ${_dcnt:-0} ))
        done
        if (( _sess_titles > 0 )); then
            (( _n_sessions++ )) || true
            _n_titles=$(( _n_titles + _sess_titles ))
            _labels+=("${_name:-$(basename "$_d")} (~${_sess_titles})")
        fi
    done

    if (( _n_sessions > 0 )); then
        local _out="+ ${_n_sessions} muu sessio jonossa, yht. ~${_n_titles} raitaa:"
        local _l
        for _l in "${_labels[@]}"; do _out+=$'\n- '"$_l"; done
        echo "$_out"
    fi
}

encode_session() {
    local session_dir="$1"

    # ── Taso A: per-session-hakemisto-lukko (rinnakkaisenkoodauksen 1. vaihe) ──
    # Suojaa TÄMÄN session-hakemiston jaettuja tiedostoja (.queue, .encode-report,
    # .skip-titles) siltä että kaksi ERI --encode-only-kutsua käsittelisi samaa
    # session-hakemistoa yhtä aikaa. Tämä on todistetusti yleinen tilanne tässä
    # projektissa: main() käynnistää oman --encode-only-kutsunsa JOKAISEN ripatun
    # levyn jälkeen samalle session-hakemistolle, joten monta kutsua saman
    # session-hakemiston käsittelyyn on tavallista, ei harvinainen reunatapaus.
    #
    # Tämä lukko on TÄYSIN itsenäinen alla olevasta globaalista ENCODE_LOCKFILE-
    # lukosta eikä riipu siitä millään tavalla — ei siis deadlock-riskiä eri
    # session-hakemistojen välillä, koska niillä on aina eri lukkotiedosto.
    local session_lock_fd
    exec {session_lock_fd}>"${session_dir}/.encode.lock"
    if ! flock -n "$session_lock_fd"; then
        log "  Toinen käsittelijä on jo aktiivinen tälle session-hakemistolle — odotetaan..."
        flock "$session_lock_fd"
        log "  Session-lukko saatu"
    fi
    # Lukko pysyy voimassa koko funktion ajan, vapautuu automaattisesti kun
    # funktio päättyy (fd sulkeutuu) — sama periaate kuin alla olevalla
    # globaalilla lukolla.

    # ── Taso B: ekstrojen jonottaminen kun kohdekansio on varattu ───────────
    # Kirjoittaa levyn ekstrat jonoon VAIN jos kohdekansion varaus onnistuu
    # (ks. dest_lock_try_acquire yllä). Jos ei onnistu, palauttaa 1 eikä
    # kirjoita mitään — kutsuja laittaa levyn _PENDING_RETRY-listalle.
    _enqueue_extras() {
        local dvd_dir="$1" dest="$2" type="$3" name="$4" season="$5" raw_dir_name="$6" disc_seq="$7"
        shift 7
        local -a extra_titles=("$@")
        (( ${#extra_titles[@]} == 0 )) && return 0
        if ! dest_lock_try_acquire "$dest"; then
            return 1
        fi
        local _epat _n_tera _n_queue extra_num
        if [[ "$type" == series ]]; then
            _epat="${name} S$(printf '%02d' "$season") Extra"
        else
            _epat="${name} - Extra"
        fi
        _n_tera=$(find "$dest" -maxdepth 1 -name "${_epat} [0-9]*.mkv" 2>/dev/null | wc -l)
        _n_queue=$(grep -cF "${_epat}" "$queue" 2>/dev/null || true)
        extra_num=$(( _n_tera + _n_queue + 1 ))
        local t out_name
        for t in "${extra_titles[@]}"; do
            case "$type" in
            # "-extra"-pääte on Jellyfinin oma ekstratunniste (ks. jellyfin.org/docs/general/server/media/shows).
            # Ilman sitä Jellyfin tulkitsee numeron jaksonumeroksi ja joko peittää
            # oikean jakson tai näyttää sen tuplana väärällä nimellä.
            series) out_name="${name} S$(printf '%02d' "$season") Extra $(printf '%02d' "$extra_num")-extra.mkv" ;;
            *)      out_name="${name} - Extra $(printf '%02d' "$extra_num")-extra.mkv" ;;
            esac
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
                "$dvd_dir" "$out_name" "$dest" "$t" "$raw_dir_name" "$disc_seq" >> "$queue"
            (( extra_num++ )) || true
        done
        return 0
    }

    # Levyt joiden ekstrat jäivät kohdekansion varauksen takia odottamaan —
    # muoto: dvd_dir\x1fdest\x1ftype\x1fname\x1fseason\x1fraw_dir_name\x1fdisc_seq\x1ftitle1,title2,...
    # Käyttäjän 2026-08-23 vaatimus: näitä EI hylätä pysyvästi seuraavaan
    # --encode-only-kierrokseen asti — niitä yritetään uudelleen TÄMÄN SAMAN
    # ajon aikana (ensin ei-blokkaavasti pääsilmukan pollauskierroksilla
    # myöhemmin Tasossa C, lopuksi blokkaavasti "sooloputkena" kun mikään muu
    # ei ole enää kesken).
    local -a _PENDING_RETRY=()

    # Yrittää uudelleen kaikkia _PENDING_RETRY-listalla olevia leviä.
    # $1 = 0 (ei-blokkaava, ohita jos yhä varattu) tai 1 (blokkaava, odota).
    _flush_pending_retry() {
        local blocking="${1:-0}"
        (( ${#_PENDING_RETRY[@]} == 0 )) && return 0
        local -a _still=()
        local entry
        for entry in "${_PENDING_RETRY[@]}"; do
            local dvd_dir dest type name season raw_dir_name disc_seq titles_str
            IFS=$'\x1f' read -r dvd_dir dest type name season raw_dir_name disc_seq titles_str <<< "$entry"
            local -a extra_titles=()
            IFS=',' read -ra extra_titles <<< "$titles_str"
            if (( blocking )); then
                dest_lock_acquire_blocking "$dest"
                _enqueue_extras "$dvd_dir" "$dest" "$type" "$name" "$season" "$raw_dir_name" "$disc_seq" "${extra_titles[@]}"
                log "  Sooloputki: kohdekansio vapautui — ${#extra_titles[@]} ekstraa (${raw_dir_name}) lisätty jonoon"
            elif _enqueue_extras "$dvd_dir" "$dest" "$type" "$name" "$season" "$raw_dir_name" "$disc_seq" "${extra_titles[@]}"; then
                log "  Kohdekansio vapautui — ${#extra_titles[@]} ekstraa (${raw_dir_name}) lisätty jonoon"
            else
                _still+=("$entry")
            fi
        done
        _PENDING_RETRY=("${_still[@]}")
    }

    # ── Taso C: varmistetaan ettei enemmän kuin PARALLEL enkoodausta ole ────
    # käynnissä SAMANAIKAISESTI KOKO KONEELLA (ei vain tässä session-
    # hakemistossa — tämä on globaali, kaikkien encode_session()-kutsujen
    # jakama paikkavaraus).
    #
    # HUOM (2026-08-23, tärkeä yksinkertaistus): tämä EI muuta mitään MUUTA
    # tässä funktiossa. `main()` käynnistää jo valmiiksi jokaiselle levylle
    # OMAN itsenäisen --encode-only-prosessinsa (todistettu tämän illan
    # tmux-sessioista) — nämä ovat siis JO ERILLISIÄ käyttöjärjestelmä-
    # prosesseja, ei saman prosessin sisäisiä säikeitä tai taustatöitä.
    # Rinnakkaisuus saadaan siis YKSINKERTAISESTI päästämällä useampi näistä
    # jo olemassa olevista itsenäisistä prosesseista etenemään yhtä aikaa —
    # jokainen niistä pysyy TÄYSIN ennallaan, käy oman jononsa läpi täsmälleen
    # samalla synkronisella "yksi raita kerrallaan" -logiikalla kuin ennenkin.
    # Ei siis tarvita taustaprosesseja, tulostiedostoja eikä minkäänlaista
    # jaetun tilan (esim. _rep_ok, _src_done) uudelleenrakennusta tämän
    # funktion SISÄLLÄ — se kaikki toimii jo oikein koska se on aina vain
    # YHDEN prosessin muistissa, ei koskaan jaettu.
    #
    # Vanha yksinkertaisempi tarkistus ("onko toinen jo käynnissä?") ei ollut
    # täysin luotettava: oli mahdollista että kaksi istuntoa kysyivät tätä
    # täsmälleen samalla hetkellä ja molemmat saivat väärän vastauksen "ei
    # ole käynnissä". Paikkavaraustiedosto (noclobber-luonti) ei kärsi tästä.
    local _my_slot=""
    if _my_slot=$(global_slot_try_acquire); then
        log "  Paikka ${_my_slot} saatu — aloitetaan enkoodaus"
    else
        log "  Enkoodausvuoro jonossa — odotetaan vapaata paikkaa..."
        # Ei-blokkaava yritys epäonnistui — jäädään lyhyeen pollaus-
        # odotukseen. Luetaan PARALLEL-asetus tuoreena JOKA yrityksellä
        # (ei kerran alussa) jotta asetuksen muuttaminen kesken odotuksen
        # vaikuttaa heti, ei vasta uudelleenkäynnistyksen jälkeen.
        while ! _my_slot=$(global_slot_try_acquire); do
            sleep 5
        done
        log "  Paikka ${_my_slot} saatu — aloitetaan enkoodaus"
    fi
    # Paikka vapautetaan _encode_cleanup()-funktiossa (alempana), joka
    # ajetaan sekä normaalissa että keskeytyneessä lopetuksessa — sama
    # periaate kuin dest-lockien vapautuksella.

    log "═══ Enkoodausvaihe alkaa ═══"

    # Poista kesken jääneet .tmp-tiedostot — virransyötön tai kaatumisen jäänne.
    # Ilman tätä ne jäisivät ikuisesti enc_dir:iin tilaa viemään.
    # Nimikaava ".tmp.mkv" (tmp ENNEN oikeaa päätettä) — ks. kommentti alempana
    # miksi ".mkv.tmp" oli väärin päin ja aiheutti MP4-kontteribugin.
    find "$session_dir" -name "*.tmp.mkv" -delete 2>/dev/null || true

    # ── Levytilan tarkistus enkoodauksen alussa ──────────��────────────────────
    # Enkoodaus voi kestää tunteja — varmista ennen aloitusta että tilaa riittää.
    # df antaa väärän tuloksen jos terastation ei ole mountattu — varmista ensin.
    #
    # HUOM: die() (tässä ja alla) sulkee koko prosessin suoraan `exit`:illä,
    # ohittaen _encode_cleanup:in — tässä kohtaa jo varattu globaali paikka
    # (_my_slot) EI siis vapaudu heti. Tämä on tarkoituksella jätetty
    # yksinkertaiseksi: global_slot_try_acquire:in kuolleen-prosessin-
    # tunnistus (ks. sen kommentit) korjaa tämän itsestään seuraavalla
    # yrityksellä — paikka ei siis jää ikuisesti vuotamaan, vain hetkeksi
    # kunnes joku yrittää sitä seuraavan kerran. Nämä die()-polut ovat
    # harvinaisia hätätilanteita (terastation kokonaan tavoittamattomissa),
    # joten viiveellinen mutta itsestään korjautuva vapautus on riittävä
    # eikä vaadi hauraan cross-scope-siivouslogiikan rakentamista tätä varten.
    wait_for_terastation 600 || die "Terastation ei saatu mountattua 10 minuutin odotuksessa"
    local local_gb tera_gb
    local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    log "Tilaa: brainbin ${local_gb} GB vapaana, terastation ${tera_gb} GB vapaana"
    (( tera_gb < 5 )) && die "Terastationilla kriittisen vähän tilaa (${tera_gb} GB) — pysäytetään"
    (( tera_gb < 20 )) && log "VAROITUS: Terastationilla vain ${tera_gb} GB vapaana"

    # ── Ensin selvitetään mitä kaikkea pitää muuntaa, ja kirjoitetaan se muistiin
    # Muunnettavien raitojen lista ("jono") tallennetaan omaan tiedostoonsa sen
    # sijaan että pidettäisiin vain väliaikaisesti muistissa, koska samaa listaa
    # täytyy lukea kahteen kertaan myöhemmin: kerran kun raidat oikeasti
    # muunnetaan, ja kerran lopussa kun tarkistetaan mitkä alkuperäiset
    # DVD-kopiot voidaan turvallisesti poistaa. Jokaisella rivillä on kuusi
    # tietoa (mistä muunnetaan, mikä on lopullinen tiedostonimi, minne se menee,
    # DVD:n raidan numero, minkä levyn se on, ja levyn järjestysnumero) erotettuna
    # toisistaan erikoismerkillä joka ei koskaan voi esiintyä tiedostonimissä.
    local queue="${session_dir}/.queue"
    > "$queue"
    log "Skannataan levyt..."
    local disc_seq=1

    while IFS= read -r mf; do
        local raw_dir; raw_dir=$(dirname "$mf")
        local type name season ep rip_mode

        # Luetaan levyn tiedot meta.conf-tiedostosta (yksinkertainen
        # "avain=arvo" -muotoinen tekstitiedosto, yksi tieto per rivi)
        type=$(grep    '^TYPE='     "$mf" | cut -d= -f2-)
        name=$(grep    '^NAME='     "$mf" | cut -d= -f2-)
        season=$(grep  '^SEASON='   "$mf" | cut -d= -f2-)
        ep=$(grep      '^START_EP=' "$mf" | cut -d= -f2-)

        # TITLE_COUNT tallennettiin rippausvaiheessa — vertailua varten
        local expected_count; expected_count=$(grep '^TITLE_COUNT=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        # MAX_EPISODES: valinnainen, rajoittaa montako titteliä enkoodataan jaksoiksi
        # (sarjoilla — jaksot ovat aina levyn alussa, ekstrat perässä, ks. ask_meta()).
        local max_episodes; max_episodes=$(grep '^MAX_EPISODES=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        # MOVIE_TITLE_NUM: valinnainen, elokuville/dokumenteille — kertoo TARKAN
        # raitanumeron joka on itse teos (ei oleta että se olisi levyn ensimmäinen
        # raita, toisin kuin MAX_EPISODES). Kaikki MUUT raidat (ennen ja jälkeen)
        # tulevat ekstroiksi. Ks. main():n kysely rippauksen jälkeen.
        local movie_title_num; movie_title_num=$(grep '^MOVIE_TITLE_NUM=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        local dest; dest=$(dest_path "$type" "$name" "$season")

        # Tarkista että dvdbackup-hakemisto on olemassa.
        #
        # HUOM (löydetty 2026-08-21 koodikatselmoinnissa): tämä EI ole
        # merkki epäonnistuneesta rippauksesta, vaikka aiemmin lokiin
        # kirjoitettiin virheellisesti "VIRHE" tästä. main() käynnistää
        # jokaisen ripatun levyn jälkeen UUDEN --encode-only-session koko
        # session-hakemistolle (ks. main(), disc_num-silmukan loppu) — eli
        # moniLevyisessä sessiossa encode_session() ajetaan kerran per levy
        # ja skannaa AINA kaikki session-hakemiston meta.conf-tiedostot
        # uudelleen alusta. Jos jokin aiempi levy on jo ehditty täysin
        # enkoodata ja siirtää terastationille, sen dvdbackup-lähdekansio on
        # jo poistettu (_cleanup_disc_if_done, rm -rf) — tämä on siis
        # NORMAALI, ODOTETTU tila eikä virhe. Todistettu ettei muuta polkua
        # ole: epäonnistunut rippaus poistaa AINA koko raw_dir:in (myös
        # meta.confin) kokonaan main()ssa, joten meta.conf joka löytyy mutta
        # jonka dvdbackup-kansio puuttuu tarkoittaa AINA "valmis ja siivottu".
        local dvd_dir
        dvd_dir=$(find "${raw_dir}/dvdbackup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
        if [[ -z "$dvd_dir" ]]; then
            log "  (jo valmis ja siivottu, ei enää enkoodattavaa: ${raw_dir##*/})"
            continue
        fi

        # Varoita jos tällä levyllä oli lukuvirheitä rippausvaiheessa
        local read_errors_stored; read_errors_stored=$(grep '^READ_ERRORS=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        [[ -n "$read_errors_stored" ]] && log "!!! HUONO LEVY: ${read_errors_stored} lukuvirhettä rippauksen aikana — tarkista lopputulos: ${raw_dir##*/} !!!"

        # Skannaa pitkät raidat HandBrakella (>=MIN_DURATION sekuntia)
        # Tämä on toinen skannaus — ensimmäinen tehtiin rippausvaiheessa TITLE_COUNT:lle.
        # Uusi skannaus tehdään jotta saadaan tarkat raita-numerot enkoodausta varten.
        local titles=()
        while IFS= read -r t; do titles+=("$t"); done < <(hb_scan_long_titles "$dvd_dir")
        (( ${#titles[@]} == 0 )) && { log "VAROITUS: ei enkoodattavia raitoja — ${raw_dir##*/}"; continue; }

        # Jaa raidat itse teokseen ja ekstroihin. Kolme tapaa, tärkeysjärjestyksessä:
        # 1) MOVIE_TITLE_NUM — tarkka raitanumero on itse teos, KAIKKI muut (missä
        #    tahansa kohtaa levyä) ekstroja. Ei oleta sijaintia levyllä.
        # 2) MAX_EPISODES — vanha, sarjoilla käytetty "ensimmäiset N raitaa"
        #    -jaottelu. Toimii taaksepäin yhteensopivasti myös elokuville jos
        #    MOVIE_TITLE_NUM puuttuu mutta MAX_EPISODES on jo asetettu (esim.
        #    ennen 2026-08-16 kysytty vastaus).
        # 3) Ei kumpaakaan — kaikki raidat samaan koriin, ei erottelua.
        local ep_titles=() extra_titles=()
        if [[ "$movie_title_num" == "0" ]]; then
            # Erillinen bonuslevy — ei itse teosta lainkaan tällä levyllä,
            # KAIKKI raidat ekstroiksi (esim. levy 2/3/4/5 kun elokuva ja osa
            # ekstroista on jo ripattu eri levyltä samalla nimellä).
            extra_titles=("${titles[@]}")
            log "  MOVIE_TITLE_NUM=0: ei itse teosta tällä levyllä, ${#extra_titles[@]} ekstraa (${raw_dir##*/})"
        elif [[ -n "$movie_title_num" ]]; then
            local _t
            for _t in "${titles[@]}"; do
                if [[ "$_t" == "$movie_title_num" ]]; then
                    ep_titles+=("$_t")
                else
                    extra_titles+=("$_t")
                fi
            done
            if (( ${#ep_titles[@]} == 0 )); then
                # Annettu raitanumero ei löytynyt (esim. levy skannautui eri
                # tavalla tällä kertaa) — turvallisempi ohittaa jaottelu kokonaan
                # kuin jättää elokuva vahingossa pois enkoodattavista.
                log "  VAROITUS: MOVIE_TITLE_NUM=${movie_title_num} ei löytynyt raidoista — ei jaotella (${raw_dir##*/})"
                ep_titles=("${titles[@]}"); extra_titles=()
            else
                log "  MOVIE_TITLE_NUM=${movie_title_num}: 1 teos + ${#extra_titles[@]} ekstraa (${raw_dir##*/})"
            fi
        elif [[ -n "$max_episodes" ]] && (( max_episodes > 0 )) && (( ${#titles[@]} > max_episodes )); then
            ep_titles=("${titles[@]:0:$max_episodes}")
            extra_titles=("${titles[@]:$max_episodes}")
            log "  MAX_EPISODES=${max_episodes}: ${#ep_titles[@]} jaksoa + ${#extra_titles[@]} ekstraa (${raw_dir##*/})"
        else
            ep_titles=("${titles[@]}")
        fi

        # Vertaa skannauksen tulosta rippausvaiheessa tallennettuun arvoon
        local total_found=$(( ${#ep_titles[@]} + ${#extra_titles[@]} ))
        if [[ -n "$expected_count" ]] && (( total_found != expected_count )); then
            log "VAROITUS: odotettiin ${expected_count} raitaa, löytyi ${total_found} — ${raw_dir##*/}"
        fi

        # Rakenna jonorivi jaksoraidoille
        local i=1 total=${#ep_titles[@]}
        for t in "${ep_titles[@]}"; do
            local out_name
            case "$type" in
            series)
                out_name="${name} S$(printf '%02d' "$season")E$(printf '%02d' "$ep").mkv"
                ;;
            *)
                (( total==1 )) && out_name="${name}.mkv" \
                               || out_name="${name} - Part $(printf '%02d' "$i").mkv"
                ;;
            esac
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
                "$dvd_dir" "$out_name" "$dest" "$t" "${raw_dir##*/}" "$disc_seq" >> "$queue"
            [[ "$type" == series ]] && (( ep++ )) || true
            (( i++ )) || true
        done

        # Rakenna jonorivi ekstraraidoille.
        #
        # Taso B -varaus: jos jokin TOINEN käynnissä oleva session on jo
        # varannut tämän kohdekansion, tätä levyä EI hylätä — se laitetaan
        # _PENDING_RETRY-listalle ja sitä yritetään uudelleen TÄMÄN SAMAN
        # ajon aikana (ks. _flush_pending_retry, kutsutaan pääsilmukan
        # pollauskierroksilla ja lopuksi blokkaavana "sooloputkena").
        # Ei koske jaksoraitoja (yllä) koska niillä ei ole juoksevaa
        # numerointia joka voisi törmätä.
        if ! _enqueue_extras "$dvd_dir" "$dest" "$type" "$name" "$season" "${raw_dir##*/}" "$disc_seq" "${extra_titles[@]}"; then
            log "  Kohdekansio varattuna toisen session toimesta — ${#extra_titles[@]} ekstraa (${raw_dir##*/}) jonossa myöhemmäksi"
            _PENDING_RETRY+=("${dvd_dir}"$'\x1f'"${dest}"$'\x1f'"${type}"$'\x1f'"${name}"$'\x1f'"${season}"$'\x1f'"${raw_dir##*/}"$'\x1f'"${disc_seq}"$'\x1f'"$(IFS=,; echo "${extra_titles[*]}")")
        fi
        (( disc_seq++ )) || true

    done < <(find "$session_dir" -name "meta.conf" | sort)

    # Yritetään heti yksi ei-blokkaava kierros _PENDING_RETRY-listalle — jos
    # jokin kohdekansio ehti vapautua kesken tämän levyjen skannauksen,
    # saadaan sen ekstrat mukaan HETI eikä vasta myöhemmällä pollauksella.
    # Tehdään ENNEN total_titles-laskentaa, jotta äsken lisätyt rivit
    # lasketaan mukaan raporttiin.
    _flush_pending_retry 0

    local total_titles; total_titles=$(wc -l < "$queue")
    local total_discs=$(( disc_seq - 1 ))
    log "Jonossa $total_titles raitaa / $total_discs levyä enkoodattavana."
    # HUOM: paikka pitää vapauttaa TÄSSÄKIN paluupolussa — _encode_cleanup
    # (joka normaalisti hoitaa vapautuksen) määritellään vasta myöhemmin
    # eikä siis vielä ole olemassa jos palataan tästä. Ilman tätä paikka
    # jäisi vuotamaan aina kun jonossa ei ole mitään enkoodattavaa.
    if (( total_titles == 0 )); then
        log "Ei enkoodattavaa."
        dest_lock_release_all
        [[ -n "$_my_slot" ]] && global_slot_release "$_my_slot"
        return
    fi

    # Lasketaan etukäteen montako raitaa kuuluu kullekin alkuperäiselle
    # DVD-kopiolle. Tätä tarvitaan hetken päästä: kun kaikki yhden levyn
    # raidat on saatu muunnettua ja siirrettyä, sen alkuperäinen DVD-kopio
    # voidaan poistaa väliaikaishakemistosta tilan vapauttamiseksi — mutta
    # vasta silloin kun TODELLA KAIKKI sen raidat ovat valmiit, ei aiemmin.
    declare -A _src_total=()
    local _qs="" _qo="" _qd="" _qt="" _ql="" _qn=""
    while IFS=$'\x1f' read -r _qs _qo _qd _qt _ql _qn; do
        _src_total["$_qs"]=$(( ${_src_total["$_qs"]:-0} + 1 ))
    done < "$queue"
    declare -A _src_done=()
    local _rep_ok=0 _rep_fail=() _rep_skip=0 _rep_untried=0
    local _rep_start; _rep_start=$(date '+%Y-%m-%d %H:%M:%S')

    # Vapauta dvdbackup-hakemisto heti kun kaikki levyn raidat ovat terastationilla.
    # Näin tila vapautuu levykohtaisesti eikä vasta koko session lopussa.
    _cleanup_disc_if_done() {
        local _s="$1"
        _src_done["$_s"]=$(( ${_src_done["$_s"]:-0} + 1 ))
        if (( ${_src_done["$_s"]:-0} >= ${_src_total["$_s"]:-9999} )) && [[ -d "$_s" ]]; then
            rm -rf "$_s"
            log "  Siivottu lähde: ${_s##*/}"
        fi
    }

    # ── Nyt alkaa itse muunnossilmukka, joka käy jonon läpi raita kerrallaan ──

    # Käynnistetään lämpötilavalvonta (aiemmin selitetty throttle_loop-funktio)
    # pyörimään omana rinnakkaisena prosessinaan koko muunnoksen ajaksi.
    throttle_loop &
    local tpid=$!

    # Tämä siivoustoiminto ajetaan aina kun muunnos päättyy — oli se sitten
    # käyttäjän itse keskeyttämä (esim. Ctrl+C) tai muusta syystä katkennut.
    # TÄRKEÄÄ: jos lämpötilavalvonta on parhaillaan laittanut enkoodusohjelman
    # tauolle sen ylikuumenemisen takia, ja käyttäjä keskeyttää skriptin juuri
    # silloin, enkoodausohjelma jäisi ikuisesti "jäädytettyyn" tilaan ilman
    # tätä siivousta — se pitää ensin herättää tauolta ennen kuin sen voi
    # sulkea siististi.
    _encode_cleanup() {
        local -a _hb
        mapfile -t _hb < <(pgrep -x HandBrakeCLI 2>/dev/null)
        if (( ${#_hb[@]} > 0 )); then
            kill -CONT "${_hb[@]}" 2>/dev/null || true
            kill -TERM "${_hb[@]}" 2>/dev/null || true
        fi
        kill "$tpid" 2>/dev/null || true
        wait "$tpid" 2>/dev/null || true
        dest_lock_release_all
        [[ -n "$_my_slot" ]] && global_slot_release "$_my_slot"
        trap - INT TERM
    }
    trap "_encode_cleanup; exit 1" INT TERM

    local done_n=0 session_start; session_start=$(date +%s)
    local last_notify_ts=$session_start
    local enc_dir="${session_dir}/encoded"
    mkdir -p "$enc_dir"

    # Käydään läpi jonoon aiemmin kirjoitetut rivit, yksi raita kerrallaan.
    while IFS=$'\x1f' read -r src out_name dest title_num disc_label disc_n; do
        (( done_n++ )) || true

        # Tarkistus 0: käyttäjä on jo aiemmin päättänyt luovuttaa tästä raidasta
        # (--skip). Ei yritetä, ei lasketa onnistuneeksi eikä epäonnistuneeksi —
        # lähde-VOB säilyy koskemattomana siltä varalta että päätös perutaan.
        if _title_is_skipped "$session_dir" "$out_name"; then
            log "  Ohitetaan pysyvästi (merkitty luovutuksi --skipillä): ${out_name}"
            (( _rep_skip++ )) || true
            continue
        fi

        # Tarkistetaan levytila ennen jokaista raitaa. Näin skripti pysähtyy
        # heti selkeällä virheviestillä jos tila loppuu kesken, sen sijaan
        # että itse muunnosohjelma epäonnistuisi myöhemmin epäselvästi.
        local enc_free_gb
        enc_free_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
        if (( enc_free_gb < ENC_SPACE_MIN_GB )); then
            # HUOM (korjattu 2026-08-21): loput jonon raidat EIVÄT saa
            # kadota jäljetönä lopullisesta raportista pelkkänä erotuksena
            # (total_titles - OK - FAIL) — aiemmin break jätti ne kokonaan
            # laskematta, jolloin esim. "12 onnistui, 3 epäonnistui" saattoi
            # todellisuudessa tarkoittaa että 5 muuta raitaa ei edes
            # yritetty. _rep_untried tallentaa tämän erikseen ja se näkyy
            # sekä lokissa että ntfy-loppuraportissa.
            local _untried=$(( total_titles - done_n + 1 ))
            log "VIRHE: Brainbinillä kriittisen vähän tilaa (${enc_free_gb} GB < ${ENC_SPACE_MIN_GB} GB) — pysäytetään enkoodaus, ${_untried} raitaa jää kokonaan yrittämättä"
            _rep_untried=$_untried
            break
        fi

        # ── Palautuminen ─────────────────────────────────────────────────────
        ensure_terastation || log "  VAROITUS: terastation ei saatavilla tarkistushetkellä — jatketaan"

        # Tarkistus 1: tiedosto on jo terastationilla — ohita
        if [[ -f "${dest}/${out_name}" ]] && \
           [[ $(stat -c%s "${dest}/${out_name}" 2>/dev/null || echo 0) -gt 1048576 ]]; then
            log "  Ohitetaan (jo valmis): ${out_name}"
            (( _rep_ok++ )) || true
            _cleanup_disc_if_done "$src"
            continue
        fi

        # Tarkistus 2: valmis tiedosto enc_dir:ssä edellisestä epäonnistuneesta siirrosta —
        # yritetään siirtoa ennen uudelleenenkoodausta (säästää tunnin työn).
        local _enc_out="${enc_dir}/${out_name}"
        if [[ -f "$_enc_out" ]] && \
           [[ $(stat -c%s "$_enc_out" 2>/dev/null || echo 0) -gt 1048576 ]]; then
            log "  Löytyi enc_dir:stä edelliseltä yritykseltä — yritetään siirtoa"
            mkdir -p "$dest" 2>/dev/null || true
            if mv "$_enc_out" "${dest}/"; then
                local _sz; _sz=$(du -sh "${dest}/${out_name}" 2>/dev/null | cut -f1 || echo "?")
                log "  ✓ ${out_name} (${_sz}) [siirretty uudelleenyrityksestä]"
                (( _rep_ok++ )) || true
                _cleanup_disc_if_done "$src"
                continue
            fi
            log "  Siirto epäonnistui edelleen — enkoodataan uudelleen"
            rm -f "$_enc_out"
        else
            # Siivoa mahdollinen vajaa/vioittunut enc_dir-tiedosto
            rm -f "${enc_dir}/${out_name}" "${enc_dir}/${out_name%.mkv}.tmp.mkv"
        fi

        # ── Edistymisraportti ─────────────────────────────────────────────────
        echo "" >&2
        printf '  ╔══════════════════════════════════════════╗\n' >&2
        printf '  ║  Levy %d / %d  |  Raita %d / %d\n' "$disc_n" "$total_discs" "$done_n" "$total_titles" >&2
        printf '  ║  %s\n' "$out_name" >&2
        if (( done_n > 1 )); then
            local elapsed=$(( $(date +%s) - session_start ))
            # Keskiarvo perustuu VALMISTUNEISIIN raitoihin (done_n-1).
            # Ensimmäistä raitaa enkoodatessa ei näytetä ETAa koska näyte on liian pieni.
            local avg=$(( elapsed / (done_n - 1) ))
            local remaining=$(( total_titles - done_n + 1 ))
            local eta_secs=$(( avg * remaining ))
            printf '  ║  Kokonais-ETA: ~%s  (%d jäljellä)\n' "$(fmt_time "$eta_secs")" "$remaining" >&2
        fi
        printf '  ╚══════════════════════════════════════════╝\n' >&2
        log "Enkoodataan ($done_n/$total_titles): ${out_name} [${disc_label}]"

        # ── Enkoodaus ─────────────────────────────────────────────────────────
        local t_start; t_start=$(date +%s)
        # HUOM (2026-08-19, VAKAVA BUGI LÖYTYI JA KORJATTU): väliaikaistiedoston
        # nimessä ".tmp" EI SAA olla viimeisenä päätteenä ("Nimi.mkv.tmp") —
        # HandBrake päättelee tallennusmuodon (MKV vs MP4) --output-polun
        # VIIMEISESTÄ päätteestä. Kun se näki ".tmp":n eikä tunnistanut sitä,
        # se kirjoitti sisällön MP4-muodossa HandBraken oletusarvon mukaan,
        # vaikka lopullinen tiedosto nimettiin myöhemmin .mkv:ksi (mv poistaa
        # vain .tmp:n, ei muuta sisältöä). Tulos: tiedosto NÄYTTÄÄ .mkv:ltä
        # mutta on sisällöltään MP4 — mkvextract/mkvmerge hylkäävät sen
        # ("no EBML head found"), vaikka ffprobe/soitin lukevat sen silti
        # (tunnistavat sisällön eivätkä välitä tiedostopäätteestä). Löytyi kun
        # mkvextract epäonnistui täysin toimivalta näyttävälle tiedostolle.
        # KORJAUS: ".mkv" pysyy aina VIIMEISENÄ päätteenä, "tmp" siirretty
        # ennen sitä ("Nimi.tmp.mkv").
        local out="${enc_dir}/${out_name%.mkv}.tmp.mkv"
        local src_sz; src_sz=$(du -sh "$src" 2>/dev/null | cut -f1 || echo "?")

        # Luo kohdepolku terastationilla — retry jos verkko katkaisi
        if ! mkdir -p "$dest"; then
            log "  Kohdepolun luonti epäonnistui — yritetään remountata..."
            ensure_terastation || { log "  VIRHE: terastation ei saatu mountattua — ohitetaan: ${out_name}"; continue; }
            mkdir -p "$dest" || { log "  VIRHE: kohdepolun luonti epäonnistui yrityksistä huolimatta: ${dest}"; continue; }
        fi

        # HUOM (poistettu 2026-08-22): tässä oli aiemmin erillinen tarkistus joka
        # pysäytti JOKAISEN raidan alun jos lämpö oli yli TEMP_RESUME(50°C) —
        # laajeni virheellisesti koskemaan kaikkia raitoja vaikka alkuperäinen
        # tarkoitus (commit 9ee9905, 2026-07-25) oli vain estää seuraavan raidan
        # käynnistyminen HETI SIGKILL-hätätapauksen jälkeen. Käyttäjä vahvisti
        # 2026-08-22 ettei tätä erillistä tarkistusta ole koskaan pyydetty —
        # ainoa haluttu käytös on `throttle_loop`:in oma jatkuva 85°C-pysäytys/
        # 50°C-jatko -mekanismi, joka jo kattaa tämän koko enkoodauksen ajan
        # ilman erillistä raitojen-välistä tarkistusta.

        run_hb "$src" "$out" "$title_num" "$out_name"
        local rc=$?

        local t_secs=$(( $(date +%s) - t_start ))
        # HUOM: pelkkä "-s" (tiedosto olemassa, ei tyhjä) EI riitä — korruptoitunut
        # lähde voi saada HandBraken palauttamaan rc=0 vaikka se tuotti vain
        # muutaman tavun käyttökelvotonta dataa (havaittu käytännössä 2026-08-17,
        # District 9: 4 tiedostoa ~4-5 KB merkittiin "✓ onnistui" terastationille
        # asti). Sama 1 MB -raja kuin muuallakin skriptissä "onko tämä oikeasti
        # valmis tiedosto" -tarkistuksissa (Tarkistus 1/2, safety-net-siivous).
        local out_sz_bytes; out_sz_bytes=$(stat -c%s "$out" 2>/dev/null || echo 0)
        if (( rc == 0 )) && (( out_sz_bytes > 1048576 )); then
            local sz; sz=$(du -sh "$out" | cut -f1)
            local final="${enc_dir}/${out_name}"
            # Tiedosto nimetään ensin väliaikaisella ".tmp"-päätteellä ja vasta
            # muunnoksen VARMASTI onnistuttua nimetään lopulliseksi tiedostoksi.
            # Näin vältetään tilanne jossa virrankatkos tai muu keskeytys jättäisi
            # jäljelle vaillinaisen, rikkinäisen tiedoston joka näyttäisi valmiilta.
            mv "$out" "$final"
            if mv "$final" "${dest}/"; then
                log "  ✓ ${out_name} (${sz}, $(fmt_time "$t_secs"), lähde: ${src_sz})"
                (( _rep_ok++ )) || true
                _cleanup_disc_if_done "$src"
            else
                log "  Siirto epäonnistui — yritetään remountata..."
                if ensure_terastation && mkdir -p "$dest" && mv "$final" "${dest}/"; then
                    log "  ✓ ${out_name} (${sz}, $(fmt_time "$t_secs"), lähde: ${src_sz}) [siirto onnistui remountin jälkeen]"
                    (( _rep_ok++ )) || true
                    _cleanup_disc_if_done "$src"
                else
                    log "  VIRHE: siirto terastationille epäonnistui — ${out_name} jäi: ${final}"
                    log "         Aja --encode-only kun terastation on taas saatavilla (tiedosto enkoodataan uudelleen)"
                fi
            fi
        else
            rm -f "$out"
            # Muunnos epäonnistui. HandBrake-ohjelma kertoo syyn omalla
            # numerollaan (samaan tapaan kuin virhekoodit yleensä toimivat) —
            # tässä käännetään yleisimmät näistä numeroista ihmisluettavaksi
            # selitykseksi, jotta lokista näkee heti mistä oli kyse ilman että
            # numeroa tarvitsee erikseen googlettaa.
            local rc_note=""
            if (( rc == 0 )); then
                # HandBrake ITSE ilmoitti onnistuneensa mutta tuotos on epäilyttävän
                # pieni — käytännössä sama korruptoitunut-lähde-oire kuin rc=2:lla,
                # HandBrake vain ei tällä kertaa huomannut/raportoinut sitä itse.
                rc_note=" (HandBrake ilmoitti onnistuneensa mutta tuotos vain ${out_sz_bytes} tavua — todennäköisesti korruptoitunut lähde)"
            else
                case "$rc" in
                    124) rc_note=" (aikakatkaisu — HandBrake jumissa yli $(fmt_time "$ENC_TIMEOUT"))" ;;
                    137) rc_note=" (tapettiin väkisin — todennäköisesti ylikuumeneminen)" ;;
                    139) rc_note=" (HandBrake kaatui muistivirheeseen)" ;;
                    141) rc_note=" (yhteys HandBrakeen katkesi kesken kaiken)" ;;
                    130) rc_note=" (keskeytetty, esim. Ctrl+C)" ;;
                      2) rc_note=" (HandBrake: ei löydettyä titteliä — korruptoitunut lähde?)" ;;
                      5) rc_note=" (HandBrake kaatui hiljaa kesken ajon, ei virheviestiä — tässä projektissa tähän mennessä liittynyt aina lähteen datavaurioon, ei skriptin bugiin)" ;;
                esac
            fi
            log "  VIRHE: enkoodaus epäonnistui — ${out_name} (rc=${rc}${rc_note}, $(fmt_time "$t_secs"))"
            log "         Jos tämä toistuu eikä kannata enää yrittää: rip-dvd.sh --skip '${session_dir}' \"${out_name}\""
            _rep_fail+=("${out_name}|rc=${rc}${rc_note}")
        fi

        # ── Lähetetään käyttäjän puhelimeen tilannepäivitys 30 minuutin välein ──
        # (ei jokaisen raidan jälkeen, koska se tulisi liian usein ja häiritsisi)
        local _now_ts; _now_ts=$(date +%s)
        if (( _now_ts - last_notify_ts >= 1800 )); then
            local _elapsed=$(( _now_ts - session_start ))

            local _local_gb _tera_gb
            _local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
            _tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
            local _temp; _temp=$(get_temp)

            # ETA: keskiarvo tähän mennessä valmistuneista raidoista × jäljellä olevat
            local _remaining_n=$(( total_titles - done_n ))
            local _eta_line=""
            if (( done_n > 0 && _remaining_n > 0 )); then
                local _avg=$(( _elapsed / done_n ))
                _eta_line=$'\n'"ETA: ~$(fmt_time "$(( _avg * _remaining_n ))")"
            fi

            # Loppujono: kaikkien odottavien raitojen nimet
            local _queue_list="" _qname
            while IFS= read -r _qname; do
                [[ -z "$_qname" ]] && continue
                _queue_list+=$'\n- '"$_qname"
            done < <(tail -n +$((done_n + 1)) "$queue" | cut -d $'\x1f' -f2)
            [[ -z "$_queue_list" ]] && _queue_list=$'\n(jono tyhjä tämän raidan jälkeen)'

            local _other; _other=$(_other_sessions_pending "$session_dir")
            local _other_line=""
            [[ -n "$_other" ]] && _other_line=$'\n\n'"$_other"

            notify "DVD-enkoodus käynnissä" \
"Levy ${disc_n}/${total_discs} — raita ${done_n}/${total_titles}
Nyt: ${out_name}
Kulunut: $(fmt_time "$_elapsed") — valmiit: ${_rep_ok}, virheet: ${#_rep_fail[@]}${_eta_line}
Tila: brainbin ${_local_gb} GB, terastation ${_tera_gb} GB — lämpötila ${_temp}°C
Jonossa (${_remaining_n}):${_queue_list}${_other_line}"
            last_notify_ts=$_now_ts
        fi

    done < "$queue"

    # HUOM: _PENDING_RETRY-listan loppuunkäsittely (blokkaava "sooloputki"
    # niille kohdekansioille jotka eivät koskaan vapautuneet tämän silmukan
    # aikana) toteutetaan Tason C:n dispatch-silmukan yhteydessä, joka
    # korvaa tämän synkronisen `while`-silmukan — ei tässä vielä, koska tässä
    # vaiheessa (yksi enkoodaus kerrallaan globaalisti) _PENDING_RETRY on
    # todistetusti aina tyhjä: kaksi encode_session()-kutsua ei voi koskaan
    # olla samaan aikaan jonon rakennusvaiheessa niin kauan kuin globaali
    # lukko sallii vain yhden kerrallaan koko käsittelyn ajan.

    # ── Lähdesiivous: turvaverkko ─────────────────────────────────────────────
    # Normaalitilanteessa _cleanup_disc_if_done() on jo siivonnut levyt yksi kerrallaan.
    # Tämä lohko hoitaa mahdolliset jäänteet (esim. enkoodausvirheet joissa osa raidoista
    # puuttuu). Jos KAIKKI levyn raidat löytyvät terastationilta (> 0 tavua), lähde
    # poistetaan. Jos yksikin puuttuu, lähde säilytetään ja lokiin tulee varoitus.
    local -A _src_ok
    local _src _out _dest _t _l _n
    while IFS=$'\x1f' read -r _src _out _dest _t _l _n; do
        # Alusta avain "yes" ensimmäisellä kohdauksella
        [[ -z "${_src_ok[$_src]+x}" ]] && _src_ok["$_src"]="yes"
        # Jos raita puuttuu tai on täysin tyhjä, merkitse lähde säilytettäväksi
        if ! [[ -f "${_dest}/${_out}" ]] || \
           (( $(stat -c%s "${_dest}/${_out}" 2>/dev/null || echo 0) == 0 )); then
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
    _encode_cleanup

    # Kirjoita enkoodausraportti — luetaan seuraavalla käynnistyskerralla.
    # Atominen kirjoitus (.tmp + mv): jos virransyöttö katkeaa kesken
    # kirjoituksen, vanha raportti säilyy ehjänä sen sijaan että jäisi
    # jäljelle puolikas tiedosto jolta esim. FAIL=-rivi puuttuisi.
    {
        echo "STARTED=${_rep_start}"
        echo "FINISHED=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "OK=${_rep_ok}"
        echo "FAIL=${#_rep_fail[@]}"
        echo "SKIP=${_rep_skip}"
        echo "UNTRIED=${_rep_untried}"
        local _rf
        for _rf in "${_rep_fail[@]}"; do echo "FAIL_TITLE=${_rf}"; done
    } > "${session_dir}/.encode-report.tmp"
    mv "${session_dir}/.encode-report.tmp" "${session_dir}/.encode-report"

    # ── Lähetetään käyttäjän puhelimeen loppuraportti kun kaikki on valmista ──
    # Otsikko ei saa väittää koko työn olevan valmis, jos toinen rippaus-istunto
    # yhä odottaa omaa vuoroaan täynnä muunnettavaa sisältöä — muuten käyttäjä
    # luulisi virheellisesti että mitään ei enää ole meneillään.
    local _fail_lines="" _rf
    for _rf in "${_rep_fail[@]}"; do _fail_lines+=$'\n'"- ${_rf}"; done
    local _prio="default"
    (( ${#_rep_fail[@]} > 0 || _rep_untried > 0 )) && _prio="high"

    local _other; _other=$(_other_sessions_pending "$session_dir")
    local _title="DVD-enkoodausjono tyhjä ✓"
    local _other_line=""
    if [[ -n "$_other" ]]; then
        _title="Sessio valmis — jono jatkuu"
        _other_line=$'\n\n'"$_other"
    fi

    local _skip_note=""
    (( _rep_skip > 0 )) && _skip_note=", ${_rep_skip} ohitettu pysyvästi (--skip)"
    local _untried_note=""
    (( _rep_untried > 0 )) && _untried_note=", ${_rep_untried} jäi kokonaan yrittämättä (tila loppui)"

    notify "$_title" \
"${_rep_ok} onnistui, ${#_rep_fail[@]} epäonnistui${_skip_note}${_untried_note} — $(fmt_time "$total_secs")${_fail_lines}${_other_line}" \
        "$_prio"

    log "═══ Enkoodaus valmis — yhteensä $(fmt_time "$total_secs") (${_rep_ok} onnistui, ${#_rep_fail[@]} epäonnistui${_skip_note}${_untried_note}) ═══"

    # Muistuta lukuvirhelevyistä session lopussa
    while IFS= read -r mf; do
        local errs; errs=$(grep '^READ_ERRORS=' "$mf" 2>/dev/null | cut -d= -f2 || echo "")
        [[ -n "$errs" ]] && log "!!! TARKISTA LOPPUTULOS: $(grep '^NAME=' "$mf" | cut -d= -f2-) — ${errs} lukuvirhettä rippauksen aikana !!!"
    done < <(find "$session_dir" -name "meta.conf" | sort)
}

# Tulostaa näytölle yhteenvedon kaikesta enkoodusta odottavasta tai parhaillaan
# käynnissä olevasta työstä — riippumatta siitä mikä rippaus-istunto sen on
# aikanaan tehnyt. Tätä näytetään käyttäjälle mm. aina kun uusi rippaus-istunto
# käynnistyy, jotta hän näkee heti kokonaiskuvan: mitä on jonossa, mikä on
# käynnissä juuri nyt, ja kauanko kaiken arvioidaan vielä kestävän.
show_enc_status() {
    local _now; _now=$(date +%s)
    local _total_eta_secs=0

    # Etsitään kaikki rippaus-istunnot joilla on vielä muunnosta vailla
    # olevaa sisältöä (käyttää samaa tarkistusta kuin muuallakin skriptissä,
    # jotta tämä näyttö ei koskaan näytä eri tietoa kuin mitä oikeasti tapahtuu).
    local _sessions=()
    for _d in "$OUTBASE"/session_*/; do
        [[ -d "$_d" ]] || continue
        [[ -n "$(_session_pending_discs "$_d")" ]] || continue
        _sessions+=("$_d")
    done
    echo ""
    echo "  Enkoodausjono:"
    echo ""
    if (( ${#_sessions[@]} == 0 )); then
        echo "    (ei jonossa)"
        echo ""
        return
    fi

    # Kootaan muistiin mikä tmux-istunto (ks. selitys tiedoston alussa) liittyy
    # mihinkin käynnissä olevaan prosessiin, jotta hetken päästä voidaan lukea
    # oikean istunnon näytöltä kunkin muunnoksen tämänhetkinen edistyminen.
    declare -A _ps
    while IFS=' ' read -r _s _p; do
        [[ "$_s" == "dvd-rip" || "$_s" == "watchdog" ]] && continue
        _ps["$_p"]="$_s"
    done < <(tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null)

    for _d in "${_sessions[@]}"; do
        local _pid; _pid=$(pgrep -f "encode-only.*$(basename "$_d")" 2>/dev/null | head -1)
        local _is_running=0; [[ -n "$_pid" ]] && _is_running=1

        # Kerää kaikki uniikit nimet + sarjatiedot vain niiltä levyiltä joilla
        # on oikeasti vielä enkoodaamatonta dataa — muuten jo valmiiden ja
        # siivottujen levyjen nimet/jaksonumerot vuotaisivat otsikkoon vaikka
        # session on merkitty "jonossa" pelkän erillisen roskalevyn takia.
        local _all_names=() _season="" _ep_start="" _ep_end="" _disc_count=0 _is_series=0
        while IFS= read -r _dmf; do
            [[ -f "$_dmf" ]] || continue
            local _dt; _dt=$(grep '^TYPE='   "$_dmf" 2>/dev/null | cut -d= -f2)
            local _dn; _dn=$(grep '^NAME='   "$_dmf" 2>/dev/null | cut -d= -f2-)
            if [[ -n "$_dn" ]]; then
                local _dup=0
                for _ex in "${_all_names[@]}"; do [[ "$_ex" == "$_dn" ]] && { _dup=1; break; }; done
                (( _dup )) || _all_names+=("$_dn")
            fi
            [[ "$_dt" == "series" ]] || continue
            _is_series=1
            (( _disc_count++ )) || true
            local _ds; _ds=$(grep '^SEASON='      "$_dmf" 2>/dev/null | cut -d= -f2)
            [[ -z "$_season" ]] && _season="$_ds"
            local _dep;  _dep=$(grep '^START_EP='    "$_dmf" 2>/dev/null | cut -d= -f2)
            local _dcnt; _dcnt=$(grep '^TITLE_COUNT=' "$_dmf" 2>/dev/null | cut -d= -f2)
            local _dmax; _dmax=$(grep '^MAX_EPISODES=' "$_dmf" 2>/dev/null | cut -d= -f2)
            [[ -n "$_dmax" && -n "$_dcnt" ]] && (( _dmax > 0 && _dcnt > _dmax )) && _dcnt=$_dmax
            [[ -z "$_dep" || -z "$_dcnt" ]] && continue
            [[ -z "$_ep_start" || "$_dep" -lt "$_ep_start" ]] && _ep_start=$_dep
            local _dend=$(( _dep + _dcnt - 1 ))
            [[ -z "$_ep_end" || "$_dend" -gt "$_ep_end" ]] && _ep_end=$_dend
        done < <(_session_pending_discs "$_d")

        # Rakenna sisältöotsikko
        local _content_lbl
        if (( ${#_all_names[@]} > 1 )); then
            # Useita eri teoksia — otsikkoon vain määrä, nimet tulostetaan omille
            # riveilleen alempana ettei tule yhtä pitkää /-erotettua pötköä.
            _content_lbl="${#_all_names[@]} eri teosta"
        elif (( ${#_all_names[@]} == 1 )); then
            _content_lbl="${_all_names[0]}"
            if (( _is_series )); then
                [[ -n "$_season" ]] && _content_lbl+=" S${_season}"
                if [[ -n "$_ep_start" && -n "$_ep_end" ]]; then
                    if (( _ep_start == _ep_end )); then
                        _content_lbl+=" E$(printf '%02d' "$_ep_start")"
                    else
                        _content_lbl+=" E$(printf '%02d' "$_ep_start")-E$(printf '%02d' "$_ep_end")"
                    fi
                    (( _disc_count > 1 )) && _content_lbl+=" (${_disc_count} levyä)"
                fi
            fi
        else
            _content_lbl="$(basename "$_d")"
        fi

        # Selvitetään kopioidun DVD-datan kokonaiskoko gigatavuina — tätä
        # käytetään hetken päästä arvioimaan kuinka kauan muunnos vielä kestää,
        # koska tiedostokoko on karkea mutta toimiva mittari muunnosajalle.
        local _vob_bytes; _vob_bytes=$(du -sb "$_d"disc-*/dvdbackup/ 2>/dev/null \
            | awk '{s+=$1} END {print (s ? s : 0)}')
        local _vob_gb; _vob_gb=$(awk "BEGIN {printf \"%.3f\", ${_vob_bytes}/1073741824}")

        # Arvioidaan kuinka kauan tältä sessiolta vielä kestää valmistua
        local _session_eta=0 _hb_status="" _hb_eta_secs=0

        if (( _is_running )); then
            # Jos muunnos on juuri nyt käynnissä, luetaan sen omalta
            # ruudultaan (tmux-istunnolta) todellinen tämänhetkinen
            # edistymisprosentti sen sijaan että vain arvattaisiin.
            local _pp; _pp=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
            local _tsess="${_ps[$_pp]:-}"
            if [[ -n "$_tsess" ]]; then
                _hb_status=$(tmux capture-pane -t "$_tsess" -p 2>/dev/null \
                    | grep -oE '\[.+\] [0-9]+\.[0-9]+%.*ETA [0-9hms]+' \
                    | tail -1 | sed 's/^[[:space:]]*//')
            fi
            # HandBrake näyttää jäljellä olevan ajan tekstimuodossa kuten
            # "1h23m45s" tai "23m45s" tai vain "45s" — tässä se puretaan
            # tunneiksi, minuuteiksi ja sekunneiksi ja muunnetaan takaisin
            # pelkiksi sekunneiksi, jotta lukuja voi myöhemmin laskea yhteen.
            if [[ "$_hb_status" =~ ETA[[:space:]]+([0-9]+h)?([0-9]+m)?([0-9]+s)? ]]; then
                local _hv="${BASH_REMATCH[1]%h}" _mv="${BASH_REMATCH[2]%m}" _sv="${BASH_REMATCH[3]%s}"
                _hb_eta_secs=$(( ${_hv:-0}*3600 + ${_mv:-0}*60 + ${_sv:-0} ))
            fi

            # Lasketaan kuinka moni tämän session raidoista on vielä
            # muuntamatta, lukemalla työjonotiedostosta.
            local _q="${_d}.queue"
            local _total_q=0 _done_q=0
            local _qsrc="" _qoname="" _qdst="" _qtnum="" _qdlbl="" _qdseq=""
            if [[ -f "$_q" ]]; then
                _total_q=$(wc -l < "$_q")
                while IFS=$'\x1f' read -r _qsrc _qoname _qdst _qtnum _qdlbl _qdseq; do
                    [[ -f "${_qdst}/${_qoname}" ]] && \
                    [[ $(stat -c%s "${_qdst}/${_qoname}" 2>/dev/null || echo 0) -gt 1048576 ]] && \
                    (( _done_q++ )) || true
                done < "$_q"
            fi
            local _remaining=$(( _total_q > _done_q ? _total_q - _done_q : 0 ))

            # Arvioidaan kuinka kauan yksi raita keskimäärin kestää, jakamalla
            # koko session datamäärä raitojen lukumäärällä ja tunnetulla
            # keskimääräisellä muunnosnopeudella (ENCODE_SPEED_GB_PER_HOUR).
            local _per_secs=0
            if (( _total_q > 0 )); then
                _per_secs=$(awk "BEGIN {print int(${_vob_gb}/${ENCODE_SPEED_GB_PER_HOUR}*3600/${_total_q})}")
            fi

            # Lopullinen arvio: käytetään HandBraken OMAA reaaliaikaista
            # arviota nykyisen raidan lopuksi asti, ja lisätään siihen
            # kaikkien jäljellä olevien raitojen arvioitu kesto.
            if (( _hb_eta_secs > 0 && _remaining > 1 )); then
                _session_eta=$(( _hb_eta_secs + (_remaining - 1) * _per_secs ))
            elif (( _hb_eta_secs > 0 )); then
                _session_eta=$_hb_eta_secs
            elif (( _remaining > 0 && _per_secs > 0 )); then
                _session_eta=$(( _remaining * _per_secs ))
            else
                # Työjonotiedostoa ei löytynyt (esim. istunto odottaa yhä omaa
                # vuoroaan lukituksesta) — arvioidaan pelkän datamäärän perusteella.
                _session_eta=$(awk "BEGIN {print int(${_vob_gb}/${ENCODE_SPEED_GB_PER_HOUR}*3600)}")
            fi
        else
            # Ei vielä käynnissä — arvioidaan pelkän datamäärän perusteella.
            _session_eta=$(awk "BEGIN {print int(${_vob_gb}/${ENCODE_SPEED_GB_PER_HOUR}*3600)}")
        fi

        (( _session_eta < 0 )) && _session_eta=0
        _total_eta_secs=$(( _total_eta_secs + _session_eta ))

        # Tulosta rivi
        local _pfx
        if (( _is_running )); then _pfx="▶ enkoodataan"; else _pfx="  jonossa   "; fi
        printf '    %s  %s\n' "$_pfx" "$_content_lbl"
        if (( ${#_all_names[@]} > 1 )); then
            for _nm in "${_all_names[@]}"; do
                printf '                 - %s\n' "$_nm"
            done
        fi
        [[ -n "$_hb_status" ]] && printf '                 %s\n' "$_hb_status"
        if (( _session_eta > 0 )); then
            printf '                 Arvio: ~%s\n' "$(fmt_time "$_session_eta")"
        fi
    done

    unset _ps

    # Yhteenveto
    if (( _total_eta_secs > 0 )); then
        local _finish=$(( _now + _total_eta_secs ))
        local _fin_str; _fin_str=$(date -d "@${_finish}" '+%a %-d.%-m. klo %H:%M')
        echo ""
        printf '  Kokonaisaika: ~%s  |  Valmis arviolta: %s\n' \
            "$(fmt_time "$_total_eta_secs")" "$_fin_str"
    fi
    echo ""
}

# Tulostaa näytölle lyhyen historian: mitä aiemmat rippaus-istunnot ovat
# saaneet valmiiksi ja onnistuivatko ne kokonaan vai jäikö jotain kesken.
# Tämä auttaa käyttäjää näkemään yhdellä silmäyksellä koko kokoelman
# senhetkisen tilanteen kun rippaussskripti käynnistetään.
show_recent_reports() {
    local _any=0
    for _d in "$OUTBASE"/session_*/; do
        local _r="${_d}.encode-report"
        [[ -f "$_r" ]] || continue
        local _ok _fail _skip _untried _finished
        _ok=$(grep '^OK='       "$_r" 2>/dev/null | cut -d= -f2)
        _fail=$(grep '^FAIL='   "$_r" 2>/dev/null | cut -d= -f2)
        _skip=$(grep '^SKIP='   "$_r" 2>/dev/null | cut -d= -f2)
        # UNTRIED puuttuu vanhoista, ennen 2026-08-21 kirjoitetuista
        # raporteista — ${:-0} alempana käsittelee sen turvallisesti.
        _untried=$(grep '^UNTRIED=' "$_r" 2>/dev/null | cut -d= -f2)
        _finished=$(grep '^FINISHED=' "$_r" 2>/dev/null | cut -d= -f2-)

        # Kootaan sarjan/elokuvan/yms. nimet tästä sessiosta, ilman
        # kertautuvia duplikaatteja jos sama nimi toistuu monella levyllä
        local _names=()
        for _mf in "${_d}"disc-*/meta.conf; do
            [[ -f "$_mf" ]] || continue
            local _n; _n=$(grep '^NAME=' "$_mf" 2>/dev/null | cut -d= -f2-)
            [[ -z "$_n" ]] && continue
            local _dup=0
            for _e in "${_names[@]}"; do [[ "$_e" == "$_n" ]] && { _dup=1; break; }; done
            (( _dup )) || _names+=("$_n")
        done
        local _lbl
        if (( ${#_names[@]} == 0 )); then
            _lbl="$(basename "$_d")"
        elif (( ${#_names[@]} == 1 )); then
            _lbl="${_names[0]}"
        else
            _lbl="${_names[0]} + $((${#_names[@]}-1)) muuta"
        fi

        (( _any++ )) || true
        local _total=$(( ${_ok:-0} + ${_fail:-0} + ${_skip:-0} + ${_untried:-0} ))
        local _date="${_finished%% *}"

        if [[ "${_fail:-0}" == "0" && "${_untried:-0}" == "0" ]]; then
            printf '  ✓ %-42s %d/%d OK  [%s]\n' "$_lbl" "$_total" "$_total" "$_date"
        else
            local _skip_suffix=""
            (( ${_skip:-0} > 0 )) && _skip_suffix=", ${_skip} ohitettu pysyvästi"
            (( ${_untried:-0} > 0 )) && _skip_suffix+=", ${_untried} jäi yrittämättä (tila loppui)"
            printf '  ✗ %-42s %d/%d OK, %d epäonnistui%s  [%s]\n' \
                "$_lbl" "${_ok:-0}" "$_total" "${_fail:-0}" "$_skip_suffix" "$_date"
            _print_fail_titles "$_d" "$_r" 0
        fi
    done
    if (( _any > 0 )); then
        echo ""
    fi
}

# ── Pääohjelma ──────────────────────────────────────────────────────────────
# Tästä skriptin suoritus varsinaisesti alkaa. Kaksi eri toimintatapaa:
#   1) Normaali käynnistys: kysytään käyttäjältä levyjä yksi kerrallaan,
#      kopioidaan kukin ja käynnistetään niiden muunnos taustalle.
#   2) --encode-only: hypätään suoraan muunnosvaiheeseen jo aiemmin
#      kopioidulle sisällölle (käytetään esim. kun edellinen ajo keskeytyi
#      kesken kaiken eikä levyjä haluta kopioida uudelleen alusta asti).

main() {
    # Jos skripti käynnistettiin --encode-only-tilassa, ei kysytä yhtään
    # mitään käyttäjältä eikä kopioida uusia levyjä — muunnetaan suoraan
    # olemassa oleva, jo aiemmin kopioitu sisältö. Tämä on hyödyllinen tapa
    # jatkaa siitä mihin jäätiin, jos muunnos on jostain syystä keskeytynyt
    # (esim. sähkökatko tai ylikuumeneminen). Muunnosvaihe itsessään tunnistaa
    # automaattisesti mitkä raidat ovat jo valmiiksi terastationilla eikä
    # muunna niitä turhaan uudelleen.
    if [[ "${1:-}" == "--encode-only" ]]; then
        local enc_dir="${2:-}"
        [[ -z "$enc_dir" ]] && die "--encode-only vaatii session-hakemiston polun"
        [[ -d "$enc_dir" ]]  || die "Hakemisto ei löydy: $enc_dir"
        ensure_terastation || die "Terastation ei saatu mountattua"
        command -v HandBrakeCLI &>/dev/null || die "HandBrakeCLI ei löydy"
        # Korjattu 2026-08-20: ${enc_dir##*/} tuotti tyhjän nimen kun enc_dir
        # päättyi kauttaviivaan (esim. main()in automaattikäynnistys antaa
        # aina "session_XXX/"-muotoisen polun). basename+%/ poistaa loppu-
        # kauttaviivan ennen pilkkomista, joten nimi näkyy aina oikein.
        log "═══ Enkoodaus-only: $(basename "${enc_dir%/}") ═══"
        encode_session "$enc_dir"
        log "═══ Kaikki valmis! ═══"
        return
    fi

    mkdir -p "$OUTBASE"
    log "═══ DVD-rippaus käynnistyy ═══"

    # Tarkista onko sessioita — käynnissä tai odottavia
    local running_enc=() pending=()
    for d in "$OUTBASE"/session_*/; do
        [[ -d "$d" ]] || continue
        [[ -n "$(_session_pending_discs "$d")" ]] || continue
        if pgrep -f "encode-only.*$(basename "$d")" > /dev/null 2>&1; then
            running_enc+=("$d")
        else
            pending+=("$d")
        fi
    done
    show_recent_reports
    show_enc_status
    if (( ${#pending[@]} > 0 )); then
        echo ""
        echo "  Löytyi ${#pending[@]} sessio(ta) enkoodaamattomalla datalla:"
        for d in "${pending[@]}"; do
            echo "    $(basename "$d")"
            # Jos tälle sessiolle on jo aiempi enkoodausraportti epäonnistumisilla,
            # kerrotaan heti mitkä raidat kaatuivat ja miksi — muuten kysymys
            # "käynnistetäänkö enkoodaus" näyttää siltä että data on vain
            # kesken, vaikka todellisuudessa samat raidat ovat jo kertaalleen
            # epäonnistuneet (esim. levyvaurio) ja todennäköisesti epäonnistuvat
            # uudelleenkin samasta syystä.
            local _rep="${d}.encode-report"
            if [[ -f "$_rep" ]] && [[ "$(grep '^FAIL=' "$_rep" 2>/dev/null | cut -d= -f2)" != "0" ]]; then
                echo "      (edellisellä yrityksellä epäonnistui:)"
                _print_fail_titles "$d" "$_rep" 1
            fi
        done
        echo ""
        local enc_ok=""
        read -rp "  Käynnistetäänkö enkoodaus taustalle? (k/e): " enc_ok </dev/tty
        if [[ "$enc_ok" == "k" ]]; then
            for d in "${pending[@]}"; do
                local sname; sname="enc-$(basename "$d" | sed 's/session_//')"
                if pgrep -f "encode-only.*$(basename "$d")" > /dev/null 2>&1; then
                    log "  $(basename "$d") enkoodataan jo — ohitetaan"
                elif tmux has-session -t "$sname" 2>/dev/null; then
                    log "  $sname on jo käynnissä — ohitetaan"
                else
                    tmux new-session -d -s "$sname" "bash /usr/local/bin/rip-dvd.sh --encode-only '$d'"
                    log "  Käynnistettiin enkoodaussessio: $sname"
                fi
            done
            echo ""
        fi
    fi

    # Varmista riippuvuudet ja levytila — vasta enkoodaustilanteen näyttämisen jälkeen
    ensure_terastation || die "Terastation ei saatu mountattua"
    command -v HandBrakeCLI &>/dev/null || die "HandBrakeCLI ei löydy"
    command -v dvdbackup   &>/dev/null || die "dvdbackup ei löydy — asenna: apt install dvdbackup"

    local local_gb tera_gb
    local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    log "Tilaa: brainbin ${local_gb} GB vapaana, terastation ${tera_gb} GB vapaana"
    (( local_gb < 14 )) && log "VAROITUS: Brainbinillä vain ${local_gb} GB — tilaa ehkä vain yhdelle levylle"
    (( local_gb <  8 )) && die "Brainbinillä ei riitä tilaa (${local_gb} GB) — pysäytetään"
    (( tera_gb  < 20 )) && log "VAROITUS: Terastationilla vain ${tera_gb} GB vapaana"
    (( tera_gb  <  5 )) && die "Terastationilla kriittisen vähän tilaa (${tera_gb} GB) — pysäytetään"

    # Session-hakemisto: yksi sessio = yksi käyttökerta (useita levyjä)
    local session_dir="${OUTBASE}/session_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$session_dir"

    # Edellisen levyn metatiedot oletuksina seuraavalle — käyttäjän ei tarvitse
    # kirjoittaa sarjan nimeä ja kautta uudelleen joka levylle
    local p_type="" p_name="" p_season="" p_ep="" p_max_ep=""
    # p_max_ep nollataan joka levyn jälkeen (se on aina KYSEISEN levyn arvo).
    # p_max_ep_suggest EI nollaannu — se muistaa viimeksi annetun luvun koko
    # session ajan, jotta ask_meta() voi ehdottaa sitä seuraavallakin levyllä.
    local p_max_ep_suggest=""
    local disc_num=0
    # Muistaa VIIMEISIMMÄN levyn nimen jolta löytyi oikea MOVIE_TITLE_NUM (ei "0").
    # Käytetään turvallisemman aikakatkaisu-oletuksen valintaan monilevyisille
    # elokuville/dokumenteille — ks. kommentti alempana MOVIE_TITLE_NUM-kysymyksen
    # kohdalla (käyttäjän 2026-08-20 huomauttama riski: pelkkiä ekstroja sisältävä
    # 2. levy saisi väärin "elokuva"-tunnisteen jos kukaan ei ehdi vastata).
    local _last_movie_name=""

    # ── Rippaussilmukka: lisää levyjä kunnes käyttäjä kirjoittaa 'q' ─────────
    while true; do
        echo ""
        echo "══════════════���═══════════════════════════════"
        printf '  Levyjä ripattuna tässä sessiossa: %d\n' "$disc_num"
        echo "══════════════════════════════════════════════"
        local cmd=""
        read -rp "  Lisää levy ja paina Enter  (q = lopeta rippaus): " cmd
        [[ "${cmd,,}" == "q" ]] && break

        # Kysy levyn metatiedot — palaa \x1F-eroteltuna merkkijonona
        local meta_str
        meta_str=$(ask_meta "$p_type" "$p_name" "$p_season" "$p_ep" "$p_max_ep_suggest")
        IFS=$'\x1f' read -r p_type p_name p_season p_ep p_max_ep <<< "$meta_str"
        [[ -z "$p_name" ]] && continue  # Virhe syötteessä (esim. tyhjä nimi) — kysytään uudelleen
        [[ -n "$p_max_ep" ]] && p_max_ep_suggest="$p_max_ep"

        # Näytetään yhteenveto juuri annetuista tiedoista ja pyydetään
        # käyttäjää vielä vahvistamaan ne ennen kuin mihinkään ryhdytään
        echo ""
        case "$p_type" in
        series) printf '  → %s S%02d alkaen E%02d\n' "$p_name" "$p_season" "$p_ep" ;;
        movie)  printf '  → Elokuva: %s (%s)\n'      "$p_name" "$p_season" ;;
        doc)    printf '  → Dokumentti: %s (%s)\n'   "$p_name" "$p_season" ;;
        music)  printf '  → Musiikki: %s\n'          "$p_name" ;;
        misc)   printf '  → Misc: %s\n'              "$p_name" ;;
        esac

        local ok=""
        read -rp "  Oikein? (k/e=peruuta): " ok
        if [[ "${ok,,}" == "e" ]]; then p_name=""; continue; fi

        # ── Tarkistetaan onko terastationilla jo tätä samaa sisältöä ────────
        # Tämä varoittaa jos kohdekansiossa on jo tiedostoja, jotta levyä ei
        # vahingossa ripata uudelleen ja ylikirjoiteta jotain jo olemassa
        # olevaa. Sarjojen kohdalla tarkistetaan seuraavat 50 mahdollista
        # jaksonumeroa alkaen annetusta jaksosta.
        local tera_dest
        tera_dest=$(dest_path "$p_type" "$p_name" "${p_season:-}")
        if [[ -d "$tera_dest" ]]; then
            local tera_existing=()
            if [[ "$p_type" == series ]]; then
                local _ce; _ce="$p_ep"
                while (( _ce < p_ep + 50 )); do
                    local _fn="${p_name} S$(printf '%02d' "$p_season")E$(printf '%02d' "$_ce").mkv"
                    [[ -f "${tera_dest}/${_fn}" ]] && tera_existing+=("$_fn")
                    (( _ce++ ))
                done
            else
                while IFS= read -r _f; do tera_existing+=("${_f##*/}"); done \
                    < <(find "$tera_dest" -maxdepth 1 -name "*.mkv" 2>/dev/null | sort)
            fi
            if (( ${#tera_existing[@]} > 0 )); then
                echo "" >&2
                echo "  HUOMIO: Terastationilla on jo tiedostoja:" >&2
                for _ef in "${tera_existing[@]}"; do echo "    ${_ef}" >&2; done
                local over_ok=""
                read -rp "  Ripataanko silti? (k/e): " over_ok
                [[ "${over_ok,,}" != "k" ]] && continue
            fi
        fi

        # ── Päällekkäisyystarkistus: tämä sessio + kaikki jonossa olevat ────────
        # Varoittaa jos jokin aiempi levy (tässä tai toisessa sessiossa) kattaa
        # samat jaksot — myös jos ne ovat vain jonossa eivätkä vielä terastationilla.
        if [[ "$p_type" == series ]]; then
            local prev_mf
            for prev_mf in "${session_dir}"/disc-*/meta.conf \
                           "$OUTBASE"/session_*/disc-*/meta.conf; do
                [[ -f "$prev_mf" ]] || continue
                local prev_name prev_season prev_ep prev_count
                prev_name=$(grep '^NAME=' "$prev_mf" | cut -d= -f2-)
                prev_season=$(grep '^SEASON=' "$prev_mf" | cut -d= -f2-)
                prev_ep=$(grep '^START_EP=' "$prev_mf" | cut -d= -f2-)
                prev_count=$(grep '^TITLE_COUNT=' "$prev_mf" 2>/dev/null | cut -d= -f2 || echo 0)
                local prev_max_ep; prev_max_ep=$(grep '^MAX_EPISODES=' "$prev_mf" 2>/dev/null | cut -d= -f2 || echo 0)
                (( prev_max_ep > 0 && prev_max_ep < prev_count )) && prev_count=$prev_max_ep
                if [[ "$prev_name" == "$p_name" && "$prev_season" == "$p_season" ]] \
                   && (( p_ep < prev_ep + prev_count )); then
                    echo "" >&2
                    echo "  VAROITUS: Päällekkäisyys! Aiempi levy alkaa E${prev_ep} ja kattaa ${prev_count} raitaa." >&2
                    echo "  Tämä levy alkaa E${p_ep} — E$(( prev_ep + prev_count - 1 )) tulee kahdesti." >&2
                    local confirm=""
                    read -rp "  Jatketaanko silti? (k/e): " confirm
                    [[ "${confirm,,}" != "k" ]] && continue 2
                fi
            done
        fi

        # Levytilan tarkistus ennen jokaista levyä
        local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
        tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
        (( local_gb <  8 )) && die "Brainbinillä ei riitä tilaa (${local_gb} GB) — pysäytetään"
        (( tera_gb  <  5 )) && die "Terastationilla kriittisen vähän tilaa (${tera_gb} GB) — pysäytetään"
        log "Levy $((disc_num+1)): $p_type | $p_name | $p_season | ep=$p_ep"

        echo "  Odotetaan levyasemaa..."
        local disc_dev; disc_dev=$(wait_for_disc)

        (( disc_num++ ))
        local raw_dir="${session_dir}/disc-$(printf '%03d' "$disc_num")"
        mkdir -p "$raw_dir"

        # Kirjoitetaan levyn tiedot muistiin heti kaikilla jo tiedossa olevilla
        # tiedoilla — ei vasta sitten kun kopiointi on onnistunut. Näin, jos
        # skripti kaatuisi jostain syystä kesken kopioinnin, tiedosto sisältää
        # silti riittävästi tietoa jotta myöhempi palautumisyritys osaa löytää
        # ja käsitellä tämän levyn oikein, sen sijaan että se jäisi kokonaan
        # tuntemattomaksi hakemistoksi ilman minkäänlaisia tietoja.
        {
            echo "TYPE=${p_type}"
            echo "NAME=${p_name}"
            echo "SEASON=${p_season}"
            echo "START_EP=${p_ep}"
            echo "RIP_MODE=dvdbackup"
            [[ -n "$p_max_ep" ]] && echo "MAX_EPISODES=${p_max_ep}"
        } > "${raw_dir}/meta.conf"

        log "Ripataan disc ${disc_num} dvdbackupilla (${disc_dev})..."
        local rip_log="${raw_dir}/rip.log"
        local dv_dir="${raw_dir}/dvdbackup"
        mkdir -p "$dv_dir"

        # Selvitetään levyn kokonaiskoko, jotta kopioinnin edistymistä voidaan
        # näyttää muodossa "X gigatavua kopioitu Y:stä" — kokeillaan ensin
        # yhtä tapaa levyn koon selvittämiseen, ja jos se ei toimi, kokeillaan
        # toista. Jos kumpikaan ei toimi, edistyminen näytetään ilman
        # kokonaismäärää (pelkkä kopioitu määrä).
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
    if b >= d: print(f'{b/d:.2f}{u}'); break
" "$disc_dev" 2>/dev/null || true)

        # Käynnistetään itse levyn kopiointiohjelma (dvdbackup) taustalle,
        # jotta skripti voi samalla seurata sen edistymistä ja tarvittaessa
        # katkaista sen jos se jää jumiin liian pitkäksi aikaa. Jos kopiointi
        # epäonnistuu (muttei ole vain jumiutunut), sitä yritetään uudelleen
        # muutaman kerran ennen kuin koko levy hylätään.
        local read_errors=0 dv_rc=0 timed_out=0
        local rip_attempt
        for (( rip_attempt=1; rip_attempt<=MAX_RIP_ATTEMPTS; rip_attempt++ )); do
            if (( rip_attempt > 1 )); then
                log "  Uudelleenyritetään rippaus (yritys ${rip_attempt}/${MAX_RIP_ATTEMPTS})..."
                find "$dv_dir" -mindepth 1 -delete 2>/dev/null || true
            fi

            local rip_tmplog; rip_tmplog=$(mktemp --tmpdir "rip-dvd-rip-XXXXXX.log")
            dvdbackup -i "$disc_dev" -o "$dv_dir" -M >"$rip_tmplog" 2>&1 &
            local dv_pid=$!
            timed_out=0

            local rip_waited=0
            while kill -0 "$dv_pid" 2>/dev/null; do
                sleep 10
                (( rip_waited += 10 )) || true
                # du -sh antaa aina vain yhden desimaalin — pieni edistyminen
                # (esim. lukuvirheen jälkeisen hidastuksen aikana) ei näy siinä
                # ollenkaan ja rippaus vaikuttaa jumiutuneelta vaikka etenee.
                local sz_bytes; sz_bytes=$(du -sb "$dv_dir" 2>/dev/null | cut -f1)
                local sz; sz=$(awk -v b="${sz_bytes:-0}" 'BEGIN {
                    if (b >= 1073741824) printf "%.2fG", b/1073741824
                    else printf "%.2fM", b/1048576
                }')
                if [[ -n "$disc_total_hr" ]]; then
                    printf '\r  [rippaus] %s / %s  (%s kulunut)' "$sz" "$disc_total_hr" "$(fmt_time "$rip_waited")" >&2
                else
                    printf '\r  [rippaus] %s  (%s kulunut)' "$sz" "$(fmt_time "$rip_waited")" >&2
                fi
                if (( rip_waited >= RIP_TIMEOUT )); then
                    kill -KILL "$dv_pid" 2>/dev/null || true
                    timed_out=1
                    break
                fi
            done
            wait "$dv_pid" 2>/dev/null; dv_rc=$?
            printf '\n' >&2

            cat "$rip_tmplog" >> "$LOGFILE" || true
            cp "$rip_tmplog" "$rip_log" 2>/dev/null || true
            read_errors=$(grep -c 'Error reading' "$rip_tmplog" 2>/dev/null | head -1 || echo 0)
            read_errors="${read_errors//[^0-9]/}"
            read_errors="${read_errors:-0}"
            rm -f "$rip_tmplog"

            if (( timed_out )); then
                log "VIRHE: dvdbackup aikakatkaisu ($(fmt_time "$RIP_TIMEOUT")) — ei yritetä uudelleen"
                break
            fi

            # Kopiointia pidetään onnistuneena jos se päättyi ilman virhettä
            # JA levyltä oikeasti löytyi kunnollisia videotiedostoja
            local vob_check
            vob_check=$(find "$dv_dir" -name "VTS_*_[1-9].VOB" -size +10M 2>/dev/null | wc -l)
            if (( vob_check > 0 && dv_rc == 0 )); then
                break
            fi
            log "  Rippaus epäonnistui (exit ${dv_rc}, VOB-tiedostoja ${vob_check}) — yritys ${rip_attempt}/${MAX_RIP_ATTEMPTS}"
        done

        local vob_count
        vob_count=$(find "$dv_dir" -name "VTS_*_[1-9].VOB" -size +10M 2>/dev/null | wc -l)
        if (( timed_out )) || (( vob_count == 0 )); then
            local fail_reason="exit ${dv_rc}, ei VOB-tiedostoja"
            (( timed_out )) && fail_reason="aikakatkaisu ${RIP_TIMEOUT}s"
            log "VIRHE: dvdbackup epäonnistui (${fail_reason}) — levy ${disc_num} ohitetaan"
            eject "$disc_dev" 2>/dev/null || true
            rm -rf "$raw_dir"
            (( disc_num-- )) || true
            continue
        fi
        if (( dv_rc != 0 )); then
            log "VAROITUS: dvdbackup exit ${dv_rc} (ei nolla) — VOB-tiedostoja löytyi silti, jatketaan"
        fi

        if (( read_errors > 0 )); then
            log "VAROITUS: ${read_errors} lukuvirhettä rippauksen aikana — tarkista lopputulos!"
            echo "READ_ERRORS=${read_errors}" >> "${raw_dir}/meta.conf"
        fi

        # Tutkitaan kopioidulta levyltä löytyvät raidat ja niiden kestot, ja
        # jos käyttäjä ei vielä kertonut montako niistä on oikeita jaksoja
        # (erotuksena ekstroista), kysytään se nyt kun tiedot ovat näkyvissä.
        log "dvdbackup onnistui (${vob_count} VOB). Skannataan raidat..."
        local dvd_inner; dvd_inner=$(find "$dv_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
        local scan_result
        # --no-dvdnav: ks. run_hb():n kommentti samasta lipusta.
        scan_result=$(timeout "$SCAN_TIMEOUT" HandBrakeCLI -i "$dvd_inner" -t 0 --scan --no-dvdnav </dev/null 2>&1 | python3 -c "
import sys, re
min_dur = $MIN_DURATION
cur = None
for line in sys.stdin.buffer:
    line = line.decode('utf-8', errors='replace')
    m = re.search(r'scan: scanning title (\d+)', line)
    if m: cur = int(m.group(1))
    m2 = re.search(r'scan: duration is (\d+):(\d+):(\d+)', line)
    if m2 and cur is not None:
        h,mn,s = int(m2.group(1)), int(m2.group(2)), int(m2.group(3))
        if h*3600 + mn*60 + s >= min_dur:
            print(f'{cur}\t{h:02d}:{mn:02d}:{s:02d}')
        cur = None
")
        local title_count; title_count=$(echo "$scan_result" | grep -c . || echo 0)

        echo ""
        echo "  Raidat levyllä:"
        while IFS=$'\t' read -r tnum tdur; do
            printf '    Raita %s: %s\n' "$tnum" "$tdur"
        done <<< "$scan_result"
        echo ""

        # Jos MAX_EPISODES/MOVIE_TITLE_NUM ei ole vielä asetettu, kysy nyt kun
        # tiedot näkyvissä. Sarjoilla erottaa jaksot ekstroista (MAX_EPISODES:
        # "ensimmäiset N raitaa", koska jaksot ovat aina levyn alussa). Elokuvilla
        # /dokumenteilla erottaa itse teoksen bonusmateriaalista TARKALLA
        # raitanumerolla (MOVIE_TITLE_NUM) — ei oleta että teos olisi levyn
        # ensimmäinen raita, toisin kuin alkuperäinen "montako ensimmäistä"
        # -kysymys teki (käyttäjän 2026-08-16 huomauttama sanamuoto-/logiikkavirhe:
        # numero ei kertonut MIKÄ raita on elokuva vaan MONTAKO ensimmäistä on).
        # Ilman tätä kaikki levyn "pitkät" raidat (myös featurette-tyyppiset
        # ekstrat) nimetään juoksevasti "Part 01, 02, 03..." erottamattomina
        # (ks. Bender's Big Score -sekaannus, jossa itse 85 min elokuva oli
        # "Part 01" muun 10 lyhyen ekstran joukossa). Musiikilla/misc:llä ei kysytä.
        if [[ "$p_type" == series ]] && [[ -z "$p_max_ep" ]] && (( title_count > 0 )); then
            local asked_max=""
            # 180s aikakatkaisu (ks. feedback-bash-script-patterns: "read ilman -t
            # blokkaa ikuisesti") — jos käyttäjä on mennyt nukkumaan, tämä EI SAA
            # jäädä ikuisesti odottamaan. Oletus aikakatkaisulla = kuin pelkkä Enter.
            read -rp "  Montako jaksoa (Enter = kaikki ${title_count}) [180s → kaikki samaan]: " -t 180 asked_max </dev/tty || true
            if [[ -n "$asked_max" ]]; then
                if [[ "$asked_max" =~ ^[0-9]+$ ]]; then
                    p_max_ep="$asked_max"
                    p_max_ep_suggest="$p_max_ep"
                    echo "MAX_EPISODES=${p_max_ep}" >> "${raw_dir}/meta.conf"
                else
                    echo "  Ei kelpaa: '${asked_max}' — ohitetaan (käytetään kaikki ${title_count})" >&2
                fi
            fi
        elif [[ "$p_type" == movie || "$p_type" == doc ]] && (( title_count > 1 )); then
            local _mtn_lbl="elokuva"; [[ "$p_type" == doc ]] && _mtn_lbl="dokumentti"
            # Oletusraita jos ei vastata: pisin raita on lähes aina itse teos —
            # ekstrat/featurettet ovat tyypillisesti selvästi lyhyempiä.
            local _longest_t; _longest_t=$(printf '%s\n' "$scan_result" | awk -F'\t' '
                { split($2, h, ":"); s = h[1]*3600 + h[2]*60 + h[3]
                  if (s > max) { max = s; t = $1 } }
                END { print t }')
            # TURVALLISEMPI OLETUS MONILEVYISEN TEOKSEN 2.+ LEVYLLE (lisätty
            # 2026-08-20, käyttäjän havaitsema riski): jos SAMAN NIMISELTÄ
            # teokselta on JO AIEMMIN tässä sessiossa löytynyt oikea elokuvaraita
            # (_last_movie_name täsmää), tämä levy on todennäköisesti pelkkiä
            # ekstroja sisältävä bonuslevy — moni DVD-julkaisu jakaa elokuvan
            # levylle 1 ja bonusmateriaalin levylle 2+. Jos kukaan ei ehdi
            # vastata 180s:ssa, oletusarvo on TÄLLÖIN "0" (ei elokuvaa) eikä
            # "pisin raita" — koska väärä "ekstra merkitty elokuvaksi" on
            # pahempi ja hämmentävämpi lopputulos soittimessa kuin väärä
            # "elokuva merkitty ekstraksi" (jälkimmäinen säilyttää sisällön
            # tallessa, vain väärässä tiedostonimessä, korjattavissa jälkikäteen).
            local _default_t="$_longest_t" _default_hint="raita ${_longest_t}"
            local _is_continuation_disc=0
            if [[ -n "$_last_movie_name" && "$_last_movie_name" == "$p_name" ]]; then
                _is_continuation_disc=1
                _default_t="0"
                _default_hint="0 (ei elokuvaa — sama nimi kuin edellisellä levyllä, oletetaan bonuslevyksi)"
            fi
            local asked_movie=""
            # "0" = erikoisarvo: TÄLLÄ levyllä ei ole itse teosta lainkaan, vain
            # ekstroja (esim. erillinen bonuslevy). Kaikki raidat menevät silloin
            # ekstroiksi saman nimen alle, ei yritetä arvata mikä olisi "elokuva".
            read -rp "  Mikä raita on itse ${_mtn_lbl}? (Enter = pisin, raita ${_longest_t} / 0 = ei tällä levyllä, kaikki ekstroja) [180s → ${_default_hint}]: " -t 180 asked_movie </dev/tty || true
            local movie_title_num="$asked_movie"
            if [[ -z "$movie_title_num" ]]; then
                movie_title_num="$_default_t"
                (( _is_continuation_disc )) && [[ "$movie_title_num" == "0" ]] && \
                    log "  180s aikakatkaisu — sama nimi kuin edellisellä levyllä, oletetaan pelkkiä ekstroja (turvallisempi oletus)"
            elif [[ "$movie_title_num" == "0" ]]; then
                : # sellaisenaan — käsitellään erikseen alla ja encode_session():issa
            elif ! [[ "$movie_title_num" =~ ^[0-9]+$ ]] || \
                 ! printf '%s\n' "$scan_result" | cut -f1 | grep -qFx "$movie_title_num"; then
                echo "  Ei löydy tällaista raitaa: '${asked_movie}' — käytetään pisin (raita ${_longest_t})" >&2
                movie_title_num="$_longest_t"
            fi
            echo "MOVIE_TITLE_NUM=${movie_title_num}" >> "${raw_dir}/meta.conf"
            if [[ "$movie_title_num" == "0" ]]; then
                log "  Ei itse ${_mtn_lbl}ta tällä levyllä — kaikki ${title_count} raitaa ekstroiksi"
            else
                _last_movie_name="$p_name"
                log "  Itse ${_mtn_lbl}: raita ${movie_title_num} (${title_count} raitaa yhteensä)"
            fi
        fi

        log "Levy ${disc_num} ripattuna (${title_count} raitaa${p_max_ep:+, MAX_EPISODES=${p_max_ep}})."
        echo "TITLE_COUNT=${title_count}" >> "${raw_dir}/meta.conf"

        eject "$disc_dev" 2>/dev/null || true

        # Lasketaan mikä jaksonumero seuraavalla levyllä todennäköisesti
        # alkaa, jotta se voidaan tarjota valmiiksi ehdotuksena seuraavan
        # levyn tietoja kysyttäessä.
        if [[ "$p_type" == series ]] && (( title_count > 0 )); then
            local effective_count=$title_count
            if [[ -n "$p_max_ep" ]] && (( p_max_ep > 0 && p_max_ep < title_count )); then
                effective_count=$p_max_ep
            fi
            p_ep=$(( p_ep + effective_count ))
            p_max_ep=""  # Nollaa seuraavaa levyä varten
        fi

        # Heti kun tämä levy on kopioitu valmiiksi, käynnistetään sen muunnos
        # omaan tmux-istuntoonsa taustalle — käyttäjä voi jatkaa seuraavan
        # levyn syöttämistä välittömästi, muunnos ei estä sitä.
        local _enc_d_sname="enc-$(basename "$session_dir" | sed 's/session_//')-d$(printf '%03d' "$disc_num")"
        if tmux new-session -d -s "$_enc_d_sname" \
            "bash /usr/local/bin/rip-dvd.sh --encode-only '$session_dir'" 2>/dev/null; then
            printf '  Enkoodaus käynnistetty taustalle (levy %d).\n' "$disc_num"
            log "  Enkoodaussessio käynnistetty: $_enc_d_sname"
        fi
    done

    if (( disc_num == 0 )); then
        log "Ei levyjä ripattuna."
        _wait_enter
        exit 0
    fi

    printf '  %d levy/levyä ripattuna — enkoodaus käynnissä taustalla.\n' "$disc_num"
    local_gb=$(df "$OUTBASE" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    tera_gb=$(df "$DEST_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
    printf '  Levytilaa: brainbin %d GB vapaana, terastation %d GB vapaana\n' "$local_gb" "$tera_gb"
    sleep 1
    show_enc_status
    local enc_sname="enc-$(basename "$session_dir" | sed 's/session_//')-d$(printf '%03d' "$disc_num")"
    echo "  Seuraa: tmux attach -t $enc_sname"
    echo ""
    # HUOM: EI "Kaikki valmis!" — se harhaanjohtaisi juuri yllä näytetyn
    # enkoodausjonon (usein tunteja jäljellä) jälkeen. Vain TÄMÄ rippaus-
    # sessio (levyjen syöttäminen) on valmis, enkoodaus jatkuu taustalla.
    log "═══ Rippaus-sessio päättyy — enkoodaus jatkuu taustalla ═══"

    # Ilman tätä tmux-ikkuna (ja koko dvd-rip-sessio) sulkeutuu heti kun
    # main() palaa, ja yllä oleva raportti vilahtaa näytöllä näkymättömiin.
    _wait_enter
}

main "$@"
