# DVD-rippaus- ja enkoodausjärjestelmä — täydellinen spesifikaatio (puhtaalta pöydältä)

Tämä on **itsenäinen spesifikaatio**: se määrittelee järjestelmän vaatimuksina ja sopimuksina
ilman viittausta mihinkään olemassa olevaan koodiin. Toteuttaja (ihminen tai toinen Claude Code
-instanssi) voi rakentaa kokonaan uuden toteutuksen pelkästään tämän dokumentin perusteella.
Kaikki tila-, komento- ja tiedostoformaatit on määritelty täsmällisesti.

Toteutuskieli oletuksena bash + jq + python3 + HandBrakeCLI + dvdbackup + lsdvd + mkvtoolnix +
ffprobe. Ne voi vaihtaa kunhan sopimukset (§4 datamalli, §5 komennot) säilyvät.

---

## 1. Tarkoitus ja periaatteet

Järjestelmä rippaa DVD-levyjä, enkoodaa ne x265-mkv:ksi mediakirjastoon, ja hallitsee tätä
**yhtenä globaalina jonona** joka enkoodaa N kohdetta rinnakkain riippumatta siitä miltä levyltä
kukin on peräisin.

**Suunnitteluperiaatteet (sitovat):**

1. **Ydin erillään käyttöliittymästä.** Ydinkomennot EIVÄT koskaan kysy interaktiivisesti mitään
   eivätkä tulosta ihmiselle. Ne ottavat argumentit ja lukevat/kirjoittavat koneluettavaa tilaa
   (JSON). Käyttöliittymä (CLI nyt, GUI myöhemmin) on ohut kerros joka hoitaa vuorovaikutuksen ja
   kutsuu ydinkomentoja.
2. **Kaikki jaettu tila koneluettavana** (JSON), atomisesti kirjoitettuna. Yksikään kahdesta
   rinnakkaisesta kirjoittajasta ei saa korruptoida tai hävittää toisen kirjoitusta.
3. **Yksi globaali enkoodausjono.** Ei per-levy- tai per-sessio-jonoja. Rinnakkaisuus toimii yli
   levyrajojen.
4. **Kaikki metadata kerätään ja tallennetaan kerran, rippausvaiheessa.** Myöhemmät vaiheet
   (enkoodaus, tilanäyttö, GUI) eivät probeaa levyjä uudelleen.
5. **Viat tunnistetaan ja siirretään sivuun.** Rikkinäistä ei koskaan yritetä enkoodata
   automaattisesti uudelleen. Ongelmallisista pidetään ajantasaista listaa.
6. **Kaikki asetukset (kansiot, laatu, kynnykset, rinnakkaisuus) ovat konfiguroitavia.** Mitään
   käyttäjää koskevaa arvoa ei kovakoodata.
7. **Peruuttamattomat operaatiot (lähteen poisto, kirjaston ylikirjoitus) vaativat aina
   sisältöverifioinnin ennen suoritusta.** Pelkkä "tiedosto on olemassa" ei riitä.
8. **Mitään ei viedä tuotantoon testaamatta.** §11 määrittelee testit jotka on läpäistävä.

---

## 2. Tila-arkkitehtuuri (ratkaisee rinnakkaisuuden dataeheyden)

Suurin datariski on jaetun jonotiedoston rinnakkainen muokkaus. Ratkaisu: **per-job-tiedostot,
ei yhtä muokattavaa jonotiedostoa.**

```
$STATE/                         (STATE = $WORK_DIR/state)
  jobs/<id>.json                Yksi tiedosto per enkoodaustyö. Ainoa totuus jobin tilasta.
                                Muutos = kirjoita temp + atominen mv (rename). Ei koskaan
                                osittaista tilaa lukijalle. Kutakin jobia muuttaa kerrallaan
                                vain se joka omistaa sen (dispatcher-slotti tai rip-komento
                                luontihetkellä) -> ei kilpajuoksua kentän muokkaukseen.
  status.json                   Live-yhteenveto (dispatcher kirjoittaa, temp+mv). Vain LUKUA
                                käyttöliittymille. Johdettu jobs/-tiedostoista.
  problematic/<id>.json         Ongelmalliset (viat). Per-job-tiedosto, sama atomisuus.
  locks/<hash>.lock             flock-tiedostot per-kohdekansio-varaukseen (ekstrojen numerointi).
  slots/slot-N.lock             Rinnakkaisslottien varaus (dispatcher).
```

