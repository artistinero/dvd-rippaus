# Työloki 2026-08-19

## Vahvistetut, todistetut löydökset

1. **Tekstitysbugin juurisyy löydetty ja KORJATTU.** brainbinillä oli HandBrakeCLI 1.7.2 (apt:n ainoa
   tarjolla ollut versio). HandBraken oma GitHub-keskustelu #6740 vahvistaa tunnetun VobSub-bugin
   (ensimmäinen tekstitysrivi putoaa, loput näkyvät edellisen rivin ajastuksessa), korjattu versiossa
   1.9.2. `--no-dvdnav`-teoria (2026-08-18) todistettu vääräksi käyttäjän omalla testillä.
   - HandBrake käännetty lähdekoodista (`/home/keitsi/HandBrake-src/build/HandBrakeCLI`,
     versio `20260816074532-d43e68f-master`, reilusti yli 1.9.2:n).
   - **Asennettu tuotantoon:** `/usr/local/bin/HandBrakeCLI` (PATH-etusija apt:n `/usr/bin/HandBrakeCLI`:n
     edellä, apt-pakettia ei koskettu).
   - **Empiirisesti vahvistettu korjatuksi:** käyttäjä katsoi VNC-playerillä Elämä on Pythonia
     -uudelleenenkoodauksen (`/dev/sr1` suoraan, molemmat suomiraidat) — tekstitys menee kohdilleen.

2. **Yläreunan kuvahäiriö (The Wire ym.) korjattu skriptiin, EI vielä olemassa oleviin tiedostoihin.**
   Mitattu pikseliarvoista: rivit 0-3 häiriöisiä, HandBraken `--crop-mode auto` ei tunnista niitä koska
   eivät ole tarpeeksi tummia. **Koskee vain TULEVIA rippauksia.** Olemassa olevien tiedostojen korjaus
   ei vaadi levyn uudelleenrippausta (vain crop+re-enkoodaus jo olemassa olevasta MKV:stä) — laajuutta
   ei ole vielä mitattu.
   - **Ensimmäinen versio (committi `99ef8a0`) oli VIRHEELLINEN:** pakotti min. 6px ylärajauksen
     SOKEASTI kaikille levyille joiden automaattitunnistus antoi vähemmän, tarkistamatta oliko
     häiriötä oikeasti olemassa. Tämä olisi leikannut oikeaa kuvasisältöä levyiltä joilla ei ole
     mitään vikaa. Käyttäjä huomautti tästä aiheellisesti ja välittömästi kun näki sen käytössä
     livenä (Broken Flowers -enkoodauksessa).
   - **Korjattu (committi seuraava tämän lokin jälkeen):** lisätty `_detect_top_artifact()` joka
     ottaa esikatselukehyksen ja MITTAA pikselikirkkauden ennen minkään pakottamista — vain jos
     ylärivit ovat oikeasti >1,5× kirkkaampia kuin niitä seuraavat rivit, rajaus nostetaan.
     Testattu: Broken Flowers palauttaa nyt `top=2` (alkuperäinen automaattiarvo, ei enää pakotettu
     6:een) — mittaus totesi ettei häiriötä ole. **Ei pystytty testaamaan positiivista tapausta**
     (Wire-raakalähde ei enää tallessa) — kynnysarvot perustuvat Wireltä käsin mitattuihin lukuihin,
     mutta täyttä kiertotestiä ei ole tehty.

3. **Elokuvien ekstra-nimeäminen ollut rikki alusta asti** (ei regressio — vahvistettu `git log`/`git show`
   committista `eb0b5c9`). Sarjat saivat `-extra`-Jellyfin-tunnisteen, elokuvat eivät koskaan. Korjattu
   skriptiin (sama committi `99ef8a0`) + nimetty uudelleen 35 olemassa olevaa tiedostoa.

## KESKENERÄINEN / EPÄVARMA — vaatii tarkistuksen ennen jatkoa

4. **"2012"-levyllä löytyi ~80 roska-/duplikaattitiedostoa** (aikaleimat 07:53-07:55 UTC 2026-08-19).
   Juurisyy: jonon-uudelleenrakennuslogiikka (rivi ~1062) laskee "jo valmiit ekstrat" pelkästä
   tiedostonimien lukumäärästä, ei validoi sisältöä. **MIKÄ TÄSMÄLLEEN KÄYNNISTI TÄMÄN EI OLE
   SELVITETTY** — cron/systemd/at/watchdog.sh/dvd-encode-recovery.sh/tmux-serverit kaikki tarkistettu
   ja suljettu pois. Jää auki.

