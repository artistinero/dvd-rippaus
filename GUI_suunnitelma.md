# dvdq GUI — suunnitelma (luonnos v1, 2026-09-02)

Tämä on **suunnitteludokumentti**, ei toteutus. Tavoite: graafinen käyttöliittymä dvdq:lle joka
tekee koko työnkulusta (levy → tiedot → rippaus → automaattinen enkoodaus → seuranta) helpon myös
ilman komentoriviä, on monikielinen (fi/en/es…) ja niin siisti että sen kehtaa jakaa muille.

## Peruslinjaus: GUI on OHUT kerros dvdq-ytimen päällä

dvdq-ydin on jo tietoisesti "GUI-valmis": **jokainen komento palauttaa JSONia** (`ok`/`error`-kuori),
`status` antaa koko jonon tilan, skannaus tuottaa JSONL-edistymistä, `verify` JSONia, ja
`dvdq daemon status` daemonin tilan. GUI EI toteuta mitään logiikkaa uudelleen — se vain
(a) kutsuu `dvdq`-komentoja, (b) näyttää niiden JSONin, (c) pollaa tilaa. Näin **CLI ja GUI pysyvät
aina samassa totuudessa** eikä bugeja tarvitse korjata kahteen paikkaan. Tämä on koko syy miksi
ydin rakennettiin JSON edellä.

## Miksi WEB-GUI (eikä työpöytäsovellus)

brainbin on käytännössä headless palvelin jota käytät SSH:lla toiselta koneelta. Siksi:
- **Web-GUI** (paikallinen palvelin brainbinillä, selain läppärillä/puhelimella) sopii parhaiten:
  näet jonon **sängystä puhelimella**, käynnistät rippauksen selaimesta, et tarvitse X-forwardausta
  etkä VNC:tä. Sopii täydellisesti "laita levy, kävele pois, seuraa muualta" -malliisi.
- Työpöytä-GUI (GTK/Qt) vaatisi näytön/etätyöpöydän brainbinille → kömpelöä etäkäytössä. Hylätään.
- Elektron ym. raskaat kehykset: turhia; kevyt selainsivu riittää.

## Arkkitehtuuri

```
selain (läppäri/puhelin)  ──HTTP/JSON──►  dvdq-web (backend, brainbin)  ──exec──►  dvdq <komento>
   HTML/CSS/JS-sivu                        pieni palvelin                            (ydin, JSON ulos)
   i18n-katalogit fi/en/es                 wrap + pollaus/SSE                         status/enqueue/rip…
```

- **Backend `dvdq-web`** (uusi, esim. `dvdq serve --port 8787`): pieni HTTP-palvelin (Python 3
  stdlib `http.server` tai kevyt Flask — ei uusia isoja riippuvuuksia). Tehtävät:
  - REST-päätepisteet jotka kääräisevät olemassa olevat komennot:
    `GET /api/status` → `dvdq status`; `POST /api/rip`; `POST /api/enqueue`; `POST /api/skip/:id`;
    `POST /api/retry/:id`; `GET /api/scan?dir=…`; `POST /api/daemon/:action`; `GET/POST /api/config`.
  - **Käynnistyksessä `dvdq daemon ensure`** (juuri kuten toivoit: GUI:n avaus käynnistää daemonin).
  - Live-edistyminen: joko selain pollaa `GET /api/status` 2 s välein, tai SSE/WebSocket työntää
    päivitykset (fps/%/ETA tulee jo `eta.sh`:sta / `dvdq-tila`:n datasta).
  - Ei omaa tilaa — kaikki dvdq-ytimessä.
- **Frontend**: yksi staattinen sivu (HTML + CSS + vanilla JS tai kevyt kirjasto). Ei build-työkaluja
  pakollisena. Kaikki tekstit **i18n-avainten** takana → katalogit `fi.json` / `en.json` / `es.json`
  (sama periaate kuin CLI:n `lib/i18n.sh`; katalogit voi jopa jakaa).

## Näkymät (mitä GUI näyttää)

1. **Rippaus-velho** (levy → valmis jonoon):
   - "Sulje kelkka & lue levy" → näyttää tittelit kestoineen + **nimiehdotuksen levyn nimiöstä**
     (kuten CLI nyt) → lomake: tyyppi (movie/series/doc/music/misc), nimi, vuosi/kausi, pääteos,
     ekstrat (esivalinta inklusiivinen, ruksit pois ei-toivotuista) → "Rippaa".
   - Sen jälkeen: "Voit poistaa levyn / vaihtaa seuraavan" — sama walk-away-malli.
2. **Jono-näkymä** (pääruutu): pending / encoding (2 rinnakkain, live fps/%/ETA) / done / failed,
   kokonais-ETA. Napit: skip, retry, pause/resume.
3. **Ongelmat**: failed/broken-jobit syineen (esim. "verify: tekstitys puuttui") + retry/ack.
4. **Asetukset**: PARALLEL, laatu (CRF), kansiot, kieli, DAEMON_IDLE_STOP_S. Kirjoittaa
   `~/.config/rip-dvd/config`.
5. **Daemon**: tila + start/stop (sama `dvdq daemon`).

## Monikielisyys (i18n) — tehdään ennen isoa GUI-tekstimäärää
- Yhteinen avain→teksti-malli. Oletus **suomi**, lisäksi **englanti + espanja**, myöhemmin muita.
- CLI: `lib/i18n.sh` (avain → käännös, kieli configista/env:stä). GUI: samat katalogit JSONina.
- Tehtävä varhain: retrofit myöhemmin on tuskaa. Tämä on GUI-työn ensimmäinen palanen.

## Toteutuksen vaiheistus (ehdotus)
1. **`dvdq serve` -backend** + read-only jono-dashboard (live status). Pienin hyöty-ensimmäinen:
   näet jonon selaimesta/puhelimesta. Ei vielä ohjausta.
2. **Rippaus-velho** (interaktiivinen flow web-lomakkeena) — korvaa `dvdq-rippaa`:n selaimessa.
3. **Ohjaus**: skip/retry/pause/daemon/asetukset.
4. **i18n fi/en/es + viimeistely** (responsiivinen, toimii puhelimella).

## Avoimet kysymykset (päätettävä ennen toteutusta)
- Backend-kieli: Python 3 (jo koneella, stdlib riittää) vs Node. Suositus: **Python 3 stdlib** —
  ei uusia riippuvuuksia, helppo jakaa.
- Autentikointi: lähiverkko riittänee aluksi; jos altistetaan laajemmin, yksinkertainen token.
- Live-päivitys: pollaus (yksinkertainen, riittää) vs SSE (sulavampi). Aloita pollauksella.

## Mitä EI muuteta
Ydin (`dvdq/lib/*`, komennot, jono, daemon) pysyy sellaisenaan — GUI on additiivinen. Jos jokin
puuttuu GUI:lta, se lisätään ytimeen uutena JSON-komentona, ei GUI:hin piiloon. Yksi totuus.