**Miksi per-job-tiedostot:** jobin tilamuutos = yhden pienen tiedoston atominen korvaus
(temp+mv). Ei koko jonon uudelleenkirjoitusta, ei kahden valmistuvan jobin kilpajuoksua, ei
"rip lisää samalla kun dispatcher kirjoittaa" -korruptiota. "Jono" = hakemistolistaus
`jobs/*.json` (luonti = uusi tiedosto, poisto = ei koskaan; valmistuminen = statuskentän
muutos). Jonon "järjestys" tulee `added`-aikaleimasta tai juoksevasta `seq`-numerosta jobissa.

`queue.jsonl`-tyyppistä yhtä tiedostoa EI käytetä mutable-tilana. (Halutessa voidaan tuottaa
read-only johdettu näkymä `status`-komennolla, mutta se ei ole totuuslähde.)

---

## 3. Jobin elinkaari ja tilat

Job = yksi enkoodattava titteli. `status`-enum, **tahallinen ohitus ja epäonnistuminen ovat eri
tiloja** (kriittinen lähteen siivouksen kannalta):

| status      | merkitys                                              | lähde saa siivota? |
|-------------|-------------------------------------------------------|--------------------|
| `pending`   | odottaa enkoodausta                                   | ei                 |
| `encoding`  | dispatcher-slotti enkoodaa parhaillaan                | ei                 |
| `done`      | enkoodattu, sisältöverifioitu, kirjastossa            | **kyllä**          |
| `failed`    | enkoodaus epäonnistui (rc≠0 / verifiointi hylkäsi)    | ei (voi retryä)    |
| `broken`    | lähde viallinen (lukuvirhe, scan-hang) — ei yritetty  | **ei** (retry tarvitsee lähteen) |
| `user_skip` | käyttäjä päätti ettei tätä tehdä                      | **kyllä** (tietoinen) |

**Lähteen (disc) VOB:it poistetaan vain kun KAIKKI saman lähteen jobit ovat tilassa jossa
"siivota=kyllä"** (`done` tai `user_skip`). Yksikin `pending/encoding/failed/broken` estää
siivouksen. Tämä takaa että `retry` (failed/broken) löytää lähteen aina.

**Dispatcherin kaatumistoipuminen (pakollinen):** dispatcher käynnistyessään käy läpi kaikki
`encoding`-jobit ja tarkistaa onko niiden `pid` (jobissa) yhä elossa (`kill -0`). Kuollut →
palauta `pending`, vapauta slotti, poista keskeneräinen temp-tulos. Näin kaatuminen/reboot ei
jätä ikuisia `encoding`-tiloja eikä vuoda slotteja.

---

## 4. Datamalli (täsmälliset skeemat)

### 4.1 Job: `$STATE/jobs/<id>.json`
`<id>`: **sisältöpohjainen, deterministinen ja uniikki** — esim. `sha1(source_abs + ":" +
title)[0:12]`. Sama lähde+titteli tuottaa aina saman id:n → ei törmäyksiä eikä duplikaatteja
(insert on idempotentti). EI satunnainen.

