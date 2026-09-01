# dvdq — DVD-rippaus- ja enkoodausjärjestelmä

Toteutus lukitusta spesifikaatiosta `../UUSI_ARKKITEHTUURI_suunnitelma.md` (10 tarkastuskierrosta +
2 koodikatselmusta). Korvaa vanhan `rip-dvd.sh`:n. Tämä dokumentti on järjestelmän täydellinen
käyttö- ja ylläpito-ohje; itse suunnitteludokumentti (§-viitteet) on erillinen.

**Ydinajatus:** rippaa DVD-levyt, enkoodaa x265-mkv:ksi mediakirjastoon, ja hallitsee tätä **yhtenä
globaalina jonona** joka enkoodaa N kohdetta rinnakkain riippumatta lähdelevystä. Kaikki tila on
levyllä koneluettavana (JSON) ja atomisesti kirjoitettuna — järjestelmä kestää kaatumisen, sähkökatkon
ja rinnakkaiset kirjoittajat.

---

## 1. Suunnitteluperiaatteet (mitä järjestelmä takaa)

| Periaate | Miten toteutettu |
|----------|------------------|
| **Ydin erillään käyttöliittymästä** | Komennot eivät kysy mitään interaktiivisesti; tulos on aina JSON-kuori stdoutiin (§6.1). UI/GUI lukee tilan ja kutsuu komentoja. |
| **Kaikki jaettu tila atomisesti** | `write_json_atomic`: mktemp + jq/rc-guard + `sync -d`(tiedosto) + `sync`(hakemisto) → ei koskaan katkennutta/tyhjää tiedostoa. |
| **Kestävyys sähkökatkossa** | Kohdetiedosto fsyncataan ENNEN `done`-tilan kirjoitusta → `done` ei koskaan ehdi levylle ennen kohdetta. |
| **Yksi globaali jono** | Per-job-tiedostot; rinnakkaisuus yli levyrajojen; ei jaettua muutettavaa jonotiedostoa → ei kilpajuoksua. |
| **Kaatumistoipuminen** | Worker pitää slot-lukkoa ITSE; recover luokittelee 4 tapausta (worker elää / kuoli / molemmat / reboot) slot-lukon + (pid,starttime) perusteella. |
| **Viat sivuun** | Rikkinäistä ei koskaan yritetä automaattisesti uudelleen; failed/broken karanteeniin, erillään enkoodausvelasta. |
| **Peruuttamattomat op:t turvallisesti** | Lähteen poisto / kirjaston korvaus vaativat aina tuoreen sisältöverifioinnin; audit-rivi kirjoitetaan ENNEN operaatiota. |
| **Mitään ei tuotantoon testaamatta** | ~200 synkronista testiväitettä (11 testisarjaa). |

---

## 2. Rakenne

```
dvdq                 CLI-entry (ei-interaktiivinen ydin). Tulos = JSON-kuori stdoutiin.
lib/common.sh        config+validointi, virhekuori, kestävä JSON-kirjoitus, lukot, seqfile, LC_ALL=C.UTF-8
lib/jobs.sh          job-datamalli, per-job-CAS, reconcile (rev), counters+state_rev, index/audit, ekstranumerointi
lib/commands.sh      enqueue/skip/unskip/retry/status/pause/resume/review-problematic + sanitize_name
lib/verify.sh        §8.4 rakenteellinen+sisältöverifiointi + verify-komento
lib/cleanup.sh       cleanup (plan/execute) + ack-quarantine + karanteeni-/velkamittarit
lib/eta.sh           MITATTU jono-ETA (nopeuskerroin toteutuneesta) + HandBraken live-progress-parseri
lib/scan.sh          scan (lsdvd-enumerointi → per-titteli HandBrake) + raitapolitiikka
lib/rip.sh           rip (levytila-esiehto → dvdbackup → scan)
lib/migrate.sh       migraatio (plan/execute) — vanhan jonon tuonti
lib/thermal.sh       lämpövahti (erillinen prosessi, heartbeat lukon ulkopuolella)
lib/dispatch.sh      dispatcher + worker (pitää slot-lukkoa) + kaatumistoipuminen + HandBrake-komento
tools/tila           ihmisluettava tilanäkymä (mitattu ETA + live-fps)
systemd/             dvdq-dispatch.service, dvdq-thermal.service
config.example       konfiguraatiomalli → ~/.config/rip-dvd/config
tests/               kattava testisarja (kukin osio ajettavissa erikseen)
```

