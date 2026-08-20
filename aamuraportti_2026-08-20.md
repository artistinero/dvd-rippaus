# Aamuraportti 2026-08-20 — yön tutkimustyö

## 1. Tekstitysten tehokkuus — RATKAISTU JA TESTATTU

Etsittiin ja löydettiin menetelmä joka on **20-40× nopeampi** kuin eilen käytetty HandBrake-
pohjainen tekstitys-vain-irrotus. Yksityiskohdat: `tekstitys_ffmpeg_menetelma.md`.

**Lyhyesti:** ffmpeg kopioi kaikki tekstitysraidat suoraan raa'asta VOB-datasta ilman videon
dekoodausta/enkoodausta (`-c:s copy`) — 155min elokuvan 13 tekstitysraitaa vietiin 25 sekunnissa
(HandBrake: n. 500-800s samankokoiselle elokuvalle). Kielitunnisteiden kartoitus ratkaistiin
DVD-spesifikaation kiinteällä säännöllä (tekstitysvirran ID 0x20+N-1 = raita N), ei arvausta.

**Testattu päästä päähän, ei vain teoretisoitu:** ajettiin oikealla "2012"-datalla, tarkistettiin
raitamäärä (13/13 oikein), kielitunnisteet (`mkvmerge -J`, kaikki täsmäsivät), ja yhden raidan
(suomi) todellinen sisältö (`mkvextract`, 1661 aitoa tekstitysriviä, oikea `id: fi`).

**Käyttövalmis skripti:** `extract_subs_fast.py` (repossa + `/usr/local/bin/`). Käyttö:
```
python3 extract_subs_fast.py <VIDEO_TS-kansio> <VTS-numero> <ulos.mkv> <kieli1,kieli2,...>
```

**Suositus:** käytä tätä HandBraken sijaan kaikille jatkossa tehtäville tekstitys-vain-
korjauksille joissa raakadata on saatavilla (E.T., District 9, Burn After Reading, Bender's Big
Score, Futurama S04 — kaikilla raakadata tallessa). Säästää arviolta 90-95% ajasta per levy.

## 2. Vaurioituneet levyt — menetelmä löydetty, ei vielä testattu käytännössä

`vaurioituneet_levyt.md`: `ddrescue` (jo asennettu, GNU-käsikirjasta vahvistettu syntaksi)
kopioi vaurioituneen levyn sinnikkäästi ISO-tiedostoksi karttatiedoston (mapfile) avulla —
voi keskeyttää ja jatkaa myöhemmin, ei lue jo onnistuneesti luettua dataa uudelleen. HandBrake
tukee ISO-tiedostoa syötteenä suoraan (purkaa CSS-salauksen automaattisesti). Tätä EI ehditty
testata oikealla vaurioituneella levyllä (2012, American Beauty) tänä yönä — molemmat olivat
poissa asemasta tutkimushetkellä. **Seuraava askel: kokeile tätä kun jompikumpi levy on
saatavilla.**

## 3. rip-dvd.sh — yksi todellinen bugi löydetty ja korjattu

Kolme `HandBrakeCLI --scan`-kutsua skriptissä eivät olleet aikakatkaistuja — tämä selitti
täsmälleen eilisillan American Beauty -jumiutumisen (skannaus jäi loputtomasti yrittämään).
Lisätty `SCAN_TIMEOUT=180` + `timeout`-komento kaikkiin kolmeen kutsuun (`_get_crop_args`,
`hb_scan_long_titles`, päärippaussilmukka). Vahvistettu turvalliseksi: kaikki kutsupaikat
käsittelivät jo entuudestaan tyhjän/osittaisen skannaustuloksen oikein. Deployattu ja committoitu.

**Tarkistettu ja todettu jo TOIMIVaksi (ei bugi):** "Mikä raita on itse elokuva" -kysymyksellä
ON jo 180s aikakatkaisu joka oletusarvoisesti valitsee pisimmän raidan (rivi 2154, `-t 180`).
Vahvistettu illan lokin aikaleimoista: joka kerta kysymys ratkesi 2-3 minuutissa oikein.

