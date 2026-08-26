# DVD-rippaus- ja enkoodausjärjestelmä — täydellinen spesifikaatio (puhtaalta pöydältä)

Itsenäinen spesifikaatio: määrittelee järjestelmän vaatimuksina ja sopimuksina **viittaamatta
mihinkään olemassa olevaan koodiin**. Toteuttaja voi rakentaa kokonaan uuden toteutuksen pelkästään
tämän pohjalta. Kaikki tila-, komento-, tiedosto- ja käsittelysopimukset on määritelty täsmällisesti.

Oletustyökalut: bash + jq + python3 + HandBrakeCLI + dvdbackup + lsdvd + mkvtoolnix + ffprobe +
libdvdnav-pohjainen tekstitysirrotus (ffmpeg `dvdvideo`-demukseri). Vaihdettavissa kunhan §4 datamalli
ja §5 komennot säilyvät.

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
6. **Kaikki käyttäjää koskevat arvot (kansiot, laatu, kynnykset, rinnakkaisuus, raitapolitiikka)
   konfiguroitavia.**
7. **Peruuttamattomat operaatiot (lähteen poisto, kirjaston ylikirjoitus) vaativat aina
   sisältöverifioinnin ennen suoritusta.** Pelkkä olemassaolo ei riitä.
8. **Mitään ei viedä tuotantoon testaamatta** (§12).

---

## 2. Atomisuus- ja lukitussopimukset (koko robustiuden perusta)

### 2.1 Atominen kirjoitus — aina samassa tiedostojärjestelmässä
`mv` on atominen VAIN saman tiedostojärjestelmän sisällä (myös **hakemistojen välillä** kunhan sama
fs). Eri fs:n välillä se on copy+unlink → kaatuminen kesken jättää katkenneen tiedoston. **Siksi
temp-tiedosto kirjoitetaan aina samaan tiedostojärjestelmään kuin lopullinen kohde.**

- **STATE-tiedostot** (`$STATE`, lokaali levy): temp samassa hakemistossa → `mv`.
- **KIRJASTON tiedostot** (NAS, `$DEST_ROOT`): enkoodaa **erilliseen työhakemistoon
  `$DEST_ROOT/.tmp/<id>.mkv`** (sama fs kuin kirjasto, mutta **yksi selkeästi skannauksen ulkopuolelle
  rajattava hakemisto**, EI kohdekansion sisään — ks. kohta 4 alla). Verifioi, sitten
  `mv "$DEST_ROOT/.tmp/<id>.mkv" "dest_dir/out_name"` — cross-dir-rename **saman fs:n sisällä** →
  atominen. **EI koskaan mv WORK_DIR→NAS** (eri fs, ei atominen). Sama koskee vanhan version
  varmuuskopiota `$BACKUP_DIR`:iin.
- **Miksi ei kohdekansion sisään:** `dest_dir/.tmp.<id>.mkv` olisi kirjaston sisällä koko
  enkoodauksen ajan, ja kaikki mediapalvelimet eivät ohita pistealkuisia tiedostoja → puolivalmis
  mkv voisi näkyä indeksoituna. `$DEST_ROOT/.tmp/` on yksi hakemisto joka rajataan mediapalvelimen
  skannauksesta (esim. Jellyfin "ignore"-sääntö / `.ignore`), jolloin kirjaston kohdekansiot pysyvät
  puhtaina. Sama syy kuin `$BACKUP_DIR`:ille (§10).

### 2.2 Kanoninen guardattu+kestävä JSON-kirjoitus (YKSI funktio, fsync sisällä)
**Kaikki** JSON-tilakirjoitukset käyttävät samaa funktiota — ei kahta eri reseptiä. Näin
kestävyystakuu (§2.5) ei koskaan jää pois `done`-kirjoituksesta unohduksen takia:
```
write_json_atomic(target, json_producer):
  dir=$(dirname target); tmp=$(mktemp "$dir/.tmp.XXXXXX")   # mktemp: uniikki myös rinnakkaisille aliprosesseille
  if json_producer >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      fsync "$tmp"; mv -f "$tmp" "$target"; fsync "$dir"     # data + rename pysyvästi levylle
  else
      rm -f "$tmp"; return 1   # jq-virhe / levy täynnä → target koskematon
  fi
```
- `mktemp` (EI `.tmp.$$`) — `$$` ei muutu aliprosesseissa (vain `$BASHPID`) → törmäys ja
  haamutiedostot rebootissa. Uniikki nimi ratkaisee molemmat.
- `jq`:n rc **ja** epätyhjyys (`-s`) tarkistetaan ennen `mv`:tä → sokeaa `mv tmp target` ei koskaan.
- `fsync` tiedostolle ja hakemistolle sisältyy funktioon → jokainen tilakirjoitus on kestävä.

### 2.3 Lukot vain lokaalilla levyllä
`$STATE/locks/`, `$STATE/slots/` ja daemonin pidfile ovat **aina lokaalilla tiedostojärjestelmällä**
(ei NAS:illa). Ne vartioivat NAS-kirjoituksia, mutta itse lukot elävät lokaalisti.

**Perustelu (liennytetty):** lukot pidetään tarkoituksella lokaalilla fs:llä koska järjestelmä on
**yhden enkoodauskoneen koordinaattori** — se ei halua tehdä NAS:in lukitussemantiikasta toiminnan
edellytystä. Tämä EI nojaa väitteeseen "NFS/CIFS-flock on aina rikki" (Linuxin `flock` toimii NFS:n
kanssa tietyissä kokoonpanoissa; CIFS-käytös riippuu kernelistä/protokollasta/mount-optioista) — se
yksinkertaisesti EI RIIPU siitä. Kaikki koordinaatio tapahtuu lokaalisti, jolloin NAS:in lukkokäytös
on merkityksetön oikeellisuudelle.

**Advisory-luonne (rajoite, §14 R3):** `flock` on advisory — konsistenssi vain **tätä lock-protokollaa
noudattavien prosessien** välillä. Ulkopuolinen/käsin tehty muutos kohdekansioon (esim. käyttäjä luo
`Episode 4.mkv` samaan aikaan kun järjestelmä varaa numeron 4) EI ole suojattu. Oletus: kirjastoa
muokkaa vain tämä järjestelmä.