```json
{
  "id": "9f3a1c2b7e04",
  "seq": 1337,                        // juokseva luontijärjestys (jonojärjestys)
  "source": "/abs/.../disc-042/VIDEO_TS",  // dvdbackup-tuloksen VIDEO_TS-hakemisto
  "disc_key": "/abs/.../disc-042",    // lähdelevyn juuri (siivouksen yksikkö)
  "title": 11,                        // HandBrake/lsdvd-tittelinumero
  "kind": "movie",                    // movie | series | doc | music | misc
  "role": "main",                     // main | extra
  "name": "Fargo",
  "year": "1996",                     // tyhjä sallittu
  "season": null,                     // sarjoille
  "episode": null,                    // sarjoille
  "dest_dir": "/abs/.../movies/Fargo (1996)",
  "out_name": "Fargo.mkv",            // main; extroille laskettu enqueuen/lukon sisällä
  "duration_s": 5640,
  "width": 712, "height": 408, "dar": "1.86:1", "fps": 25, "format": "PAL",
  "crop": "66:66:2:2",                // autocrop; huomioi sijaintibugi rajatuilla
  "subs": ["fin","swe"],              // tekstityskielet (ISO-639)
  "audio": ["eng"],                   // äänikielet
  "read_errors": 0,                   // lähdelevyn lukuvirheet (rippausvaiheesta)
  "status": "pending",
  "slot": null,                       // varattu slotti kun encoding
  "pid": null,                        // HandBrake-prosessin PID kun encoding (toipumiseen)
  "quality": 21, "encoder": "x265",   // efektiiviset arvot (configista enqueue-hetkellä)
  "added": "2026-08-26T09:00:00Z",
  "started": null, "finished": null,
  "fail_reason": null,
  "confidence": "high"                // high | low (pääelokuvan tunnistuksen varmuus, §7)
}
```

### 4.2 Live-tila: `$STATE/status.json` (dispatcher kirjoittaa, temp+mv)
```json
{"updated":"2026-08-26T09:05:00Z","parallel":2,
 "encoding":[{"id":"...","name":"Fargo","pct":42.1,"eta_s":1830,"fps":31.2,"slot":1}],
 "pending":57,"done":812,"failed":3,"broken":5,
 "queue_eta_s":41000,"temps_c":[55,58,54,56],"disk_free_gb":80}
```

### 4.3 Ongelmallinen: `$STATE/problematic/<id>.json`
Jobin kopio + `reason` + `detected` -aikaleima. Per-job-tiedosto (ei jaettua liitostiedostoa →
ei append-kilpailua). `review-problematic` listaa hakemiston, `retry <id>` yrittää uudelleen.

### 4.4 Konfiguraatio: `$HOME/.config/rip-dvd/config`
`AVAIN=arvo` per rivi. **Ei rivinsisäisiä kommentteja** (vain kokonaiset `#`-alkuiset
kommenttirivit). Parsinta strippaa aina trailing-whitespacen. Kaikki kynnykset mukana:
```
PARALLEL=2
CRF=21
ENCODER=x265
DEST_ROOT=/mnt/terastation/dlna/vids
DIR_MOVIES=movies
DIR_SERIES=series
DIR_DOCS=documentaries
DIR_MUSIC=music
DIR_MISC=misc
WORK_DIR=/home/keitsi/dvd-rip-tmp
TEMP_WARN=85
TEMP_KILL=95
MIN_DURATION=300
READ_ERROR_MAX=20
SCAN_TIMEOUT=600
RIP_MIN_FREE_GB=40
RIP_AHEAD_MAX=8
```
Luku: `val=$(sed -n "s/^KEY=//p" config | head -1); val="${val%%[[:space:]]*}"` tai vastaava —
**aina trailing-strippaus.** Ei `source` (ei suoriteta configin sisältöä koodina).

---

## 5. Ydinkomennot (ei-interaktiiviset, sopimukset)

Kaikki tulostavat JSONia stdoutiin ja/tai muuttavat tilaa; eivät kysy mitään.

