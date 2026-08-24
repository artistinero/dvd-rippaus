# KANONINEN MENETTELY: tekstitysten (VobSub-desync) korjaus — noudata ORJALLISESTI

Tämä korvaa hajanaiset menetelmämuistiinpanot. Sama joka kerta, jokaiselle teokselle.

## Soveltamisala (LUE ENSIN)
- Tämä korjaa VAIN enkooderin aiheuttaman tekstitys-desyncin (vanha HandBrake 1.7.2 VobSub-bugi).
- Olettaa että video/ääni ovat jo kunnossa kirjastossa — vaihdetaan VAIN tekstitykset.
- **Rikkinäiset/skipatut/vajaat rippaukset (esim. District 9) EIVÄT kuulu tähän.** Ne ovat
  erillinen ongelma (levyvaurio → ddrescue/uudelleenrippaus), ratkotaan omana työnään. Älä sekoita.

## MENETELMÄ: ffmpeg 7.1 `dvdvideo`-demukseri (VALIDOITU KATSOMALLA 2026-08-24, Barfly)
**Käytä TÄTÄ.** `/opt/ffmpeg-dvdvideo/bin/ffmpeg` (erillinen käännös libdvdnavilla — järjestelmän
ffmpeg 6.1.1 on koskematon eikä siinä ole demukseria). Komento:
```
/opt/ffmpeg-dvdvideo/bin/ffmpeg -y -f dvdvideo -title <N> -i /dev/sr1 -map 0:s -c:s copy ulos.mkv
```
Demukseri lukee DVD-tittelin **NAV-ajastuksella** (sama libdvdnav kuin HandBrake käyttää videolle)
→ tekstitykset synkkaan videon kanssa. Tuo automaattisesti: **kaikki raidat, kielitunnisteet JA
paletit** — ei manuaalista kartoitusta. Nopea (~20× reaaliaika, ei videon enkoodausta).
Sitten remux: `mkvmerge -o final.mkv --no-subtitles kirjasto.mkv ulos.mkv` (video/ääni koskematta).

**Barfly 1987 (2026-08-24): täysi ketju validoitu — käyttäjä katsoi, suomiteksti kohdillaan.**

### Hylätyt / väärät menetelmät (älä käytä)
- **Raaka VOB-konkatenointi** (`ffmpeg -i 'concat:VTS_..VOB|..' -map 0:s -c:s copy`): EI seuraa
  NAV/PGC-ajastusta → tekstit desyncissä. Tuotti Barflylle PAHEMMAN synkan. TÄMÄ ON UMPIKUJA.
  (Vanha `extract_subs_fast.py` käytti tätä — älä luota siihen.)
- Koko elokuvan uudelleenenkoodaus HandBrakella (1–1,5 h, koskee ehjää videota turhaan).
- HandBraken tekstitys-vain irrotus (dekoodaa videon turhaan ~500–800 s, ja tekstimuotoinen
  `--scan` katkaisee raitalistan ~10:een → tästä raitoja on tiputettu aiemmin). Toimii, mutta hidas.

## Vaiheet (jokaiselle levylle sama — dvdvideo-menetelmä)
1. **Tunnista levy + oikea title** — `lsdvd /dev/sr1` antaa tittelit + kestot. Valitse se jonka
   kesto täsmää kirjaston tiedostoon. Ellei selvä → yksi täsmällinen kysymys, ei arvausta.
2. **Irrota kaikki tekstitykset suoraan levyltä** (ei dvdbackuppia — libdvdcss purkaa CSS:n lennossa):
   `/opt/ffmpeg-dvdvideo/bin/ffmpeg -y -f dvdvideo -title N -i /dev/sr1 -map 0:s -c:s copy ulos.mkv`
   → kaikki raidat, kielitunnisteet ja paletit automaattisesti, NAV-ajastus oikein.
3. **Varmista tulos** — `ffprobe` ulos.mkv: raitamäärä järkevä + kielet oikein + ajastus järkevä
   (ensimmäinen tekstitys EI ajassa 0.000, viimeinen lähellä elokuvan loppua). Ellei → PYSÄHDY.
4. **Remux kirjaston tiedostoon** — `mkvmerge -o final.mkv --no-subtitles kirjasto.mkv ulos.mkv`
   (video/ääni koskematta; kielet tulevat ulos.mkv:stä valmiina).
5. **Verifioi + korvaa atomisesti** — final.mkv: N raitaa, oikeat kielet, kesto ennallaan. Kopioi
   dest-kansioon, `mv` vanha → .desync-bak, `mv` uusi → kirjaston nimi (atominen).
6. **Kirjaa** — tracker-CSV + muistio + git commit per levy. Käyttäjä voi pistokoetarkistaa katsomalla.

## Miksi remux eikä uudelleenrippaus
Vain tekstitykset olivat desyncissä; video/ääni ehjät → vaihdetaan vain tekstitykset.