### 2.4 Numeeriset vertailut ja yksikkömuunnokset — eksplisiittinen sopimus
Anturit/HandBrake antavat desimaaleja (`58.0`, `42.1`); bashin `[ -gt ]` kaatuu desimaaliin. **Sopimus:
kaikki numeeriset vertailut awk:lla** (`awk -v a="$x" -v b="$y" 'BEGIN{exit !(a>b)}'`) **tai
strippaamalla desimaalit ennen `[ ]`** (`${x%%.*}`). Koskee: lämpötila, pct, fps, kesto-toleranssi,
levytila. Yksikään desimaali ei päädy paljaaseen `[ ]`-lausekkeeseen.

**Yksikkömuunnokset (eksplisiittiset, ei implisiittisiä):** kaikki `*_GB`-konfiguraatiot ovat
gigatavuja; kaikki mittaus (`du -sb`, `df --output=avail -B1`) on **tavuja**. Vertailu tehdään aina
tavuissa: `raja_tavua = GB * 1073741824`, ja verrataan mitattuun tavumäärään awk:lla. **Missään ei
verrata GB-lukua suoraan tavumäärään.** (Ilman muunnosta esim. `RIP_AHEAD_MAX_GB=60` verrattaisiin
`du -sb`-tavuihin → 60 tavun raja ylittyisi aina, rippaus estyisi pysyvästi.)

### 2.5 Kestävyys (power-loss durability) — atominen rename ≠ pysyvä levyllä
`mv` on **atominen** (ei koskaan puolivalmista nimeä), mutta ei takaa että data+metadata on
**pysyvästi levyllä** sähkökatkossa. Sekvenssi "kirjoita → verifioi → mv → merkitse `done`" voi kaatua
niin että fs käynnistyy tilaan jossa job on `done` mutta tiedosto puuttuu/on vanha. **Koska `done`
valtuuttaa lähde-VOBien poiston (§4), tämä ei ole hyväksyttävää.**

**Sopimus (peruuttamattomien kirjoitusten kestävyysjärjestys):**
1. kirjoita `$DEST_ROOT/.tmp/<id>.mkv`, **`fsync`(tiedosto)**,
2. **`fsync`($DEST_ROOT/.tmp)**,
3. `mv` lopulliseen nimeen kohdekansioon,
4. **`fsync`(dest_dir)** (rename pysyväksi),
5. **vasta sitten** `done`-tila §2.2:n kanonisella (fsync-sisältävällä) kirjoituksella.

Näin `done` ei koskaan ehdi levylle ennen kohdetiedostoa. Sama järjestys `$BACKUP_DIR`-varmuuskopiolle.
**NAS-varaus (§14 R1):** jos verkkolevy valehtelee `fsync`in kestävyydestä, viimeinen suoja on
`cleanup`in tuore sisältötarkistus ennen lähteen poistoa (§8.6).

### 2.6 Per-job-kirjoitussopimus (CAS) — kaikki jobin kirjoittajat, ei vain worker
`jobs/`-mallin lupaus "yhtä jobia muuttaa vain omistaja" **ei toteudu ilman valvontaa**, koska myös
CLI-komennot (`skip`/`unskip`/`retry`) ja dispatcher/worker kirjoittavat samaan jobiin. Ilman lukkoa
`skip <id>` voisi osua samaan hetkeen kun worker asettaa `encoding` → viimeinen kirjoittaja voittaa,
job voisi jäädä `user_skip`:iin enkoodauksen jatkuessa — ja `user_skip` valtuuttaa lähteen poiston.
Tämä on juuri se kilpajuoksuluokka jonka per-job-malli piti poistaa.

**Sopimus:** jokainen jobin tilamuutos tehdään **per-job-flockin** (`$STATE/locks/job-<id>.lock`)
sisällä lyhyenä read-modify-write-operaationa. Lukkoa EI pidetä koko enkoodauksen ajan — vain itse
JSON-päivityksen ajan. Konkreettiset säännöt:
- **Worker alussa:** flock → jos status yhä `pending`, aseta `encoding`+`pid`+`pgid`+`starttime`,
  `rev`++ → unlock. Enkoodaa (pitkä, ei lukkoa). **Commit:** flock → jos `skip_requested` asetettu
  (ks. alla) TAI status ei enää `encoding`, keskeytä (poista temp, aseta `user_skip`/reclaim
  sääntöjen mukaan); muuten aseta `done`/`failed` → unlock.
- **skip:** flock → jos `pending`: suoraan `user_skip`. Jos `encoding`: aseta `skip_requested=true`
  (EI suoraan `user_skip`); worker havaitsee commitissa ja keskeyttää siististi → `user_skip`. Näin
  enkoodaus ei koskaan jatku "kummituksena" user_skip-tilan rinnalla.
- **unskip/retry:** flock → tilasiirtymä sääntöjen mukaan (vaatii lähteen, §4), `rev`++.
- **rev-kenttä** on monotoninen versionumero jokaisessa jobissa — GUI ja testit voivat havaita
  muutokset; flock takaa serialisoinnin, rev tekee muutokset havaittaviksi.

---

## 3. Tila-arkkitehtuuri: per-job-tiedostot (yksi tiedosto per job, sijainti = tilaluokka)

```
$STATE/                         (STATE = paikallinen, esim. $WORK_DIR/state)
  jobs/<id>.json                pending / encoding
  problematic/<id>.json         failed / broken   (SIIRRETTY tänne, EI kopio — §4)
  jobs/done/<id>.json           done / user_skip  (arkisto)
  counters.json                 tilalaskurit {pending,encoding,failed,broken,done,user_skip}
  status.json                   live-yhteenveto (vain dispatcher kirjoittaa)
  seqfile                       flock-suojattu monotoninen jonojärjestysnumero (§5.1) — pakollinen
  locks/job-<id>.lock           per-job read-modify-write -lukko (§2.6)
  locks/dest-<sha1(dest)>.lock  per-kohdekansio-lukko (ekstranumerointi)
  locks/disc-<sha1(key)>.lock   per-disc-lukko (cleanup ↔ unskip/retry, §8.6)
  locks/counters.lock           counters.json-päivitys
  slots/slot-N.lock             rinnakkaisslotit (flock; N = 1..PARALLEL_MAX kova katto)
  dispatch.pid                  daemonin single-instance-lukko
  thermal.heartbeat             lämpövahdin elossaolo-aikaleima (fail-safe, §8)
```