**Tila levyllä** (`$WORK_DIR/state/`): `jobs/` (pending/encoding), `problematic/` (failed/broken),
`jobs/done/` (done/user_skip/abandoned) — yksi tiedosto per job, sijainti = tilaluokka. Lisäksi
`counters.json`, `status.json`, `seqfile`, `locks/`, `slots/`, `scans/`, `audit.jsonl`,
`jobs/done/index.jsonl`, `thermal.heartbeat`, `dispatch.pid`, `paused`.

---

## 3. Job-tilat

| tila | sijainti | merkitys | lähde saa siivota? |
|------|----------|----------|--------------------|
| `pending` | jobs/ | odottaa enkoodausta | ei |
| `encoding` | jobs/ | worker-slotti enkoodaa | ei |
| `done` | jobs/done/ | enkoodattu, verifioitu, kestävästi kirjastossa | **kyllä** |
| `failed` | problematic/ | enkoodaus epäonnistui (rc≠0 / verify hylkäsi) | ei (retry voi tarvita) |
| `broken` | problematic/ | lähde viallinen (lukuvirhe/scan-hang) | ei (retry tarvitsee lähteen) |
| `abandoned` | problematic/ | käyttäjä kuittasi karanteenin (retry EI enää mahdollinen) | **kyllä** |
| `user_skip` | jobs/done/ | käyttäjä päätti ettei tehdä | **kyllä** |

Lähteen VOB-poisto vain kun KAIKKI saman levyn jobit ovat `done`/`user_skip`/`abandoned`.

---

## 4. Komennot

Kaikki palauttavat JSON-kuoren stdoutiin: `{"ok":true,...}` tai `{"ok":false,"error":"<koodi>","detail":{...}}` (rc≠0).

| Komento | Kuvaus |
|---------|--------|
| `tools/rippaa [laite]` | **INTERAKTIIVINEN** rippaus→enqueue (oletuslaite /dev/sr1): rippaa, näyttää tittelit + pääelokuva-ehdotuksen, kysyy nimen/tyypin, enqueuaa metadatoineen. Tämä on tavallinen käyttötapa. |
| `dvdq rip <laite>` | (matalan tason) rippaa levy (dvdbackup) + skannaa → `scans/<sha1>.json`. `tools/rippaa` käyttää tätä. |
| `dvdq scan <dvd_dir>` | skannaa tittelit (lsdvd→HandBrake), JSONL-edistyminen, pääelokuva-heuristiikka. |
| `dvdq enqueue --source S --title N --kind K --name NIMI [--year Y --season SS --episode EE] [--role main\|extra] [--force] [metadata-liput]` | lisää työ jonoon (idempotentti). |
| `dvdq dispatch [--once]` | enkoodausdaemon (systemd). `--once` = yksi täyttökierros. |
| `dvdq thermal [--backup]` | lämpövahti (systemd). |
| `dvdq status` | tilanne JSON-kuorena (counters, encoding-lista live-fps:llä, mitattu ETA, mittarit). |
| `tools/tila` | ihmisluettava tilanäkymä (ks. §6). |
| `dvdq review-problematic` | listaa failed/broken-jobit. |
| `dvdq skip <id>` | pending→user_skip; encoding→skip_requested (worker keskeyttää siististi). |
| `dvdq unskip <id>` / `dvdq retry <id>` | →pending. Vaatii lähteen olemassaolon. |
| `dvdq ack-quarantine <id>` | failed/broken→abandoned. **Peruuttamaton, estää retryn.** Siivoaa vain kyseisen levyn. |
| `dvdq verify [<id>\|--all]` | kirjaston jälkitarkistus (§8.4). `--all` vain tyhjälle jonolle/pauselle. |
| `dvdq cleanup [--dry-run]` | lähteen poisto + orpo-tempit + backup-retention + scans-TTL. Plan/execute. |
| `dvdq migrate --manifest FILE [--dry-run]` | vanhan jonon tuonti. **Kertaluontoinen, peruuttamaton.** |
| `dvdq pause` / `dvdq resume` | pysäytä/jatka uusien slottien avaus (käynnissä olevat jatkuvat loppuun). |
| `dvdq reconcile` | käynnistyksen tila-eheytys (rev-pohjainen kaksoisrecord + counters + index). |

