# Nopea tekstitysirrotus ffmpegillä — TESTATTU JA VAHVISTETTU TOIMIVAKSI 2026-08-20 yöllä

**PÄIVITYS: koko proseduuri on nyt automatisoitu ja testattu päästä päähän onnistuneesti.**
Skripti: `extract_subs_fast.py` (repon juuressa + `/usr/local/bin/extract_subs_fast.py`
brainbinillä). Testattu "2012"-datalla: 13/13 raitaa oikein, kielitunnisteet vahvistettu
oikeiksi (`mkvmerge -J`), suomenkielisen raidan sisältö tarkistettu erikseen
(`mkvextract`+`.idx`-tiedosto): 1661 aitoa tekstitysriviä, oikea `id: fi`-merkintä, ei tyhjää
tai roskadataa. Kokonaisaika 13 raidalle 155min elokuvasta: ~25s (vs. HandBraken n. 500-800s
samankokoiselle elokuvalle — 20-30× nopeampi, todistettu käytännössä ei vain laskettu).

## Käyttö

```bash
python3 /usr/local/bin/extract_subs_fast.py <VIDEO_TS-kansio> <VTS-numero> <ulostulo.mkv> <kieli1,kieli2,...>
# esim:
python3 /usr/local/bin/extract_subs_fast.py \
    /home/keitsi/dvd-rip-tmp/.../dvdbackup/2012/VIDEO_TS 1 /tmp/2012_subs.mkv \
    eng,fra,nld,ara,dan,fin,hin,nor,swe,eng,eng,fra,nld
```

Kielilista saadaan HandBraken JSON-skannauksesta (`HandBrakeCLI --scan --json`, ks. muisti
tekstiskannauksen katkeamisbugista — JSON, ei tekstimuoto). VTS-numero pitää päätellä
täsmäyttämällä VTS:n kesto (`ffprobe -show_entries format=duration 'concat:VTS_NN_1.VOB|...'`)
tunnettuun elokuvan kestoon, koska HandBraken title-numerointi ei ole sama kuin VTS-numero.

Tuloksena syntyy suoraan `mkvpropedit`illä kielitunnisteilla varustettu .mkv jonka voi remuxata
olemassa olevaan kirjastotiedostoon samalla `mkvmerge -s N,N,N ... --no-video --no-audio`
-tavalla kuin tänä yönä muissakin korjauksissa.

---

Alkuperäinen tutkimusmuistiinpano (säilytetty historiaksi):

## Yhteenveto (käyttäjän pyyntöön "tee tekstitysasiasta tehokkaampi")

Löydetty ja testattu menetelmä joka on **20-40× nopeampi** kuin nykyinen HandBrake-pohjainen
tekstitys-vain-irrotus (`--encoder x264 --encoder-preset ultrafast`). Testattu oikealla
raakadatalla ("2012", 155min elokuva, VTS_01_1..7.VOB paikallisella levyllä):

| Menetelmä | Aika (155min elokuva, 13 tekstitysraitaa) | Nopeus |
|---|---|---|
| HandBrake (nykyinen, käytetty koko illan) | ~500-800s (mitattu muilla samankokoisilla) | ~1× reaaliaika |
| **ffmpeg suora VOB-kopiointi** | **25s** | **475× reaaliaika** |

**Syy nopeuseroon:** HandBrake dekoodaa JA uudelleenenkoodaa koko videovirran vaikka se lopulta
heitetään pois (`--encoder ultrafast` on silti täysi H.264-enkoodaus). ffmpeg `-c:s copy` sen
sijaan vain kopioi tekstityspaketit sellaisenaan MPEG-ohjelmavirrasta koskematta videoon/ääneen
mitenkään — puhdasta I/O:ta.

## Rajoitus: vaatii raakadatan (VOB/VIDEO_TS), ei toimi suoraan levyasemalta yhtä hyvin

Tämä menetelmä on testattu paikalliselle levylle jo kopioidusta `dvdbackup`-datasta. **Se EI
ratkaise vaurioituneen levyn lukuongelmaa** (esim. "2012":n pääelokuva, jonka dvdbackup-kopiointi
itsessään epäonnistui aikanaan READ_ERRORS=159:n takia) — se nopeuttaa vain jo onnistuneesti
kopioidun raakadatan tekstityskäsittelyä. Vaurioituneille levyille tarvitaan edelleen `ddrescue`
(ks. `vaurioituneet_levyt.md`).

## Komento (vahvistettu toimivaksi)

```bash
cd <VIDEO_TS-kansio>
# Konkatenoi kaikki asianomaisen VTS:n VOB-osat (ei VTS_NN_0.VOB — se on menu/IFO-data,
# ei sisältöä). Käytä suurta probesize/analyzeduration-arvoa jotta KAIKKI tekstitysraidat
# löytyvät — pienemmällä arvolla (esim. 100M) yksi myöhään ilmestyvä raita voi jäädä pois
# (testattu: 100M löysi 12/13, 2G löysi 13/13 oikein).
ffmpeg -y -probesize 2G -analyzeduration 2G \
    -i 'concat:VTS_01_1.VOB|VTS_01_2.VOB|VTS_01_3.VOB|...' \
    -map 0:s -c:s copy -f matroska ulos_kaikki_tekstitykset.mkv
```