**Yksi totuus per job:** jobin record on **täsmälleen yhdessä** hakemistossa, tilaluokan mukaan.
`problematic/` EI ole kopio `jobs/`:sta (tarkistuksen kohta 14) vaan se paikka jossa failed/broken-job
*asuu*. Tilasiirtymä joka ylittää luokkarajan (esim. `pending`→`broken` tai `encoding`→`done`):
1. kirjoita uuden sijainnin tiedosto (§2.2 guardattu+fsync),
2. poista vanhan sijainnin tiedosto.
Kaatuminen näiden välissä → **käynnistyksen reconcile** pitää *terminaalisimman* (prioriteetti
`jobs/done` > `problematic` > `jobs`) ja poistaa toisen.

**Miksi per-job-tiedostot:** jobin muutos = yhden pienen tiedoston atominen korvaus (§2.2). Ei jaettua
muutettavaa jonotiedostoa → ei rinnakkaiskirjoituksen kilpajuoksua.

**Skaalaus:** dispatch-silmukka skannaa vain `jobs/` (pending/encoding + karanteeniin jäävät
failed/broken jotka se ohittaa halvasti). done/user_skip on arkistoitu `jobs/done/`:iin pois skannista.
Laskurit luetaan `counters.json`:sta — **status ei koskaan skannaa `jobs/done/`:ia** (muuten
arkistointi palauttaisi O(N):n takaisin, tarkistuksen kohta 6a).

---

## 4. Jobin elinkaari ja tilat

| status      | sijainti      | merkitys                                            | lähde saa siivota? |
|-------------|---------------|-----------------------------------------------------|--------------------|
| `pending`   | jobs/         | odottaa                                             | ei                 |
| `encoding`  | jobs/         | worker-slotti enkoodaa                              | ei                 |
| `done`      | jobs/done/    | ks. vahva määritelmä alla                           | **kyllä**          |
| `failed`    | problematic/  | enkoodaus epäonnistui (rc≠0 / verifiointi hylkäsi)  | ei (retry voi tarvita) |
| `broken`    | problematic/  | lähde viallinen (lukuvirhe/scan-hang) — ei yritetty | **ei** (retry tarvitsee lähteen) |
| `user_skip` | jobs/done/    | käyttäjä päätti ettei tehdä                         | **kyllä**          |

**`done`:n vahva määritelmä (koska se valtuuttaa lähteen poiston):** lopullinen kohdetiedosto on
*olemassa, luettavissa, verifioitu (§8.4), ja sen sekä jobin tila on kestävästi levylle kirjattu*
(§2.5). `done` EI ole pelkkä historiallinen väite — `cleanup` (§8.6) tekee lähteen poiston hetkellä
lisäksi oman tuoreen sisältötarkistuksen (§14 R1). `done` + cleanup-recheck yhdessä ovat poiston ehto,
ei `done` yksin.

**Lähteen (disc) VOB-poisto vain kun KAIKKI saman `disc_key`:n jobit ovat `done` tai `user_skip`.**
Yksikin `pending/encoding/failed/broken` estää. `retry` (failed/broken→pending) JA `unskip`
(user_skip→pending) **molemmat edellyttävät lähteen olemassaoloa** — kumpikin epäonnistuu selkeällä
virheellä jos lähde on jo siivottu (ei ikuista pending-jumia).

### Kaatumistoipuminen — worker pitää slot-lukkoa, ei dispatcher
**Omistajuussopimus:** slot-lukkoa (`slots/slot-N.lock`, flock) pitää **enkooderi-worker-prosessi
itse** koko enkoodauksen ajan (fd auki workerissa), EI vanhempi dispatcher. Worker myös kirjoittaa
oman jobinsa tilasiirtymät (§2.6). Näin worker on itsenäinen: se saattaa jobin loppuun ja commitoi
tuloksen vaikka dispatcher kuolisi kesken (tarkistuksen kohta 1).

**Neljä toipumistapausta** — dispatcher käy käynnistyessään ja jatkuvasti jokaisen `encoding`-jobin
läpi ja luokittelee sen slot-lukon + `(pid,starttime)`-parin perusteella:

| tilanne | slot-lukko | (pid,starttime) elossa? | toiminta |
|---------|-----------|--------------------------|----------|
| **A. dispatcher kuoli, worker elää** | varattu (worker pitää) | kyllä | **älä koske** — worker commitoi itse; dispatcher vain adoptoi seurannan |
| **B. worker kuoli, dispatcher elää** | vapaa (OS vapautti) | ei | reclaim: job → `pending`, poista `$DEST_ROOT/.tmp/<id>.mkv` |
| **C. molemmat kuolivat** | vapaa | ei | sama kuin B |
| **D. reboot** | kaikki vapaat | ei | kaikki `encoding` → `pending`, temp-tulokset poistetaan |

**Miksi (pid,starttime) eikä paljas PID:** rebootin/uudelleenkäytön yli pelkkä PID valehtelisi.
Pari (PID + käynnistysaika `/proc/<pid>/stat` field 22) tunnistaa saman prosessin. **Slot-lukko on
ensisijainen totuus** (OS vapauttaa deterministisesti); (pid,starttime) erottaa A/B kun slot-lukko
sattuu vapaaksi mutta job vielä `encoding`.

---

## 5. Datamalli

### 5.1 Job: `$STATE/{jobs|problematic|jobs/done}/<id>.json`
`<id>`: **titteli-job** `sha1(source_abs + ":" + title)[0:12]`. **Levytason** ongelma (koko levy
luettavissa-kelvoton, ei titteliä → ei title-id:tä, tarkistuksen kohta 14): `id = "disc:"+sha1(disc_key)[0:12]`,
`title=null`, `status=broken`, `problematic/`:ssa — antaa levytason vialle identiteetin.

