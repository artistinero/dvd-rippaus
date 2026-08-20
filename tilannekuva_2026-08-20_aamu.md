# Tilannekuva 2026-08-20 klo 11:20 — kaikki todennettu, ei arvattu

Tämä dokumentti korvaa aiemman hajanaisen, osin virheellisen keskustelun tämän aamun
enkoodausjonosta. Jokainen väite tässä on tarkistettu suoraan (terastation-tiedostolistaus,
prosessilista, lokitiedostot) — ei päätelty tai arvattu.

## Käynnissä juuri nyt (klo 11:20)

1. **Gandhi** — aktiivisesti enkoodautumassa (HandBrakeCLI-prosessi vahvistettu käynnissä).
2. **Inside Deep Throat** — jonossa, odottaa Gandhin valmistumista (yksi HandBrake-prosessi
   kerrallaan, ylikuumenemissuoja).
3. **enc-20260816_003233** ja **enc-20260817_224959** — käynnistettiin klo 11:15, mutta
   odottavat NYT kohteliaasti flock-lukkoa Gandhin/Inside Deep Throatin takana. Eivät ole
   jumissa, eivät virheessä — vain oikeutetusti jonossa. Kun niiden vuoro tulee, ne
   valmistuvat sekunneissa (ks. alla miksi).
4. **The Harder They Come (1972)** — uusi levy, dvdbackup-kopiointi käynnissä (`session_20260820_111502`).

## Miksi enc-20260816_003233 ja enc-20260817_224959 valmistuvat nopeasti

Tarkistettu suoraan terastationilta rivi riviltä (ei encode-reportin varassa, koska se
osoittautui epäluotettavaksi moniajoisissa sessioissa — ks. alla):

**session_20260816_003233** (10 levyn erä, virheellisesti aiemmin puhuttu vain "District 9":nä):
| Teos | Tila |
|---|---|
| District 9 | 4/10 raitaa pysyvästi valmis, 6/10 pysyvästi menetetty (aito levyvaurio, 230+ lukuvirhettä, dokumentoitu jo aiemmin) |
| Circus, 2001: Avaruusseikkailu, Elämä on Pythonia, Back to the USSR, 1984, Everything You Always Wanted to Know About Sex, 101 Reykjavik, 99 frangia, 12 apinaa | KAIKKI jo täydessä kirjastossa |

**session_20260817_224959**:
| Teos | Tila |
|---|---|
| E.T. the Extra-Terrestrial | Jo kirjastossa (2,3GB päätiedosto, luotu 19.8. klo 02:14 — vahvistettu ettei tämä liity mitenkään eiliseen tekstityskorjaustyöhön, se on eri, aiempi onnistunut enkoodauskerta) |
| Dante 01 | Jo kirjastossa |
| Broken Flowers | Jo kirjastossa |

Eli KAIKKI näiden kahden session-hakemiston sisältö on jo valmiina — ne näkyivät "jonossa"
vain koska raaka dvdbackup-data on yhä levyllä siivoamatta, ei koska työtä olisi jäljellä.

## Korjatut bugit tämän tutkinnan aikana

1. **`_session_has_pending_work()` FAIL=0-ohitusbugi** (löydetty, korjattu, sitten OSITTAIN
   PERUTTU kun havaittiin korjauksen olevan vaarallisempi kuin alkuperäinen ongelma
   moniajoisissa sessioissa — ks. `session_2026-08-19_loki.md` yksityiskohdat). Nykytila:
   alkuperäinen, turvallinen käytös (näyttää joskus turhaan "jonossa", mutta EI KOSKAAN
   virheellisesti "valmis" kun jotain on kesken).
2. **`SCAN_TIMEOUT` puuttui `--scan`-kutsuista** — korjattu, deployattu (committi `7ff0aa1`).
   Esti mm. eilisillan American Beauty -jumiutumisen.
3. **Tyhjä sessionimi enkoodaus-only-lokissa** (`"═══ Enkoodaus-only:  ═══"`, trailing-slash-
   bugi `${enc_dir##*/}`:ssä) — korjattu, deployattu (committi `0ede3b1`).

## Miksi encode-report ei ole luotettava lähde "onko kaikki valmis" -kysymykseen

Kun session käsitellään USEANA erillisenä `--encode-only`-ajona (yksi per levy, kuten
tänä aamuna Apocalypse Now/Goodbye Lenin/Gandhi/Inside Deep Throat), jaettu
`.encode-report`-tiedosto YLIKIRJOITTUU jokaisen yksittäisen ajon lopussa — se ei koskaan
kerro koko session-hakemiston kumulatiivista totuutta silloin kun toinen levy on yhä
kesken. Tämä havaittiin konkreettisesti: raportti näytti "OK=2" vaikka levyt 3-4 olivat
sillä hetkellä aktiivisesti/vielä kokonaan kesken. **Oikea tapa tarkistaa "onko kaikki
valmis" on aina tarkistaa suoraan terastationin tiedostolistaus, ei luottaa raporttiin.**

## VAKAVA, VAHVISTETTU AVOIN RISKI: monilevyisen elokuvan myöhemmät levyt

Käyttäjän 2026-08-20 11:20 huomauttama, tarkistettu koodista (rivi 2172-2201): "Mikä raita on
itse elokuva?" -kysymys kysytään ERIKSEEN jokaiselta yksittäiseltä levyltä (`p_type ==
movie/doc AND title_count > 1`), eikä skriptissä ole mitään logiikkaa joka tunnistaisi "tämä
on saman elokuvan 2./3. levy, todennäköisesti pelkkiä ekstroja". Vastausvaihtoehto "0 = ei
tällä levyllä, kaikki ekstroja" on olemassa juuri tätä varten, MUTTA jos kukaan ei vastaa
180 sekunnin aikakatkaisun sisällä, **oletusarvo valitsee levyn PISIMMÄN raidan "elokuvaksi"
sokeasti** — jos toisella/kolmannella levyllä on vain pitkä bonusfeature eikä oikeaa elokuvan
jatkoa, tämä voi nimetä sen virheellisesti osaksi elokuvaa (esim. "Elokuva - Part 02.mkv").

**Ei korjattu tänään** — vaatisi harkitun, testatun ratkaisun (esim. tunnistaa saman-nimisen
elokuvan aiempi levy samassa sessiossa ja kysyä eri, varovaisempi oletusvastaus, tai pidentää
aikakatkaisua/muuttaa oletusarvoa "0":ksi tälläisessä tilanteessa) — päätetty olla tekemättä
hätiköityä muutosta kesken kaiken muun tämänpäiväisen työn. **Käytännön neuvo toistaiseksi:**
vastaa AINA itse tähän kysymykseen manuaalisesti monilevyisten elokuvien 2.+ levyillä äläkä
luota 180s-oletukseen niissä tapauksissa.

## Ei vielä tehty / avoimet asiat

- `extract_subs_fast.py`-menetelmää (20-40× nopeampi tekstitysirrotus) ei ole vielä
  käytetty tuotannossa oikeille kohteille (District 9:n jäljellä olevat 4 osaa, jne.) —
  odottaa käyttäjän hyväksyntää.
- Crop-häiriön 6 muuta tunnettua tapausta (Wire S01E11, 2046 Part04, Eräs rakkaus tarina
  Part06, Star Trek Wrath of Khan Part02, 2 musiikkielokuvaa) eivät ole vielä korjattu.
- ddrescue-menetelmää vaurioituneille levyille (2012, American Beauty) ei ole vielä
  testattu käytännössä.
