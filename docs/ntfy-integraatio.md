# ntfy-integraatio enkoodausraportointiin

## Tavoite

`rip-dvd.sh`:n enkoodausvaihe (`encode_session`) voi kestää tunteja eikä sitä
seurata jatkuvasti. Lisätään ntfy-ilmoitukset kahdessa kohdassa:

1. **Määräajoin enkoodauksen aikana** (~30 min välein) — lyhyt tilannekatsaus.
2. **Kun sessio-kohtainen enkoodausjono (`.queue`) tyhjenee** — yhteenveto
   onnistuneista/epäonnistuneista raidoista ja kokonaiskestosta.

Sama malli kuin duunivahti/pcloud-backup-projekteissa käyttää: `curl` suoraan
ntfy-topicciin, ei erillistä kirjastoa.

## Infra (jo olemassa brainbinillä)

ntfy pyörii jo brainbinillä duunivahti-projektin asentamana:

- Kuuntelee `127.0.0.1:4444` (docker-compose, `restart: unless-stopped`)
- Julkinen osoite Tailscalen kautta: `https://brainbin.tailf1fe0b.ts.net`

`rip-dvd.sh` **ajetaan itse brainbinillä**, joten kannattaa julkaista suoraan
paikalliseen porttiin (`127.0.0.1:4444`) eikä kiertää Tailscalen kautta —
sama palvelin, yksi verkkohyppy vähemmän, ei riipu Tailscale-reitityksestä.
ntfy-topic näkyy silti puhelimessa normaalisti, koska kyse on samasta
palvelininstanssista riippumatta mistä osoitteesta julkaisu tehdään.

**Uusi topic:** `dvd-rippaus` — oma kanava, ei sekoiteta duunivahti- tai
pcloud-backup-ilmoituksiin. Puhelimessa tilataan ntfy-sovelluksella:
`https://brainbin.tailf1fe0b.ts.net/dvd-rippaus`.

## 1. Apufunktio

Lisää `log()`-funktion viereen (rip-dvd.sh:n alkuun, apufunktio-osioon,
n. rivi 100):

```bash
NTFY_URL="http://127.0.0.1:4444/dvd-rippaus"

# Lähettää ntfy-ilmoituksen. Epäonnistuminen (esim. ntfy pois päältä) ei saa
# koskaan katkaista enkoodausta — siksi -m timeout ja || true.
notify() {
    local title="$1" msg="$2" prio="${3:-default}"
    curl -s -m 10 -d "$msg" \
        -H "Title: $title" \
        -H "Priority: $prio" \
        "$NTFY_URL" >/dev/null 2>&1 || log "  VAROITUS: ntfy-ilmoitus epäonnistui"
}
```

## 2. Määräaikaisraportti enkoodauksen aikana

`encode_session()`-funktiossa, samassa kohdassa jossa `session_start`
alustetaan (n. rivi 713), lisää myös viimeisimmän ilmoituksen aikaleima:

```bash
local done_n=0 session_start; session_start=$(date +%s)
local last_notify_ts=$session_start
```

Enkoodaussilmukan lopussa, sen jälkeen kun raidan tulos (✓ tai VIRHE) on
kirjattu lokiin mutta ennen `done < "$queue"`-rivin päättymistä (n. rivi
841–843), lisää aikaperusteinen tarkistus. 30 min = 1800 s, ei per-raita
laukaisu, jotta lyhyet raidat eivät spämmää:

```bash
        # ── Määräaikaisraportti ntfy:hen (30 min välein) ────────────────────
        local _now_ts; _now_ts=$(date +%s)
        if (( _now_ts - last_notify_ts >= 1800 )); then
            local _elapsed=$(( _now_ts - session_start ))
            notify "DVD-enkoodus käynnissä" \
"Levy ${disc_n}/${total_discs} — raita ${done_n}/${total_titles}
Nyt: ${out_name}
Kulunut: $(fmt_time "$_elapsed") — valmiit: ${_rep_ok}, virheet: ${#_rep_fail[@]}"
            last_notify_ts=$_now_ts
        fi

    done < "$queue"
```

`disc_n`, `out_name`, `_rep_ok` ja `_rep_fail` ovat jo olemassa silmukan
sisällä — ei tarvitse laskea mitään uutta, vain koota ne viestiksi.

## 3. Loppuraportti kun jono tyhjenee

`encode_session()`:n lopussa, heti `.encode-report`-tiedoston kirjoituksen
jälkeen (n. rivi 881, ennen `log "═══ Enkoodaus valmis..."`-riviä):

```bash
    # ── Loppuraportti ntfy:hen ────────────────────────────────────────────────
    local _fail_lines="" _rf
    for _rf in "${_rep_fail[@]}"; do _fail_lines+=$'\n'"- ${_rf}"; done
    local _prio="default"
    (( ${#_rep_fail[@]} > 0 )) && _prio="high"
    notify "DVD-enkoodausjono tyhjä ✓" \
"${_rep_ok} onnistui, ${#_rep_fail[@]} epäonnistui — $(fmt_time "$total_secs")${_fail_lines}" \
        "$_prio"
```

Tämä laukeaa jokaisen `encode_session`-kutsun (eli jokaisen session-hakemiston
oman `.queue`:n tyhjentymisen) lopussa — jos useampi sessio on jonossa,
jokainen ilmoittaa erikseen valmistuttuaan. `flock`-lukko (rivi 529) sarjoittaa
ne joka tapauksessa peräkkäin, joten ilmoitukset eivät mene päällekkäin.

## Huomioita

- `notify()` käyttää `-m 10` timeoutia ja `|| true`-tyylistä virheenkäsittelyä
  (lokiin varoitus) — ntfy-katkos ei saa koskaan pysäyttää enkoodausta.
- Prioriteetti: `default` normaaliraporteille, `high` loppuraportille jos
  yksikin raita epäonnistui — näkyy puhelimessa selvemmin.
- Sisältö tarkoituksella suppea (levy/raita-numerot, nykyinen tiedosto,
  kulunut aika, onnistuneet/epäonnistuneet) — täysi loki on jo
  `~/logs/rip-dvd.log`:ssa, ntfy on vain nopea tilannekatsaus.
- Mahdollinen jatkokehitys (ei tässä laajuudessa): watchdogin
  ylikuumenemistapahtumat (`watchdog.sh`, KRIITTINEN-taso) omaan
  ilmoitukseen samalle tai erilliselle topicille.

## Testaus

1. Julkaisutesti ilman skriptiä:
   ```bash
   curl -s -d "testi" -H "Title: Testi" http://127.0.0.1:4444/dvd-rippaus
   ```
   Varmista että ilmoitus tulee puhelimeen.
2. Aja `rip-dvd.sh --encode-only <lyhyt sessio>` ja seuraa että 30 min
   välein tulee tilannekatsaus ja jonon tyhjentyessä loppuraportti.
