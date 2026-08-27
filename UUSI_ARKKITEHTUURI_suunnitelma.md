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
      sync -d "$tmp" || { rm -f "$tmp"; return 2; }         # data ei kestävä → EI mv:tä, target koskematon
      mv -f "$tmp" "$target"
      sync "$dir"     || return 3                           # rename ei kestävä → target on paikallaan, mutta rc≠0
      return 0
  else
      rm -f "$tmp"; return 1   # jq-virhe / levy täynnä → target koskematon
  fi
```
- **`sync -d` (EI `fsync`)** — Ubuntussa ei ole `fsync`-binääriä (`command not found`); coreutilsin
  `sync` on oikea työkalu. **Tarkka valinta (A4): `sync -d "$tmp"` TIEDOSTOLLE** (`fdatasync`, data
  riittää), mutta **`sync "$dir"` HAKEMISTOLLE ilman `-d`:tä** — hakemiston kestävyys on nimenomaan
  *metadataa* (rename/hakemistomerkinnän pysyvyys), johon `-d`:n `fdatasync` ei riitä; ilman `-d`:tä
  `sync` tekee täyden `fsync`in. Yksiselitteinen vaihtoehto hakemistolle:
  `python3 -c 'import os,sys;fd=os.open(sys.argv[1],os.O_RDONLY);os.fsync(fd);os.close(fd)' DIR`
  (python3 on jo riippuvuuslistalla; `os.fsync` = täysi fsync, ei tulkinnanvaraa). **Koko
  kestävyystakuu (§2.5) nojaa tähän — varmistettava Ubuntu 24.04:llä ennen lukkoonlyöntiä.**
- `mktemp` (EI `.tmp.$$`) — `$$` ei muutu aliprosesseissa (vain `$BASHPID`) → törmäys ja
  haamutiedostot rebootissa. Uniikki nimi ratkaisee molemmat.
- `jq`:n rc **ja** epätyhjyys (`-s`) tarkistetaan ennen `mv`:tä → sokeaa `mv tmp target` ei koskaan.
- **`sync -d` tiedostolle ja `sync` (ilman `-d`) hakemistolle** sisältyy funktioon → jokainen
  tilakirjoitus on kestävä. (Ei `-d` hakemistolle — A4: hakemiston kestävyys on metadataa.)
- **`sync`in rc tarkistetaan (kohta 1, ainoa toiminnallinen):** guard tarkisti tähän asti vain `jq`:n
  rc:n ja `-s`:n; `sync`in epäonnistuminen olisi mennyt läpi huomaamatta → `done` voitaisiin kirjoittaa
  ilman kestävyyttä. Funktio palauttaa nyt: `2` = data ei kestynyt (ennen `mv`:tä, target koskematon),
  `3` = rename ei kestynyt (tiedosto paikallaan mutta ei varmistettu). Kutsuja (§2.5) valitsee
  toiminnan rc:n mukaan. **Tämä EI korvaa R1:tä:** rc-tarkistus suojaa *raportoiduilta* virheiltä, R1
  koskee tilannetta jossa NAS valehtelee onnistumisesta — molempia tarvitaan.

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
1. kirjoita `$DEST_ROOT/.tmp/<id>.mkv`, **`sync -d` (tiedosto — fdatasync)**,
2. **`sync` ($DEST_ROOT/.tmp — dir-fsync, ei `-d`)**,
3. `mv` lopulliseen nimeen kohdekansioon,
4. **`sync` (dest_dir — dir-fsync, ei `-d`)** (rename pysyväksi),
5. **vasta sitten** `done`-tila §2.2:n kanonisella (`sync -d`-sisältävällä) kirjoituksella.

Näin `done` ei koskaan ehdi levylle ennen kohdetiedostoa. Sama järjestys `$BACKUP_DIR`-varmuuskopiolle.

**`sync`-epäonnistumisen käsittely (kohta 1) — kolme eri käytöstä, ei yhtä sääntöä.** **Huom:
vaiheet 1–4 koskevat MKV-tiedostoa, jonka HandBrake kirjoittaa ja worker synkkaa suoraan — tämä EI
kulje `write_json_atomic`in kautta** (se on JSON-tilakirjoituksille; vain vaihe 5 käyttää sitä).
Worker toteuttaa mediapolulle **saman rc-konvention** kuin §2.2 (`2` = ennen `mv`:tä, `3` = renamen
jälkeen):

| Kohta | Jos `sync` epäonnistuu |
|---|---|
| vaiheet 1–2 (MKV, ennen `mv`:tä; rc-konventio `2`) | Keskeytä, poista temp, job → `failed`. Mitään ei tapahtunut, kirjastoa ei kosketa. |
| vaihe 4 (`sync dest_dir` renamen jälkeen; rc-konventio `3`) | Ei voi keskeyttää — tiedosto on jo paikallaan. **ÄLÄ kirjoita `done`ia** (job jää `encoding`→reclaimin kautta `pending`). Toipuminen turvallinen: uudelleenenkoodaus korvaa saman tiedoston idempotentisti ja lähde on yhä olemassa (ei siivottu koska ei `done`). |
| vaihe 5 (`done`-JSON, `write_json_atomic`) | Funktio nostaa `sync`in rc:n paluuarvoon (`2`/`3`); jos `done`-kirjoitus ei kestänyt, job ei ole luotettavasti `done` → reclaim yrittää uudelleen (tiedosto on jo kirjastossa, verify läpäisee, `done` kirjoitetaan uudelleen). |

**NAS-varaus (§14 R1):** jos verkkolevy valehtelee `sync`in kestävyydestä (rc=0 mutta data ei
levyllä), rc-tarkistus ei auta — viimeinen suoja on `cleanup`in tuore sisältötarkistus ennen lähteen
poistoa (§8.6). Rc-tarkistus (kohta 1) suojaa *raportoiduilta* virheiltä, R1 *valehdelluilta*;
molempia tarvitaan.

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
- **lämpövahti:** flock → asettaa `thermal_kill=true` **vain jos status yhä `encoding`** (muuten
  no-op, §4) → unlock, sitten `kill`. On myös jobin kirjoittaja, ei vain worker/CLI.
- **rev-kenttä** on monotoninen versionumero jokaisessa jobissa — GUI ja testit voivat havaita
  muutokset; flock takaa serialisoinnin, rev tekee muutokset havaittaviksi.
- **`rev`-INVARIANTTI (A1, aito korrektiusriski):** mikä tahansa kirjoittaja joka luo tai korvaa
  recordin **jo olemassa olevalle id:lle ottaa `rev = max(kaikki tuolle id:lle löydetyt rev, kaikista
  kolmesta hakemistosta) + 1`**. **`rev` ei koskaan nollaudu eikä laske** — ei `--force`issa, ei
  migraatiossa, ei missään. Muuten `--force` voisi luoda `rev=1`-recordin samaan aikaan kun
  kaatumisen jäljiltä toisessa hakemistossa on `rev=5`, ja boot-reconcile (§3, "suurin rev voittaa")
  heittäisi pakotetun pois → sama hiljainen kumoutuminen jonka §3 juuri korjasi, toista reittiä.

---

## 3. Tila-arkkitehtuuri: per-job-tiedostot (yksi tiedosto per job, sijainti = tilaluokka)

```
$STATE/                         (STATE = paikallinen, esim. $WORK_DIR/state)
  jobs/<id>.json                pending / encoding
  problematic/<id>.json         failed / broken   (SIIRRETTY tänne, EI kopio — §4)
  jobs/done/<id>.json           done / user_skip  (arkisto)
  counters.json                 tilalaskurit {pending,encoding,failed,broken,done,user_skip,abandoned}
  status.json                   live-yhteenveto (vain dispatcher kirjoittaa)
  scans/<sha1(disc_key)>.json   skannaustulos joka odottaa vahvistusta+enqueueta (GUI-aukko c, §5.5)
  jobs/done/index.jsonl         append-only arkistoindeksi GUI:lle (A6, §8.6)
  audit.jsonl                   append-only audit-loki peruuttamattomille operaatioille (§15 B2)
  paused                        lippu: pause aktiivinen (§15 B5)
  seqfile                       flock-suojattu monotoninen jonojärjestysnumero (§5.1) — pakollinen
  locks/job-<id>.lock           per-job read-modify-write -lukko (§2.6)
  locks/dest-<sha1(dest)>.lock  per-kohdekansio-lukko (ekstranumerointi)
  locks/disc-<sha1(key)>.lock   per-disc-lukko (cleanup ↔ unskip/retry, §8.6)
  locks/counters.lock           counters.json + state_rev -päivitys (§15 B3)
  locks/thermal.lock            pää-/varavahdin keskinäinen omistajuus (§8.2, vain yksi ohjaa pgid:tä)
  slots/slot-N.lock             rinnakkaisslotit (flock; N = 1..PARALLEL_MAX kova katto)
  dispatch.pid                  daemonin single-instance-lukko
  thermal.heartbeat             lämpövahdin elossaolo-aikaleima (fail-safe, §8)