**Idempotenssi (tarkistuksen kohta 7):** `enqueue` tarkistaa id:n **kaikista kolmesta hakemistosta**
(jobs/, problematic/, jobs/done/). Jos id on jo olemassa: oletus **kieltäydy** (rc≠0, ei hiljaista
päällekirjoitusta); `--force` sallii uudelleenluonnin (nollaa tilan `pending`, säilyttää `seq`:n jos
on). Sama id ei koskaan päädy kahteen hakemistoon yhtä aikaa.

**Huom id:n tarkka merkitys:** sama `source_abs`+titteli → sama id **yhden ripin sisällä**. Fyysisen
levyn tahaton uudelleenrippaus saa eri `disc-NNN`-polun → eri id. Duplikaattilevyn tunnistus (§14 R4)
on erillinen valinnainen tarkistus, ei id:n vastuulla.

```json
{
  "id":"9f3a1c2b7e04",
  "seq":10427,                                  // flock-suojattu monotoninen jonojärjestys (§5.1)
  "rev":3,                                       // monotoninen versionumero (§2.6 CAS)
  "created":"2026-08-26T09:00:00Z",              // ISO-aikaleima (info/GUI); EI jonojärjestys
  "source":"/abs/…/disc-042/VIDEO_TS",
  "disc_key":"/abs/…/disc-042",
  "title":11, "kind":"movie", "role":"main",
  "name":"Fargo", "year":"1996", "season":null, "episode":null,
  "dest_dir":"/abs/…/movies/Fargo (1996)", "out_name":"Fargo.mkv",
  "duration_s":5640, "width":712, "height":408, "dar":"1.86:1", "fps":25, "format":"PAL",
  "interlaced":false, "crop":"66:66:2:2",
  "src_subs":["fin","swe"], "src_audio":["eng","eng-commentary"],
  "want_subs":["fin","swe"], "want_audio":["eng"],   // raitapolitiikasta johdettu (§8.3)
  "read_errors":0,
  "status":"pending", "slot":null, "pid":null, "pgid":null, "starttime":null,
  "skip_requested":false,
  "quality":21, "encoder":"x265", "audio_codec":"copy", "deinterlace":"auto",
  "started":null, "finished":null, "fail_reason":null, "warnings":[],
  "confidence":"high", "alt_main_titles":[]
}
```
**`pgid`** talletetaan jotta lämpövahti tietää minkä prosessiryhmän `-STOP`/`-CONT`aa (tarkistuksen
kohta 9). **`want_audio`/`want_subs`** ovat raitapolitiikan (§8.3) tulos — verifiointi (§8.4) johtaa
odotetun raitamäärän NÄISTÄ, ei lähteen raitamäärästä (tarkistuksen kohta 13).

**Jonojärjestys = `seq`, flock-suojatusta `seqfile`:stä** (ei kellonaika). `enqueue`: `flock seqfile`
→ lue → `+1` → kirjoita (§2.2) → vapauta. Ainoa jaettu laskuri, aina lukon takana. `created` on pelkkä
näyttöaikaleima.

### 5.2 Live: `$STATE/status.json` (dispatcher, §2.2)
```json
{"updated":"…Z","parallel":2,
 "encoding":[{"id":"…","name":"Fargo","pct":42.1,"eta_s":1830,"fps":31.2,"slot":1}],
 "pending":57,"encoding_n":2,"done":812,"failed":3,"broken":5,
 "quarantine_gb":41,                                // failed+broken-lähteiden koko (§7, erillään velasta)
 "encode_debt_gb":22,                               // vain pending/encoding-lähteet (rip-ahead-mittari)
 "queue_eta_s":41000,"temps_c":[55,58,54,56],
 "disk_free_work_gb":80,"disk_free_dest_gb":540,"thermal_ok":true}
```
Laskurit `counters.json`:sta (ei `jobs/done/`-skannausta). **pct/fps/eta lähde:** HandBrakeCLI
`--json`-edistymisvirta (viimeinen `Working`-objekti: `Progress`, `Rate`, `ETASeconds`); jos puuttuu,
kentät `null` — status ei koskaan kaadu progress-parsintaan.

### 5.3 Konfiguraatio: `$HOME/.config/rip-dvd/config`
`AVAIN=arvo` per rivi. **Ei rivinsisäisiä kommentteja** (parseri ei poistaisi niitä → arvoon jäisi
roskaa). Kommentit vain omilla `#`-alkuisilla riveillään. Parsinta: `sed -n 's/^KEY=//p' | head -1`,
sitten **trailing-whitespace + CR** ankkuroituna perästä (EI ensimmäisestä välilyönnistä, jotta
`DIR=/mnt/my movies` säilyy): `val="${val%$'\r'}"; val="${val%%+([[:space:]])}"`.
```
# --- rinnakkaisuus ja laatu ---
PARALLEL=2
PARALLEL_MAX=4
CRF=21
ENCODER=x265
# --- raitapolitiikka (§8.3) ---
AUDIO_POLICY=original+commentary
AUDIO_CODEC=copy
SUB_POLICY=all
DEINTERLACE=auto
# --- kansiot ---
DEST_ROOT=/mnt/terastation/dlna/vids
DIR_MOVIES=movies
DIR_SERIES=series
DIR_DOCS=documentaries
DIR_MUSIC=music
DIR_MISC=misc
WORK_DIR=/home/keitsi/dvd-rip-tmp
# BACKUP_DIR: kirjaston ULKOPUOLELLA, ei mediapalvelimen skannauksessa
BACKUP_DIR=/mnt/terastation/dlna/desync-backups
BACKUP_RETENTION_DAYS=30
# --- lämpö ---
TEMP_WARN=85
TEMP_KILL=95
# --- kynnykset (kaikki *_GB gigatavuja, §2.4) ---
MIN_DURATION=300
READ_ERROR_MAX=20
SCAN_TIMEOUT=600
RIP_MIN_FREE_GB=40
DEST_MIN_FREE_GB=20
# RIP_AHEAD_MAX_GB: rippaamatonta enkoodausVELKAA gigatavuina (vain pending/encoding, §7)
RIP_AHEAD_MAX_GB=60
QUARANTINE_MAX_GB=100
LOOP_INTERVAL=5
```
Ei `source` (ei suoriteta configin sisältöä koodina).

---

## 6. Ydinkomennot (ei-interaktiiviset)