5. **Koko kirjaston audit löysi saman duplikaatiobugin 6 muusta kansiosta.** 34 tiedostoa poistettu
   kestovertailun perusteella (pienin numero säilytetty per kestoryhmä).
   - **Futurama S04: VAHVA todiste** (8 uniikkia kestoa, kukin toistui 3-5x systemaattisesti samassa
     suhteellisessa numerojärjestyksessä joka kierroksella — rakenteellinen todiste, ei vain kesto).
   - **Cube, Caveman's Valentine, E.T. (yksittäiset parit/kolmikot): HEIKOMPI todiste** — vain kesto
     täsmäsi, ei tiedostokokoa/muuta vahvistusta tarkistettu ennen poistoa. **Käyttäjä varoitti
     aiheellisesti liiallisesta varmuudesta.** Näitä poistoja EI VOI enää todentaa jälkikäteen koska
     tiedostot on jo poistettu.
     - **Palautusmahdollisuus:** E.T.:lle raakalähde on vielä koneella (voi tarkistaa/palauttaa).
       Cube:lle, Caveman's Valentinelle, Futurama S02/S03:lle EI ole raakalähdettä — palautus
       vaatisi fyysisen levyn uudelleen.
   - **PÄÄTÖS: ei enää poistoja pelkän kestovertailun perusteella.** Jos vastaava tilanne toistuu,
     vaaditaan lisäksi tiedostokoko+bittinopeusvertailu ennen poistoa, tai käyttäjän oma vahvistus.

## Tallessa olevat raakalähteet (dvdbackup, ei vaadi levyä takaisin asemaan)

11 kpl, joista osa EI OLE VIELÄ KOSKAAN ENKOODATTU KIRJASTOON (ei tekstitysbugin korjaus vaan
tavallinen puuttuva enkoodaus, turvallista jatkaa normaalilla jonolla):

| Teos | Kirjastossa jo? | Huomio |
|---|---|---|
| The Blues Brothers | EI | puuttuu kokonaan, jono kesken |
| Blues Brothers 2000 | EI | puuttuu kokonaan |
| Broken Flowers | EI | puuttuu, 2 eri dvdbackup-kopiota (disc-001 ja disc-005 — syytä ei selvitetty) |
| E.T. the Extra-Terrestrial | KYLLÄ (pääelokuva + osa ekstroista) | tekstitys pitää korjata olemassa olevaan |
| Dante 01 | KYLLÄ | tekstitys pitää korjata olemassa olevaan |
| 2012 | OSITTAIN (vain ekstrat, pääelokuva puuttuu/rikki) | ks. kohta 4 |
| Burn After Reading | KYLLÄ (12/14 osaa, Part 10/11 pysyvästi menetetty) | tekstitys pitää korjata |
| Futurama S04 (disc-003) | KYLLÄ | tekstitys pitää korjata |
| Futurama - Bender's Big Score | ? (ei vielä tarkistettu) | |
| District 9 | KYLLÄ (osittain, ks. aiempi muisti pysyvästä menetyksestä) | tekstitys pitää korjata |

## Crop-häiriön laajuus koko kirjastolle (mitattu, ei arvattu)

Skannattu kaikki 612 pää-titteliä (`scan_crop_artifact.py`, sama pikselikirkkausmenetelmä kuin
skriptikorjauksessa). **7 tiedostoa löytyi**, ei koko kirjastoa koskeva ongelma:

- The Wire S01E01, S01E11 (EI koko kausi — vain nämä kaksi jaksoa 23:sta tarkistetusta)
- 2046 - Part 04
- Eräs rakkaus tarina - Part 06
- STAR TREK The Wrath of Khan - Part 02
- George Clinton/Parliament/Funkadelic - The Mothership Connection (konserttielokuva)
- Led Zeppelin - Immigrant Song 1972 - Part 02

Huomio: kaksi musiikkielokuvaa mukana — järkeenkäypää, koska konserttitallenteet ovat usein
analogisista (VHS/Betamax-lähtöisistä) masterista, samantyyppinen VBI-jäänne todennäköinen.

**Ei vielä korjattu** — vaatii kohdistetun crop+re-enkoodauksen jo olemassa olevasta MKV:stä
(ei levyn uudelleenrippausta) näille 7 tiedostolle. Ei tehty automaattisesti, koska käyttäjä
halusi nähdä laajuuden ensin.