```

**Yksi totuus per job:** jobin record on **täsmälleen yhdessä** hakemistossa, tilaluokan mukaan.
`problematic/` EI ole kopio `jobs/`:sta (tarkistuksen kohta 14) vaan se paikka jossa failed/broken-job
*asuu*. Tilasiirtymä joka ylittää luokkarajan (esim. `pending`→`broken` tai `encoding`→`done`):
1. kirjoita uuden sijainnin tiedosto (§2.2 guardattu+fsync),
2. poista vanhan sijainnin tiedosto.
Kaatuminen näiden välissä → **käynnistyksen reconcile** ratkaisee kaksoisrecordin **`rev`-kentän
perusteella: säilytä suurin `rev`, poista muut.** Hakemistoprioriteetti (`jobs/done` > `problematic`
> `jobs`) on **vain tasapelin ratkaisija** samalla rev:llä. **Miksi ei pelkkä hakemistoprioriteetti
(tarkistuksen kohta 1, aito korrektiusbugi):** se olettaisi että siirtymät kulkevat aina kohti
terminaalia, mutta `retry` (`problematic/`→`jobs/`) ja `unskip` (`jobs/done/`→`jobs/`) kulkevat
**taaksepäin** ja kasvattavat `rev`:iä (§2.6). Pelkkä prioriteetti pitäisi vanhan `failed`/`user_skip`-
recordin ja poistaisi juuri luodun `pending`in → käyttäjän komento peruuntuisi ilman merkkiä. `rev`
on määritelty monotoniseksi juuri tähän: suurin rev = viimeisin tahto.

**counters.json ei saa ajautua pysyvästi eroon (tarkistuksen kohta 6):** hakemistosiirto ja
`counters.json`-päivitys eivät ole atomisia keskenään — kaatuminen niiden välissä jättäisi luvut
pysyvästi väärin, koska status ei koskaan skannaa `jobs/done/`:ia. **Siksi käynnistyksen reconcile
laskee `counters.json`:n uudelleen täydellä skannauksella** (kaikki kolme hakemistoa). Kertaluontoinen
O(N) bootissa on täysin hyväksyttävä hinta; ajonaikaiset päivitykset pysyvät inkrementaalisina.

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
| `abandoned` | problematic/  | käyttäjä kuittasi karanteenin (`ack-quarantine`) — retry EI enää mahdollinen | **kyllä** |
| `user_skip` | jobs/done/    | käyttäjä päätti ettei tehdä                         | **kyllä**          |

**`abandoned` (tarkistuksen kohta 3):** `ack-quarantine` EI saa hiljaa muuttaa failed/broken-jobin
lähdettä poistokelpoiseksi ilman omaa tilaa — se olisi peruuttamaton polku joka ei näy tilamallissa,
ja kuittauksen jälkeinen `retry` epäonnistuisi ("vaatii lähteen") ilman että käyttäjälle kerrottiin
kuittauksen tuhonneen retry-mahdollisuuden. Siksi kuittaus siirtää jobin **`abandoned`**-tilaan
(pysyy `problematic/`:ssa, näkyy `review-problematic`issa), joka **eksplisiittisesti sallii lähteen
siivouksen mutta estää retryn**. `ack-quarantine` **varoittaa ennen suoritusta** että tämä on
peruuttamaton ja poistaa retry-mahdollisuuden. Vasta `abandoned` (tai `done`/`user_skip`) sallii
kyseisen `disc_key`:n lähteen poiston.

**Lämpötapon erottaminen aidosta virheestä (tarkistuksen kohta 2):** kun lämpövahti `TEMP_KILL`:aa
enkooderin, worker näkee vain `rc≠0` — saman signaalin kuin oikeasta epäonnistumisesta. Ilman
lisätietoa se merkitsisi jobin `failed`:iksi ja lämpötapot valuisivat karanteeniin (§8.2:n lupaus
"→ pending" ei toteutuisi). **Sopimus: lämpövahti asettaa jobiin `thermal_kill=true` (per-job-flock,
§2.6) ENNEN `kill`iä**, ja tämä kirjoitus on **no-op jos status ei ole `encoding`** (§2.6 —
estää haamutiedoston jos worker jo commitoi ja siirsi recordin `jobs/done/`:iin).

Worker/reclaim tulkitsee lipun commitissa **vain kun `rc≠0`** (tarkistuksen kohta 6):
- `rc≠0` JA `thermal_kill=true` → job `pending` (ei `failed`), nollaa lippu, poista temp.
- **`rc=0` (enkoodaus ehti valmistua lipun kirjoituksen ja killin välissä) → normaali commit,
  `done`** — kelvollista valmista enkoodausta EI heitetä pois pelkän lipun takia. Lippu nollataan.
- `rc≠0` ilman lippua → aito `failed`.

**`done`:n vahva määritelmä (koska se valtuuttaa lähteen poiston):** lopullinen kohdetiedosto on
*olemassa, luettavissa, verifioitu (§8.4), ja sen sekä jobin tila on kestävästi levylle kirjattu*
(§2.5). `done` EI ole pelkkä historiallinen väite — `cleanup` (§8.6) tekee lähteen poiston hetkellä
lisäksi oman tuoreen sisältötarkistuksen (§14 R1). `done` + cleanup-recheck yhdessä ovat poiston ehto,
ei `done` yksin.

**Lähteen (disc) VOB-poisto vain kun KAIKKI saman `disc_key`:n jobit ovat `done`, `user_skip` tai
`abandoned`.** Yksikin `pending/encoding/failed/broken` estää. `retry` (failed/broken→pending) JA `unskip`
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
päällekirjoitusta); `--force` sallii uudelleenluonnin (nollaa tilan `pending`, **säilyttää `seq`:n
jos on — tarkoituksellisesti**, jolloin uudelleenajettu job pitää vanhan paikkansa jonossa eikä
mene kärkeen tai hännille; **`rev = max(löydetyt rev)+1`, EI nollaus — §2.6 invariantti A1**). Sama
id ei koskaan päädy kahteen hakemistoon yhtä aikaa.

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
  "skip_requested":false, "thermal_kill":false,
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
{"updated":"…Z","parallel":2,"dispatcher_alive":true,"paused":false,"state_rev":90431,
 "encoding":[{"id":"…","name":"Fargo","pct":42.1,"eta_s":1830,"fps":31.2,"slot":1}],
 "pending":57,"encoding_n":2,"done":812,"failed":3,"broken":5,"user_skip":12,"abandoned":2,
 "quarantine_gb":41,                                // failed+broken-lähteiden koko (§7, erillään velasta)
 "abandoned_gb":8,                                  // kuitattu, odottaa cleanupia (§8.6, ei näkymätön lattia)
 "encode_debt_gb":22,                               // vain pending/encoding-lähteet (rip-ahead-mittari)
 "queue_eta_s":41000,"temps_c":[55,58,54,56],
 "disk_free_work_gb":80,"disk_free_dest_gb":540,"thermal_ok":true}
```
Laskurit `counters.json`:sta (ei `jobs/done/`-skannausta) — **kaikki tilat raportoidaan** (myös
`user_skip`, `abandoned`), jotta GUI voi näyttää ne. **`dispatcher_alive`** = `dispatch.pid`-flockin
tila (onko daemon pystyssä): ilman sitä GUI näyttäisi vanhaa status.jsonia täysin normaalin näköisenä
vaikka daemon olisi alhaalla — GUI luottaa lisäksi `updated`-aikaleiman tuoreuteen. **pct/fps/eta
lähde:** HandBrakeCLI
`--json`-edistymisvirta (viimeinen `Working`-objekti: `Progress`, `Rate`, `ETASeconds`); jos puuttuu,
kentät `null` — status ei koskaan kaadu progress-parsintaan.

