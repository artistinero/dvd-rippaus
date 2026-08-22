# Vaurioituneiden/vaikeasti luettavien levyjen palautusproseduuri

Tutkittu ja vahvistettu yönä 2026-08-19/20, primäärilähteistä (GNU ddrescue -käsikirja
`man ddrescue` brainbinillä, HandBraken oma dokumentaatio ISO-tuesta). Tarkoitettu tapauksiin
kuten "2012" (pääelokuva epäonnistuu heti, READ_ERRORS=159) ja American Beauty (skannaus jumiutuu
toistuvasti samaan kohtaan) — levyjä joita nykyinen suora `dvdbackup`/`HandBrakeCLI --input /dev/srN`
-lähestymistapa ei saa luettua, vaikka levy ei ole dmesg:n mukaan täysin lukukelvoton.

## Miksi tämä voisi auttaa kun suora luku ei toiminut

- `dvdbackup`/`HandBrakeCLI` tekevät yhden lukuyrityksen ja luovuttavat virheen kohdalla (tai
  HandBraken tapauksessa: skannaus voi jäädä loputtomasti yrittämään ilman aikakatkaisua,
  havaittu American Beautyllä tänä iltana).
- `ddrescue` on suunniteltu nimenomaan tähän: se yrittää lukea hyvät alueet ensin, merkitsee
  huonot alueet karttatiedostoon (mapfile), ja voi yrittää huonoja alueita uudelleen määrätyn
  (tai rajattoman) määrän kertoja — TALLENTAEN edistymisen niin että työn voi keskeyttää ja
  jatkaa myöhemmin ilman että jo onnistuneesti luettu data luetaan uudelleen.
- HandBrake tukee ISO-tiedostoa syötteenä täysin samalla tavalla kuin elävää levyä tai
  VIDEO_TS-kansiota, ja purkaa CSS-salauksen automaattisesti `libdvdcss`:llä (jo asennettuna
  brainbinille) — ei siis tarvita erillistä purkuvaihetta ddrescue-kuvan jälkeen.

## Komennot (vahvistettu `man ddrescue`:sta, DVD-sektorikoko 2048 tavua)

```bash
# 1. Kopioi raaka levykuva sinnikkäästi, tallenna edistyminen mapfileen.
#    -r 3 = yritä huonoja sektoreita 3 kertaa lisää (perusarvoa laajemmin voi käyttää -r -1
#    = rajattomasti, mutta se voi juuttua ikuisesti — 3 on järkevä ensimmäinen yritys).
#    -v = näytä eteneminen.
ddrescue -b 2048 -r 3 -v /dev/sr1 /home/keitsi/dvd-rip-tmp/levy.iso /home/keitsi/dvd-rip-tmp/levy.mapfile

# Jos ensimmäinen ajo jättää huonoja alueita jäljelle, voi ajaa saman komennon UUDELLEEN
# (sama mapfile) — ddrescue lukee VAIN vielä lukemattomat/epäonnistuneet alueet, ei koko
# levyä uudelleen. Voi myös nostaa -r-arvoa tai vaihtaa levyasemaa jos toinen on saatavilla
# (käsikirja suosittelee: eri asemat lukevat eri kohtia eri tavalla onnistuneesti).

# 2. Kun kuva on valmis (tai niin valmis kuin saadaan), käytä sitä suoraan HandBraken syötteenä:
HandBrakeCLI --input /home/keitsi/dvd-rip-tmp/levy.iso --title 0 --scan
# ... ja jatka normaalisti kuten minkä tahansa muun lähteen kanssa.
```

## Milloin käyttää