- **`scan <dvd_dir>`** → JSON tittelilistasta. **Per-titteli** timeout-wrapatut skannaukset
  (`timeout $SCAN_TIMEOUT HandBrakeCLI -i … --title N --scan --json`) tai lsdvd-fallback → yksi
  vaurioitunut titteli ei vie ehjien metadataa eikä jumita discia. Yksittäisen tittelin timeout → se
  titteli `broken` scan-tuloksessa, muut palautuvat. Per titteli: numero, kesto, mitat, dar, fps,
  format, **interlaced-lippu**, crop, src_subs[], src_audio[]. EI kirjoita jonoa.
- **`enqueue --source … --title … --kind … --name … [--year] [--season/--episode] --role … [--force]`**
  → luo `jobs/<id>.json`. Idempotenssi kaikkien kolmen hakemiston yli (§5.1). Johtaa `want_audio`/
  `want_subs` raitapolitiikasta (§8.3). Ekstran `out_name` per-dest-lukossa kirjoitushetkellä.
- **`dispatch`** (daemon): §8.
- **`status [--json]`** → status.json.
- **`skip <id>`** → §2.6 (pending→user_skip suoraan; encoding→skip_requested).
- **`unskip <id>`** / **`retry <id>`** → →`pending` (**vaatii lähteen**, per-disc-lukko §8.6).
- **`review-problematic`** → listaa `problematic/` (yksi totuus, ei erillistä kopiota).
- **`ack-quarantine <id|disc>`** → kuittaa karanteenilevyn: poistaa sen velka-/karanteenimittarista ja
  vapauttaa lähteen poistettavaksi (käyttäjän eksplisiittinen päätös, §7/§14).
- **`cleanup`** → §8.6.
- **`migrate`** → §9.

---

## 7. Rippaus + levytila + pääelokuvan tunnistus

`rip <laite>`:
1. **Levytila-esiehdot (tavupohjaiset, §2.4-muunnos):** älä rippaa jos
   - `WORK_DIR` vapaa < `RIP_MIN_FREE_GB`, TAI
   - **enkoodausvelka > `RIP_AHEAD_MAX_GB`**. Velka = **uniikkien `disc_key`-hakemistojen yhteiskoko
     joilla on `pending`/`encoding`-jobeja** (`du -sb` per disc_key **kerran**, ei per job —
     7 GB:n levy ei saa näyttää 28 GB velalta, tarkistuksen kohta 3). **failed/broken EIVÄT ole
     velkaa** vaan karanteenia (ks. alla, tarkistuksen kohta 11).
   Karkea vartio (TOCTOU: rinnakkaiset enkoodaustempit samaan `$DEST_ROOT/.tmp`:iin) — vähentää, ei
   poista, täyttymisriskiä; dispatcher lisäksi valvoo `DEST_MIN_FREE_GB` (§8.1).
2. **Karanteeni erillään velasta:** failed/broken-lähteitä ei siivota (retry tarvitsee ne) eikä
   yritetä automaattisesti uudelleen — mutta ne EIVÄT saa hiljaa syödä `RIP_AHEAD_MAX_GB`:tä ja estää
   rippausta ilman näkyvää syytä (tämä olisi alkuperäinen 270 GB -ongelma uudessa asussa). Siksi:
   karanteeni on **oma mittari** `quarantine_gb` (status.json), ja jos se ylittää `QUARANTINE_MAX_GB`,
   `rip`/`status` **varoittaa näkyvästi** ja pyytää käyttäjää joko `retry`- tai `ack-quarantine`-
   käsittelyyn. Karanteenia ei poisteta automaattisesti (ei hiljaista datahävikkiä), mutta se ei myöskään
   jää näkymättömäksi lattiaksi.
3. `dvdbackup -M` → `disc-NNN/`. Tallenna READ_ERRORS.
4. `scan` (per-titteli, timeout). READ_ERRORS > `READ_ERROR_MAX` tai scan-timeout → titteli/levy
   `broken` (`problematic/`), ei jonoon. Koko levyn lukukelvottomuus → levytason `disc:`-broken (§5.1).
5. UI esittää tittelit+metadatan; käyttäjä vahvistaa. **`confidence=low` → vahvistus pakollinen.**
6. `enqueue` jokaisesta enkoodattavasta tittelistä.

**Pääelokuvan tunnistus:** eksplisiittinen pää­titteli → `confidence=high`. Muuten heuristiikka
(pisin=pää) → **ehdotus + `confidence` + `alt_main_titles[]`**. Useampi pitkä / epäselvä →
`confidence=low`, UI pyytää vahvistuksen. Ydin ei koskaan hiljaa arvaa epävarmassa.

---

## 8. Dispatcher

### 8.1 Silmukka, slotit, levytila
- **Single-instance:** `flock` `dispatch.pid`:iin heti; toinen instanssi poistuu virheellä. systemd
  `Restart=on-failure`.
- **Pääsilmukka EI `set -e`:n alla** — glitchaava alikomento ei tapa dispatcheria; virheet per-job
  (`failed`), silmukka jatkaa.
- **Slotit — PARALLEL-laskun kestävä logiikka (sivuhuomio):** slot-pool on `slot-1..slot-PARALLEL_MAX`
  (kova katto). Uuden jobin saa aloittaa **vain jos tällä hetkellä pidettyjen slot-lukkojen määrä <
  `PARALLEL`** (luettu tuoreena joka kierroksella). Näin PARALLELin lasku 2:een silloin kun slotit 3–4
  ovat workereiden hallussa EI johda siihen että dispatcher laskee slotit 1–2 vapaiksi ja käynnistää
  kaksi lisää (→ 4 rinnakkaista). Pidetty-määrä lasketaan yrittämällä ei-blokkaavaa flockia jokaiseen
  pool-slottiin; jo varatut jäävät workereille. Rinnakkaisuus laskee asteittain sitä mukaa kun
  käynnissä olevat valmistuvat.
- **Levytila ennen slotin avaamista:** älä avaa uutta slottia jos `WORK_DIR` vapaa < `RIP_MIN_FREE_GB`
  **tai `DEST_ROOT` vapaa < `DEST_MIN_FREE_GB`** (tarkistuksen kohta 10 — temp on nyt NAS:illa
  `$DEST_ROOT/.tmp`, joten NAS:in täyttyminen kaataisi jokaisen enkoodauksen → failed → velka kasvaa).

