# dvd-rippaus

## Tavoite

Ripata oma DVD-kokoelma MKV-tiedostoiksi Jellyfin-mediapalvelimelle terastationille.
Kaikki ajo tapahtuu brainbin-koneella. Käyttäjä ottaa SSH:lla yhteyden, käynnistää
skriptin, syöttää levyjä ajuriin ja voi sen jälkeen sulkea läppärin — prosessit
pyörivät tmux-sessioissa brainbinillä eivätkä riipu SSH-yhteydestä.

## Työkalu: `rip-dvd.sh`

```
rip-dvd.sh                                        Normaali rippaus + enkoodaus
rip-dvd.sh --encode-only <hakemisto>               Enkoodaa olemassaoleva sessio uudelleen
rip-dvd.sh --skip   <hakemisto> "<tiedostonimi>"   Luovu raidasta pysyvästi (peruttavissa)
rip-dvd.sh --unskip <hakemisto> "<tiedostonimi>"   Peru luovutus, yritä uudelleen
rip-dvd.sh --help                                  Ohje
```

Sijainnit: paikallinen repo `rip-dvd.sh` ↔ brainbin `/usr/local/bin/rip-dvd.sh` —
pidetään aina synkassa (scp + sudo cp), commitoidaan ja pushataan joka muutoksen jälkeen.

## Miksi dvdbackup eikä MakeMKV

MakeMKV jää loputtomaan silmukkaan aluekoodittomilla/RPC2-asemilla. `dvdbackup` +
`libdvdcss2` toimii aina — libdvdcss2 murtaa CSS-avaimet matemaattisesti eikä
välitä aluekoodeista. MakeMKV on poistettu kokonaan käytöstä.

## Pipeline

1. **dvdbackup** kopioi DVD:n VIDEO_TS-rakenteen paikalliseen väliaikaishakemistoon
   (`~/dvd-rip-tmp/session_YYYYMMDD_HHMMSS/disc-NNN/dvdbackup/`)
2. **HandBrakeCLI** enkoodaa x265 CRF 21, kaikki ääniraidat (copy/AAC-fallback) ja
   tekstitykset mukaan
3. Siirto terastationille: `/mnt/terastation/dlna/vids/{series,movies,documentaries,music}/`
4. Lähdekansio poistetaan vasta kun KAIKKI levyn raidat on varmistettu terastationilla

Enkoodaus käynnistyy automaattisesti jokaisen ripatun levyn jälkeen (oma tmux-sessio
per levy, `flock`-lukko varmistaa ettei kaksi HandBrake-prosessia pyöri yhtä aikaa —
kriittistä ylikuumenemisen estämiseksi).

## Asemat brainbinillä

`/dev/sr0` = sisäinen, **fyysisesti rikki, ei käytetä**. `/dev/sr1` = ulkoinen
FREECOM_ USB-asema, ainoa toimiva.

## Tunnetut, pysyvästi menetetyt raidat

Levyvaurio (`critical medium error` / `L-EC uncorrectable error` dmesg:ssä, ei
korjattavissa ohjelmallisesti kohtuullisessa ajassa):

| Teos | Puuttuu | Levy |
|---|---|---|
| Futurama S03 | E04, E05, Extra 06 | Disc 1, `READ_ERRORS=717` |
| Futurama S03 | E21, E22 | Disc 4 (fyysinen), laaja ddrescue-yritys epäonnistui |
| Futurama - Bender's Big Score | **koko elokuva** (85 min, muu levyn sisältö on tallessa) | 158× medium error, jätetty toistaiseksi sivuun `--skip`illä |

Kaikki muut tähän mennessä ripatut sarjat/elokuvat/musiikkitallenteet ovat
täydellisinä terastationilla.

## `--skip`/`--unskip`: raidan valikoiva luovutus

Jos yksittäinen raita epäonnistuu toistuvasti eikä sitä kannata yrittää enää,
`--skip` merkitsee sen pysyvästi ohitetuksi (`.skip-titles`-tiedosto sessiossa)
ilman että lähde-VOB poistetaan. Skripti lakkaa kysymästä samasta raidasta
uudelleen, mutta muut saman levyn/session raidat käsitellään normaalisti.
Peruttavissa milloin tahansa `--unskip`illä.

**Diagnoosi ennen luovutusta:** tarkista aina `journalctl -k` (tai `dmesg -T`)
kyseisen levyn tarkkaan rippausikkunaan (`meta.conf`:in aikaleima) ennen
päätöstä yrittää uudelleen tai luovuttaa — osa epäonnistumisista (esim. rc=2
"ei löydettyä titteliä", rc=139 "muistivirhe") ei liity levyvaurioon lainkaan
ja korjautuu suoralla uusintayrityksellä. Vain aidosti toistuva
`critical medium error` -kuvio samalla sektorialueella on oikea peruste
luovuttaa.

## Terastationin hakemistorakenne

```
/mnt/terastation/dlna/vids/
├── movies/          elokuvat (+ scifi/, silent/ alakansiot)
├── series/          sarjat (+ cartoons/ alakansio)
├── documentaries/   dokumentit (+ propaganda/, docventures/ alakansiot)
├── music/           konserttitallenteet ja musiikkivideot
└── originals/       käyttäjän omat tuotannot
```

## Jellyfin

Ekstrat nimetään Jellyfinin omalla `-extra`-päätteellä (esim.
`Sarja S01 Extra 01-extra.mkv`) — ilman sitä Jellyfin tulkitsee numeron
jaksonumeroksi ja peittää oikean jakson tai luo duplikaatin.

## Tarkempi historia

Yksityiskohtainen aikajana korjatuista bugeista, tehdyistä päätöksistä ja
yksittäisten levyjen palautusyrityksistä on Claude Coden projektikohtaisessa
muistissa, ei tässä tiedostossa.