- **`scan <dvd_dir>` → JSON tittelilistasta metadatoineen.** Ajaa `timeout $SCAN_TIMEOUT
  HandBrakeCLI --scan --json` (ja/tai lsdvd). Palauttaa jokaisesta tittelistä:
  numero, kesto, mitat, dar, fps, format, crop, subs[], audio[]. **Timeout → virhe-JSON
  (`{"error":"scan_timeout"}`), ei jää roikkumaan.** EI kirjoita jonoa — pelkkä analyysi.
  (Erottelu `scan` ↔ `enqueue`: käyttöliittymä ajaa scanin, kysyy käyttäjältä luokittelun
  epävarmoissa, ja kutsuu sitten enqueuen eksplisiittisillä arvoilla.)
- **`enqueue --source … --title … --kind … --name … [--year …] [--season/--episode] --role …`**
  → luo `jobs/<id>.json` (idempotentti id:n perusteella). Ottaa metadatan `scan`-tuloksesta
  (annettuna) — ei probeaa uudelleen. Ekstroille `out_name` lasketaan **per-dest-lukon sisällä**
  kirjoitushetkellä (numero = olemassa olevat + jonossa olevat + 1), ei etukäteen.
- **`dispatch`** (pitkäikäinen daemon): toipumis­skannaus (§3), sitten silmukka: lue PARALLEL
  tuoreena, varaa vapaat slotit `pending`-jobeille (per-dest-lukko + lämpöturva), enkoodaa,
  verifioi, siirrä kirjastoon, päivitä job + status.json. Lähteen siivous kun disc valmis (§3).
- **`status [--json]`** → tuottaa status.json:n (tai lukee sen). UI/enkoodaustila.sh käyttää.
- **`skip <id>`** → `status=user_skip`. **`unskip <id>`** → `pending`.
- **`retry <id>`** → `failed|broken` → `pending` (edellyttää lähteen olemassaoloa).
- **`review-problematic`** → listaa `problematic/`.
- **`cleanup`** → poistaa valmiiden discien lähteet (§3-sääntö) + tyhjät työhakemistot.
- **`migrate`** → §9.

---

## 6. Rippaus + metadatan tallennus

`rip <levy_laite>`-vuo (CLI-kerros ohjaa, ydin tekee):
1. Tarkista levytila-esiehto: **jos `WORK_DIR` vapaa < `RIP_MIN_FREE_GB` TAI rippaamatonta
   enkoodausvelkaa > `RIP_AHEAD_MAX` jobia → älä rippaa, ilmoita.** (Estää WORK_DIR:n täyttymisen
   kun rippaus juoksee enkoodauksen edelle.)
2. `dvdbackup -M` levyltä → `disc-NNN/`. Tallenna dvdbackupin/dmesgin **READ_ERRORS**.
3. `scan` (timeout-wrapattu). Timeout tai READ_ERRORS > `READ_ERROR_MAX` → koko levy tai
   yksittäiset tittelit `problematic/` (status `broken`), ei jonoon.
4. Käyttöliittymä esittää tittelit + metadatan, käyttäjä vahvistaa luokittelun (movie/series/…,
   nimi, vuosi, pää/ekstra) — **erityisesti kun `confidence=low`** (§7). Ydin ei arvaa.
5. `enqueue` jokaisesta enkoodattavasta tittelistä täydellä metadatalla.

---

## 7. Pääelokuvan / ekstrojen tunnistus

- Jos käyttäjä/metadata antaa eksplisiittisen pää­titteli­numeron → käytä sitä (`confidence=high`).
- Muuten heuristiikka (pisin = pää) tuottaa **ehdotuksen + `confidence`-lipun ja vaihtoehtoiset
  tittelit** jobiin. Kun useampi pitkä titteli tai epäselvä rakenne → `confidence=low`, ja
  käyttöliittymä **pyytää vahvistuksen ennen enqueueta.** Ydin ei koskaan hiljaa arvaa
  epävarmassa tapauksessa. (Estää väärintunnistuksen kun outo levy tulee.)
- Sarjat: useampi pitkä titteli → jaksot; jakso ↔ titteli täsmätään kestolla, käyttäjä
  vahvistaa jakso­numeroinnin.

---

