# DVD-rippaus- ja enkoodausjärjestelmä — täydellinen spesifikaatio (puhtaalta pöydältä)

Itsenäinen spesifikaatio: määrittelee järjestelmän vaatimuksina ja sopimuksina **viittaamatta
mihinkään olemassa olevaan koodiin**. Toteuttaja voi rakentaa kokonaan uuden toteutuksen pelkästään
tämän pohjalta. Kaikki tila-, komento-, tiedosto- ja käsittelysopimukset on määritelty täsmällisesti.

Oletustyökalut: bash + jq + python3 + HandBrakeCLI + dvdbackup + lsdvd + mkvtoolnix + ffprobe.
Vaihdettavissa kunhan §4 datamalli ja §5 komennot säilyvät.

---

## 1. Tarkoitus ja periaatteet

Rippaa DVD-levyjä, enkoodaa x265-mkv:ksi mediakirjastoon, hallitsee tätä **yhtenä globaalina
jonona** joka enkoodaa N kohdetta rinnakkain riippumatta lähdelevystä.

**Periaatteet (sitovat):**
1. **Ydin erillään käyttöliittymästä.** Ydinkomennot eivät koskaan kysy interaktiivisesti mitään
   eivätkä tulosta ihmiselle. Ne ottavat argumentit, lukevat/kirjoittavat koneluettavaa tilaa (JSON).
2. **Kaikki jaettu tila koneluettavana ja atomisesti kirjoitettuna.** Kahdesta rinnakkaisesta
   kirjoittajasta kumpikaan ei saa korruptoida tai hävittää toisen kirjoitusta.
3. **Yksi globaali enkoodausjono.** Rinnakkaisuus yli levyrajojen.
4. **Kaikki metadata kerätään ja tallennetaan kerran, rippausvaiheessa.**
5. **Viat tunnistetaan ja siirretään sivuun.** Rikkinäistä ei koskaan yritetä automaattisesti
   uudelleen; ongelmallisista pidetään ajantasaista listaa.
6. **Kaikki käyttäjää koskevat arvot (kansiot, laatu, kynnykset, rinnakkaisuus) konfiguroitavia.**
7. **Peruuttamattomat operaatiot (lähteen poisto, kirjaston ylikirjoitus) vaativat aina
   sisältöverifioinnin ennen suoritusta.** Pelkkä olemassaolo ei riitä.
8. **Mitään ei viedä tuotantoon testaamatta** (§12).

---

## 2. Atomisuus- ja lukitussopimukset (koko robustiuden perusta)

### 2.1 Atominen kirjoitus — aina samassa tiedostojärjestelmässä
`mv` on atominen VAIN saman tiedostojärjestelmän sisällä. Eri fs:n välillä se on copy+unlink →
kaatuminen kesken jättää katkenneen tiedoston. **Siksi temp-tiedosto kirjoitetaan aina samaan
hakemistoon kuin lopullinen kohde**, ja renametaan siellä.

- **STATE-tiedostot** (`$STATE` lokaalilla levyllä): temp `$STATE/…/.tmp.<id>` → `mv` samassa
  hakemistossa.
- **KIRJASTON tiedostot** (NAS, `$DEST_ROOT`): enkoodaa suoraan **kohdehakemistoon**
  `dest_dir/.tmp.<id>.mkv`, verifioi, sitten `mv dest_dir/.tmp.<id>.mkv dest_dir/out_name` —
  rename tapahtuu NAS:in **saman fs:n sisällä** → atominen. **EI koskaan mv WORK_DIR→NAS**
  (eri fs, ei atominen). Sama koskee vanhan version varmuuskopiota (§8.4).

### 2.2 Guardattu JSON-kirjoitus (ettei jq-virhe tuhoa tiedostoa)
Jokainen JSON-kirjoitus:
```
tmp="$dir/.tmp.$$"; if jq … >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then mv -f "$tmp" "$target";
else rm -f "$tmp"; <virhe, ei muuteta targettia>; fi
```
`jq`:n rc **ja** epätyhjyys (`-s`) tarkistetaan ennen mv:tä. Levy täynnä / viallinen JSON →
targetti jää koskemattomaksi. Sokeaa `mv tmp target` ei koskaan tehdä.

### 2.3 Lukot vain lokaalilla levyllä
`$STATE/locks/`, `$STATE/slots/` ja daemonin pidfile ovat **aina lokaalilla tiedostojärjestelmällä**
(ei NAS:illa). Ne vartioivat NAS-kirjoituksia, mutta itse lukot elävät lokaalisti. Kaikki
kirjoittajaprosessit jakavat saman lokaalin lukkohakemiston.

**Perustelu (tarkennettu):** lukot pidetään tarkoituksella lokaalilla fs:llä koska järjestelmä on
**yhden enkoodauskoneen koordinaattori** — se ei halua tehdä NAS:in lukitussemantiikasta toiminnan
edellytystä. Tämä ei nojaa väitteeseen "NFS/CIFS-flock on aina rikki" (Linuxin `flock` toimii
NFS:n kanssa tietyissä kokoonpanoissa; CIFS-käytös riippuu kernelistä/protokollasta/mount-optioista)
— se yksinkertaisesti EI RIIPU siitä. Kaikki koordinaatio tapahtuu lokaalisti, jolloin NAS:in
lukkokäytös on merkityksetön koko järjestelmän oikeellisuudelle.

