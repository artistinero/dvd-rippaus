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

## Koko kirjaston laajuusmittaus (VobSub-tekstitykset) + suunnitelma (21:35)

`mkvmerge -J` koko kirjastolle: **425/706 .mkv-tiedostoa sisältää VobSub-tekstityksen**
(381 pääteosta/jaksoa, 44 ekstraa). Paljon suurempi laajuus kuin vanhan trackerin 54 kohdetta.
Koko suunnitelma: `suunnitelma_tekstityskorjaus.md` (committi `2ae23a5`). Käyttäjän vahvistamat
pelisäännöt tallennettu pysyvään muistiin: `feedback_disc_swap_protocol.md` — kysy aina
epäselvissä, avaa levykelkka heti valmistuttua, kerro poikkeamat, levy=käsittelyn yksikkö,
aakkosjärjestys, kaikki kuluneet ajat lokiin.

## Levy-kerrallaan-korjaukset (aikaleimat)

| # | Teos | Irrotus (HandBrake) | Remux (mkvmerge) | Yhteensä | Huomiot |
|---|---|---|---|---|---|
| 1 | 99 frangia (2007) | ei tarkkaa aikaa kirjattu (ensimmäinen, opittu tästä eteenpäin kirjata aina) | 33s | ~muutama min | 5 tekstitysraitaa levyllä, 4 käytössä (2xsuomi+2xruotsi), 1 "Unknown"-raita jätetty pois koska ei ollut kirjastossakaan alunperin. Kesto täsmäsi täydellisesti (6004,224s). Levykelkka avattu onnistuneesti heti valmistuttua. |
| 2 | 101 Reykjavik (2000) | 310s (5min10s) | 13s | 5min23s | 2 suomiraitaa (WS+LB), täsmäsi täydellisesti (5075,808s). Levykelkka avattu heti valmistuttua. |

**Sääntö tästä eteenpäin:** jokaiselle levylle kirjataan `date +%s` ennen ja jälkeen sekä
irrotuksen että remuxin, jotta kokonaisaika on tarkka.

## Menetelmäanalyysi: miksi HandBrake-yhden-ajon-menetelmä voitti (perusteltu, ei vain lopputulos)

**Kolme menetelmää kokeiltu, tässä miksi kaksi hylättiin ja yksi jäi:**

1. **HandBrake, kaikki tekstitysraidat yhdessä ajossa** (`--subtitle 1,2,3...N --encoder x264
   --encoder-preset ultrafast`). Video dekoodataan ja enkoodataan kerran, mutta KAIKKI pyydetyt
   tekstitysraidat poimitaan SAMALLA läpikäynnillä koska ne kulkevat samassa MPEG-ohjelmavirrassa
   videon kanssa — HandBrake demuksii ne "ilmaiseksi" saman lukukerran aikana.
   **Mitattu kesto riippuu elokuvan PITUUDESTA, ei raitamäärästä:**
   - 101 Reykjavik: 84min, 2 raitaa → 310s
   - 2001 Avaruusseikkailu Part01: 142min, 10 raitaa → 789s
   - 2010: 111min, 21 raitaa → 523s
   Näistä näkyy: 2010 (111min) on nopeampi kuin 2001 (142min) VAIKKA siinä on 2× enemmän raitoja
   — pituus selittää keston, ei raitamäärä. Tämä on looginen seuraus siitä että video on ainoa
   asia jota oikeasti pitää DEKOODATA/ENKOODATA; tekstitysraidat ovat vain rinnakkaisia,
   kevyitä datavirtoja samassa tiedostossa.