### 8.2 Lämpövahti = ERILLINEN riippumaton prosessi
Ei dispatch/verify/mv-silmukassa (jottei blokkaava NAS-mv viivästytä pollausta). Pollaa lämpöä
kiinteällä välillä, lukee kohteena olevat `pgid`:t `encoding`-jobeista (§5.1):
- **`TEMP_WARN`:** `kill -STOP` enkooderien **prosessiryhmille** (pgid; ei dispatcher, ei vahti itse),
  `-CONT` kun lämpö laskee. Palautuva. Ryhmä (ei yksittäinen pid), koska HandBrake haarauttaa.
- **`TEMP_KILL`:** `kill` enkooderit; worker/dispatcher havaitsee → job `pending` (ei failed), temp
  poistetaan. Lämpö ei koskaan merkitse jobia pysyvästi rikki.
- **STOP-reunatapaukset:** `-STOP` kesken kirjoituksen on turvallista — tulos on aina
  `$DEST_ROOT/.tmp/<id>.mkv` (ei lopullinen nimi); jäädytetty worker ei voi commitoida → puolivalmis
  ei mene `done`:ksi; TEMP_KILL STOP-tilassa → temp vain poistetaan reclaimissa; sammutus STOP-tilassa
  → reboot-toipuminen (tapaus D) → `pending`.

**Lämpövahdin OMA kaatuminen (fail-safe, tarkistuksen kohta 8 — suojaa MYÖS käynnissä olevat):**
kaksi kynnystä heartbeatin (`$STATE/thermal.heartbeat`) iälle:
- **Vanhentuma > 3× pollausväli:** dispatcher **ei avaa uusia slotteja** (fail-closed).
- **Vanhentuma > 6× pollausväli:** lämpösuojaa ei tosiasiassa ole, ja **käynnissä olevat kaksi x265:tä
  jatkuvat suojaamatta** — juuri se tilanne jota vastaan mekanismi on. Silloin **dispatcher ottaa
  lämpöpollauksen itse hoitaakseen** (varamekanismi: lukee lämmöt, `-STOP`aa enkooderiryhmät jos
  `TEMP_WARN` ylittyy) kunnes erillinen vahti (systemd `Restart=on-failure`) elpyy. Fail-closed EI
  koske vain uusia slotteja vaan johtaa aktiiviseen suojaan olemassa oleville.

### 8.3 Raitapolitiikka (tarkistuksen kohta 13)
`enqueue` johtaa `want_audio`/`want_subs` configin politiikasta, EI ota sokeasti kaikkia:
- `AUDIO_POLICY`: `original` | `original+commentary` | `all` — valitsee ääniraidat kielen/roolin
  mukaan scan-metadatasta.
- `AUDIO_CODEC`: `copy` (oletus, häviötön) tai transkoodaus (esim. `ac3`/`aac`) jos määritelty.
- `SUB_POLICY`: `all` | kielilista — VobSub-tekstitykset (ks. §8.5).
- `DEINTERLACE`: `auto` (HandBrake `decomb`, laukeaa vain lomitetuille kentille) | `off` | `on`.
  DVD (PAL/NTSC) on usein lomitettu/telecinattu → oletus `auto` on laadun kannalta olennainen.

### 8.4 Verifiointi ennen kirjastoon vientiä — rakenteellinen vs sisältö
**(a) Rakenteellinen (KOVA, hylkää `failed`):**
- ≥ 1 videoraita ja **`want_audio`-politiikan mukainen määrä** ääniraitoja läsnä (EI "≥ lähteen
  audio" — jos politiikka valitsee 1 raidan, odotus on 1, muuten jokainen job hylättäisiin turhaan,
  tarkistuksen kohta 13),
- `abs(tulos_kesto - duration_s) <= max(2, ceil(0.005*duration_s))` s (0,5 % — 5640 s elokuvalla
  ~28 s; tiukempi kuin 1 % jotta tynkä ei livahda toleranssiin, sivuhuomio),
- `ffprobe` avaa ilman virhettä; viimeinen paketti ~keston kohdalla (ei ennenaikaista loppua vaikka
  format-kesto sattuisi toleranssiin).
Hylkäys → `failed`.

**(b) Sisältöheuristiikat (PEHMEÄ, `warnings[]`-kenttään, EI automaattihylkäys):**
- tekstityksen kattavuus (viimeisin sub-aika vs kesto) — matala arvo voi olla desync/katkos TAI
  laillinen harva/aikaisin loppuva tekstitys → vain varoitus.
- odotetut kielet/raitamäärät.

**Mitä verifiointi EI todista (§14 R2):** *oikeat* ääniraidat/kielet, *oikea* titteli (ei
naapurititteli samalla kestolla), ei keskeltä puuttuvaa sisältöä. Rakenteellinen havaitsee
katkenneen/tyhjän/vääränmittaisen, ei "väärä-mutta-oikeanmittainen". Tietoinen rajaus.

### 8.5 Tekstitysten irrotus ja sijainti (v1:n toistuva laatuvika — nyt eksplisiittinen)
DVD-VobSub-tekstityksissä on tässä projektissa toistunut kaksi vikaa, jotka EIVÄT saa pudota
spesifikaatiosta (tarkistuksen kohta 12):
- **Desync:** raaka VOB-konkatenointi ei sisällä NAV-ajastusta → tekstit epäsynkassa. **Sopimus:
  tekstitykset irrotetaan libdvdnav-pohjaisella demukserilla** (ffmpeg `dvdvideo`), joka lukee
  NAV-paketit → oikea ajastus. Raaka `concat:VTS…` on kielletty.
- **Sijainti (tekstit ruudun ulkopuolelle):** VobSub `.idx`:n `size: WxH`-otsake määrää tekstien
  koordinaatiston. Jos se putoaa, tekstit valuvat ulos rajatulla/anamorfisella kuvalla. **Sopimus:
  idx:n `size`-otsake säilytetään/injektoidaan vastaamaan lähderesoluutiota; `crop` (job-kentässä)
  huomioidaan ettei tekstejä työnnetä pois näkyvistä.**
Automaattinen desync-*havaitseminen* on silti vain heuristiikka (§8.4b, §14 R6) — menetelmä on
oikea, mutta "tekstit synkassa" ei ole koneellisesti todistettavissa ilman katselua.