**Advisory-luonne (rajoite, kirjattava):** `flock` on advisory — se takaa konsistenssin **vain
tätä lock-protokollaa noudattavien prosessien välillä**. Ulkopuolinen prosessi tai käsin tehty
tiedostomuutos (esim. käyttäjä luo `Episode 4.mkv` samaan aikaan kun järjestelmä varaa numeron 4)
EI ole lukkojen suojaama. Oletus: NAS-kirjaston kohdekansioita muokkaa vain tämä järjestelmä.
Ks. §14 rajoite R3.

### 2.5 Kestävyys (power-loss durability) — atominen rename ≠ pysyvä levyllä
`mv` on **atominen** (ei koskaan puolivalmista nimeä), mutta atomisuus ei takaa että data+metadata
on **pysyvästi levyllä** sähkökatkon sattuessa. Sekvenssi "kirjoita → verifioi → mv → merkitse
`done`" voi kaatua niin että tiedostojärjestelmä käynnistyy tilaan jossa job on `done` mutta tiedosto
puuttuu/on vanha. **Koska `done` antaa myöhemmin luvan poistaa lähde-VOBit (§4), tämä ei ole
hyväksyttävää.**

**Sopimus (peruuttamattomien kirjoitusten kestävyysjärjestys):**
1. kirjoita `dest_dir/.tmp.<id>.mkv`, sitten **`fsync`(tiedosto)**,
2. **`fsync`(dest_dir)** (jotta temp-nimi on pysyvä),
3. `mv` lopulliseen nimeen,
4. **`fsync`(dest_dir)** uudelleen (jotta rename on pysyvä),
5. **vasta tämän jälkeen** kirjoita `done`-tila (itsekin atomisesti+`fsync`, §2.2).

Näin `done` ei koskaan ehdi levylle ennen kohdetiedostoa. Sama järjestys koskee `BACKUP_DIR`-
varmuuskopiota ennen kirjaston korvausta. **NAS-varaus:** verkkolevyllä `fsync`in kestävyystakuu
riippuu palvelimen/protokollan asetuksista (write-back-välimuisti voi valehdella) — järjestelmä
tekee `fsync`in aina, mutta jos NAS ei kunnioita sitä, viimeinen suoja on `cleanup`in oma
sisältöverifiointi ennen lähteen poistoa (§8.5, §14 R1): lähdettä ei poisteta jos kohde ei ole
sillä hetkellä luettavissa ja verifioitavissa.

### 2.4 Numeeriset vertailut (liukuluvut) — eksplisiittinen sopimus
Anturit ja HandBrake antavat desimaaleja (`58.0`, `42.1`). Bashin `[ -gt ]` kaatuu desimaaliin.
**Sopimus: kaikki numeeriset vertailut tehdään joko awk:lla** (`awk -v a="$x" -v b="$y"
'BEGIN{exit !(a>b)}'`) **tai strippaamalla desimaalit ennen `[ ]`-vertailua** (`${x%%.*}`).
Koskee: lämpötila vs TEMP_WARN/KILL, pct, fps, kesto-toleranssi, levytila. Yksikään numeerinen
vertailu ei saa antaa desimaalin päätyä paljaaseen `[ ]`-lausekkeeseen.

---

## 3. Tila-arkkitehtuuri: per-job-tiedostot

```
$STATE/                         (STATE = paikallinen, esim. $WORK_DIR/state)
  jobs/<id>.json                Aktiiviset/valmistuvat jobit. Yksi tiedosto per työ.
  jobs/done/<id>.json           Terminaalitilan (done/user_skip) jobit arkistoituna.
  problematic/<id>.json         Viat (broken/failed pysyvästi). Per-job.
  status.json                   Live-yhteenveto (vain dispatcher kirjoittaa).
  seqfile                       flock-suojattu monotoninen jonojärjestysnumero (§5.1) — pakollinen.
  locks/<sha1(dest)>.lock       per-kohdekansio-lukko (ekstranumerointi).
  slots/slot-N.lock             rinnakkaisslotit — flock, OS vapauttaa prosessin kuollessa.
  dispatch.pid                  daemonin single-instance-lukko.
  thermal.heartbeat             lämpövahdin elossaolo-aikaleima (fail-safe, §8).
```

**Miksi per-job-tiedostot:** jobin muutos = yhden pienen tiedoston atominen korvaus (§2.2). Ei
jaettua muutettavaa jonotiedostoa → ei rinnakkaiskirjoituksen kilpajuoksua, ei "rip lisää samalla
kun dispatcher kirjoittaa" -korruptiota. Kutakin jobia muuttaa kerrallaan vain sen omistaja
(luova rip-komento tai varaava dispatcher-slotti).

**Skaalaus (jobs/ ei kasva rajatta):** kun job siirtyy terminaalitilaan (`done`/`user_skip`), se
**siirretään `jobs/done/`-alihakemistoon**. Dispatcherin O(N)-skannaus (poimi pending, tarkista
disc-valmius, laske ekstranumero, kirjoita status) kohdistuu vain aktiivisiin `jobs/*.json`:iin,
ei koko historiaan. `jobs/done/` on arkisto (statukselle/GUI:lle), ei dispatch-silmukan skannauksessa.

---

## 4. Jobin elinkaari ja tilat

`status`-enum. **Tahallinen ohitus, epäonnistuminen ja lähdevika ovat eri tiloja** (lähteen
siivouksen kannalta kriittistä):