### 5.3 Konfiguraatio: `$HOME/.config/rip-dvd/config`
`AVAIN=arvo` per rivi. **Ei rivinsisäisiä kommentteja** (parseri ei poistaisi niitä → arvoon jäisi
roskaa). Kommentit vain omilla `#`-alkuisilla riveillään. Parsinta: `sed -n 's/^KEY=//p' | head -1`,
sitten **trailing-whitespace + CR** ankkuroituna perästä (EI ensimmäisestä välilyönnistä, jotta
`DIR=/mnt/my movies` säilyy). **Käytä `sed`-ankkurointia** (ei bash-extglobia):
`val=$(printf '%s' "$val" | sed 's/[[:space:]]*$//; s/\r$//')`. **Miksi ei `${val%%+([[:space:]])}`
(tarkistuksen kohta 3):** se vaatii `shopt -s extglob`in — ilman sitä `+(...)` tulkitaan
kirjaimellisesti eikä strippi tee mitään, jolloin arvoihin (mm. numeerisiin kynnyksiin) jäisi
välilyöntejä hiljaa. `sed` toimii aina.
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
SCAN_TTL_DAYS=14
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

### 5.4 Configin validointi ja oletukset (pakollinen — yleisin tuotantovikaluokka, tarkistuksen kohta 1)
Parsinta ei riitä: puuttuva avain → tyhjä merkkijono → awk-vertailu tyhjällä → määrittelemätön käytös.
Validointi on **kaksitasoinen (tarkistuksen kohta 5 — ei saa kaataa lukukomentoja):**
- **Aina pakolliset (kaikki komennot):** tyypit, välit, ristiriidat (alla). Kelvoton → **kieltäytyminen**
  (rc≠0, virhekuori §6.1) — nämä ovat halpoja eivätkä koske NASia.
- **Operaatiokohtaiset (vain kirjoittavat komennot):** polkujen (`DEST_ROOT`, `WORK_DIR`) olemassaolo
  ja kirjoitettavuus — tekevät NAS-statin. Näitä **EI aja luku­komennoille** (`status`,
  `review-problematic`): jos terastation on hetkellisesti irti, GUI:n on silti voitava lukea
  diagnoosi (`dispatcher_alive`, viimeisin status) — luku­komento **varoittaa**, ei kieltäydy, eikä
  tee jumittuvaa NAS-stat-kutsua joka status-kyselyllä.

- **Oletusarvo jokaiselle avaimelle** (koodissa, ei configissa): puuttuva/tyhjä avain → oletus.
  Configin täydellinen puuttuminen → kaikki oletukset (turvallinen minimikäytös: `PARALLEL=1`).
- **Tyyppi- ja välitarkistukset** (kelvoton → kieltäytyminen):
  - `PARALLEL` kokonaisluku `1..PARALLEL_MAX`; `PARALLEL_MAX` kokonaisluku `≥1`.
  - `CRF` kokonaisluku sallitulla välillä (esim. `0..51`); `ENCODER` sallitusta joukosta.
  - `TEMP_WARN` < `TEMP_KILL`, molemmat järkevällä välillä (esim. `40..110`).
  - kaikki `*_GB`, `*_DAYS` (ml. `BACKUP_RETENTION_DAYS`, `SCAN_TTL_DAYS`), `MIN_DURATION`,
    `READ_ERROR_MAX`, `SCAN_TIMEOUT`, `LOOP_INTERVAL` ei-negatiivisia kokonaislukuja.
  - `AUDIO_POLICY`/`SUB_POLICY`/`AUDIO_CODEC`/`DEINTERLACE` sallituista joukoista.
  - `DIR_*` suhteellisia (ei absoluuttisia) — halpa syntaksitarkistus, aina.
  - **(operaatiokohtainen, vain kirjoittajille):** `DEST_ROOT` ja `WORK_DIR` olemassa ja
    kirjoitettavissa (NAS-stat) — ei lukukomennoille.
- **Ristiriitatarkistukset:** `RIP_MIN_FREE_GB`/`DEST_MIN_FREE_GB` eivät saa olla suurempia kuin
  vastaavan levyn koko (varoitus); `PARALLEL > PARALLEL_MAX` → kieltäytyminen.
- Validointi on **yhteinen funktio** jonka jokainen komento kutsuu ensimmäisenä. Virheilmoitus kertoo
  avaimen, saadun arvon ja odotetun muodon (virhekuori §6.1).

### 5.5 Skannaustulos: `$STATE/scans/<sha1(disc_key)>.json` (A5)
Kaatumisen kestävä välitila scan→vahvistus→enqueue-ketjulle (§6.2, GUI-aukko c). Skeema:
```json
{
  "disc_key":"/abs/…/disc-042", "source":"/abs/…/disc-042/VIDEO_TS",
  "scanned":"2026-08-26T09:00:00Z", "volume":"FARGO",
  "titles":[
    {"title":11,"duration_s":5640,"width":712,"height":408,"dar":"1.86:1","fps":25,
     "format":"PAL","interlaced":false,"crop":"66:66:2:2",
     "src_subs":["fin","swe"],"src_audio":["eng"],
     "status":"ok","main_suggestion":true,"confidence":"high"},
    {"title":3,"status":"broken","reason":"scan_timeout"}
  ],
  "enqueued":[11], "confirmed":false
}
```
`enqueued[]` kasvaa kun titteli viedään jonoon (idempotenssi). Tiedosto poistetaan kun kaikki
`ok`-tittelit on enqueuattu tai käyttäjä hylkää, TAI `SCAN_TTL_DAYS`:n vanhentuessa (cleanup).

---

## 6. Ydinkomennot (ei-interaktiiviset)

### 6.1 Vakio tulos-/virhekuori (GUI-aukko a — suurin yksittäinen GUI-puute)
Ydin ei tulosta ihmiselle (§1), joten **jokainen komento palauttaa koneluettavan kuoren stdoutiin**
ja käyttää vakaata virhekoodijoukkoa — GUI ei voi näyttää "PARALLEL=8 ylittää PARALLEL_MAX=4" jos
virhe on vapaamuotoista tekstiä stderrissä.
- Onnistuminen: `{"ok":true, ...komennon data...}`
- Virhe: `{"ok":false,"error":"<vakaa_koodi>","detail":{...}}`, rc≠0.
  Esim. `{"ok":false,"error":"config_invalid","detail":{"key":"PARALLEL","got":"8","expected":"1..4"}}`.
