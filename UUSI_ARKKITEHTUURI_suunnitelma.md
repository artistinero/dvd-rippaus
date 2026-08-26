# Uusi rippaus-/enkoodausarkkitehtuuri — täydellinen suunnitelma

Tavoite: korvata nykyinen rip-dvd.sh järjestelmällä joka on (1) **robusti**, (2) käyttää **yhtä
globaalia enkoodausjonoa** (rinnakkaisuus toimii ilman monia sessioita), (3) tallentaa **kaiken
metadatan valmiiksi**, (4) **tunnistaa ja siirtää viat sivuun** ajantasaiselle listalle, (5) on
**konfiguroitava** (kansiot, laatu ym.), ja (6) rakenteeltaan **GUI-valmis** (ydin erillään
käyttöliittymästä).

Tämä on SUUNNITELMA, ei toteutus. Toteutus tehdään vaiheittain ja testataan ennen tuotantoa —
mitään ei deployata käynnissä olevan rippauksen päälle ennen hyväksyntää.

---

## 0. Nykyisen rip-dvd.sh:n ongelmat joita tämä korjaa (kamman kanssa läpikäynti)

Löydetty tämän ja aiempien sessioiden aikana:

1. **Ei globaalia jonoa.** Jokainen ripattu levy → oma session-hakemisto + oma `.encode-only`-kutsu.
   Rinnakkaisuus toimii vain eri sessioiden VÄLILLÄ; yhden session sisällä per-session-lukko
   sarjallistaa. 17 levyä yhteen sessioon → 17 lukon takana jonottavaa prosessia, 1 ajaa.
2. **Lähde-VOB:it jäävät siivoamatta** valmistuneista sessioista → 270 GB roskaa levyllä (82 %
   täynnä), JA pending-tarkistus (perustuu "onko VOB olemassa") listaa valmiit sessiot
   käynnistys­kehotteessa.
3. **Valmis-tunnistus hauras.** Raporttimuoto vaihtelee (vanhoissa ei UNTRIED-riviä); jaettu
   `.encode-report` ylikirjoittuu joka osa-ajolla eikä kerro session kumulatiivista totuutta.
4. **Laatu (CRF 21) kovakoodattu** — käyttäjä oletti parasta mahdollista, ei kysytty. Pitää olla
   konfiguroitava.
5. **Metadataa ei tallenneta** rippausvaiheessa (kestot, tekstityskielet, mitat, fps, levyn kunto)
   → jälkikäteen probeaminen hidasta ja hauraaa (lsdvd/ffprobe epäonnistuu osalle).
6. **Viat yritetään enkoodata** joka kerta uudelleen sen sijaan että rikkinäiset siirrettäisiin
   sivuun. Ei ajantasaista "ongelmalliset"-listaa.
7. **Tekstitysbugi** (vanha HandBrake VobSub-desync) — levykohtainen, ei versiokohtainen; erillinen
   korjaustyökalu (korjaa-tekstitys.sh) rakennettu. Uusi HandBrake korjaa tulevat.
8. **Sijaintibugi** (anamorfiset/rajatut videot: tekstit ruudun ulkopuolella) — pitää huomioida
   crop-tiedon tallennuksessa.