---

## 5. Konfiguraatio (`~/.config/rip-dvd/config`)

`AVAIN=arvo` per rivi, EI rivinsisäisiä kommentteja. Validoidaan käynnistyksessä (tyypit/välit/
ristiriidat) — kelvoton arvo → kieltäytyminen. Puuttuva avain → oletus. Ks. `config.example`.

Keskeiset: `PARALLEL` (1..`PARALLEL_MAX`), `CRF`, `ENCODER`, `AUDIO_POLICY`
(`original`/`original+commentary`/`all`), `SUB_POLICY`, `DEINTERLACE`, `DEST_ROOT`, `WORK_DIR`,
`BACKUP_DIR` (mediapalvelimen skannauksen ULKOPUOLELLA), `TEMP_WARN`/`TEMP_KILL`, `RIP_MIN_FREE_GB`,
`DEST_MIN_FREE_GB`, `RIP_AHEAD_MAX_GB`, `QUARANTINE_MAX_GB`, `*_RETENTION_DAYS`, `SCAN_TTL_DAYS`.
Kaikki `*_GB` gigatavuja.

**Kaksitasoinen validointi:** lukukomennot (`status`, `verify`, `thermal`, `pause`…) EIVÄT tee
NAS-statia → toimivat NAS-katkon aikana. Vain NAS-kirjoittajat tarkistavat `DEST_ROOT`-kirjoitettavuuden.

---

## 6. Tilanäkymä ja TOTUUDENMUKAINEN aikaennuste

Vanhan järjestelmän ETA oli hyödytön: rivilaskuri sisälsi ohituksia ja HandBraken per-kohde-ETA oli
optimistinen. `dvdq` korjaa tämän rakenteellisesti:

- **Jäljellä oleva työ** = `pending`-jobien todellinen lukumäärä (per-job-jono, ei haamurivejä) ja
  niiden tallennettujen `duration_s`-videosekuntien summa.
- **Nopeus MITATTU:** `speed_factor` = mediaani(`duration_s` / seinäaika) viim. 20 valmistuneesta
  jobista (`started`→`finished`).
- **`queue_eta_s`** = jäljellä olevat videosekunnit ÷ `speed_factor` ÷ `PARALLEL`. **Tyhjä (null)
  ennen ensimmäisiä valmistumisia** — ei arvausta.
- **Live-fps/%** luetaan HandBraken oikeasta progress-rivistä per-job-lokista.

`tools/tila` renderöi tämän ihmisluettavasti:
```
Enkoodataan:
  ● Blade Runner   73.59% , 10.50 fps, ETA 19min
Jono: 3 odottaa | 812 valmis | 3 failed | 5 broken | 12 user_skip | 2 abandoned
Mitattu tahti: 1.04× reaaliaika   →  jono valmis ~1h 54min (MITATTU)
```

---

## 7. Merkistö, localet ja tiedostonimet

- **Locale-riippumaton:** `dvdq` pakottaa sisäisesti `LC_ALL=C.UTF-8` (fallback `C`). Desimaali on
  AINA piste (awk/printf/jq oikein missä tahansa käyttäjän localessa — Suomen pilkku ei riko
  vertailuja) ja merkistö UTF-8 (Unicode säilyy).
- **Unicode-nimet** (ä/ö/日 ym.) säilyvät ehjinä läpi ketjun (läpinäkyvät tavujonot).
- **Tiedostonimien sanitointi** (`sanitize_name`): millä tahansa fs:llä/SMB:llä kielletyt merkit
  muunnetaan turvallisiksi ENNEN kirjaston polkua: `:`→` -`, `/ \ |`→`-`, `"`→`'`, `<`→`(`, `>`→`)`,
  `? *`→pois, kontrollimerkit pois, loppupisteet/-välit trimmataan. **Vain polut sanitoidaan; jobin
  `.name` säilyy raakana** (näyttö/metadata). (Vanha rip-dvd.sh ei sanitoinut lainkaan — vastuu oli
  käyttäjällä.)

---

## 8. Testien ajo