| status      | merkitys                                            | lähde saa siivota? |
|-------------|-----------------------------------------------------|--------------------|
| `pending`   | odottaa                                             | ei                 |
| `encoding`  | dispatcher-slotti enkoodaa                          | ei                 |
| `done`      | ks. vahva määritelmä alla                           | **kyllä**          |
| `failed`    | enkoodaus epäonnistui (rc≠0 / verifiointi hylkäsi)  | ei (retry voi tarvita) |
| `broken`    | lähde viallinen (lukuvirhe/scan-hang) — ei yritetty | **ei** (retry tarvitsee lähteen) |
| `user_skip` | käyttäjä päätti ettei tehdä                         | **kyllä**          |

**`done`:n vahva määritelmä (koska se valtuuttaa lähteen poiston):** `done` tarkoittaa että
lopullinen kohdetiedosto on *olemassa, luettavissa, verifioitu (§8), ja sen sekä tiedoston tila on
kestävästi levylle kirjattu* (§2.5 fsync-järjestys). `done` EI ole pelkkä historiallinen väite
"joskus valmistui" — `cleanup` (§8.5) tekee lisäksi lähteen poiston hetkellä oman, tuoreen
sisältötarkistuksen (§14 R1), joten `done` + cleanup-recheck yhdessä muodostavat poiston ehdon,
ei `done` yksin.

**Lähteen (disc) VOB-poisto vain kun KAIKKI saman `disc_key`:n jobit ovat `done` tai
`user_skip`.** Yksikin `pending/encoding/failed/broken` estää. `retry` (failed/broken) JA `unskip`
(user_skip→pending) **molemmat edellyttävät lähteen olemassaoloa** — kumpikin epäonnistuu selkeällä
virheellä jos lähde on jo siivottu (ei ikuista pending-jumia).

### Kaatumistoipuminen — worker pitää slot-lukkoa, ei dispatcher
**Kriittinen omistajuussopimus:** slot-lukkoa (`slots/slot-N.lock`, flock) pitää **enkooderi-
worker-prosessi itse** koko enkoodauksen ajan (fd auki workerissa), EI vanhempi dispatcher. Worker
myös **kirjoittaa oman jobinsa tilasiirtymät itse** (`encoding`→`done`/`failed`, §2.2+§2.5) ja
tallettaa jobiin `pid`+`starttime` heti alkuun. Näin worker on itsenäinen: se saattaa jobin
loppuun ja commitoi tuloksen vaikka dispatcher kuolisi kesken.

Tämä ratkaisee tarkistuksen kohdan 1 (dispatcher kaatuu, enkooderi elää). **Neljä toipumistapausta,
eksplisiittiset säännöt** — dispatcher käy käynnistyessään (ja jatkuvasti) jokaisen `encoding`-jobin
läpi ja luokittelee sen slot-lukon + `pid`/`starttime`-parin perusteella:

| tilanne | slot-lukko | (pid,starttime) elossa? | toiminta |
|---------|-----------|--------------------------|----------|
| **A. dispatcher kuoli, worker elää** | varattu (worker pitää) | kyllä | **älä koske** — worker vie loppuun ja commitoi itse; dispatcher vain adoptoi seurannan (status.json) |
| **B. worker kuoli, dispatcher eli/elää** | vapaa (OS vapautti) | ei | reclaim: job → `pending`, poista `dest_dir/.tmp.<id>.mkv` |
| **C. molemmat kuolivat** | vapaa | ei | sama kuin B |
| **D. reboot** | kaikki vapaat | ei | kaikki `encoding` → `pending`, temp-tulokset poistetaan |

**Miksi (pid,starttime)-pari eikä paljas PID:** rebootin/uudelleenkäytön yli pelkkä PID valehtelisi
"elossa". Pari (PID + prosessin käynnistysaika `/proc/<pid>/stat` field 22) tunnistaa saman
prosessin luotettavasti. **Slot-lukko on ensisijainen totuus** (OS vapauttaa sen deterministisesti
prosessin kuollessa, myös rebootissa); (pid,starttime) on ristiintarkistus tapausten A/B erottamiseen
silloin kun slot-lukko sattuu olemaan vapaa mutta job vielä `encoding` (= worker kuoli). Ei nojata
pelkkään toiseen.

**Orpo-worker (tapaus A jälkinäytös):** kun adoptoitu worker lopulta valmistuu ja commitoi
jobin `done`:ksi, se on ehtinyt myös vapauttaa slot-lukon — dispatcher havaitsee vapautuneen slotin
normaalisti seuraavalla kierroksella. Ei erityiskäsittelyä tarvita, koska worker on aina oman
jobinsa ja slottinsa auktoriteetti.

---

## 5. Datamalli

### 5.1 Job: `$STATE/jobs/<id>.json`
`<id>`: deterministinen `sha1(source_abs + ":" + title)[0:12]`. **Huom tarkka merkitys:** sama
`source_abs`+titteli tuottaa saman id:n **yhden ripin sisällä**. Saman fyysisen levyn tahaton
uudelleenrippaus saa eri `disc-NNN`-polun → eri id (tarkoituksella tuore job). Duplikaattilevyn
tunnistus (jos vahinkorippaus todennäköinen) on erillinen valinnainen tarkistus (esim. levyn
volume-nimi + kestosummat), ei id:n vastuulla.