2. **mencoder, yksi ajo per kieli** (`-ovc copy -sid N -vobsuboutindex N`, toistettu N kertaa).
   Idea oli hyvä teoriassa (`-ovc copy` = ei uudelleenenkoodausta = pitäisi olla nopea), mutta
   käytännössä KATASTROFAALINEN moniraitaisille levyille: jokainen ajo lukee koko elokuvan
   ALUSTA LOPPUUN uudelleen VAIN yhtä kieltä varten. 2010:llä (111min, 21 kieltä) tämä olisi
   tarkoittanut 21 × ~11min ≈ 4 tuntia — 27× hitaampi kuin HandBraken yhden-ajon-menetelmä
   samalle levylle (523s). **Miksi tämä ei tullut heti ilmi:** ensimmäinen ajatus oli että
   `-ovc copy` tekee sen nopeaksi koska ei enkoodaa — mutta unohdin että jokainen ERILLINEN ajo
   silti lukee/demuksii koko streamin ajallisesti alusta loppuun, riippumatta enkoodauksesta.
   N kertaa toistettuna N× kustannus, ei amortoidu.

3. **Harkittu mutta EI kokeiltu: dvdbackup-paikalliskopio + mencoder paikallisesta kopiosta.**
   Ajatus: mencoderin hitaus voisi johtua optisen aseman I/O-nopeudesta (~1-2MB/s) eikä
   ohjelmiston laskentakustannuksesta — paikallinen levy on 5-10× nopeampi. **Miksi tätä ei
   silti oteta käyttöön:** koska HandBrake jo hoitaa KAIKKI raidat yhdessä ajossa riippumatta
   niiden määrästä (kohta 1), ei ole mitään toistokertoja joita amortoida — paikalliskopion
   9,5min lisäkustannus ei toisi mitään hyötyä, koska HandBrake ei tarvitse montaa erillistä
   läpikäyntiä ylipäätään. Paikalliskopio olisi hyödyllinen VAIN jos joutuisimme ajamaan monta
   ERILLISTÄ prosessia saman levyn läpi — emme joudu, koska HandBrake ei ole per-kieli-rajoitettu
   kuten mencoder.

**Lopullinen sääntö kaikille tuleville levyille:** suora `HandBrakeCLI --input /dev/sr1 --title N
--subtitle <kaikki pilkulla eroteltuna> --encoder x264 --encoder-preset ultrafast --quality 40
--audio <kaikki> --aencoder copy` — ei paikalliskopiota, ei mencoderia, riippumatta raitamäärästä.

## KRIITTINEN PROSESSIVIRHE: tekstiskannaus tekstimuodossa katkeaa

`HandBrakeCLI --scan` (ilman `--json`) näyttää tekstimuotoisessa tulosteessa VAIN ENSIMMÄISET
N tekstitysraitaa (havaittu raja: näytti tasan 10 kun oikea määrä oli 21). Tämä ei ole eri
levypainos eikä levyvaurio — se on HandBraken OMAN tekstitulosteen katkeaminen, joka paljastui
vasta kun 2010-levyn kirjaston 21 raitaa ei täsmännyt tekstiskannauksen 10:een.

**Korjattu prosessi:** käytä AINA `HandBrakeCLI --input X --title N --scan --json` (tulostus
sisältää log-rivejä ENNEN JSON:ia, hae `JSON Title Set: {`-rivi ja parsi siitä eteenpäin) kun
pitää tietää tarkka tekstitysraitojen (tai minkä tahansa raidan) määrä. Älä koskaan luota
`grep`-pohjaiseen tekstiskannaukseen raitamäärän laskemiseen.

**Vaikutus jo tehtyyn työhön:** 2001: Avaruusseikkailu Part01 KORJATTIIN tekstiskannauksen (10
raitaa) perusteella ENNEN kuin tämä bugi löytyi — levy on jo palautettu, ei voida tarkistaa
jälkikäteen ilman levyn uudelleenasettamista asemaan. **Merkitty uudelleentehtäväksi.**

## Seuraavaksi