```bash
# synkroniset sarjat (ajettavissa dev-koneella, ei DVD-toolchainia):
for t in dvdq/tests/test_*.sh; do echo "== $t =="; bash "$t" | tail -1; done
# dispatcher-osiot (kukin OMANA prosessinaan):
dvdq/tests/test_dispatch.sh
```
Testit käyttävät STUB-työkaluja (lsdvd/HandBrake/dvdbackup korvattu). **Async-osat** (worker
päästä-päähän, oikea rinnakkaisuus, setsid/pgid, oikea DVD/lämpö) todennetaan **brainbinilla** —
dev-koneen bash-sandbox tappaa setsid-prosessit.

---

## 9. Käyttöönotto brainbinille (GATED)

**Järjestys on sitova:**
1. **Odota että vanhat `rip-dvd.sh`-enkoodaukset ovat valmiit** (uusi ei häiritse niitä — eri hakemisto).
2. Asenna toolchain: `lsdvd`, `HandBrakeCLI`, `dvdbackup`, `mkvtoolnix`, `jq`, ffmpeg (dvdvideo-tuki).
3. Kopioi `dvdq/` → `/usr/local/lib/dvdq/`, symlinkkaa `dvdq` PATHiin (atominen deploy temp+mv).
4. `cp config.example ~/.config/rip-dvd/config` ja muokkaa.
5. Aja koko testisarja brainbinilla; **validoi worker päästä-päähän oikealla enkoodauksella** +
   oikea DVD (lsdvd/HandBrake/dvdbackup) + oikea lämpö + oikea fps (`ps -o pgid`).
6. **Ennen migratea:** varmista B1 (`--dry-run`), B2 (`audit.jsonl`), B4 (`verify`). Aja
   `migrate --dry-run`, tarkista suunnitelma. Vasta sitten `migrate` (270 GB, PERUUTTAMATON —
   käyttäjän erillinen lupa).
7. Ota systemd-unitit käyttöön. Rajaa mediapalvelin ohittamaan `$DEST_ROOT/.tmp` ja `$BACKUP_DIR`.

---

## 10. Tietoiset poikkeamat ja rajoitteet

- **`migrate --manifest FILE`** poikkeaa spec'n §9:stä (joka lukee `session_*/.queue`-hakemistot):
  ottaa eksplisiittisen JSONL-manifestin (turvallisempi, dry-run näyttää tarkalleen). Adapteri
  rip-dvd.sh `.queue` → JSONL viimeistellään brainbinilla oikeaa dataa vasten.
- **Enkooderin pgid nojaa non-interactive-shelliin** (daemon): `setsid enc &` → `$!` = pgid vain
  kun job control pois. Systemd ajaa non-interactivena → pätee. Todennettava brainbinilla.
- **Verifiointi on rakenteellinen, ei sisältövertaava:** havaitsee katkenneen/tyhjän/vääränmittaisen,
  EI "väärä-mutta-oikeanmittainen" (väärä titteli samalla kestolla). Tekstityksen desync-havaitseminen
  on heuristiikka (varoitus, ei takuu).
- **Advisory-lukot** koordinoivat vain tämän järjestelmän prosesseja — ulkopuolinen käsin tehty muutos
  kohdekansioon ei ole suojattu.
- **Duplikaattilevyjä ei yhdistetä** (sama teos eri julkaisuina = eri työt).
- **Mediapalvelimen ignore-sääntö** (`$DEST_ROOT/.tmp`, `$BACKUP_DIR`) on ulkoinen oletus — järjestelmä
  varoittaa jos merkintää ei löydy, mutta ei voi pakottaa vieraan palvelimen asetusta.
- **Tiedostonimen lopullinen raja on kohde-fs:** sanitointi kattaa yleiset kielletyt merkit; jos SMB-jako
  on erittäin rajoittava, jotkin harvinaiset merkit voivat silti vaatia lisäsääntöjä.
- **Sandbox-testaus:** worker päästä-päähän + setsid/pgid + oikea DVD/lämpö = brainbin, ei dev-kone.

---

## 11. Suhde spesifikaatioon

`../UUSI_ARKKITEHTUURI_suunnitelma.md` on lukittu SUUNNITTELUdokumentti (§-viitteet, jäännösrajoitteet
R1–R8, testisuunnitelma). Tämä README on KÄYTTÖ-/YLLÄPITÖdokumentti. Koodin kommentit viittaavat
spec-pykäliin (esim. `§2.5`, `§8.6`) ja kertovat *miksi* — koodi ja suunnitelma pysyvät kytköksissä.
