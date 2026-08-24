# Tekstitys-audit 2026-08-24 — koko kirjaston koneellinen läpikäynti

**Menetelmä:** VobSub-tekstitysbugi (HandBrake 1.7.2:n off-by-one desync) on sisäänleivottu
enkoodaushetkellä ja riippuu HandBrake-versiosta. Korjattu HandBrake (lähdekoodista käännetty,
>1.9.2) asennettiin brainbinille **2026-08-19 08:56:18 UTC**. Skannattiin kaikki .mkv-tiedostot
`/mnt/terastation/dlna/vids`-puusta: jokaisen tekstitysraidat (`ffprobe`, dvd_subtitle) + tiedoston
muutosaika. Luokittelu tätä rajapäivää vasten.

**HUOM — tämä on HEURISTIIKKA, ei visuaalinen vahvistus:**
- `EPAILTY` = tehty ennen korjausta vanhalla HandBrakella → tekstitys TODENNÄKÖISESTI desyncissä,
  mutta ei katselulla vahvistettu. Osa saattaa mennä sattumalta oikein.
- `OK_UUSI` = tehty korjatun HandBraken jälkeen → tekstityksen PITÄISI olla kunnossa.
- Muutosaika ≈ enkoodausaika (skripti siirtää tiedoston heti enkoodauksen jälkeen), mutta
  jos tiedosto on kopioitu/kosketettu myöhemmin, luokitus voi olla harhaanjohtava.

**Validointipiste:** Woody Allen — Manhattan, Movies & Me, jonka käyttäjä vahvisti itse katsomalla
rikkinäiseksi, osui `EPAILTY`-listalle → heuristiikka tunnistaa oikein tunnetun rikkinäisen.

## Kokonaisluvut
- Skannattu: **1140 .mkv-tiedostoa**
- VobSub-tekstitys: **779**
- EPÄILLYT (ennen korjausta): **398**
- OK/uusi (korjauksen jälkeen): **381**

Täydet tiedostokohtaiset rivit: `tekstitys_audit_2026-08-24.tsv`
(sarakkeet: luokka, raitamäärä, muutospäivä, polku)

## EPÄILLYT ryhmiteltynä

### TV-sarjat (vahvistaa käyttäjän epäilyn: koko The Wire, ei vain S01)
| Sarja / kausi | jaksoja epäiltynä |
|---|---|
| Futurama S02 | 25 |
| Futurama S03 | 24 |
| Futurama S04 | 22 |
| Futurama S01 | 17 |
| The Wire S04 | 16 |
| The Wire S03 | 14 |
| The Wire S05 | 13 |
| The Wire S02 | 12 |
| The Wire S01 | 12 |
| Dempsey and Makepeace S01 | 10 |
| The Andromeda Strain S01 | 2 |

**HUOM Futuramasta:** aiemmin korjatuiksi merkityt Futurama S04 E15-E18 (4 jaksoa) pitäisi näkyä
OK_UUSI-puolella — tarkista tsv:stä ristiin, koska tässä S04:llä on 22 epäiltyä.

### Elokuvat (scifi-alikansio eritelty)
STAR TREK (kaikki 10 elokuvaa, osina): 67 · 2012: 12 · Futurama-elokuvat (Into the Wild Green
Yonder 11, Bender's Game 10, Beast With a Billion Backs 9, Bender's Big Score 1): 31 ·
Eräs rakkaus tarina: 11 · Barton Fink: 8 · E.T.: 7 · 2046: 7 · Circus: 6 · Aikakone: 6 ·
Darjeeling Limited: 5 · Contact: 4 · 12 apinaa: 4 · American Beauty: 3 · Tetsuo I+II: 6 ·
+ lukuisia 1-2 tiedoston teoksia (Departed, Infernal Affairs, Easy Rider, Cube², Brazil, Che I+II,
Dead Zone, Caveman's Valentine, Astronaut's Wife, Astronaut Farmer, Freejack, Fargo, Everything
You Always Wanted, Dark City, Cube, Big Lebowski, Being John Malkovich, Barfly, 99 frangia, 1984,
Stranded, Lipton Cockton).

### Dokumentit
Stanley Kubrick - Ohjaajan muotokuva · The Evolution of Gollum · Vincent van Gogh (+ Bonus Disc) ·
Whisky - The Islay Edition · **Woody Allen - Manhattan Movies & Me (vahvistettu rikki)**.

### Musiikki
Led Zeppelin (Immigrant Song 1972, Live at Royal Albert Hall 1970) · Patty Smith - Dream of Life ·
The Band - The Last Waltz · Weird Al Yankovic - Ultimate Video Collection.

## Mitä tästä seuraa
- Korjattavia (EPÄILTY) on ~398 tiedostoa — iso työ. Korjaus vaatii raakalähteen (VOB/VIDEO_TS)
  joko levyltä (asemaan) tai koneelta. Menetelmä: `extract_subs_fast.py` (ffmpeg VOB-kopiointi).
- Aiemmin "korjatuiksi" merkityt (District 9, Burn After Reading, Bender's Big Score, Futurama S04
  E15-18, 2046 Part01, Elämä on Pythonia) tulee näkyä OK_UUSI-puolella — jos jokin niistä on yhä
  EPAILTY-listalla, korjaus ei tarttunut. **Ristiintarkistus tsv:stä tekemättä vielä.**
- Tämä on heuristiikka: lopullinen varmuus per tiedosto vaatii katselun/OCR:n. Mutta tämä on
  ensimmäinen kerta kun koko kirjasto on käyty läpi yhdellä koneellisella ajolla.