Vasta KUN suora `dvdbackup`/`HandBrakeCLI --input /dev/srN` -yritys epäonnistuu tai jumiutuu —
tämä on hitaampi ja monimutkaisempi reitti, ei oletustapa. Sopii erityisesti:
- "2012" (READ_ERRORS=159, pääelokuva epäonnistuu heti 0,57s kohdalla)
- American Beauty (skannaus jumiutuu tittelin 1 esikatselussa)
- **Asterix and the Vikings (2006)** — lisätty 2026-08-22. `dvdbackup` jäi taistelemaan samaa
  viallista kohtaa vastaan (`Error reading VTS_01_1.VOB at block 629`) niin pitkään että
  kopioitu määrä paisui 22,19 GB:hen (levyn oikea sisältö ~7,9GB, DVD-9/kaksikerroksinen, kaksi
  title setiä VTS_01+VTS_02) ennen kuin `RIP_TIMEOUT` (2h) katkaisi sen väkisin. `dmesg`
  vahvisti aidon fyysisen vaurion: toistuvia "critical medium error"/"L-EC uncorrectable error"
  -merkintöjä sektoreilla n. 809960, 815528, 101941-101943 (klo 21:54-21:55). Koko keskeneräinen
  data siivottiin automaattisesti pois epäonnistumisen jälkeen (ei jäänyt mitään talteen) —
  vaatii levyn uudelleen asemaan ja täyden `ddrescue`-yrityksen tästä alusta.
- Muut tulevat samantyyppiset tapaukset

## LÖYDETTY VAKAVA RAJOITUS 2026-08-22: ddrescue ei toimi salatuille DVD-levyille sellaisenaan

Testattiin ensimmäistä kertaa oikeasti käytännössä (Asterix and the Vikings, 2026-08-22).
`ddrescue` lukee raakoja 2048-tavun sektoreita suoraan `/dev/sr1`:stä OHITTAEN normaalin CSS-
todennuksen jota `dvdbackup`/`libdvdcss` käyttävät. Tulos: valtaosa lukuyrityksistä epäonnistui
virheeseen **"Illegal Request: Read of scrambled sector without authentication"** — TÄMÄ ON ERI
VIRHE kuin aiemmin dmesg:llä vahvistettu fyysinen vaurio ("critical medium error"/"L-EC
uncorrectable"), ja se ilmeni jo levyn alkupäässä (sektori ~88960), ei vain tunnetulla
vaurioalueella. Trendi: 46 lukuvirhettä 26s kohdalla → 205 virhettä 1min27s kohdalla, "rescued"
(oikeasti pelastettu data) vain 35MB/447MB käydystä — valtaosa sektoreista palautui "scrambled"-
tilassa, ei käyttökelpoisena datana. Arvioitu kokonaisaika paisui 1h39min:stä 9h29min:iin.
Pysäytetty ja siivottu (ei jätetty osittaista tiedostoa).

**Johtopäätös: tämän dokumentin `ddrescue`-proseduuri EI SELLAISENAAN toimi salatuille
kaupallisille DVD-levyille** — vaatisi CSS-avainten esineuvottelun (esim. `libdvdcss`:n kautta)
ennen raakalukua, mitä ei ole toteutettu eikä tutkittu. Ei tiedetä onko tämä ylipäätään
ratkaistavissa `ddrescue`:lla vai vaatiiko täysin eri työkalun. **Asterix and the Vikings on
edelleen ratkaisematta** — ainoat jäljellä olevat vaihtoehdot ovat toinen fyysinen kappale tai
luovuttaminen, ellei parempaa CSS-yhteensopivaa palautustyökalua löydy.

## EI VIELÄ TEHTY

- Ei testattu käytännössä oikealla vaurioituneella levyllä tänä yönä (kumpikaan tunnetuista
  ongelmalevyistä — 2012, American Beauty — ei ollut asemassa tutkimushetkellä).
- Ei integroitu `rip-dvd.sh`:hen automaattisesti — tietoisesti jätetty käyttäjän päätettäväksi,
  koska tuotantoskriptin muuttaminen valvomatta yön yli olisi riski.
- Levytilavaatimus: koko levyn raakakuva (n. 4,7-8,5GB single/dual-layer) — varmista tilaa ennen
  käyttöä `df -h /home/keitsi/dvd-rip-tmp`.