## 4. Yön aikana tehdyt tekstityskorjaukset (levy kerrallaan, aakkosjärjestyksessä)

| Teos | Tila |
|---|---|
| 99 frangia | ✅ Valmis |
| 101 Reykjavik | ✅ Valmis |
| 2001: Avaruusseikkailu | ✅ Valmis (uudelleentehty kerran, ks. kohta 6) |
| 2010: The Year We Make Contact | ✅ Valmis |
| 2012 | ⏸️ Siirretty — pääelokuva ei ole koskaan onnistunut kopioitumaan (aito lukuvirhe), ekstrat deduplikoitu mutta ei tekstityskorjattu |
| 2046 | ⏸️ Vain Part01 valmis, Part02-09 (8 ekstraa) jäi kesken (levy vaihdettu liian aikaisin) |
| Amarcord | ✅ Valmis, pieni huomio: 5,4s kestoero, ei tutkittu tarkemmin |
| American Beauty | ⏸️ Ei päästy edes aloittamaan — skannaus jumiutui (nyt korjattu skriptiin, mutta itse levyn lukuongelma vaatii vielä ddrescue-yrityksen) |
| Arthur's Dyke | ✅ Valmis |
| Elämä on Pythonia | ✅ Valmis, käyttäjän itse vahvistama |
| Broken Flowers, Blues Brothers, Blues Brothers 2000 | ✅ Pääelokuvat valmiit (olivat aiemmin kokonaan puuttuvia, nyt enkoodattu). Osa ekstroista epäonnistui aidosta levyvauriosta. |

Lisäksi Wire S01E01:n yläreunan crop-häiriö korjattu ja vahvistettu (6 muuta samaa häiriötä
sisältävää tiedostoa — Wire S01E11, 2046 Part04, Eräs rakkaus tarina Part06, Star Trek Wrath
of Khan Part02, 2 musiikkielokuvaa — odottavat vielä).

## 5. Yön aikana ripatut uudet levyt (rip-dvd.sh, oma putkensa)

Apocalypse Now Redux, Goodbye Lenin!, Gandhi, Inside Deep Throat — kaikki neljä ripattu
onnistuneesti, enkoodaus käynnissä/jonossa taustalla tätä kirjoittaessa.

## 6. Rehellisesti kirjatut virheet/epävarmuudet yön ajalta

- **2001: Avaruusseikkailu jouduttiin tekemään kahdesti** — ensimmäisellä kerralla käytin
  tekstimuotoista `--scan`-tulostetta joka katkeaa 10 raitaan (todellinen määrä oli 11).
  Löydettiin JSON-skannauksesta, korjattiin. **Opetus siirretty pysyvään käytäntöön: käytä
  AINA `--scan --json`, ei koskaan tekstimuotoa raitamäärän laskentaan.**
- **2046:n laajuus aliarvioitiin** — rajasin oman tarkistukseni `head`-komennolla ja näin
  vain 3 ensimmäistä osaa, vaikka kirjastossa oli 9. Levy ehdittiin vaihtaa ennen kuin huomasin.
- **Cube, Caveman's Valentine, Futurama S02/S03:n duplikaattisiivous** aamulla perustui
  heikompaan todisteeseen (vain kestovertailu) kuin muut vastaavat korjaukset — ei voida enää
  tarkistaa jälkikäteen koska tiedostot on jo poistettu.
- **"2012"-arvoituksen alkuperäinen syy** (mikä käynnisti ~80 duplikaattitiedoston synnyn
  eilisaamuna) jäi koskaan selvittämättä.

## 7. Tarkistettava kun palaat

1. Onko American Beauty tai 2012 fyysisesti saatavilla `ddrescue`-testiä varten?
2. Hyväksytkö `extract_subs_fast.py`-menetelmän käyttöönoton lopuille raakadatallisille
   levyille (E.T., District 9, Burn After Reading, Bender's Big Score, Futurama S04)?
3. 2046:n loput 8 ekstraa ja American Beauty vaativat levyn takaisin asemaan.