## 8. Dispatcher yksityiskohdat

- **Slotit:** `PARALLEL` kpl `slots/slot-N.lock`. Luettu tuoreena joka varauskierroksella.
- **Per-dest-lukko:** ennen ekstran `out_name`-laskentaa flock `locks/<sha1(dest_dir)>.lock`;
  numero lasketaan lukon sisällä; vapauta kirjoituksen jälkeen. Estää kahden rinnakkaisen jobin
  saman numeron.
- **Lämpöturva (määritelty per kynnys):**
  - **`TEMP_WARN` (esim. 85°C):** dispatcher lähettää `kill -STOP` **enkooderiprosessiryhmälle**
    (ei koko koneelle; dispatcher itse jää ajoon), `kill -CONT` kun lämpö laskee alle rajan.
    Palautuva, työtä ei menetetä.
  - **`TEMP_KILL` (esim. 95°C):** hätäsammutus — `kill` enkooderit, ja **kyseiset jobit
    palautetaan `pending`:iksi** (ei `failed`), keskeneräiset temp-tulokset poistetaan. Työ
    yritetään uudelleen kun lämpö sallii. Lämpötila ei koskaan merkitse jobia pysyvästi rikki.
- **Verifiointi ennen kirjastoon kirjoitusta:** valmis tulos tarkistetaan: video- ja ääniraidat
  läsnä, kesto ~ `duration_s`, tekstitysten kattavuus järkevä. Hylkäys → `failed`, kirjastoa ei
  kosketa.
- **Atominen kirjaston korvaus:** kirjoita temp kohdekansioon, `mv` atomisesti; vanhan
  mahdollisen korvattavan versio varmuuskopioidaan **kirjaston ULKOPUOLELLE** (ettei mediapalvelin
  indeksoi sitä).

---

## 9. Migraatio vanhasta järjestelmästä + turvallinen tilan­vapautus

`migrate` (kertaluontoinen, ajetaan vasta kun uusi testattu):
1. Tuo vanhat jonorivit → `enqueue` uusiksi jobeiksi (metadata: probe kerran migraatiossa).
2. Merkitse `done` vain ne joiden **dest-tiedosto läpäisee sisältöverifioinnin** (video+ääni
   läsnä, kesto ~ tallennettu) — **ei koskaan pelkän olemassaolon perusteella.** Katkennut/
   korruptoitunut dest → jää `pending`, ei `done`.
3. Muut → `pending`-jobeja uuteen jonoon (lähde säilyy).
4. **Lähteen (VOB) poisto vain niille disceille joiden KAIKKI jobit ovat `done` (verifioitu) tai
   `user_skip`.** Tämä on ainoa oikea tapa vapauttaa iso määrä levytilaa turvallisesti.
5. Vanhat rakenteet poistetaan vasta kun migraatio on todettu oikeaksi.

---

## 10. Tiedostonimet, lainaus, GUI-syöte

- **Erikoismerkit** (heittomerkki, sulut, välit, ääkköset nimissä ja poluissa): kaikki muuttujat
  lainataan aina (`"$var"`), jq:lle `--arg`/`-r`, ei koskaan lainaamatonta interpolointia →
  ei rikkoutumista eikä injektiota. Testitapaukset: `Astronaut's Wife`, `Fargo (1996)`.
- **Atomisuus:** `status.json` ja jokainen `jobs/<id>.json`/`problematic/<id>.json` kirjoitetaan
  aina temp-tiedostoon samaan hakemistoon + `mv` (sama tiedostojärjestelmä → atominen rename).
  Lukija ei koskaan näe puolikasta.
- **GUI-valmius:** GUI (erillinen projekti) lukee `status.json` + `jobs/*.json` +
  `problematic/*.json` ja kutsuu ydinkomentoja (`scan/enqueue/skip/retry/config/dispatch`).
  Ei muutoksia ytimeen. Aikaleimat ISO-8601 UTC (`Z`).

---