### 8.6 Kirjastoon vienti, cleanup, ekstranumerointi
- **Kirjaston korvaus:** `mv "$DEST_ROOT/.tmp/<id>.mkv" dest_dir/out_name` (atominen, sama fs, §2.1).
  Vanha korvattava → `$BACKUP_DIR` (temp+mv+fsync). Job → `done` (§2.5-järjestys), siirto `jobs/done/`.
- **cleanup (kilpajuoksuton):** per-disc-lukko (`locks/disc-<sha1>.lock`); sen sisällä re-check että
  discen kaikki jobit yhä `done|user_skip` (ei muuttunut unskipillä/retryllä), tuore sisältötarkistus
  kohdetiedostolle (§14 R1), vasta sitten poista lähde. `unskip`/`retry` ottavat saman lukon.
- **Ekstranumerointi (arkisto huomioitu, tarkistuksen kohta 6b):** per-dest-lukon sisällä numero =
  **max(kohdekansiossa levyllä olevat ekstraindeksit ∪ aktiivisten jobien varaamat ekstra-out_namet
  samaan dest_diriin) + 1**. Koska done-ekstrojen **tiedostot ovat levyllä** (vaikka job on
  arkistoitu `jobs/done/`:iin), kohdekansion tiedostojen skannaus kattaa ne — laskenta ei jää
  jumiin siihen että jobs/done/:ia ei lueta. Numero sidotaan **enqueue-hetkellä tittelijärjestyksessä**;
  **retry säilyttää saman numeron** (ei aukkoa/törmäystä).
- **SIGTERM:** ei uusia slotteja; käynnissä olevat jäävät toipumiselle (seuraava käynnistys
  `encoding`→`pending`). Ei katkennutta kirjastotiedostoa (temp ei renametty).

---

## 9. Migraatio + turvallinen tilanvapautus

`migrate` (kertaluontoinen, vasta testauksen jälkeen):
1. Vanhat jonorivit → `enqueue` (idempotenssi kolmen hakemiston yli, §5.1). Metadata:
   **timeout-wrapattu** probe (sama scan kuin §6); vaurioitunut → `broken`.
2. `done` **vain** jos dest-tiedosto **läpäisee §8.4(a) rakenteellisen verifioinnin** (video+
   want_audio-määrä läsnä, kesto ~ tallennettu). **Ei koskaan pelkän olemassaolon perusteella.**
3. Muut → `pending` (lähde säilyy).
4. Lähteen VOB-poisto vain disceille joiden kaikki jobit `done` (verifioitu) tai `user_skip`.
5. Vanhat rakenteet poistetaan vasta kun migraatio todettu oikeaksi.

**Duplikaatit = eksplisiittinen rajoite, ei ominaisuus (§14 R4):** ehjä dest + olemassa oleva lähde →
ei uutta jobia samalle sisällölle. Sama teos eri julkaisuina / sama levy kahdesti = eri `disc_key` →
eri työt, ei yhdistetä. Karsinta jää käyttäjälle (valinnainen volume-nimi+kestosumma-tarkistus).

---

## 10. GUI-valmius + varmuuskopioiden retention

- **GUI** (erillinen projekti) lukee `status.json` + `jobs/*` + `problematic/*` + `jobs/done/*` +
  `counters.json` ja kutsuu ydinkomentoja. `rev`-kenttä (§2.6) tekee muutokset havaittaviksi. Ei
  muutoksia ytimeen.
- **Skannauksesta rajattavat NAS-hakemistot:** `$DEST_ROOT/.tmp/` (keskeneräiset enkoodaukset) **ja**
  `$BACKUP_DIR` (vanhat versiot) — molemmat mediapalvelimen ignore-säännöllä pois indeksistä, jotta
  kirjaston kohdekansiot pysyvät puhtaina.
- **Retention:** `cleanup` poistaa `$BACKUP_DIR`:istä `BACKUP_RETENTION_DAYS`:ää vanhemmat.

---

## 11. Nimet ja lainaus
Erikoismerkit (`Astronaut's Wife`, `Fargo (1996)`, ääkköset): kaikki muuttujat aina lainattuina
(`"$var"`); jq:lle `--arg`/`-r`; ei lainaamatonta interpolointia → ei rikkoutumista/injektiota.

---

## 12. Testaus ennen tuotantoa (pakollinen)

1. `bash -n` + `shellcheck`.
2. **Rinnakkaisuus (stub-enkooderi `sleep N; return 0/1`):** N+1 jobia → tasan N encoding; jobs-
   tiedostojen rinnakkaiskirjoitus → ei korruptiota; per-dest-lukko → eri numerot; lähteen siivous
   täsmälleen kerran.
3. **Per-job-CAS (tarkistuksen kohta 5):** `skip` samaan hetkeen kun worker asettaa `encoding` →
   lopputulos aina eheä (joko user_skip+enkoodaus keskeytyy, tai encoding jatkuu ja skip_requested
   honoroituu commitissa) — EI koskaan user_skip+enkoodaus jatkuu -tilaa.
4. **Kaatumis-/reboottoipuminen:** tapa dispatcher/worker eri kohdissa → 4 tapausta (A–D) oikein;
   PID-reuse ei estä toipumista; dir-luokkasiirron keskeytys → reconcile pitää terminaalisimman.
5. **Atomisuus + sijainti:** kirjasto `$DEST_ROOT/.tmp`-tempin kautta (ei WORK_DIR→NAS); temp EI
   kohdekansiossa; jq-guard (viallinen JSON/levy täynnä ei tuhoa targettia); fsync-järjestys.
6. **Ekstranumerointi arkiston yli (tarkistuksen kohta 6b):** enkoodaa ekstra → arkistoi → enqueue
   uusi ekstra samaan kansioon → saa seuraavan vapaan numeron, ei törmäystä.
7. **cleanup ↔ unskip/retry:** samanaikaisuus → lähde ei katoa unskipatulta.
8. **Verifiointi:** tyhjä/vajaa/katkennut/väärä-audio-määrä hylätään; want_audio-johdettu odotus.
9. **Lämpö:** WARN→STOP/CONT; KILL→pending; vahdin kuolema → uudet slotit pysähtyvät JA (kova
   vanhentuma) dispatcher suojaa käynnissä olevat (tarkistuksen kohta 8).