- **Vakaa virhekoodijoukko** (laajennettavissa, ei koskaan uudelleenmääriteltävissä): `config_invalid`,
  `source_missing`, `id_exists`, `id_not_found`, `bad_state` (esim. retry ei-problematic-jobille),
  `dest_unwritable`, `scan_failed`, `disc_broken`, `lock_timeout`. Ihmisluettava teksti saa mennä
  stderriin, mutta **totuus GUI:lle on stdoutin kuori**.

### 6.2 Komennot

- **`scan <dvd_dir>`** → JSON tittelilistasta. **Kaksivaiheinen (tarkistuksen kohta 5 — kana–muna:
  per-titteli-scan tarvitsee N:ien luettelon, mutta se saataisiin normaalisti juuri siitä koko levyn
  skannauksesta jota vältetään):**
  1. **Enumerointi `lsdvd`:llä** (nopea, EI dekoodaa videota → ei jumita mätään titteliin) → titteli-
     numeroiden luettelo + karkea kesto. Jos **enumerointikin epäonnistuu** (levy lukukelvoton) →
     **levytason `disc:`-broken** (§5.1), ei jonoon.
  2. **Per-titteli** timeout-wrapatut tarkkuusskannaukset (`timeout $SCAN_TIMEOUT HandBrakeCLI -i …
     --title N --scan --json`) enumeroiduille N:ille → yksi vaurioitunut titteli ei vie ehjien
     metadataa. Yksittäisen tittelin timeout/virhe → se titteli `broken` scan-tuloksessa, muut
     palautuvat.
  Per titteli: numero, kesto, mitat, dar, fps, format, **interlaced-lippu**, crop, src_subs[],
  src_audio[]. EI kirjoita jonoa.
  - **Edistyminen (GUI-aukko b):** per-titteli-scan × `SCAN_TIMEOUT` voi kestää minuutteja. `scan`
    **emittoi JSONL-edistymisrivin per valmistunut titteli** stdoutiin (`{"scan":"…","title":3,
    "done":3,"total":8}`), jottei GUI:lle näy pelkkä blokkaava tyhjä kutsu.
  - **Tuloksen pysyvyys (GUI-aukko c, skeema §5.5):** `scan` **kirjoittaa tuloksen
    `$STATE/scans/<sha1(disc_key)>.json`:iin** (§2.2, sha1-nimi kuten lukot — `disc_key` on polku,
    ei kelvollinen tiedostonimi sellaisenaan), ei vain palauta muistiin. `enqueue` lukee sen. Jos GUI
    suljetaan/kaatuu vahvistuksen aikana, skannausta ei menetetä. **Ylikirjoitus:** saman levyn
    uudelleenskannaus **korvaa** aiemman scan-tiedoston atomisesti (§2.2) — tuorein voittaa.
    **Retention:** `cleanup` poistaa `SCAN_TTL_DAYS`:ää vanhemmat scan-tiedostot (yleisin tapaus:
    käyttäjä unohtaa enqueuata/hylätä → ei saa kertyä ikuisesti). Tiedosto siivotaan myös kun kaikki
    sen tittelit on enqueuattu tai käyttäjä hylkää eksplisiittisesti.
- **`enqueue --source … --title … --kind … --name … [--year] [--season/--episode] --role … [--force]`**
  → luo `jobs/<id>.json`. Idempotenssi kaikkien kolmen hakemiston yli (§5.1). Johtaa `want_audio`/
  `want_subs` raitapolitiikasta (§8.3). Ekstran `out_name` per-dest-lukossa kirjoitushetkellä.
- **`dispatch`** (daemon): §8.
- **`status [--json]`** → status.json.
- **`skip <id>`** → §2.6 (pending→user_skip suoraan; encoding→skip_requested).
- **`unskip <id>`** / **`retry <id>`** → →`pending` (**vaatii lähteen**, per-disc-lukko §8.6).
- **`review-problematic`** → listaa `problematic/` (yksi totuus, ei erillistä kopiota).
- **`ack-quarantine <id|disc>`** → siirtää failed/broken-jobin **`abandoned`**-tilaan (§4): poistaa
  karanteenimittarista ja sallii lähteen poiston. **Varoittaa ennen suoritusta** että tämä on
  peruuttamaton ja **estää retryn** pysyvästi. Käyttäjän eksplisiittinen päätös (§4/§7/§14).
- **`verify [<id>|--all]`** → aja §8.4:n itsenäinen verifiointifunktio jälkikäteen kirjastolle
  (§15 B4); palauttaa rakenteisen tuloksen per tiedosto. Ei muuta tilaa ellei erikseen pyydetä.
  **`--all` on raskas** (800+ × `ffprobe` NAS:ia vasten, kilpailee enkoodausten I/O:sta) → **tarkoitettu
  ajettavaksi jonon ollessa tyhjä tai `pause`n aikana** (kohteliaisuusehto, §15 B4).
- **`cleanup [--dry-run]`** → §8.6 (plan/execute, §15 B1). `--dry-run` tulostaa suunnitelman koskematta.
- **`migrate [--dry-run]`** → §9 (plan/execute, §15 B1).
- **`pause`** / **`resume`** → §15 B5 (lippu `$STATE/paused`): ei uusia slotteja / normaali.

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
- **Pending-jobin valintajärjestys (sivuhuomio):** dispatcher poimii aina **pienimmän `seq`:n
  pending-jobin ensin** (§5.1 jonojärjestys) — EI hakemistolistauksen järjestystä (joka olisi
  toteutus-/fs-riippuvainen). Näin jono etenee siinä järjestyksessä kuin työt lisättiin.
- **Slotit — PARALLEL-laskun kestävä logiikka (sivuhuomio):** slot-pool on `slot-1..slot-PARALLEL_MAX`
  (kova katto). Uuden jobin saa aloittaa **vain jos tällä hetkellä pidettyjen slot-lukkojen määrä <
  `PARALLEL`** (luettu tuoreena joka kierroksella). Näin PARALLELin lasku 2:een silloin kun slotit 3–4
  ovat workereiden hallussa EI johda siihen että dispatcher laskee slotit 1–2 vapaiksi ja käynnistää
  kaksi lisää (→ 4 rinnakkaista). Pidetty-määrä lasketaan yrittämällä ei-blokkaavaa flockia jokaiseen
  pool-slottiin; jo varatut jäävät workereille. Rinnakkaisuus laskee asteittain sitä mukaa kun
  käynnissä olevat valmistuvat.
- **Slotin avaamisen ehdot yhtenä predikaattina `may_open_slot()` (§15 B5):** kaikki neljä ehtoa
  yhdessä paikassa, ei hajallaan: (1) pidetyt slotit < `PARALLEL`; (2) `WORK_DIR` vapaa ≥
  `RIP_MIN_FREE_GB` JA `DEST_ROOT` vapaa ≥ `DEST_MIN_FREE_GB` (tarkistuksen kohta 10 — temp on NAS:illa
  `$DEST_ROOT/.tmp`, täyttyminen kaataisi jokaisen enkoodauksen → failed → velka kasvaa); (3)
  lämpöheartbeat tuore (§8.2 fail-closed); (4) **ei `$STATE/paused`-lippua** (`pause`/`resume`).
  Käynnissä olevat jatkuvat aina loppuun riippumatta predikaatista.

### 8.2 Lämpövahti = ERILLINEN riippumaton prosessi
Ei dispatch/verify/mv-silmukassa (jottei blokkaava NAS-mv viivästytä pollausta). Pollaa lämpöä
kiinteällä välillä, lukee kohteena olevat `pgid`:t `encoding`-jobeista (§5.1):
- **`TEMP_WARN`:** `kill -STOP` enkooderien **prosessiryhmille** (pgid; ei dispatcher, ei vahti itse),
  `-CONT` kun lämpö laskee. Palautuva. Ryhmä (ei yksittäinen pid), koska HandBrake haarauttaa.
