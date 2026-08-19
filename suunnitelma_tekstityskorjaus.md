# Tekstitysbugin koko kirjaston korjaussuunnitelma

## Konteksti

Juurisyy on nyt vahvistettu ja korjaus todistettu toimivaksi (Elämä on Pythonia, käyttäjän oma
VNC-tarkistus): brainbinillä oli apt:n HandBrakeCLI 1.7.2, jossa on tunnettu VobSub-tekstitysbugi
(HandBraken oma GitHub-keskustelu #6740), korjattu versiossa 1.9.2. Korjattu HandBrake on käännetty
lähdekoodista ja asennettu tuotantoon (`/usr/local/bin/HandBrakeCLI`). Bugi ei riipu teoksen
pituudesta — se koskee periaatteessa mitä tahansa DVD:tä jolla on VobSub-tekstitys, koska vanha
HandBrake on ollut käytössä koko n. 2,5kk projektin ajan.

Juuri äsken skannattu koko kirjasto (`mkvmerge -J`, luetaan container-metadata, ei arvattu):
**425/706 .mkv-tiedostoa sisältää VobSub-tekstityksen** (381 pääteosta/jaksoa, 44 ekstraa). Tämä on
todellinen laajuus — paljon suurempi kuin vanhan `subtitle_tracker.csv`:n 54 kohteen lista (joka
perustui virheelliseen ">75min"-oletukseen). Tarkistuslista pitää rakentaa uudelleen oikean datan
päälle.

Tavoite: käyttäjä halusi mahdollisimman vähän interaktiota — syöttää levyjä, minä teen lopun.
Tämä suunnitelma kuvaa miten 425 tiedosto käydään läpi järjestelmällisesti, miten edistymistä
seurataan, ja mitä käyttäjältä oikeasti tarvitaan (vain fyysinen levy niille joilla ei ole
raakalähdettä tallessa).

## Kaksi korjaustapaa (jo validoitu tässä istunnossa)

1. **Täysi uudelleenenkoodaus** (käytetty: Elämä on Pythonia) — kun koko tiedosto pitää joka
   tapauksessa tehdä uudelleen tai video/ääni on epäselvä. Hidas (~1-1,5h/teos).
2. **Tekstitys-vain irrotus + remux** (käytetty: Dante 01) — kun video/ääni on jo kunnossa
   kirjastossa. `HandBrakeCLI --subtitle N --encoder x264 --encoder-preset ultrafast` (nopea,
   video hylätään) → `mkvmerge -o final.mkv --no-subtitles vanha.mkv -s N --no-video --no-audio
   uusi_teksti.mkv`. Nopea (minuutteja/teos), ei kosketa videolaatua. **Oletustapa jatkossa**,
   paitsi jos raakalähteen rakenne on epäselvä (ks. E.T.-tapaus alla).

## Käyttäjän korjaukset suunnitelmaan

- **Ei erillistä "pääteokset ensin, ekstrat myöhemmin" -jakoa.** Kun levy on kerran asemassa,
  KAIKKI sillä oleva (pääteos + ekstrat) korjataan samalla kertaa — järkevää, koska levyä ei
  haluta laittaa asemaan kahdesti. Käsittelyn perusyksikkö on siis LEVY/SESSIO, ei yksittäinen
  tiedosto.
- **Järjestys: aakkosjärjestys teoksen nimen mukaan**, ei raakalähteen saatavuuden mukaan.
- **Ensimmäinen: 99 frangia — levy on jo asemassa nyt.** Aloitetaan siitä heti suunnitelman
  hyväksynnän jälkeen.
- **Verifiointi:** käyttäjä joutuu joka tapauksessa vaihtamaan levyjä käsin, joten hän "vilkaisee
  välillä" luonnostaan — ei vaadita erillistä pysäytys+vahvistus-askelta jokaiselle teokselle.
  Rakenteellinen tarkistus (raidat/kesto) riittää oletukseksi jokaiselle korjaukselle.

## Vaihe 1: Rakenna uusi, oikea seurantataulukko

Korvaa `subtitle_tracker.csv` uudella, joka kattaa kaikki 425 VobSub-tiedostoa (ei vain >75min).
Sarakkeet: `tiedostopolku, kesto_min, kielet, tila (TARKISTAMATON/RIKKI/KORJATTU/EI_TARVETTA),
raakalähde_tallessa (K/E), raakalähteen_polku, huomiot`. `EI_TARVETTA` varataan ekstroille joissa
korjaus ei ole prioriteetti (voi jättää myöhemmäksi).

## Vaihe 2: Kategorisoi jokainen raakalähteen saatavuuden mukaan

Jo tiedossa 11 levyä joilla raakalähde on tallessa (ks. `session_2026-08-19_loki.md`) — 6 näistä
jo käsitelty tänään (Pythonia, Broken Flowers, Blues Brothers, Blues Brothers 2000, Dante 01,
+ E.T. todettu ongelmalliseksi). Loput ~4 (Burn After Reading, Futurama S04, District 9,
Bender's Big Score) + kaikki muut 425:stä joilla EI ole raakalähdettä = vaativat fyysisen levyn.

**Ennen jokaista raakalähteestä tehtävää korjausta:** tarkista että skannattu titteli/kesto
täsmää kirjaston nykyisen tiedoston kestoon (kuten E.T.:n kohdalla tehtiin — siellä ei täsmännyt,
ei jatkettu). Jos ei täsmää, merkitse `TARKISTAMATON` + huomio, älä arvaa.

## Vaihe 3: Käsittele raakalähteelliset tapaukset nyt (ei vaadi käyttäjää)

Jatka tästä istunnosta kesken jäänyttä työtä: Futurama S04 (4 jaksoa, selvä täsmäys), sitten
Burn After Reading / District 9 / Bender's Big Score (moniosaisia — pitää ensin selvittää
titteli↔osa-vastaavuus kestojen perusteella ennen korjausta, ei arvata).

## Vaihe 4: Matala kitka -protokolla fyysisille levyille

Käsittelyn perusyksikkö on LEVY, ei yksittäinen tiedosto — kaikki levyllä oleva (pääteos + kaikki
ekstrat) korjataan samalla kertaa kun levy on asemassa. Aakkosjärjestys teosnimen mukaan.

Kun käyttäjä laittaa levyn asemaan ja sanoo niin:
1. Skannaan `/dev/sr1`/`/dev/sr0` automaattisesti, tunnistan levyn (nimi/kesto) ja vertaan tracker-
   taulukkoon löytääkseni sitä vastaavat rivit (pääteos + kaikki sen ekstrat).
2. Jos täsmää selvästi: korjaan KAIKKI kyseisen levyn VobSub-tekstitykselliset tiedostot
   (tekstitys-vain irrotus+remux jos video/ääni jo kirjastossa, muuten täysi enkoodaus),
   verifioin rakenteellisesti (raidat, kesto), korvaan, päivitän trackerin.
3. Jos ei täsmää selvästi: kysyn TÄSMÄLLISEN yhden kysymyksen sen sijaan että arvaan.
4. Kerron lyhyen yhteenvedon koko levystä (ei per-tiedosto-raportointia) ja pyydän seuraavaa
   levyä. Käyttäjä voi syöttää useita peräkkäin, vilkaisten välillä miten meni.

**Ensimmäinen levy: 99 frangia — jo asemassa, aloitetaan heti suunnitelman hyväksynnän jälkeen.**

## Vaihe 5: Seuranta ja lokitus

- **`subtitle_tracker.csv`** — pysyvä, elävä tilataulukko (päivitetään jokaisen korjauksen
  jälkeen, committoidaan).
- **`session_YYYY-MM-DD_loki.md`** — päiväkohtainen työloki (mitä tehtiin, miksi, mikä jäi kesken,
  samaan tapaan kuin tänään). Uusi tiedosto joka työpäivälle.
- Jokaisen merkittävän erän (esim. jokaisen korjatun teoksen tai levyn) jälkeen: git commit + push,
  Jellyfin-kirjaston päivitys.
- Ei vaadita käyttäjän manuaalista tarkistusta jokaiselle korjatulle teokselle — korjaus
  luotetaan oletuksena (juurisyy + mekanismi + yksi empiirinen vahvistus jo tehty), mutta
  poikkeavat/epäselvät tapaukset (kuten E.T.) merkitään selvästi ja käyttäjä voi halutessaan
  pistokoetarkistaa.

## Avoimet kysymykset — RATKAISTU

- ~~Ekstrojen prioriteetti~~ → käsitellään levyn mukana, ei erillisenä eränä.
- ~~Verifiointitapa~~ → rakenteellinen tarkistus riittää, käyttäjä pistokoetarkistaa luonnostaan
  levyjä vaihtaessaan.