9. **Ekstrojen nimeäminen / pääelokuvan tunnistus** — monta erikoistapausta (pääelokuva ei Part 01;
   Astronaut's Wife=Part03, Tetsuo=Part06). Numerointi laskettu epäluotettavasti.
10. **Interaktiiviset promptit sekoittuvat ydinlogiikkaan** → GUI mahdoton rakentaa nykyisen päälle.

---

## 1. Perusperiaate: YDIN erillään KÄYTTÖLIITTYMÄSTÄ (GUI-valmius)

Kaikki logiikka on **ydinkomennoissa** jotka eivät koskaan kysy interaktiivisesti mitään ja
lukevat/kirjoittavat **koneluettavaa tilaa** (JSON/JSONL). Käyttöliittymä (nyt CLI, myöhemmin GUI)
on ohut kerros joka kutsuu ydinkomentoja ja renderöi tilatiedostot.

```
  ┌─────────────┐     kutsuu      ┌──────────────────────────┐
  │ CLI (nyt)   │ ─────────────►  │  YDIN (komennot)         │
  │ GUI (myöh.) │                 │  rip / enqueue / dispatch│
  └─────────────┘  ◄───────────── │  status / skip / retry   │
        lukee tilan (JSON)        │  config                  │
                                  └──────────────────────────┘
                                        │ luku/kirjoitus
                                  ┌──────────────────────────┐
                                  │  TILA (koneluettava)     │
                                  │  queue.jsonl             │
                                  │  status.json (live)      │
                                  │  problematic.jsonl       │
                                  │  config                  │
                                  └──────────────────────────┘
```

**GUI rakennetaan myöhemmin** lukemalla samoja JSON-tiedostoja ja kutsumalla samoja ydinkomentoja
— ei tarvitse muuttaa ydintä lainkaan. Tämä on koko GUI-valmiuden ydin: **ei interaktiivisia
promptteja ytimessä, kaikki tila koneluettavana.**

---

## 2. Konfiguraatio (konfiguroitavat kansiot ym.)

Yksi tiedosto `~/.config/rip-dvd/config` (KEY=VALUE, laajennetaan nykyisestä):

```
# Rinnakkaisuus
PARALLEL=2
# Laatu (KÄYTTÄJÄN VALITTAVISSA — ei enää kovakoodattu 21)
CRF=21                    # 18 = lähes häviötön/isot tiedostot, 21 = tasapaino
ENCODER=x265
# Kansiot (KAIKKI konfiguroitavissa)
DEST_ROOT=/mnt/terastation/dlna/vids
DIR_MOVIES=movies
DIR_SERIES=series
DIR_DOCS=documentaries
DIR_MUSIC=music
DIR_MISC=misc
# Työhakemisto + lämpöturva
WORK_DIR=/home/keitsi/dvd-rip-tmp
TEMP_WARN=85
TEMP_KILL=95
# Vähimmäiskesto (mikä lasketaan "pitkäksi" tittelöksi)
MIN_DURATION=300
```

Ydin lukee tämän `grep`illä (ei `source`, turvallisuus). Muutokset config-tiedostoon vaikuttavat
seuraaviin ajoihin; dispatcher lukee PARALLEL/CRF tuoreena joka slot-varauksella (opittu
50°C-bugista: ei välimuistiin ladattua vanhaa arvoa).

---

## 3. Globaali enkoodausjono (RINNAKKAISUUDEN KORJAUS)

### 3.1 Yksi jonotiedosto: `WORK_DIR/state/queue.jsonl`
Yksi JSON-rivi per enkoodattava titteli (job). Ei enää session-hakemistoja jonon perustana.

```json
{"id":"a1b2c3","source":"/…/disc-042/VIDEO_TS","title":11,"type":"movie",
 "name":"Fargo","year":"1996","dest":"/…/movies/Fargo (1996)","out":"Fargo.mkv",
 "duration":5640,"width":712,"height":408,"dar":"1.86","fps":25,"format":"PAL",
 "crop":"66:66:2:2","subs":["fin","swe"],"audio":["eng"],"read_errors":0,
 "status":"pending","slot":null,"added":"2026-08-26T09:00:00","started":null,
 "finished":null,"fail_reason":null}
```

`status` ∈ `pending | encoding | done | failed | skipped | broken`.

### 3.2 Dispatcher (yksi pitkäikäinen prosessi)
Yksi taustaprosessi (tmux/systemd) joka:
1. Lukee `queue.jsonl`.
2. Pitää N slottia (N = PARALLEL, luettu tuoreena).
3. Poimii seuraavan `pending`-jobin joka EI ole lukittuna (per-dest-lukko ekstrojen numerointiin)
   ja jonka lämpötila sallii → asettaa `status=encoding`, käynnistää HandBraken.
4. Kun HandBrake valmis: siirtää tuloksen kirjastoon, `status=done` (tai `failed` + syy).
5. Päivittää `status.json` (live: per-job %, koko jonon ETA, lämmöt).
6. **True N-rinnakkaisuus riippumatta siitä miltä levyltä job on** — koska jono on yksi.

Ekstrojen numerointi: per-dest-kansio-lukko (opittu Taso B). Numero lasketaan job-kohtaisesti
lukon sisällä kirjoitushetkellä (ei jonon rakennusvaiheessa) → ei törmäyksiä rinnakkaisajossa.

Lämpöturva: sama todistettu throttle-mekanismi (koko koneen `kill -STOP`/`-CONT` yli 85°C).

### 3.3 Lähteen siivous (270 GB -ongelman korjaus)
Job-kohtainen: kun **kaikki saman lähteen (disc) jobit** ovat `done|skipped|broken`, lähde-VOB:it
poistetaan. Laskenta jonosta (ei per-session-laskurista) → luotettava. Ratkaisee sekä levytilan
ETTÄ "valmiit listautuvat kehotteessa" -ongelman (jono on totuus, ei VOB:ien olemassaolo).

---

## 4. Rippaus + metadatan tallennus

`rip <levy>` -ydinkomento:
1. `dvdbackup -M` levyltä työhakemistoon. Tallenna **READ_ERRORS** (levyn kunto).
2. **Yksi HandBrake `--scan --json`** → kaikki metadata kerralla: jokaisen tittelin kesto,
   mitat, DAR, fps, format, crop (autocrop), **tekstityskielet**, **äänikielet**.
3. Tunnista pääelokuva + ekstrat (ks. 4.1).
4. Kirjoita jokaisesta enkoodattavasta tittelistä **queue.jsonl-rivi täydellä metadatalla.**
5. Vikatarkistus (ks. 5).

Metadata on siis valmiina jonossa — enkoodaustila.sh / GUI ei koskaan probeaa mitään.

### 4.1 Pääelokuvan / ekstrojen tunnistus (erikoistapaukset)
- Ensisijaisesti: `MOVIE_TITLE_NUM` metadatasta jos annettu.
- Muuten: pisin titteli = pääelokuva, muut ekstroja — MUTTA tallenna KAIKKIEN kestot, ja
  tunnista tapaukset joissa pääelokuva ei ole ensimmäinen (Astronaut's Wife, Tetsuo).
- Sarjat: useampi pitkä titteli → jaksot (kysytään/konfiguroidaan jaksomäärä), täsmää kesto ↔ jakso.

---

## 5. Vikojen tunnistus + ongelmalliset sivuun (`problematic.jsonl`)

**Rikkinäisiä EI yritetä enkoodata.** Rippaus-/skannausvaiheessa tunnistetaan:
- `READ_ERRORS > kynnys` (levyvaurio, esim. District 9, 2012).
- Titteli jota HandBrake ei löydä / skannaus jumittaa (American Beauty).
- (Enkoodauksen jälkeen) rc≠0 tai tuotos liian pieni (<1MB) → merkitse `failed`.

Nämä → `problematic.jsonl` (id, teos, levy, syy, aikaleima, status). **Ei koskaan
automaattista uusintayritystä.** Ydinkomento `review-problematic` listaa, `retry <id>` yrittää
uudelleen (esim. ddrescuen jälkeen). Tämä on se **ajantasainen lista** jota käyttäjä vaati.

---

## 6. Tila + edistyminen (status + GUI-syöte)

Dispatcher kirjoittaa `WORK_DIR/state/status.json`:
```json
{"updated":"…","parallel":2,"encoding":[
   {"id":"…","name":"Fargo","pct":42.1,"eta_s":1830,"fps":31.2,"slot":1}],
 "queue_pending":57,"queue_total_eta_s":41000,"temps":[55,58,54,56],"disk_free_gb":80}
```
- `enkoodaustila.sh` (CLI) renderöi tämän.
- Tuleva **GUI** lukee saman → reaaliaikainen näkymä ilman muutoksia ytimeen.
- Per-job ETA lasketaan tallennetusta `duration`sta / mitatusta HandBrake-nopeudesta (fps).

---

## 7. Migraatio nykyisestä (backlogin jatkuvuus + 270 GB siivous)

Kertaluontoinen `migrate`-komento:
1. Käy läpi `session_*/.queue`-rivit → luo queue.jsonl-entryt.
2. Merkitse `done` ne joiden tulos on jo kirjastossa (dest-tarkistus) tai joiden lähde on siivottu.
3. Kirjoita metadata mitä saa (probe kerran migraatiossa; uudet rippaukset saavat sen suoraan).
4. Tunnista 14 sessiota joilla lähde-VOB:it (270 GB): jos jonon mukaan done → **siivoa lähteet**
   (vapauttaa ~270 GB), muuten jätä ja lisää pending-jobeina uuteen jonoon.
5. Vanhat session-hakemistot voidaan poistaa migraation jälkeen.

Migraatio ajetaan vasta kun uusi järjestelmä on testattu, EI kesken nykyistä rippausta.

---

## 8. Robustius + testaussuunnitelma (ennen tuotantoa)

Opittu: **ei luoteta testaamattomaan koodiin.** Ennen mitään tuotantokäyttöä:
1. `bash -n` + shellcheck.
2. **Eristetyt yksikkötestit** stub-HandBrakella (`sleep N; return 0/1`): dispatcher poimii oikein,
   N-rinnakkaisuus tasan N, per-dest-lukko estää törmäyksen, lähteen siivous laukeaa täsmälleen
   kerran per lähde kun kaikki sen jobit valmiit (ei koskaan liian aikaisin → ei datamenetystä).
3. **Sisältö-/kattavuustarkistukset** (opittu Easy Rider/Tetsuo): valmis tulos verifioidaan
   (video/ääni säilyneet, kesto järkevä) ENNEN kirjastoon kirjoittamista.
4. **Atominen deploy** (temp+mv), ei koskaan käynnissä olevan prosessin päälle.
5. Pieni oikea päästä-päähän-testi (1-2 levyä) ennen migraatiota.

---

## 9. Rakenne (tiedostot)

```
rip-core.sh          # ydin: komennot rip/enqueue/dispatch/status/skip/retry/config/migrate
                     #   — EI interaktiivisia promptteja, kaikki tila JSONina
rip                  # ohut CLI (kutsuu rip-core.sh:ta, hoitaa levynvaihtokehotteet)
enkoodaustila.sh     # (on jo) lukee status.json / queue.jsonl
~/.config/rip-dvd/config
WORK_DIR/state/queue.jsonl, status.json, problematic.jsonl
```
GUI (myöhemmin) = erillinen projekti joka kutsuu `rip-core.sh <komento>` ja lukee state/-JSONit.

---

## 10. Toteutusjärjestys (vaiheittain, kukin testataan erikseen)

1. **Konfiguraatio + tilamalli** (config, queue.jsonl-skeema, luku/kirjoitusfunktiot).
2. **Rip + metadatan tallennus** (dvdbackup + scan → queue-entryt täydellä metadatalla + vikatunnistus).
3. **Dispatcher** (globaali jono, N-slotti, per-dest-lukko, lämpöturva, lähteen siivous) — eristetyt
   testit stub-HandBrakella ENNEN oikeaa.
4. **status.json + enkoodaustila.sh -integraatio.**
5. **Migraatio** vanhasta + 270 GB siivous.
6. **CLI-kuori** (levynvaihto, käyttäjän valinnat) ohuena ytimen päälle.
7. (Myöhemmin) **GUI** state-JSONien + ydinkomentojen päälle.

---

## Yhteenveto

Tämä korvaa per-session-mallin **yhdellä globaalilla jonolla** (rinnakkaisuus toimii aidosti),
tallentaa **kaiken metadatan valmiiksi**, **siirtää viat sivuun** ajantasaiselle listalle, tekee
**laadun ja kansiot konfiguroitaviksi**, siivoaa **270 GB** roskaa, ja erottaa **ytimen
käyttöliittymästä** niin että GUI voidaan rakentaa myöhemmin koskematta logiikkaan. Kaikki
tämän session opit (testaamattomaan ei luoteta, atominen deploy, sisältötarkistus, ei
kovakoodattuja arvoja, ei stale-prosesseja) on rakennettu sisään.