- **`TEMP_KILL`:** aseta ensin jobiin `thermal_kill=true` (per-job-flock, **vain jos status yhä
  `encoding`** — no-op muuten, §2.6), sitten `kill` enkooderit; worker/reclaim tulkitsee lipun
  commitissa **vain kun `rc≠0`** → `pending` (ei failed), nollaa lippu, poista temp; `rc=0` (ehti
  valmistua) → normaali `done` (§4). Lämpö ei koskaan merkitse jobia pysyvästi rikki eikä valu
  karanteeniin (tarkistuksen kohta 2/6).
- **STOP-reunatapaukset:** `-STOP` kesken kirjoituksen on turvallista — tulos on aina
  `$DEST_ROOT/.tmp/<id>.mkv` (ei lopullinen nimi); jäädytetty worker ei voi commitoida → puolivalmis
  ei mene `done`:ksi; TEMP_KILL STOP-tilassa → temp vain poistetaan reclaimissa; sammutus STOP-tilassa
  → reboot-toipuminen (tapaus D) → `pending`.

**Lämpövahdin OMA kaatuminen (fail-safe, tarkistuksen kohta 8 — suojaa MYÖS käynnissä olevat):**
kaksi kynnystä heartbeatin (`$STATE/thermal.heartbeat`) iälle:
- **Vanhentuma > 3× pollausväli:** dispatcher **ei avaa uusia slotteja** (fail-closed).
- **Vanhentuma > 6× pollausväli:** lämpösuojaa ei tosiasiassa ole, ja **käynnissä olevat kaksi x265:tä
  jatkuvat suojaamatta** — juuri se tilanne jota vastaan mekanismi on. Silloin dispatcher **käynnistää
  minimaalisen erillisen varavahtiprosessin** (sama pgid-kohdennettu STOP/CONT-logiikka, oma prosessi)
  kunnes systemd elvyttää varsinaisen vahdin. **Se EI ota pollausta omaan dispatch-silmukkaansa**
  (tarkistuksen kohta 7): koko syy vahdin erottamiseen oli ettei blokkaava NAS-mv saa viivästyttää
  lämpöpollausta — inline-pollaus hätätilassa antaisi heikoimman suojan juuri silloin kun sitä
  tarvitaan. Varavahti on kevyt itsenäinen prosessi kuten pääkin. Fail-closed (uusia slotteja ei
  avata) pysyy voimassa koko ajan; varavahti hoitaa aktiivisen suojan olemassa oleville.
- **Päävahdin ja varavahdin omistajuus (tarkistuksen kohta 2):** jos päävahti oli vain hetkellisesti
  myöhässä ja herää samaan aikaan kun varavahti on käynnistetty, molemmat ohjaisivat samaa pgid:tä.
  STOP/CONT ovat idempotentteja (ei bugi), mutta jätetään määrittelemättä. **Sopimus:
  `locks/thermal.lock` — vain **pgid-ohjaus (STOP/CONT)** tehdään lukon sisällä.**
  - **Heartbeat kirjoitetaan LUKON ULKOPUOLELLA** (heti käynnistyttyä ja joka pollauskierroksella).
    Heartbeat on elossaolosignaali, EI ohjaustoimenpide — sen sitominen lukkoon aiheuttaisi
    lukkiuman: varavahti pitää lukkoa → herännyt päävahti odottaa lukkoa → ei kirjoittaisi
    heartbeatia → varavahti ei havaitsisi tuoreutumista → ei poistuisi → lukko ei vapaudu → dispatcher
    näkee heartbeatin ikuisesti vanhentuneena → **fail-closed jää pysyvästi päälle, enkoodaus pysähtyy
    hiljaa** (tarkistuksen kohta: v11:n oma regressio). Irrotus lukosta estää tämän.
  - **Väistämissääntö:** herännyt päävahti kirjoittaa heartbeatin (lukon ulkopuolella) ja jää
    odottamaan lukkoa; **varavahti havaitsee tuoreutuvan heartbeatin, vapauttaa lukon ja poistuu**;
    päävahti saa lukon ja jatkaa normaalisti. Korkeintaan yksi vahti ohjaa pgid:tä kerrallaan, ja
    fail-closed purkautuu heti kun päävahti elpyy.

