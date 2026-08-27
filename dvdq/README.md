# dvdq — DVD-rippaus- ja enkoodausjärjestelmä

Toteutus `UUSI_ARKKITEHTUURI_suunnitelma.md`-spesifikaatiosta (lukittu, 10 tarkastuskierrosta).
Yksi globaali enkoodausjono, N rinnakkaista, metadata rippausvaiheessa, viat sivuun, kestävä tila.

## Rakenne

```
dvdq                 CLI-entry (ei-interaktiivinen ydin, §1). Tulos = JSON-kuori stdoutiin (§6.1).
lib/common.sh        config+validointi, virhekuori, kestävä JSON-kirjoitus (sync -d), lukot, seqfile
lib/jobs.sh          job-datamalli, per-job-CAS, reconcile (rev), counters+state_rev, index/audit, ekstranumerointi
lib/commands.sh      enqueue/skip/unskip/retry/status/pause/resume/review-problematic
lib/verify.sh        §8.4 rakenteellinen+sisältöverifiointi + verify-komento
lib/cleanup.sh       cleanup (plan/execute) + ack-quarantine + karanteeni-/velkamittarit
lib/scan.sh          §6.2 scan (lsdvd-enumerointi → per-titteli HandBrake) + §8.3 raitapolitiikka
lib/rip.sh           §7 rip (levytila-esiehto → dvdbackup → scan)
lib/migrate.sh       §9 migraatio (plan/execute) — AJO vasta luvalla
lib/thermal.sh       §8.2 lämpövahti (erillinen prosessi, heartbeat lukon ulkopuolella)
lib/dispatch.sh      §8 dispatcher + worker (pitää slot-lukkoa) + kaatumistoipuminen (4 tapausta)
systemd/             dvdq-dispatch.service, dvdq-thermal.service
config.example       konfiguraatiomalli → ~/.config/rip-dvd/config
tests/               kattava testisarja (kukin osio ajettavissa erikseen)
```

## Komennot (kaikki palauttavat JSON-kuoren §6.1)

- `dvdq rip <laite>` — rippaa levy + skannaa (UI vahvistaa + enqueuaa)
- `dvdq scan <dvd_dir>` — skannaa tittelit (JSONL-edistyminen, scans/<sha1>.json)
- `dvdq enqueue --source S --title N --kind K --name NIMI [--year --season --episode --role --force]`
- `dvdq dispatch [--once]` — enkoodausdaemon (systemd)
- `dvdq thermal [--backup]` — lämpövahti (systemd)
- `dvdq status [--json]` / `dvdq review-problematic`
- `dvdq skip|unskip|retry <id>` / `dvdq ack-quarantine <id>`
- `dvdq verify [<id>|--all]` — §8.4 jälkitarkistus
- `dvdq cleanup [--dry-run]` — lähteen poisto + orpo-tempit + retention (plan/execute)
- `dvdq migrate --manifest FILE [--dry-run]` — vanhan jonon tuonti
- `dvdq pause | resume` — pysäytä/jatka uusien slottien avaus
- `dvdq reconcile` — käynnistyksen tila-eheytys

## Testien ajo

```
for t in dvdq/tests/test_*.sh; do echo "== $t =="; bash "$t" | tail -1; done
dvdq/tests/test_dispatch.sh   # ajaa dt_*-osiot erillisinä prosesseina
```
Async-osiot (worker päästä-päähän, oikea rinnakkaisuus, oikea DVD/lämpö) todennetaan brainbinilla
(§12/9) — dev-koneella STUB-työkalut ja synkroniset testit.

## Käyttöönotto brainbinille (EI vielä tehty — §C + vanhat enkoodaukset)

**Järjestys on sitova (§C):**
1. Odota että vanhat `rip-dvd.sh`-enkoodaukset ovat valmiit (uusi järjestelmä ei häiritse niitä).
2. Asenna toolchain: `lsdvd`, `HandBrakeCLI`, `dvdbackup`, `mkvtoolnix`, `jq`, ffmpeg (dvdvideo-tuki §8.5).
3. Kopioi `dvdq/` → esim. `/usr/local/lib/dvdq/`, symlinkkaa `dvdq` PATHiin (atominen deploy temp+mv).
4. `cp config.example ~/.config/rip-dvd/config` ja muokkaa.
5. Aja koko testisarja brainbinilla; validoi worker päästä-päähän oikealla enkoodauksella.
6. **Ennen migratea:** varmista B1 (`cleanup/migrate --dry-run`), B2 (`audit.jsonl`), B4 (`verify`)
   toimivat. Aja `migrate --dry-run` ja tarkista suunnitelma. Vasta sitten `migrate` (270 GB,
   PERUUTTAMATON — käyttäjän erillinen lupa).
7. Ota systemd-unitit käyttöön. Rajaa mediapalvelin ohittamaan `$DEST_ROOT/.tmp` ja `$BACKUP_DIR` (R7).
```

## Tietoiset poikkeamat spec'stä ja rajoitteet

- **`migrate --manifest FILE`** poikkeaa §9:stä (joka lukee vanhat `session_*/.queue`-hakemistot):
  migraatio ottaa **eksplisiittisen JSONL-manifestin** (yksi vanha jonorivi per rivi). Erillinen
  adapteri muuntaa `rip-dvd.sh`:n `.queue` → JSONL; se viimeistellään brainbinilla oikeaa dataa
  vasten. Manifesti on turvallisempi (dry-run näyttää tarkalleen mitä tuodaan) mutta on tietoinen
  spec-poikkeama.
- **Enkooderin käynnistys nojaa non-interactive-shelliin** (daemon): `setsid enc &` → `$!` on
  enkooderin pgid vain kun job control on pois päältä. Systemd ajaa daemonin non-interactivena, joten
  tämä pätee — mutta se on hauras riippuvuus. Todennettava brainbinilla (`ps -o pgid`).
- **Orpo-tempin fd-tarkistus** (`/proc/*/fd`) ei näe muiden käyttäjien fd:itä ilman roottia; 5 min
  mtime-marginaali kattaa käytännön tapaukset. Kova AND-ehto on niin kova kuin yhden käyttäjän
  näkymä sallii.
- **Sandbox-testaus:** dev-koneen bash-työkalu tappaa `setsid`-prosesseja käynnistävät komennot →
  `worker_run` päästä-päähän (oikea rinnakkaisuus, setsid/pgid, oikea lämpö, oikea DVD) todennetaan
  brainbinilla. Dev-koneella STUBit + synkroniset testit (n. 190 väitettä).