```json
{
  "id":"9f3a1c2b7e04",
  "created":"2026-08-26T09:00:00.123456789Z",  // ISO-aikaleima (info/GUI); EI jonojärjestys, ks. seq
  "seq":10427,                                  // flock-suojattu monotoninen jonojärjestys (§5.1)
  "source":"/abs/…/disc-042/VIDEO_TS",
  "disc_key":"/abs/…/disc-042",
  "title":11, "kind":"movie", "role":"main",
  "name":"Fargo", "year":"1996", "season":null, "episode":null,
  "dest_dir":"/abs/…/movies/Fargo (1996)", "out_name":"Fargo.mkv",
  "duration_s":5640, "width":712, "height":408, "dar":"1.86:1", "fps":25, "format":"PAL",
  "crop":"66:66:2:2", "subs":["fin","swe"], "audio":["eng"], "read_errors":0,
  "status":"pending", "slot":null, "pid":null, "starttime":null,
  "quality":21, "encoder":"x265",
  "started":null, "finished":null, "fail_reason":null,
  "confidence":"high", "alt_main_titles":[]
}
```
**Jonojärjestys = `seq`, flock-suojatusta `seqfile`:stä** (ei kellonaika). Perustelu (tarkistuksen
kohta 9): seinäkelloa ei taata monotoniseksi kahden rinnakkaisen `enqueue`-prosessin välillä
(NTP-korjaus, kellon hyppy, sama nanosekunti eri corella) → aikaleimapohjainen järjestys voi
poiketa siitä missä järjestyksessä käyttäjä työt aloitti. Siksi `enqueue` ottaa numeron atomisesti:
`flock seqfile` → lue nykyinen → `+1` → kirjoita (temp+mv+fsync) → vapauta. Tämä on ainoa jaettu
laskuri koko järjestelmässä ja se on aina lukon takana — **ei koskaan lukitsematonta jaettua
laskuria**. `created` on pelkkä ISO-aikaleima näyttöä/GUI:ta varten, ei järjestyskenttä.

### 5.2 Live: `$STATE/status.json` (dispatcher, temp+mv §2.2)
```json
{"updated":"…Z","parallel":2,
 "encoding":[{"id":"…","name":"Fargo","pct":42.1,"eta_s":1830,"fps":31.2,"slot":1}],
 "pending":57,"done":812,"failed":3,"broken":5,
 "queue_eta_s":41000,"temps_c":[55,58,54,56],"disk_free_gb":80}
```
**pct/fps/eta lähde:** HandBrakeCLI `--json` -edistymisvirta (rakenteinen JSON stderriin/lokiin),
josta dispatcher lukee viimeisen `Working`-objektin (`Progress`, `Rate`, `ETASeconds`). Jos
`--json`-progressia ei ole saatavilla, kentät ovat **best-effort** ja voivat olla `null` — status
ei koskaan kaadu progress-parsintaan.