## 11. Testaus ennen tuotantoa (pakollinen)

1. `bash -n` + `shellcheck` kaikille.
2. **Rinnakkaisuustestit stub-enkooderilla** (`sleep N; return 0/1`, ei oikeaa HandBrakea):
   - N+1 jobia N slotille → tasan N `encoding` kerrallaan.
   - **Jonon rinnakkaiskirjoitus:** monta jobia valmistuu + `enqueue` lisää samaan aikaan →
     yksikään job-tiedosto ei korruptoidu, yksikään päivitys ei katoa (per-job-mallin verifiointi).
   - **Kaatumistoipuminen:** tapa dispatcher kesken `encoding`-jobin → uudelleenkäynnistys
     palauttaa jobin `pending`:iksi, ei jää ikuiseen `encoding`-tilaan, slotti ei vuoda.
   - **Per-dest-lukko:** kaksi rinnakkaista ekstra-jobia samaan kansioon → eri numerot.
   - **Lähteen siivous täsmälleen kerran:** laukeaa vasta kun kaikki discen jobit `done/user_skip`,
     ei koskaan `pending/encoding/failed/broken` läsnä ollessa.
3. **Sisältöverifioinnin testit:** tyhjä/vajaa/katkennut tulos hylätään ennen kirjastoa; migraation
   `done`-merkintä vaatii verifioinnin.
4. **Lämpökäytös:** simuloitu WARN → STOP/CONT palautuu; KILL → job `pending`, ei `failed`.
5. Vasta läpäisyn jälkeen pieni oikea päästä-päähän-testi (1–2 levyä), sitten migraatio.

---

## 12. Yhteenveto vaatimuksista (tarkistuslista toteuttajalle)

- [ ] Ydin ei kysy mitään; kaikki tila JSONina, atomisesti (temp+mv).
- [ ] Per-job-tiedostot (ei yhtä mutable-jonotiedostoa) → ei rinnakkaiskirjoituksen kilpajuoksua.
- [ ] Yksi globaali jono; N-rinnakkaisuus yli levyrajojen; PARALLEL luettu tuoreena.
- [ ] Metadata (kesto, mitat, dar, fps, format, crop, subs, audio, read_errors) tallennettu
      rippausvaiheessa jokaiseen jobiin.
- [ ] `broken` ≠ `user_skip` ≠ `failed`; lähteen siivous vain `done`/`user_skip`.
- [ ] Dispatcherin kaatumistoipuminen (encoding→pending kuolleille).
- [ ] Scan timeout-wrapattu; timeout/READ_ERRORS>max → problematic, ei hangi/enkoodausyritys.
- [ ] Lämpö per kynnys määritelty; KILL palauttaa jobin pending, ei failed.
- [ ] Rippaus estyy jos WORK_DIR täynnä / rip-ahead-raja ylitetty.
- [ ] scan ↔ enqueue erillään; epävarma pääelokuva → confidence=low → UI vahvistaa.
- [ ] Kaikki asetukset configissa (kansiot, CRF, kynnykset), ei kovakoodattuja; ei inline-kommentteja.
- [ ] Nimien erikoismerkit lainattu kaikkialla; deterministinen uniikki id.
- [ ] Migraation lähteen poisto vaatii sisältöverifioinnin (ei pelkkä olemassaolo).
- [ ] Testit §11 läpäisty ennen tuotantoa.

---

Tämä spesifikaatio on itsenäinen: se ei edellytä vanhan koodin tuntemusta ja kelpaa sellaisenaan
uuden toteutuksen pohjaksi. Kaikki tarkastuksessa nousseet 13 riskiä on ratkaistu (per-job-tila,
broken≠skip, verifioitu siivous, kaatumistoipuminen, scan-timeout, lämpökynnykset, rip-ahead-raja,
scan/enqueue-erottelu, epävarmuuslippu, config-parsinta, nimien lainaus, atominen status/problematic,
puuttuvat kynnykset ja id-generointi).