### 8.3 Raitapolitiikka (tarkistuksen kohta 13)
`enqueue` johtaa `want_audio`/`want_subs` configin politiikasta, EI ota sokeasti kaikkia:
- `AUDIO_POLICY`: `original` | `original+commentary` | `all` — valitsee ääniraidat kielen/roolin
  mukaan scan-metadatasta. **Varaus (tarkistuksen kohta 8, §14 R8):** DVD:n kommenttiraita-lippu on
  usein täyttämättä/väärin; HandBrake/lsdvd raportoi luotettavasti *kielen*, ei *roolia*. Siksi
  `original+commentary` degeneroituu tarvittaessa **heuristiikaksi** ("toinen samankielinen raita =
  todennäköinen kommentti") ja se kirjataan jobin `warnings[]`iin kun rooli jouduttiin arvaamaan.
  **`want_audio` on tällöin best-effort-arvio, ja verifioinnin (§8.4a) kova raitamäärävertailu käyttää
  ALARAJANA `original`-politiikan varmaa määrää** (ei arvattua kommenttimäärää) — ettei politiikan
  väärinarviointi hylkää muuten kelvollista enkoodausta failed:iin.
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
- **Arkistoindeksi (A6):** arkistointihetkellä (siirto `jobs/done/`:iin, myös `user_skip`) **appendaa
  yksi tiivis rivi `jobs/done/index.jsonl`:iin** (`{"id","name","dest","finished","status"}`). Append
  on halpa (O(1)). **Atomisuussopimus (tarkistuksen kohta 2):** rivi kirjoitetaan **yhtenä
  `write()`-kutsuna** (`printf '%s\n' "$rivi" >> tiedosto`, EI useaa peräkkäistä kirjoitusta samaan
  fd:hen, jotka voivat lomittua) ja **rivi mahtuu `PIPE_BUF`iin** (≤ 4096 tavua Linuxissa) → POSIX
  takaa lomittumattoman O_APPENDin. Sama sopimus koskee **`audit.jsonl`ia (§15 B2)**. Jos rivi ei
  mahtuisi PIPE_BUFiin (ei odotettua näillä kentillä), käytä per-tiedosto-flockia. GUI sivuttaa
  indeksiä eikä koskaan skannaa `jobs/done/*.json`:ia listaukseen — täysi JSON luetaan vain kun rivi
  avataan. Ilman tätä §3:n O(N)-optimointi vain siirtyisi dispatcherilta GUI:lle (~800+ tiedostoa,
  kasvaa ikuisesti). **Reconcile rakentaa indeksin uudelleen** täydellä skannauksella jos se puuttuu/
  on epäeheä (kuten counters.json).
- **cleanup (kilpajuoksuton, plan/execute §15 B1):** tuottaa ensin koneluettavan suunnitelman
  (`--dry-run` pysähtyy tähän), sitten suorittaa. Kattaa: lähteen poisto, `$DEST_ROOT/.tmp`-orvot,
  `$BACKUP_DIR`-retention (§10), `scans/`-TTL (§5.5). Lähteen poisto: per-disc-lukko
  (`locks/disc-<sha1>.lock`); sen sisällä re-check että discen kaikki jobit yhä `done|user_skip|
  abandoned` (ei muuttunut unskipillä/retryllä), tuore sisältötarkistus (§8.4-funktio, §14 R1),
  **audit-rivi ennen poistoa (§15 B2)**, vasta sitten poista. `unskip`/`retry` ottavat saman lukon.
- **Kuitattujen (`abandoned`) mittarikatve (tarkistuksen kohta 8):** `ack-quarantine` poistaa levyn
  `quarantine_gb`:stä heti, mutta VOB:it ovat levyllä kunnes `cleanup` ajetaan — siinä välissä tila
  olisi näkymätön (ei velassa eikä karanteenissa). Estetään kahdella toisiaan tukevalla keinolla:
  (1) `abandoned`-lähteet näkyvät omana lukunaan **`abandoned_gb`** (status.json) kunnes siivottu,
  JA (2) `ack-quarantine` **laukaisee cleanupin kyseiselle `disc_key`:lle** heti (per-disc-lukossa),
  joten katve on lyhyt ja aina näkyvä. Ei uutta näkymätöntä lattiaa (§7:n koko idea).
- **Orpo-tempien siivous (tarkistuksen kohta 9):** cleanup pyyhkäisee `$DEST_ROOT/.tmp/*` ja poistaa
  jokaisen tempin **jolle ei löydy vastaavaa `encoding`-jobia** (id ei enää olemassa, id vaihtunut,
  `--force` loi uuden, tai reclaim ei ehtinyt). Ilman tätä NAS:iin jää hiljaa kasvava temp-roska —
  ja koska `DEST_MIN_FREE_GB` on nyt portti kaikelle enkoodaukselle (§8.1), täyttyminen pysäyttäisi
  koko järjestelmän. **Yksi KOVA ehto (kaikki AND, ei "tai" — poisto on peruuttamaton, tarkistuksen
  kohta 7):** poista temp vain jos (1) sille **ei löydy `encoding`-jobia**, JA (2) **mikään prosessi
  ei pidä sitä auki** (`/proc/*/fd`-skannaus — toimii, worker on lokaali prosessi), JA (3) sen
  **mtime on turvamarginaalia vanhempi**, JA (4) **cleanup ei koskaan aja ennen kuin
  boot-reconcile on valmis**. Pelkkä "vanhempi kuin encoding-jobit" -heuristiikka voisi poistaa
  elävän enkoodauksen tempin erityisesti tapauksessa A (adoptoitu worker) jos cleanup ehtii ennen
  reconcilea — siksi avoin-fd-ehto on pakollinen, ei vaihtoehtoinen.
- **Ekstranumerointi (arkisto huomioitu, tarkistuksen kohdat 4 & 6b):** per-dest-lukon sisällä
  numero = **max(kohdekansiossa levyllä olevat ekstraindeksit ∪ KAIKKIEN kolmen hakemiston
  (`jobs/`, `problematic/`, `jobs/done/`) jobien varaamat ekstra-out_namet samaan dest_diriin) + 1**.
  Done-ekstrojen tiedostot ovat levyllä (kohdekansion skannaus kattaa ne), mutta **failed-ekstra asuu
  `problematic/`:ssa eikä sen tiedostoa ole levyllä** (verifiointi hylkäsi, kirjastoon ei koskettu) —
  silti se pitää numeroaan, koska §8.6 lupaa retryn säilyttävän saman numeron. Jos unioni ei kattaisi
  `problematic/`:ia, uusi enqueue saisi saman numeron → retry törmäisi. Siksi unioni kattaa **samat
  kolme hakemistoa kuin idempotenssitarkistus (§5.1)**. Numero sidotaan enqueue-hetkellä
  tittelijärjestyksessä; **retry säilyttää saman numeron** (ei aukkoa/törmäystä).
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
4. Lähteen VOB-poisto vain disceille joiden kaikki jobit `done` (verifioitu), `user_skip` tai
   `abandoned` — sama invariantti kuin §4/§8.6 (tarkistuksen kohta 4c).
5. Vanhat rakenteet poistetaan vasta kun migraatio todettu oikeaksi.

**Duplikaatit = eksplisiittinen rajoite, ei ominaisuus (§14 R4):** ehjä dest + olemassa oleva lähde →
ei uutta jobia samalle sisällölle. Sama teos eri julkaisuina / sama levy kahdesti = eri `disc_key` →
eri työt, ei yhdistetä. Karsinta jää käyttäjälle (valinnainen volume-nimi+kestosumma-tarkistus).

---

## 10. GUI-valmius + varmuuskopioiden retention

- **GUI** (erillinen projekti) lukee `status.json` + `jobs/*` + `problematic/*` +
  **`jobs/done/index.jsonl`** (sivutettu arkistolistaus, EI `jobs/done/*.json`-massaskannaus, A6) +
  `counters.json` + `scans/*` ja kutsuu ydinkomentoja. `rev`-kenttä (§2.6) tekee muutokset
  havaittaviksi; **valmis job näytetään muodossa `DONE — structurally verified`, ei pelkkänä `DONE`**
  (R2: verifiointi on rakenteellinen ei sisältövertaava — käyttäjä ei lue §14:ää, hän lukee sanan
  "done"; ei muuta ydintä); **virhekuori (§6.1)** tekee virheistä esitettäviä; **`dispatcher_alive` + `updated`**
  (§5.2) paljastavat alhaalla olevan daemonin; **`scans/<sha1(disc_key)>.json`** (§5.5/§6.2) tekee scan→vahvistus→
  enqueue-ketjusta kaatumisen kestävän. Ydin ei kysy mitään, kaikki tila on levyllä → GUI on tilaton
  renderöivä kerros. Ei muutoksia ytimeen.
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
   PID-reuse ei estä toipumista; dir-luokkasiirron keskeytys → reconcile pitää **suuremman `rev`:n**
   (§3; EI hakemistoprioriteettia — prioriteetti vain tasapelin ratkaisija).
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
14. **Config-validointi:** puuttuva avain → oletus; PARALLEL=0 / TEMP_WARN>TEMP_KILL / CRF=abc →
    kieltäytyminen, ei hiljainen jatko (§5.4).
15. **Lämpötappo ≠ virhe:** TEMP_KILL → `thermal_kill` → job `pending`, ei `failed` eikä karanteeniin.
16. **abandoned:** ack-quarantine → siivous sallittu, retry estetty; tila näkyy mallissa.
17. **Ekstranumerointi problematic/:n yli:** failed-ekstra pitää numeronsa, uusi enqueue ei törmää.
18. **counters-drift:** tapa kesken hakemistosiirron → boot-reconcile korjaa luvut täysin.
19. **Orpo-temp:** jätä temp ilman jobia → cleanup poistaa (kova AND-ehto); DEST_MIN_FREE ei täyty.
20. **Reconcile ei kumoa retryä/unskipiä (tarkistuksen kohta 1, ainoa jäljellä ollut hiljainen
    datavirhe):** tapa prosessi kesken `retry`n (`problematic/`→`jobs/`) hakemistosiirron →
    boot-reconcile säilyttää suuremman `rev`:n (uusi `pending`), EI vanhaa `failed`ia. Sama `unskip`ille.
21. **thermal_kill vs rc=0:** enkoodaus valmistuu lipun ja killin välissä → `done`, ei hukata.
22. **Config-validointi ei kaada lukukomentoja:** DEST_ROOT irti → `status`/`review-problematic`
    toimivat (varoittavat), kirjoittavat komennot kieltäytyvät.
23. **Virhekuori:** kelvoton komento → vakaa `{"ok":false,"error":…}` stdoutiin, rc≠0.
24. **scan-pysyvyys:** scan → tapa GUI ennen enqueueta → `$STATE/scans/<sha1>.json` säilyy, enqueue
    lukee sen ilman uudelleenskannausta.
25. **A1 `--force` vs reconcile:** `--force` olemassa olevalle id:lle jonka kaksoisrecord jäi
    kaatumisesta → pakotettu record voittaa (`rev=max+1`), EI vanha suurempi-rev.
26. **B1 dry-run:** `cleanup --dry-run` ja `migrate --dry-run` eivät koske levyyn; tuotettu
    suunnitelma vastaa TÄSMÄLLEEN sitä mitä execute tekee.
27. **B2 audit:** audit-rivi on olemassa **ennen** poistoa; kesken tapettu cleanup jättää rivin joka
    paljastaa mitä oltiin tekemässä.
28. **B3 state_rev:** job-muutos → `state_rev` kasvaa; ei muutosta → ei kasva (GUI voi luottaa).
29. **A6 arkistoindeksi:** 1000 arkistoitua jobia → GUI-listaus rakentuu `index.jsonl`:stä lukematta
    yhtään `jobs/done/*.json`-tiedostoa.
30. **Append-atomisuus (kohta 2):** N rinnakkaista kirjoittajaa appendaa `index.jsonl`/`audit.jsonl`
    yksi-`write()`-muodolla → jokainen rivi eheä, ei lomittunutta (todistaa §8.6/§15 B2 -sopimuksen,
    EI testin 2 kautta joka koskee job-tiedostoja).
31. **sync-rc (kohta 1):** `sync` epäonnistuu vaiheessa 4 (renamen jälkeen) → `done`ia EI kirjoiteta,
    lähde säilyy, uudelleenajo korvaa saman tiedoston ja onnistuu.
32. **Vahdin omistajuus + elpyminen (kohta 2):** päävahti myöhässä → varavahti käynnistyy → päävahti
    herää → vain toinen ohjaa pgid:tä (`thermal.lock`). **JA elpyminen:** päävahti elpyy varavahdin
    pitäessä lukkoa → heartbeat tuoreutuu (lukon ulkopuolella) → varavahti vapauttaa lukon ja poistuu
    → **fail-closed purkautuu, slotteja avataan taas** (ei jää pysyvään varatilaan). Ei lukkiumaa.
33. Vasta läpäisyn jälkeen pieni oikea päästä-päähän-testi, sitten migraatio.

---

## 13. Tarkistuslista toteuttajalle (seitsemän tarkastuskierrosta integroitu; jäännösrajoitteet §14)

- [ ] **`rev` ei koskaan nollaudu/laske; luonti olemassa olevalle id:lle = max(rev)+1 (§2.6 A1) —
      `--force` ei saa kumota reconcilea.**
- [ ] **`sync -d` tiedostolle, `sync` (ei -d) / python os.fsync hakemistolle (A4); listakohdat myös.**
- [ ] **scans/: sha1-nimi, skeema §5.5, TTL, atominen ylikirjoitus (A5).**
- [ ] **jobs/done/index.jsonl: GUI lukee indeksin, ei massaskannaa (A6); reconcile rakentaa uud.**
- [ ] **§15 B1: cleanup+migrate plan/execute + `--dry-run` (rakenne alusta, ei jälkiasennus).**
- [ ] **§15 B2: audit.jsonl, rivi ENNEN peruuttamatonta operaatiota.**
- [ ] **Append-tiedostot (index.jsonl, audit.jsonl): yksi `write()` + PIPE_BUF-mittainen rivi.**
- [ ] **`sync`in rc tarkistetaan (§2.2 rc 2/3); vaihe-4-fail → EI `done`ia, reclaim→pending (§2.5).**
- [ ] **Pää-/varavahti: `thermal.lock` vain STOP/CONT-ohjaukselle; heartbeat LUKON ULKOPUOLELLA
      (muuten lukkiuma + pysyvä fail-closed); vara poistuu kun heartbeat tuoreutuu.**
- [ ] **§15 B3: state_rev (counters.lockissa), GUI ohittaa skannauksen muuttumattomana.**
- [ ] **§15 B4: verifiointi itsenäinen funktio + `verify`-komento (3 kutsujaa jo nyt).**
- [ ] **§15 B5: `may_open_slot()` kokoaa 4 ehtoa; `pause`/`resume` (`$STATE/paused`).**
- [ ] **C: B1/B2/B4 valmiina+testattuna ENNEN kertaluontoista migraatiota.**
- [ ] **Reconcile ratkaisee kaksoisrecordin `rev`:llä (suurin voittaa), EI hakemistoprioriteetilla —
      muuten retry/unskip kumoutuisi hiljaa (§3, aito korrektiusbugi).**
- [ ] **Kestävyys: `sync -d` (EI olematon `fsync`-binääri); config-strippi `sed` (EI extglob).**
- [ ] **`thermal_kill` tulkitaan vain rc≠0:lla; lipun kirjoitus no-op jos status≠encoding.**
- [ ] **`abandoned` counters-enumissa + status.jsonissa + migraatiossa (ei jäänyt kesken).**
- [ ] **Config-validointi kaksitasoinen: lukukomennot eivät kaadu NAS-statiin (GUI-ystävällinen).**
- [ ] **Virhekuori §6.1 (vakaat koodit); status.json `dispatcher_alive`; scan-tulos `scans/`:iin.**
- [ ] **Orpo-temp: kova AND-ehto (ei avointa fd:tä ∧ mtime ∧ ei jobia ∧ reconcile valmis).**
- [ ] **ack-quarantine: `abandoned_gb`-luku + laukaisee cleanupin → ei mittarikatvetta.**
- [ ] **scan kaksivaiheinen (lsdvd-enumerointi → per-titteli-scan) + JSONL-edistyminen.**
- [ ] **Config-validointi (§5.4): oletukset + tyyppi/väli + kieltäydy käynnistymästä jos kelvoton.**
- [ ] **Lämpötappo erotettu virheestä: `thermal_kill`-lippu ennen killiä → pending, ei failed.**
- [ ] **`abandoned`-tila: ack-quarantine varoittaa, sallii siivouksen, estää retryn.**
- [ ] **Ekstranumeroinnin unioni kattaa problematic/:in (failed-ekstran numero ei törmää retryssä).**
- [ ] **Tittelien enumerointi lsdvd:llä → per-titteli-scan; enumeroinnin fail → disc:-broken.**
- [ ] **counters.json lasketaan reconcilessa täydellä skannauksella (ei pysyvää driftiä).**
- [ ] **Lämpö-varamekanismi = erillinen varavahtiprosessi, EI inline-pollaus dispatch-silmukassa.**
- [ ] **Orpo-`$DEST_ROOT/.tmp/*`-siivous cleanupissa (ei jobia → poista).**
- [ ] **Raitapolitiikan commentary = heuristiikka; verifiointi alarajana `original`-määrä.**
- [ ] **Pending-valinta pienin `seq` ensin; ignore-sääntö-varoitus (R7).**
- [ ] Kirjasto `$DEST_ROOT/.tmp`-tempin kautta (sama fs), EI kohdekansion sisällä, EI WORK_DIR→NAS.
- [ ] `$DEST_ROOT/.tmp` JA `$BACKUP_DIR` rajattu mediapalvelimen skannauksesta.
- [ ] Kanoninen JSON-kirjoitus (§2.2): mktemp + jq-rc + `-s` + `sync -d`(tiedosto)+`sync`(hakemisto)
      — YKSI funktio (EI olematon `fsync`-binääri).
- [ ] Kestävyysjärjestys (§2.5): temp→`sync -d`→mv→`sync`(dir)→vasta sitten `done`.
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
- **R7 — Mediapalvelimen ignore-sääntö on järjestelmän ULKOPUOLINEN oletus (tarkistuksen kohta 10).**
  §2.1/§10 nojaavat siihen että käyttäjä konfiguroi mediapalvelimen (Jellyfin) ohittamaan
  `$DEST_ROOT/.tmp/` ja `$BACKUP_DIR`. Jos sitä ei tehdä, puolivalmis mkv/varmuuskopio voi näkyä
  kirjastossa — juuri se mitä siirrolla haluttiin estää. Järjestelmä ei voi pakottaa vieraan
  palvelimen asetusta. **Lieventävä toimi:** käynnistys-/`rip`-tarkistus varoittaa näkyvästi jos
  odotettua ignore-merkintää (esim. `$DEST_ROOT/.tmp/.ignore` tai mediapalvelimen ohitussääntö) ei
  löydy — ei estä toimintaa, mutta ei jätä oletusta hiljaiseksi.
- **R8 — Kommenttiraidan tunnistus on heuristiikka (tarkistuksen kohta 8, §8.3).** DVD-metadatan
  rooli-lippu on usein tyhjä/väärä; `original+commentary` arvaa tarvittaessa ("toinen samankielinen
  raita"). Verifiointi käyttää alarajana `original`-määrää ettei arvaus hylkää jobeja. Väärä
  kommenttivalinta on laatuseikka, ei rakenteellinen virhe.

---

## 15. Läpileikkaavat sopimukset (sitovat NYT, toteutus vaiheistuu §10/§C mukaan)

Nämä eivät ole §6:n komentolistan hännille ripustettavia erillisiä ominaisuuksia — juuri se
sijoittelu tekisi niistä myöhemmin unohtuvia. Ne **rajoittavat sitä miten muut osat kirjoitetaan**,
joten ne ovat sopimuksia jotka lyödään lukkoon nyt.

**B1 — `cleanup` ja `migrate` rakennetaan plan/execute-parina.** Molemmat tuottavat ensin
**koneluettavan suunnitelman** (mitä poistettaisiin, mitkä lähteet, montako tavua vapautuisi, mikä
ehto laukaisi kunkin) ja suorittavat vasta sitten. **`--dry-run` = sama komento ilman execute-vaihetta**
(käytännössä ilmainen jos rakenne on tämä alusta). Jos nämä kirjoitetaan yhtenä "päätä ja tee"
-silmukkana, kuivaharjoittelun lisääminen jälkikäteen vaatii molempien purkamisen. Nämä ovat spec'n
kaksi tuhoavinta komentoa ja migraatio ajetaan **kerran** 270 GB:n päälle — turvaverkko, ei mukavuus.

**B2 — Audit-loki: `$STATE/audit.jsonl` (append-only).** Rivi per peruuttamaton operaatio: aikaleima,
operaatio, kohde, koko, laukaissut ehto, komento. Kirjoituskohdat: lähteen poisto, kirjaston korvaus,
`ack-quarantine`, orpo-temppien poisto. **Rivi kirjoitetaan ENNEN operaatiota, ei jälkeen** — jotta
kesken jäänyt poisto näkyy lokista (mitä oltiin tekemässä). Append noudattaa **samaa
yksi-`write()`/PIPE_BUF-atomisuussopimusta kuin `index.jsonl` (§8.6)**. Läpileikkaava: kohdat ovat
hajallaan §8.6:ssa, ja jälkikäteen lisättynä yksi jää aina lokittamatta — ja se yksi on aina se joka
kaivattaisiin.

**B3 — `state_rev` status.jsoniin.** Globaali monotoninen laskuri joka kasvaa **jokaisella `rev`++:lla
(§2.6), MYÖS kun tilalaskurit eivät muutu** (tarkistuksen kohta 4). Esim. `skip_requested=true` tai
`thermal_kill=true` eivät siirrä yhtään `counters.json`-lukua, mutta ovat job-muutoksia jotka GUI:n on
havaittava — jos `state_rev` kasvaisi vain laskurin muuttuessa, koko lupaus ("ohita skannaus kun mikään
ei ole muuttunut") pettäisi hiljaa näissä. **`counters.lock` on vain `state_rev`in serialisointipaikka,
EI ehto sen kasvulle.** GUI vertaa yhtä lukua ja ohittaa hakemistoskannauksen kun se ei ole muuttunut.
Tämä yhteys on päätettävä nyt, koska se on kaikkein huonoin jälkiasennettava (kirjoituskohdat olisivat
jo hajallaan §2.6:n viidessä paikassa).

**B4 — Verifiointi (§8.4) itsenäisenä funktiona + `verify`-komento.** Funktio ottaa `(tiedosto,
odotukset)` → rakenteinen tulos, **ei upotettuna workerin commit-polkuun**. Sama funktio palvelee jo
nyt kolmea kutsujaa: worker-commit, `cleanup`-recheck (§8.6/§14 R1), migraation `done`-päätös (§9).
Sen päälle **`verify [<id>|--all]`** jolla kirjaston voi tarkistaa jälkikäteen (käyttäjä poisti
tiedoston käsin, NAS korruptoitui, `done` ei enää vastaa todellisuutta). **`--all` on raskas
(800+ kohdetta × `ffprobe` NAS:illa, kilpailee enkoodausten I/O:sta, tarkistuksen kohta 5):** se on
tarkoitettu ajettavaksi **jonon ollessa tyhjä**, ja se noudattaa kohteliaisuusehtoa — rajattu
rinnakkaisuus ja tauko jos enkoodauksia on käynnissä (samaan tapaan kuin `may_open_slot()` väistää
kuormaa). Ei aja täyttä kirjastoa täydellä teholla kesken enkoodausjonon.

**B5 — Yksi predikaatti `may_open_slot()` + `pause`/`resume`.** Slotin avaamisen ehdot (§8.1 levytila
WORK+DEST, §8.2 lämpöheartbeat, PARALLEL-katto) kootaan **yhdeksi predikaatiksi**, ja **pause on neljäs
ehto** (lippu `$STATE/paused`): `pause` → ei uusia slotteja, käynnissä olevat jatkuvat loppuun;
`resume` → normaali. **Huom:** "aseta `PARALLEL=0`" on §5.4:n validoinnin kieltämä (`PARALLEL≥1`),
joten siistiä pysäytystä ei ole tällä hetkellä lainkaan SIGTERMin lisäksi — siksi pause kuuluu
sopimukseen nyt, ei erilliseksi ehdoksi neljänteen paikkaan myöhemmin.

---

## C. Vaiheistus (sopimus vs. koodi)

Sopimus (§1–§15) lyödään lukkoon **kerralla**; koodi syntyy §10:n vaiheissa ja jokainen vaihe
testataan erikseen. **Yksi kova ehto: B1 (`--dry-run`), B2 (audit-loki) ja B4:n verifiointifunktio
ovat valmiina ja testattuina ENNEN migraatiota**, koska migraatio on kertaluontoinen, ei peruttavissa
eikä toistettavissa. Ainoa aidosti myöhemmäksi siirtyvä osa on **GUI itse** — erillinen kerros, ei
ytimen ominaisuus.

Tämä spesifikaatio on itsenäinen eikä edellytä vanhan koodin tuntemusta. **Kymmenen tarkastuskierrosta
(13+20+10+14+10+9+6+6+3+2 riskiä + GUI-aukot + läpileikkaavat §15) on integroitu sopimuksiksi.**
En väitä että "kaikki riskit on ratkaistu" — tunnistetut korjattavat kohdat on korjattu, ja loput ovat
§14:n (R1–R8) tietoisia, dokumentoituja rajauksia. Seitsemännen kierroksen aito korrektiusriski oli
**`--force` joka olisi voinut kumota `rev`-reconcilen — nyt `rev` on globaalisti monotoninen (§2.6 A1)**;
lisäksi `sync -d`:n väärä hakemistokäyttö (A4), `scans/`:n ja arkiston GUI-skaalaus (A5/A6) ja viisi
läpileikkaavaa sopimusta (**§15**: dry-run, audit-loki, `state_rev`, itsenäinen verifiointi, pause) on
lukittu — nyt, jotta ne eivät jää myöhemmin unohtuviksi hännänpätkiksi. Sopimus on lukossa; toteutus
vaiheistuu §C:n mukaan, ja **B1/B2/B4 ovat ehtona ennen kertaluontoista migraatiota**.
