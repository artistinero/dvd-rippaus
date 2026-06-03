# dvd-rippaus

## Tavoite

Ripata oma DVD-kokoelma MKV-tiedostoiksi Jellyfin-palvelimelle. Työnkulku:
MakeMKV (häviötön raakakopiointi) + HandBrake (pakkaus H.265/MKV).

## Palvelinympäristö (brainbin)

- Ubuntu, headless
- SSH: `ssh brainbin` (Tailscale MagicDNS, toimii ilman salasanaa)
- DVD-asema: sisäänrakennettu (tunnistuu todennäköisesti `/dev/sr0`)
- Jellyfin toiminnassa, musiikkikirjasto `/mnt/music`

## Hakemistorakenne (brainbin, `/mnt/lacie2`)

```
/mnt/lacie2/vids/dvd-rip/        <- väliaikainen rippaustyöhakemisto
/mnt/lacie2/vids/movies/         <- valmiit elokuvat Jellyfiniin
/mnt/lacie2/vids/series/         <- valmiit sarjat Jellyfiniin
/mnt/lacie2/vids/music/          <- valmiit musiikkivideot Jellyfiniin
```

Valmis tiedosto siirretään käsin oikeaan hakemistoon rippauksen jälkeen.

## Työnkulku

1. Levy asemaan brainbinilla
2. MakeMKV ripaa häviöttömästi `/mnt/lacie2/vids/dvd-rip/<levyn-nimi>/`
3. HandBrakeCLI pakkaa valitut titlet H.265 MKV-tiedostoiksi samaan kansioon
4. Tarkistus: kuva, ääni, tekstitykset kunnossa
5. Siirto oikeaan kansioon (`movies/`, `series/`, `music/`)
6. Raakakopiot poistetaan levytilan säästämiseksi

## Ohjaus läppäriltä

HandBraken graafinen käyttöliittymä läppärillä (Linux Mint 22.3) ohjaa
brainbinin HandBrakeCLI:tä SSH:n kautta Remote Scan -toiminnolla.
Vaihtoehtoisesti kaikki voidaan ajaa SSH-terminaalista käsin.

## Asennettavat ohjelmat brainbinille

- `makemkv` (beta, ilmainen lisenssiavain haetaan MakeMKV-foorumilta)
- `handbrake-cli`
- `libdvdcss2` (CSS-suojan purku, tarvitaan useimmille kaupallisille DVD:ille)

## Asennettavat ohjelmat läppärille

- `handbrake` (graafinen käyttöliittymä, valinnainen)

## Enkoodausasetukset (HandBrake)

- Kontti: MKV
- Video: H.265 (HEVC), RF 20-22 (laatu vs. tiedostokoko)
- Ääni: AC3/Dolby Digital pass-through (surround säilyy), tai AAC fallback
- Tekstitykset: kaikki haluatut raidat mukaan (SRT tai PGS)

## Huomioita

- MakeMKV beta-lisenssiavain vanhenee muutaman kuukauden välein.
  Voimassa oleva avain löytyy aina: https://forum.makemkv.com/forum/viewtopic.php?t=1053
- libdvdcss2 ei kuulu Ubuntun virallisiin repositorioihin, asennetaan
  erillisestä lähteestä (videolan tai handbrake PPA).
- Älä käynnistä Jellyfin-skannausta ennen kuin tiedostot ovat valmiissa
  hakemistossaan, ei dvd-rip-välikansiossa.

## Projektin tila

Asennusta ei ole aloitettu. Ensimmäinen tehtävä: asenna MakeMKV, HandBrakeCLI
ja libdvdcss2 brainbinille, luo hakemistorakenne, testaa DVD-aseman tunnistus.