10. **Levytila:** DEST_ROOT täynnä → uusi slotti ei avaudu (tarkistuksen kohta 10); GB→tavu-muunnos
    (tarkistuksen kohta 2) — `RIP_AHEAD_MAX_GB=60` ei estä rippausta väärällä yksiköllä.
11. **Yksikkö/config:** esimerkki-config parsiutuu ilman inline-kommenttiroskaa (tarkistuksen kohta 1).
12. **Numeeriset:** desimaaliset anturi-/fps-arvot eivät kaada vertailuja (§2.4).
13. **Rip-ahead per disc_key:** moni-titteli-levy lasketaan kerran (tarkistuksen kohta 3);
    karanteeni erillään velasta (kohta 11).
14. Vasta läpäisyn jälkeen pieni oikea päästä-päähän-testi, sitten migraatio.

---

## 13. Tarkistuslista toteuttajalle (neljä tarkastuskierrosta integroitu; jäännösrajoitteet §14)

- [ ] Kirjasto `$DEST_ROOT/.tmp`-tempin kautta (sama fs), EI kohdekansion sisällä, EI WORK_DIR→NAS.
- [ ] `$DEST_ROOT/.tmp` JA `$BACKUP_DIR` rajattu mediapalvelimen skannauksesta.
- [ ] Kanoninen JSON-kirjoitus (§2.2): mktemp + jq-rc + `-s` + fsync(tiedosto)+fsync(dir) — YKSI funktio.
- [ ] Kestävyysjärjestys (§2.5): temp→fsync→mv→fsync→vasta sitten `done`.
- [ ] Per-job-CAS (§2.6): kaikki kirjoittajat per-job-flockissa; skip encoding→skip_requested; rev++.
- [ ] Worker (ei dispatcher) pitää slot-lukkoa; 4 toipumistapausta; pgid tallennettu.
- [ ] Yksi totuus per job: problematic/ on sijainti ei kopio; dir-luokkasiirron reconcile.
- [ ] counters.json → status ei skannaa jobs/done/:ia (O(N) pois).
- [ ] Ekstranumerointi max(levyn tiedostot ∪ aktiiviset varaukset)+1; retry säilyttää numeron.
- [ ] enqueue-idempotenssi kolmen hakemiston yli; --force määritelty.
- [ ] GB→tavu-muunnos eksplisiittinen (§2.4); RIP_AHEAD_MAX_GB tavuvertailuun.
- [ ] Rip-ahead-velka per disc_key (ei per job); failed/broken = karanteeni erillään (mittari+ack).
- [ ] DEST_MIN_FREE_GB tarkistetaan ennen slotin avaamista (NAS-temp).
- [ ] Lämpövahti erillinen; pgid-kohdennettu STOP; kuolema → uudet slotit seis + kova vanhentuma
      suojaa käynnissä olevat.
- [ ] Raitapolitiikka (§8.3); verifioinnin audio-odotus want_audio:sta, ei lähteestä.
- [ ] Deinterlace/detelecine määritelty (DVD-laatu).
- [ ] Tekstitys: libdvdnav-demukseri (desync) + idx size-otsake/crop (sijainti) (§8.5).
- [ ] PARALLEL-lasku: aloita vain jos pidetyt slotit < PARALLEL (ei ylitä laskettaessa).
- [ ] config: ei inline-kommentteja; ankkuroitu trailing-strip + \r.
- [ ] Jonojärjestys flock-seqfilestä (`seq`); numeeriset awk/strip; lukot lokaalisti; ei set -e;
      single-instance flock; SIGTERM; migraation probe timeout-wrapattu; scan per-titteli.

---

## 14. Tunnetut jäännösrajoitteet (tietoiset rajaukset, EI ratkaistuja aukkoja)

Nämä eivät ole korjattuja riskejä vaan **tarkoituksellisia rajauksia**. Toteuttajan/käyttäjän on
tunnettava ne, ettei niitä luulla katetuiksi.

- **R1 — NAS-fsyncin kestävyys ei ole hallinnassa.** §2.5 tekee oikean järjestyksen, mutta jos
  verkkolevy valehtelee `fsync`ista, viimeinen suoja on `cleanup`in tuore sisältötarkistus ennen
  lähteen poistoa (§8.6).
- **R2 — Verifiointi on rakenteellinen, ei sisältövertaava (§8.4).** Havaitsee katkenneen/tyhjän/
  vääränmittaisen, EI "väärä-mutta-oikeanmittainen" (väärä titteli samalla kestolla, väärät kielet,
  puuttuva keskiosa toleranssin sisällä). Lähdevertailua ei tehdä.
- **R3 — Lukot ovat advisory, koordinoivat vain tämän järjestelmän prosesseja (§2.3).**
- **R4 — Duplikaattilevyjä ei yhdistetä (§9).** Karsinta käyttäjälle.
- **R5 — Optimaalista `PARALLEL`:ia ei voi tietää ilman mittausta kohderaudalla.** Lämpöturva on
  N:stä riippumaton, mutta hyödyllinen N mitataan.
- **R6 — Tekstityksen desync-havaitseminen on heuristiikka.** Irrotus*menetelmä* on oikea (§8.5,
  libdvdnav), mutta "tekstit synkassa" ei ole koneellisesti todistettavissa ilman katselua; §8.4(b)
  tuottaa vain varoituksen, ei takuuta.

---

Tämä spesifikaatio on itsenäinen eikä edellytä vanhan koodin tuntemusta. **Neljä tarkastuskierrosta
(13 + 20 + 10 + 14 riskiä) on integroitu sopimuksiksi.** En väitä että "kaikki riskit on ratkaistu" —
tunnistetut korjattavat kohdat on korjattu, ja loput ovat §14:n tietoisia, dokumentoituja rajauksia.
Aidosti arkkitehtuuritason kohdat (worker-omisteinen slot-lukko + toipuminen, fsync-kestävyys ennen
`done`:a, per-job-CAS, temp pois kirjastosta, arkiston-tietoinen numerointi, karanteeni erillään
velasta) on ratkaistu §2–§8:ssa.