### 5.3 Konfiguraatio: `$HOME/.config/rip-dvd/config`
`AVAIN=arvo` per rivi. **Ei rivinsisäisiä kommentteja.** Parsinta:
- lue `sed -n 's/^KEY=//p' | head -1`,
- **strippaa TRAILING-whitespace ja CR** (Windows-editointi): `val="${val%$'\r'}"; val="${val%%*(
  )}"` — ankkuroitu perästä, EI ensimmäisestä välilyönnistä (jotta `DIR=/mnt/my movies` säilyy).
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
BACKUP_DIR=/mnt/terastation/dlna/desync-backups   # kirjaston ULKOPUOLELLA, ei mediapalvelimen skannauksessa
BACKUP_RETENTION_DAYS=30                            # vanhat varmuuskopiot siivotaan tämän jälkeen
TEMP_WARN=85
TEMP_KILL=95
MIN_DURATION=300
READ_ERROR_MAX=20
SCAN_TIMEOUT=600
RIP_MIN_FREE_GB=40
RIP_AHEAD_MAX_GB=60                                 # rippaamatonta enkoodausvelkaa tavuissa, ei jobeissa
LOOP_INTERVAL=5
```
Ei `source` (ei suoriteta configin sisältöä koodina).

---

## 6. Ydinkomennot (ei-interaktiiviset)

- **`scan <dvd_dir>` → JSON tittelilistasta metadatoineen.** Ajaa **per-titteli** timeout-wrapatut
  skannaukset (`timeout $SCAN_TIMEOUT HandBrakeCLI -i … --title N --scan --json`) tai lsdvd-fallback,
  **jotta yksi vaurioitunut titteli ei vie kaikkien ehjien metadataa** eikä jumita koko discia.
  Yksittäisen tittelin timeout → se titteli merkitään scan-tuloksessa `broken`, muut ehjät
  palautuvat normaalisti. Palauttaa per titteli: numero, kesto, mitat, dar, fps, format, crop,
  subs[], audio[]. EI kirjoita jonoa.
- **`enqueue --source … --title … --kind … --name … [--year] [--season/--episode] --role …`** →
  luo `jobs/<id>.json` (idempotentti id:llä). Ottaa metadatan scan-tuloksesta (annettuna). Ekstran
  `out_name` lasketaan **per-dest-lukon sisällä** kirjoitushetkellä.
- **`dispatch`** (daemon): §8.
- **`status [--json]`** → tuottaa/lukee status.json.
- **`skip <id>`** → `user_skip`. **`unskip <id>`** → `pending` (**vaatii lähteen olemassaolon**,
  kuten retry).
- **`retry <id>`** → `failed|broken` → `pending` (vaatii lähteen olemassaolon).
- **`review-problematic`** → listaa `problematic/`.
- **`cleanup`** → §8.5 (per-disc-lukko + tila-recheck ennen poistoa).
- **`migrate`** → §9.

---

## 7. Rippaus + metadata + pääelokuvan tunnistus

`rip <laite>` (CLI ohjaa, ydin tekee):
1. **Levytila-esiehto (tavupohjainen, karkeuden dokumentointi):** älä rippaa jos `WORK_DIR` vapaa
   < `RIP_MIN_FREE_GB`, TAI rippaamatonta enkoodausvelkaa > `RIP_AHEAD_MAX_GB`. **Enkoodausvelka
   lasketaan per fyysinen levy (`disc_key`), EI per job** (tarkistuksen kohta 3): yksi DVD tuottaa
   monta jobia jotka viittaavat samaan `disc-NNN`-hakemistoon ja samoihin VOB-tiedostoihin — jos
   kunkin jobin lähteen koko laskettaisiin erikseen, 7 GB:n levy näyttäisi esim. 28 GB velalta ja
   estäisi rippauksen turhaan. Velka = **uniikkien `disc_key`-hakemistojen yhteiskoko** joilla on
   yhä `pending`/`failed`/`broken` jobeja (`du -sb` per disc_key kerran, ei per job).
   **Tämä on karkea vartio (TOCTOU: rinnakkaiset enkoodaustempit kirjoittavat
   samaan WORK_DIR:iin) — se vähentää, ei poista, täyttymisriskiä; dispatcher lisäksi keskeyttää
   uuden slotin avaamisen jos vapaa tila alittaa turvarajan.**
2. `dvdbackup -M` → `disc-NNN/`. Tallenna READ_ERRORS.
3. `scan` (per-titteli, timeout-wrapattu). READ_ERRORS > `READ_ERROR_MAX` tai tittelin scan-timeout
   → kyseinen titteli/levy `problematic/` (`broken`), ei jonoon.
4. Käyttöliittymä esittää tittelit + metadatan; käyttäjä vahvistaa luokittelun. **`confidence=low`
   (§ alla) → vahvistus pakollinen ennen enqueueta.**
5. `enqueue` jokaisesta enkoodattavasta tittelistä.

**Pääelokuvan tunnistus:** eksplisiittinen pää­titteli → `confidence=high`. Muuten heuristiikka
(pisin=pää) tuottaa **ehdotuksen + `confidence` + `alt_main_titles[]`**. Useampi pitkä titteli /
epäselvä rakenne → `confidence=low`, UI pyytää vahvistuksen. Ydin ei koskaan hiljaa arvaa
epävarmassa.

---

## 8. Dispatcher

- **Single-instance:** `dispatch` ottaa `flock`in `dispatch.pid`:iin heti; toinen instanssi
  poistuu virheellä. Suositellaan ajettavaksi systemd-unittina `Restart=on-failure`.
- **Pääsilmukka EI ole `set -e`:n alla** — yksittäinen glitchaava alikomento ei saa tappaa
  dispatcheria. Virheet käsitellään per-job (job → `failed`), silmukka jatkaa.
- **Slotit:** `PARALLEL` kpl `slots/slot-N.lock` (flock). PARALLEL luettu tuoreena joka kierroksella.
- **Per-dest-lukko:** ennen ekstran `out_name`-laskentaa flock `locks/<sha1(dest_dir)>.lock`.
  Tämä on **advisory** ja suojaa vain tämän järjestelmän omilta prosesseilta (§2.3, §14 R3) — ei
  ulkopuoliselta/käsin tehdyltä samanaikaiselta kirjoitukselta samaan kohdekansioon.
- **Lämpövahti = ERILLINEN riippumaton prosessi** (ei dispatch/verify/mv-silmukassa, jottei
  bloknaava NAS-mv viivästytä lämmön pollausta). Se pollaa lämpöä kiinteällä välillä ja:
  - **`TEMP_WARN`:** `kill -STOP` **enkooderi-prosessiryhmälle** (HandBrake-prosessit; ei dispatcher,
    ei lämpövahti itse), `kill -CONT` kun lämpö laskee. Palautuva, työ säilyy. `-STOP`/`-CONT`
    kohdistetaan enkooderin **prosessiryhmään** (pgid), ei yksittäiseen pid:iin — HandBrake voi
    haarauttaa aliprosesseja, ja koko ryhmän on pysähdyttävä/jatkuttava yhtenä.
  - **`TEMP_KILL`:** `kill` enkooderit; dispatcher/worker havaitsee ja **palauttaa jobin
    `pending`:iksi** (ei `failed`), poistaa temp-tulokset. Lämpö ei koskaan merkitse jobia pysyvästi
    rikki.
- **Lämpövahdin STOP-tilan reunatapaukset (tarkistuksen kohta 4):** `-STOP` pysäyttää prosessin
  välittömästi, myös kesken tiedostokirjoituksen — tämä on turvallista koska tulos on aina
  `dest_dir/.tmp.<id>.mkv` eikä lopullinen nimi (§2.1/§2.5): keskeneräinen temp ei ole koskaan
  kirjaston tiedosto, ja jos worker myöhemmin `TEMP_KILL`:ataan STOP-tilassa, temp vain poistetaan
  reclaimissa. STOP-tilassa oleva worker EI voi commitoida jobia (se on jäädytetty) → ei riskiä että
  puolivalmis menisi `done`:ksi. Jos kone sammuu STOP-tilassa: reboot-toipuminen (tapaus D) palauttaa
  jobin `pending`.
- **Lämpövahdin OMA kaatuminen (fail-safe, tarkistuksen kohta 4):** lämpövahti ei saa olla hiljainen
  yksittäinen vikapiste. Kaksi suojaa: (1) se ajetaan **omana systemd-unittina `Restart=on-failure`**
  (kuten dispatcher); (2) lämpövahti päivittää **heartbeat-aikaleiman** (`$STATE/thermal.heartbeat`,
  temp+mv) joka pollauskierroksella, ja **dispatcher tarkistaa sen ennen uuden slotin avaamista** —
  jos heartbeat on vanhentunut (esim. > 3× pollausväli), lämpösuojaa ei ole aktiivisena → dispatcher
  **ei avaa uusia enkoodaus-slotteja** ennen kuin heartbeat elpyy (fail-closed, ei fail-open). Näin
  lämpövahdin kuolema hidastaa/pysäyttää työn kasautumisen, ei jätä konetta suojattomaksi kuumenemaan.
- **Enkoodaus:** kohteeseen `dest_dir/.tmp.<id>.mkv` (sama fs kuin lopullinen, §2.1). Talleta jobiin
  `pid`+`starttime`.
- **Verifiointi ennen kirjastoon vientiä — kaksi eri asiaa (tarkistuksen kohta 5):**

  **(a) Rakenteellinen verifiointi (KOVA, hylkää `failed`:iin):** todistaa että tiedosto on ehjä ja
  sisältää odotetut raidat. Nämä ovat ehdottomia:
  - ≥ 1 videoraita ja ≥ lähteen ääniraitojen määrä läsnä,
  - `abs(tulos_kesto - duration_s) <= max(2, ceil(0.01*duration_s))` s (sallii HandBraken legitiimin
    sekuntien pudotuksen chapter/PAL-trimmauksesta, pysäyttää katkenneen/tyngän),
  - tiedosto avautuu `ffprobe`lla ilman virhettä, viimeinen paketti ~keston kohdalla (ei ennenaikaista
    loppua vaikka format-kesto sattuisi toleranssiin).
  Hylkäys → `failed`, kirjastoa ei kosketa.

  **(b) Sisältöheuristiikat (PEHMEÄ, `warnings[]`-kenttään jobiin, EI automaattihylkäys):** vihjeitä
  siitä että tulos vastaisi lähteen *odotettua* sisältöä. Näitä ei käytetä kovana porttina koska ne
  tuottavat sekä vääriä hylkäyksiä että vääriä hyväksyntöjä:
  - tekstityksen kattavuus (viimeisen tekstityksen aika vs kesto) — matala arvo voi olla joko desync/
    katkos TAI täysin laillinen harva/aikaisin loppuva tekstitys (esim. kokeellinen elokuva). Siksi
    vain varoitus, GUI:hin näkyviin, ei hylkäys.
  - odotetut kieli-/raitamäärät scan-metadatasta.

  **Mitä verifiointi EI todista (rehellinen rajoite, §14 R2):** että *oikeat* ääniraidat/kielet ovat
  mukana, että *oikea* titteli enkoodattiin (ei vaihdettu naapurititteliin samalla kestolla), eikä
  paikallista sisältöä keskeltä. Näiden todistaminen vaatisi lähdevertailun jota tässä ei tehdä —
  rakenteellinen verifiointi havaitsee **katkenneen/tyhjän/vääränmittaisen**, ei **väärää-mutta-
  oikeanmittaista**. Tämä on tietoinen rajaus, ei aukko jota luultaisiin katetuksi.
- **Kirjaston korvaus:** `mv dest_dir/.tmp.<id>.mkv dest_dir/out_name` (atominen, sama fs). Vanha
  mahdollinen korvattava → `BACKUP_DIR` (kirjaston ulkopuolella); temp+mv myös sinne. Job → `done`,
  siirrä `jobs/done/`.
- **8.5 cleanup (kilpajuoksuton):** ottaa **per-disc-lukon**, sen sisällä re-checkaa että kaikki
  discen jobit yhä `done|user_skip` (ei muuttunut esim. unskipillä), vasta sitten poistaa lähteen.
  `unskip` ottaa saman lukon → ei voi tapahtua yhtä aikaa.
- **Ekstranumerointi:** numero = olemassa olevat kohdekansiossa + jonossa olevat + 1, laskettu
  **tittelijärjestyksessä** (ei valmistumisjärjestyksessä): numero sidotaan **enqueue-hetkellä**
  tittelin järjestyksen mukaan, ei enkoodauksen kirjoitushetkellä. **Retry säilyttää saman
  numeron** (ei aukkoa). (Dokumentoitu käytös, ei määrittelemätön.)
- **Sammutus (SIGTERM):** dispatcher pyytää lopettaa uusien slottien avaamisen, antaa käynnissä
  olevien enkoodausten jatkua (tai keskeyttää → jobit `pending` toipumiselle). Määritelty: SIGTERM
  → ei uusia jobeja, käynnissä olevat jäävät toipumiselle (seuraava käynnistys palauttaa
  `encoding`→`pending`). Ei jätä katkennutta kirjastotiedostoa (temp ei ole vielä renametty).

---

## 9. Migraatio + turvallinen tilanvapautus

`migrate` (kertaluontoinen, vasta testauksen jälkeen):
1. Tuo vanhat jonorivit → `enqueue`. Metadata: **timeout-wrapattu** probe (sama scan kuin §6 — ei
   paljas scan; vaurioitunut levy → `broken`, ei jumita migraatiota).
2. Merkitse `done` **vain** ne joiden dest-tiedosto **läpäisee §8:n sisältöverifioinnin** (video+
   ääni läsnä, kesto ~ tallennettu). **Ei koskaan pelkän olemassaolon perusteella** — katkennut/
   korruptoitunut dest → `pending`, ei `done`.
3. Muut → `pending` (lähde säilyy).
4. Lähteen VOB-poisto vain disceille joiden kaikki jobit `done` (verifioitu) tai `user_skip`.
5. Vanhat rakenteet poistetaan vasta kun migraatio todettu oikeaksi.

**Duplikaattien käsittely on eksplisiittinen rajoite, ei ominaisuus (tarkistuksen kohta 10, §14 R4):**
jos olemassa oleva dest-tiedosto on ehjä JA lähde on yhä olemassa, migraatio ei muodosta uutta jobia
samalle sisällölle (dest-tiedoston läsnäolo + verifiointi ⇒ `done`, ei uudelleenenkoodausta). **Sama
elokuva kahdella eri DVD-julkaisulla, tai sama levy vahingossa kahteen kertaan ripattuna, ovat eri
`disc_key`-polkuja → järjestelmä käsittelee ne eri töinä eikä yritä yhdistää niitä.** Duplikaattien
tunnistus ja karsinta jää **tarkoituksella käyttäjän vastuulle** (valinnainen volume-nimi+kestosumma-
tarkistus, §5.1). Tätä ei luvata ratkaistuksi.

---

## 10. GUI-valmius + varmuuskopioiden retention

- **GUI** (erillinen projekti) lukee `status.json` + `jobs/*.json` + `jobs/done/*.json` +
  `problematic/*.json` ja kutsuu ydinkomentoja. Ei muutoksia ytimeen. Aikaleimat ISO-8601 UTC
  (nanosekuntitarkkuus `created`ssa).
- **Varmuuskopiot** (`BACKUP_DIR`) ovat kirjaston ULKOPUOLELLA (ei mediapalvelimen skannauksessa).
  `cleanup` poistaa `BACKUP_RETENTION_DAYS`:ää vanhemmat → ei uutta hiljaista levyntäyttöä.

---

## 11. Nimet ja lainaus
Erikoismerkit (heittomerkki `Astronaut's Wife`, sulut/välit `Fargo (1996)`, ääkköset) poluissa ja
nimissä: kaikki muuttujat lainataan aina (`"$var"`); jq:lle `--arg`/`-r`; ei lainaamatonta
interpolointia → ei rikkoutumista eikä injektiota.

---

## 12. Testaus ennen tuotantoa (pakollinen)

1. `bash -n` + `shellcheck`.
2. **Rinnakkaisuus (stub-enkooderi `sleep N; return 0/1`):** N+1 jobia → tasan N encoding;
   jobs-tiedostojen rinnakkaiskirjoitus (valmistuvat + enqueue yhtä aikaa) → ei korruptiota/hukkaa;
   per-dest-lukko → eri numerot; lähteen siivous täsmälleen kerran (vain kaikki done/user_skip).
3. **Kaatumis-/rebootтoipuminen:** tapa dispatcher kesken encoding → uudelleenkäynnistys palauttaa
   `pending` **slot-lukon perusteella** (testaa myös PID-reuse-tilanne: väärä prosessi samalla
   PID:llä ei saa estää toipumista).
4. **Atomisuus:** cross-fs-tilanne (WORK_DIR vs NAS) — varmista että kirjasto kirjoitetaan
   dest_dir-tempin kautta, ei WORK_DIR→NAS-mv:llä; jq-guard (viallinen JSON/levy täynnä ei tuhoa targettia).
5. **cleanup ↔ unskip -kilpajuoksu:** samanaikainen cleanup + unskip → lähde ei katoa unskipatulta.
6. **Verifiointi:** tyhjä/vajaa/katkennut hylätään; toleranssi sallii legitiimin sekuntien pudotuksen.
7. **Lämpö (erillinen vahti):** WARN → STOP/CONT palautuu; KILL → job `pending` (ei failed); bloknaava
   mv silmukassa EI viivästytä lämmön pollausta (vahti erillisenä prosessina).
8. **Numeeriset:** desimaaliset anturi-/fps-arvot eivät kaada vertailuja (§2.4).
9. Vasta läpäisyn jälkeen pieni oikea päästä-päähän-testi, sitten migraatio.

---

## 13. Tarkistuslista toteuttajalle (kolme tarkastuskierrosta integroitu; jäännösrajoitteet §14)

- [ ] Kirjasto kirjoitetaan dest_dir-tempin kautta (sama fs), EI WORK_DIR→NAS-mv (atomisuus).
- [ ] **Kestävyysjärjestys (§2.5): fsync(tiedosto)→fsync(dir)→mv→fsync(dir)→vasta sitten `done`.**
- [ ] **Worker (ei dispatcher) pitää slot-lukkoa ja commitoi oman jobinsa; 4 toipumistapausta (§4).**
- [ ] **Jonojärjestys flock-seqfilestä (`seq`), EI kellonaika; `created` vain näyttöä varten.**
- [ ] **Verifiointi: rakenteellinen (kova hylkäys) vs sisältöheuristiikka (pehmeä varoitus) erillään.**
- [ ] **rip-ahead-velka per `disc_key`, ei per job (ei tuplalaskentaa samasta levystä).**
- [ ] **Lämpövahdin heartbeat + dispatcherin fail-closed (ei uusia slotteja jos vahti kuollut).**
- [ ] Kaatumistoipuminen slot-lukon, ei paljaan PID:n, varassa (reboot/PID-reuse).
- [ ] Ei lukitsematonta jaettua laskuria; jonojärjestys nanosekunti-`created` (tai flock-seqfile).
- [ ] cleanup per-disc-lukko + tila-recheck; unskip vaatii lähteen (kuten retry).
- [ ] JSON-kirjoitus: jq rc + `-s` ennen mv (ei tyhjän/katkenneen mv).
- [ ] Numeeriset vertailut awk/strip-desimaali -sopimuksella (ei 50°C-bugia).
- [ ] Lämpövahti erillinen prosessi; KILL → pending; STOP kohdistuu enkooderiryhmään.
- [ ] Verifioinnin toleranssit numeerisesti määritelty (kesto ±max(2s,1%), kattavuus ≥60%).
- [ ] Daemonin single-instance (flock pidfile) + systemd Restart; pääsilmukka ei set -e.
- [ ] Progress-lähde määritelty (HandBrake --json), best-effort jos puuttuu.
- [ ] jobs/ terminaalitilat arkistoidaan jobs/done/ → dispatch skannaa vain aktiiviset.
- [ ] Config-parsinta ankkuroitu trailing-strippi + \r; ei inline-kommentteja.
- [ ] Scan per-titteli/lsdvd-fallback → yksi rikki ei vie muiden metadataa.
- [ ] Lukot lokaalilla fs:llä, ei NAS:illa.
- [ ] Ekstranumerointi tittelijärjestyksessä; retry säilyttää numeron (dokumentoitu).
- [ ] Varmuuskopiot BACKUP_DIR + retention (ei uutta levyntäyttöä).
- [ ] SIGTERM + set -e -käytös määritelty.
- [ ] Migraation probe timeout-wrapattu.
- [ ] rip-ahead tavupohjainen; TOCTOU-karkeus dokumentoitu + dispatcher-turvaraja.
- [ ] id:n idempotenssi tarkasti kuvattu (per-rip, ei uudelleenrippausten yli); duplikaattitunnistus valinnainen.

---

## 14. Tunnetut jäännösrajoitteet (tietoiset rajaukset, EI ratkaistuja aukkoja)

Rehellisyyden vuoksi: nämä eivät ole korjattuja riskejä vaan **tarkoituksellisia rajauksia**.
Toteuttajan ja käyttäjän on tunnettava ne, ettei niitä luulla katetuiksi.

- **R1 — NAS-fsyncin kestävyys ei ole järjestelmän hallinnassa.** §2.5 tekee oikean fsync-järjestyksen,
  mutta jos verkkolevy valehtelee `fsync`in kestävyydestä (write-back-cache), viimeinen suoja on
  `cleanup`in tuore sisältötarkistus ennen lähteen poistoa (§8.5). Lähdettä ei poisteta jos kohde ei
  ole sillä hetkellä luettavissa ja verifioitavissa.
- **R2 — Verifiointi on rakenteellinen, ei sisältövertaava (§8).** Havaitsee katkenneen/tyhjän/
  vääränmittaisen tuloksen, EI "väärä-mutta-oikeanmittainen" (väärä titleri samalla kestolla, väärät
  kielet, puuttuva keskiosa toleranssin sisällä). Lähdevertailua ei tehdä.
- **R3 — Lukot ovat advisory ja koordinoivat vain tämän järjestelmän prosesseja (§2.3).** Ulkopuolinen
  tai käsin tehty samanaikainen muutos NAS-kohdekansioon ei ole suojattu. Oletus: kirjastoa muokkaa
  vain tämä järjestelmä.
- **R4 — Duplikaattilevyjä ei yhdistetä (§9).** Sama teos eri julkaisuina / sama levy kahdesti ripattuna
  = eri työt. Karsinta jää käyttäjälle.
- **R5 — Optimaalista rinnakkaisuus­astetta (PARALLEL) ei voi tietää ilman mittausta kohderaudalla.**
  x265-läpimeno per lisä-slotti pienenee CPU-ydinten rajallisuuden takia; lämpöturva (erillinen vahti)
  on N:stä riippumaton, mutta hyödyllinen N mitataan, ei arvata.

---

Tämä spesifikaatio on itsenäinen eikä edellytä vanhan koodin tuntemusta. **Kolme tarkastuskierrosta
(13 + 20 + 10 riskiä) on integroitu sopimuksiksi.** En väitä että "kaikki riskit on ratkaistu" —
tunnistetut korjattavat kohdat on korjattu, ja loput ovat §14:n tietoisia, dokumentoituja rajauksia.
Ennen toteutusta erityistä huomiota vaativat aidosti arkkitehtuuritason kohdat olivat **(1) worker-
omisteinen slot-lukko + 4 toipumistapausta ja (2) fsync-kestävyysjärjestys ennen `done`:a** — molemmat
nyt §4:ssä ja §2.5:ssä.