2001: Space Odyssey — käyttäjä ilmoitti sen olevan seuraava levy joka laitetaan asemaan.
| 3 | 2001- Avaruusseikkailu (1968) Part01+02 | 789s (13min9s, HandBrake-menetelmä, viimeinen kerta ennen mencoderiin siirtymistä) | 30s+1s | ~13min40s | 10 tekstitysraitaa Part01:lle (levy: eng,ger,dut,swe,nor,dan,fin,ice,ita,ger — kirjastossa oli aiemmin 11, yksi ylimääräinen "eng" jota ei löytynyt levyltä, korvattu levyn 10:llä). Part02:lle lisättiin ensimmäistä kertaa tekstitys (eng) — ei ollut aiemmin lainkaan. **HandBrake-menetelmä todettu liian hitaaksi (13min per pitkä elokuva) — vaihdettu mencoderiin joka ei kosketa videoon (`-ovc copy`), vahvistettu primäärilähteestä (mplayerhq.hu-peili).** |
| 4 | 2010- The Year We Make Contact (1984) | 523s (8min43s) | 40s | ~9min | 21 tekstitysraitaa. **TÄRKEÄ HAVAINTO: HandBraken tekstiskannaus tekstimuodossa katkeaa ~10 raitaan!** JSON-skannaus (`--scan --json`) paljasti oikean 21 raidan listan. **2001: Avaruusseikkailu Part01 tehtiin AIEMMIN tekstiskannauksella (näytti 10) — todennäköisesti puuttuu 11. raita, VAATII UUDELLEENTEON.** Kokeiltiin myös mencoder-menetelmää (yksi ajo per kieli) mutta todettiin katastrofaalisen hitaaksi 21 kielelle (~4h) koska käy koko elokuvan läpi erikseen jokaista kieltä kohden — hylätty, palattu HandBrake-yhden-ajon-menetelmään. **Analyysi: HandBraken kesto riippuu elokuvan PITUUDESTA ei raitamäärästä (yksi pass kaikille), joten se on jo optimaalinen kaikille tapauksille — ei tarvita paikalliskopio+mencoder-kiertotietä millekään levylle.** |

## 2012 — SIIRRETTY MYÖHEMMÄKSI, aito levyvaurio

Pääelokuva puuttuu kirjastosta kokonaan (aiemmin poistettu rikkinäisenä, ks. "2012"-osio
yllä). Yritettiin täysi tuotantoenkoodaus levyltä (`/dev/sr1`, titteli 1, 151min, x265 CRF21,
13 tekstitysraitaa + 4 ääniraitaa vahvistettu JSON-skannauksella) — **epäonnistui heti**:
vain 12 kehystä (0,57s) enkoodautui, 10KB tiedosto, HandBrake raportoi silti rc=0 ("Encode
done!"). Sama aito lukuvirhe kuin aiemmin tänään dokumentoitu (READ_ERRORS=159 alkuperäisessä
rippauksessa 2026-08-17). Väliaikaistiedosto siivottu, levykelkka avattu.

**Käyttäjän päätös: siirretään myöhemmäksi, ei yritetä nyt uudelleen.** Vaatii todennäköisesti
erikoiskäsittelyä (esim. lukuvirhettä sietävä osissa-uudelleenyritys, ks. Futurama S03 -levyjen
vastaava historia projektissa) kun siihen palataan. 13 olemassa olevaa ekstraa (jo deduplikoitu
aiemmin tänään) eivät vielä saaneet tekstityskorjausta — myös nämä odottavat.

## Seuraavaksi (päivitetty)

## 2046 (2004) — LEVYÄ EI LÖYDY

Käyttäjä ei löydä fyysistä levyä. Jää odottamaan kunnes levy löytyy. Huomio: tämä teos oli myös
aiemmin tänään mitatussa crop-häiriölistalla ("2046 - Part 04", top=3.8 vs alla=2.2) — kun levy
joskus löytyy, kannattaa hoitaa sekä tekstityskorjaus että crop-korjaus samalla kertaa.