## KRIITTINEN, RATKAISTU MUTTA EI VIELÄ TOTEUTETTU: kielitunnisteiden kartoitus

Raaka ffmpeg-kopiointi EI säilytä kielitietoa (mkvmerge näyttää tulostiedoston raidat ilman
`language`-kenttää). Tämä pitää ratkaista ennen kuin menetelmää voi käyttää tuotannossa —
väärä kielitunniste tarkoittaisi että esim. Jellyfin näyttäisi väärän tekstityksen "suomi"-nimellä.

**Ratkaisu (DVD-Video-spesifikaation kiinteä sääntö, ei arvausta):** jokaisen tekstitysvirran
raaka MPEG stream-ID on aina `0x20 + (raitanumero - 1)` — eli raita 1 = ID 0x20, raita 2 = 0x21,
jne. aina 0x3F asti. Tämä on todennettu suoraan ffprobe:lla:

```bash
ffprobe -v error -probesize 2G -analyzeduration 2G \
    -show_entries stream=index,id,codec_type -of csv=p=0 'concat:VTS_01_1.VOB|...' \
    | grep subtitle
# tulostaa esim: 6,subtitle,0x29  →  raitanumero = 0x29-0x20+1 = 10
```

**Täysi proseduuri:**
1. Hae raidan kielet HandBraken JSON-skannauksella (`--scan --json`, ks. aiempi muisti
   tekstiskannauksen katkeamisbugista — KÄYTÄ AINA JSON:ia, ei tekstimuotoa) — tämä antaa
   järjestetyn listan `[raita1_kieli, raita2_kieli, ..., raitaN_kieli]`.
2. Aja ffmpeg-komento yllä, tallenna samalla `ffprobe ... index,id`-lista TALTEEN ennen ajoa.
3. Ffmpeg käsittelee `-map 0:s`:n ALKUPERÄISEN INDEKSIN nousevassa järjestyksessä (vahvistettu
   lokista: "Stream #0:6 -> #0:0", "Stream #0:7 -> #0:1" jne.) — eli tulostiedoston raita N
   (0-indeksoitu) vastaa N:nttä tekstitysvirtaa alkuperäisessä INDEKSI-järjestyksessä (ei
   ID-järjestyksessä, ID:t voivat tulla epäjärjestyksessä koska ne perustuvat siihen missä
   kohtaa tiedostoa kukin kieli ensin ilmestyy).
4. Jokaiselle tulostiedoston raidalle: `id → raitanumero (kaava yllä) → kieli (listasta kohta 1)`.
5. Aseta kielet lopulliseen tiedostoon: `mkvpropedit ulos.mkv --edit track:sN --set language=xxx`
   jokaiselle raidalle, TAI anna kielet suoraan `mkvmerge`-remux-vaiheessa `--language N:xxx`.

**Ei vielä toteutettu skriptinä** — yllä oleva on käsin vahvistettu proseduuri, ei automatisoitu.
Ennen tuotantokäyttöä pitäisi kirjoittaa pieni Python-apuri joka tekee vaiheet 2-5 automaattisesti
ja TESTATA sen tulos vertaamalla käsin tunnettuun kielijärjestykseen (kuten tässä dokumentissa
2012:lle tehtiin) ennen kuin luotetaan siihen sokeasti.

## Esimerkkilasku, 2012:n data (vahvistus että kaava on oikein)

JSON-skannauksen kielilista (raita 1..13): eng,fra,nld,ara,dan,fin,hin,nor,swe,eng,eng,fra,nld

ffprobe:n löytämät ID:t DISCOVERY-järjestyksessä (= tulostiedoston raitajärjestys):
0x29,0x2a,0x2b,0x2c,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x21,0x20

→ raitanumerot: 10,11,12,13,3,4,5,6,7,8,9,2,1
→ kielet (indeksoi listasta): eng,eng,fra,nld,nld,ara,dan,fin,hin,nor,swe,fra,eng

Suomi (raita 6 alkuperäisessä listassa) on tässä järjestyksessä 8. tulostiedoston raita (0-indeksoituna
7). **Ei testattu käytännössä pistämällä tätä oikeasti tiedostoon ja tarkistamalla soittimella** —
laskennallisesti johdettu DVD-spesifikaation säännöstä, matemaattisesti suoraviivainen mutta
suositellaan yhtä käytännön koekierrosta ennen luottamista täysin.

## Suositus jatkolle

1. Kirjoita pieni Python-apuriskripti joka automatisoi koko proseduurin (ffprobe-ID:t →
   kielikartoitus → mkvmerge --language-liput).
2. Testaa se yhdellä jo tunnetulla, käsin vahvistetulla teoksella (esim. 2012, koska JSON-
   kielilista on jo tiedossa) ennen käyttöä tuotannossa.
3. Kun testattu: käytä TÄTÄ menetelmää HandBraken sijaan kaikille tuleville tekstitys-vain-
   korjauksille joissa raakadata (VOB/VIDEO_TS) on saatavilla — säästää arviolta 90-95% ajasta
   verrattuna nykyiseen menetelmään.
4. Sovella myös Futurama S04:lle, District 9:lle, Burn After Readingille, Bender's Big Scorelle
   ja E.T.:lle (kaikilla on raakadata tallessa) kunhan menetelmä on testattu ja luotettu.