## Operatiivinen huomio: rinnakkaiset enkoodaukset lämmittävät yhdessä

Pythonia-tuotantoenkoodaus ajettiin suoraan (ei `rip-dvd.sh`:n flock-mekanismin kautta), jolloin
se pyöri samanaikaisesti Broken Flowers -session kanssa. Ei ylikuumenemisvaaraa (54-58°C, raja
80-100°C), mutta Broken Flowers -sessio jäi odottamaan skriptin oman (varovaisen) <50°C-kynnyksen
täyttymistä eikä edennyt niin kauan kuin molemmat pyörivät yhtä aikaa. **Opetus:** älä aja
manuaalisia HandBrakeCLI-komentoja ohi flock-mekanismin kun toinenkin sessio on jonossa —
käytä `--encode-only`-jonoa myös kertaluontoisille korjauksille jos mahdollista.

## Elämä on Pythonia — LOPULLISESTI KORJATTU (13:24)

Uudelleenenkoodattu suoraan `/dev/sr1`:ltä tuotantolaadulla (x265 CRF21, `--all-subtitles`,
`--all-audio`). Valmis tiedosto (848MB, 6 raitaa: video+ääni+2×suomi+2×ruotsi, kesto 84,68min
täsmää alkuperäiseen) korvasi vanhan kirjastotiedoston atomisesti. Vanha rikkinäinen versio
säilytetty varmuuskopiona: `/home/keitsi/dvd-rip-tmp/_vanhat_ennen_tekstityskorjausta/`.
Testikansiot (`_TESTI Elämä on Pythonia ...`) poistettu terastationilta. Jellyfin päivitetty.
`subtitle_tracker.csv` päivitetty: RIKKI → KUNNOSSA.

## session_20260818_003843 valmistui (19:09) — 3/3 pääelokuvaa onnistui

Broken Flowers, The Blues Brothers, Blues Brothers 2000 — kaikki uudella HandBrakella, uudella
mitatulla crop-korjauksella, `-extra`-nimeämiskorjauksella. Kaikki kolme löytyvät nyt kirjastosta.
5/10 raitaa epäonnistui — kaikki ekstroja, aitoja levyvirheitä ("ei löydettyä titteliä" tai
epäilyttävän pieni tuotos, esim. 1044843 tavua). Skripti tunnisti nämä oikein epäonnistuneiksi
(myös rc=0-mutta-liian-pieni-tapaukset) sen sijaan että olisi hyväksynyt roskadatan — hyvä merkki,
sama validointi joka puuttui aiemmin "onnistui ≠ oikein" -tapauksissa toimii nyt oikein.
Yksityiskohdat: `/home/keitsi/dvd-rip-tmp/session_20260818_003843/.encode-report`.

## Pieni, ei-blokkaava sivuvirhe havaittu (ei vielä diagnosoitu)

Broken Flowers -session lokissa näkyi `sed: -e expression #1, char 4: unterminated 's' command`
kun "Broken Flowers - Extra 01-extra.mkv" epäonnistui (rc=2, tunnettu lukuvirhe tällä levyllä).
Ei estänyt etenemistä seuraavaan raitaan. Nopea `grep 'sed '` rip-dvd.sh:stä ei paljastanut
ilmeistä syytä (mikään löytyneistä sed-kutsuista ei käytä muuttuvaa tiedostonimeä suoraan
sed-lausekkeena). Vaatii tarkemman tutkinnan — mahdollisesti liittyy uuteen `-extra`-päätteeseen
jos jokin koodinpätkä käsittelee tiedostonimeä sed:llä jota en löytänyt.

## Seuraavat askeleet (turvallisia, ei-tuhoavia — voi jatkaa ilman käyttäjää)

1. Käynnistä normaali `--encode-only`-jono niille sessioille joissa on kokonaan puuttuvia elokuvia
   (Blues Brothers, Blues Brothers 2000, Broken Flowers) — puhdas lisäys, ei kosketa mitään olemassa
   olevaa.
2. Mittaa yläreunan crop-häiriön laajuus per-jakso koko kirjastolle (lukeva, ei muuta mitään).
3. Tekstityskorjaukset (irrotus+remux) niille joilla on jo video/ääni kirjastossa — TEHDÄÄN VASTA
   kun käyttäjä voi tarkistaa tuloksen, ei blind-mass-fix.
