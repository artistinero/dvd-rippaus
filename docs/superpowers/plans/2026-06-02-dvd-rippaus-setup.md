# DVD-rippaus: brainbin-asennussuunnitelma

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Asentaa MakeMKV + HandBrakeCLI + libdvdcss2 brainbinille, luoda hakemistorakenne ja varmistaa, että DVD-asema tunnistuu ja koko työnkulku toimii.

**Architecture:** Kaikki komennot ajetaan SSH:n kautta brainbinille (`ssh brainbin`). MakeMKV ripaa levyn häviöttömästi väliaikaiseen kansioon, HandBrakeCLI pakkaa H.265-muotoon, valmis tiedosto siirretään Jellyfin-kirjastoon.

**Tech Stack:** Ubuntu (headless), MakeMKV CLI (`makemkvcon`), HandBrakeCLI, libdvdcss2, bash

---

## Tiedostot ja hakemistot

Luodaan brainbinille:
- `/mnt/lacie2/vids/dvd-rip/` — rippaustyöhakemisto
- `/mnt/lacie2/vids/movies/` — valmiit elokuvat
- `/mnt/lacie2/vids/series/` — valmiit sarjat
- `/mnt/lacie2/vids/music/` — valmiit musiikkivideot

---

### Task 1: Yhteyden ja ympäristön tarkistus

**Files:**
- Ei tiedostomuutoksia

- [ ] **Step 1: Testaa SSH-yhteys**

```bash
ssh brainbin "echo 'yhteys toimii' && lsb_release -d && uname -r"
```

Odotettu tuloste: Ubuntu versiotiedot ja kernel.

- [ ] **Step 2: Tarkista levytila**

```bash
ssh brainbin "df -h /mnt/lacie2"
```

Odotettu tuloste: `/mnt/lacie2` on mountattu ja tilaa on riittävästi (väh. 50 GB suositeltavaa).

- [ ] **Step 3: Tarkista DVD-asema**

```bash
ssh brainbin "ls -la /dev/sr* /dev/dvd* 2>/dev/null || echo 'ei DVD-asemaa näkyvissä'"
ssh brainbin "lsblk -o NAME,TYPE,MOUNTPOINT | grep rom"
```

Odotettu tuloste: `/dev/sr0` tai vastaava näkyy.

---

### Task 2: Asenna HandBrakeCLI

**Files:**
- Ei tiedostomuutoksia (apt-paketti)

- [ ] **Step 1: Lisää HandBrake PPA ja asenna**

```bash
ssh brainbin "sudo add-apt-repository -y ppa:stebbins/handbrake-releases && sudo apt-get update && sudo apt-get install -y handbrake-cli"
```

Jos PPA ei toimi Ubuntun versiolla, vaihtoehto:

```bash
ssh brainbin "sudo apt-get update && sudo apt-get install -y handbrake-cli"
```

- [ ] **Step 2: Verifioi asennus**

```bash
ssh brainbin "HandBrakeCLI --version"
```

Odotettu tuloste: `HandBrake <versio>` — ei virheitä.

---

### Task 3: Asenna libdvdcss2

**Files:**
- Ei tiedostomuutoksia (apt-paketti)

- [ ] **Step 1: Asenna libdvdcss2 VideoLAN-lähteestä**

```bash
ssh brainbin "sudo apt-get install -y libdvd-pkg && sudo dpkg-reconfigure libdvd-pkg"
```

`libdvd-pkg` hakee ja rakentaa `libdvdcss2`:n automaattisesti. Vaihtoehtoisesti suoraan .deb-paketista:

```bash
ssh brainbin "wget http://download.videolan.org/pub/debian/stable/libdvdcss2_1.4.3-1_amd64.deb && sudo dpkg -i libdvdcss2_1.4.3-1_amd64.deb && rm libdvdcss2_1.4.3-1_amd64.deb"
```

- [ ] **Step 2: Verifioi asennus**

```bash
ssh brainbin "dpkg -l | grep -i dvdcss"
```

Odotettu tuloste: rivi jossa `libdvdcss2` ja status `ii` (installed).

---

### Task 4: Asenna MakeMKV

**Files:**
- Ei tiedostomuutoksia (buildi lähteestä tai snap)

- [ ] **Step 1: Tarkista onko snap saatavilla (helpoin tapa)**

```bash
ssh brainbin "snap find makemkv 2>/dev/null || echo 'snap ei saatavilla'"
```

Jos snap toimii:

```bash
ssh brainbin "sudo snap install makemkv"
```

Siirry suoraan Step 4:ään.

- [ ] **Step 2: Jos snap ei toimi — asenna buildiriippuvuudet**

```bash
ssh brainbin "sudo apt-get install -y build-essential pkg-config libc6-dev libssl-dev libexpat1-dev libavcodec-dev libgl1-mesa-dev qtbase5-dev zlib1g-dev"
```

- [ ] **Step 3: Lataa ja buildaa MakeMKV lähdekoodista**

Hae uusin versio MakeMKV:n sivulta (https://www.makemkv.com/download/). Alla esimerkki versiolla 1.17.9 — tarkista ensin uusin versio:

```bash
ssh brainbin "
  MKVER=1.17.9
  cd /tmp
  wget https://www.makemkv.com/download/makemkv-bin-\$MKVER.tar.gz
  wget https://www.makemkv.com/download/makemkv-oss-\$MKVER.tar.gz
  tar xf makemkv-oss-\$MKVER.tar.gz
  tar xf makemkv-bin-\$MKVER.tar.gz
  cd makemkv-oss-\$MKVER
  ./configure && make && sudo make install
  cd /tmp/makemkv-bin-\$MKVER
  make && sudo make install
"
```

- [ ] **Step 4: Verifioi asennus**

```bash
ssh brainbin "makemkvcon --version"
```

Odotettu tuloste: `MakeMKV v<versio> linux(x64-release)`.

- [ ] **Step 5: Aseta beta-lisenssiavain**

Hae voimassa oleva avain: https://forum.makemkv.com/forum/viewtopic.php?t=1053

```bash
ssh brainbin "makemkvcon reg <LISENSSIAVAIN>"
```

Korvaa `<LISENSSIAVAIN>` foorumilta haetulla avaimella (muoto `T-XXXX...`).

Odotettu tuloste: `App registered successfully.`

---

### Task 5: Luo hakemistorakenne

**Files:**
- `/mnt/lacie2/vids/dvd-rip/` (uusi)
- `/mnt/lacie2/vids/movies/` (uusi tai olemassa)
- `/mnt/lacie2/vids/series/` (uusi tai olemassa)
- `/mnt/lacie2/vids/music/` (uusi tai olemassa)

- [ ] **Step 1: Luo kaikki hakemistot**

```bash
ssh brainbin "mkdir -p /mnt/lacie2/vids/{dvd-rip,movies,series,music}"
```

- [ ] **Step 2: Verifioi rakenne**

```bash
ssh brainbin "ls -la /mnt/lacie2/vids/"
```

Odotettu tuloste: neljä hakemistoa listattuna.

- [ ] **Step 3: Tarkista kirjoitusoikeudet**

```bash
ssh brainbin "touch /mnt/lacie2/vids/dvd-rip/.test && echo 'kirjoitus ok' && rm /mnt/lacie2/vids/dvd-rip/.test"
```

Odotettu tuloste: `kirjoitus ok`.

---

### Task 6: Testaa DVD-aseman tunnistus (ilman levyä)

**Files:**
- Ei muutoksia

- [ ] **Step 1: Tarkista aseman tila**

```bash
ssh brainbin "makemkvcon info disc:0 2>&1 | head -5"
```

Odotettu tuloste ilman levyä: virheviesti kuten `Failed to open disc` tai `No disc`. Jos tuloste on jotain muuta, asema ei tunnistunut oikein — tarkista `/dev/sr0` -oikeudet.

- [ ] **Step 2: Tarkista käyttäjän ryhmäjäsenyys (optionaalinen)**

Jos MakeMKV ei pääse levyasemaan ilman sudoa:

```bash
ssh brainbin "groups && ls -la /dev/sr0"
```

Jos käyttäjä ei ole `cdrom`-ryhmässä:

```bash
ssh brainbin "sudo usermod -aG cdrom $USER && echo 'Kirjaudu ulos ja takaisin SSH-yhteydellä voimaan saattamiseksi'"
```

---

### Task 7: Testirippaus oikealla DVD:llä

**Files:**
- Tuloste: `/mnt/lacie2/vids/dvd-rip/<levyn-nimi>/`

- [ ] **Step 1: Laita DVD asemaan brainbinilla**

Fyysinen toimenpide. Varmista, että levy on luettavissa:

```bash
ssh brainbin "makemkvcon info disc:0 2>&1 | grep -E '(Title|CINFO)' | head -20"
```

Odotettu tuloste: levyn nimi ja title-lista.

- [ ] **Step 2: Ripaa kaikki titleset MakeMKV:llä**

```bash
ssh brainbin "makemkvcon mkv disc:0 all /mnt/lacie2/vids/dvd-rip/"
```

Tämä ripaa kaikki titleset. Jos haluat vain yhden titlen (esim. title 1):

```bash
ssh brainbin "makemkvcon mkv disc:0 1 /mnt/lacie2/vids/dvd-rip/"
```

- [ ] **Step 3: Verifioi raakakopiot**

```bash
ssh brainbin "ls -lh /mnt/lacie2/vids/dvd-rip/"
```

Odotettu tuloste: `.mkv`-tiedostoja, koko tyypillisesti 4–8 GB per tiedosto.

- [ ] **Step 4: Pakkaa HandBrakeCLI:llä H.265**

Korvaa `INPUT.mkv` oikealla tiedostonimellä:

```bash
ssh brainbin "HandBrakeCLI \
  --input /mnt/lacie2/vids/dvd-rip/INPUT.mkv \
  --output /mnt/lacie2/vids/dvd-rip/OUTPUT.mkv \
  --encoder x265 \
  --quality 21 \
  --audio-lang-list fin,eng \
  --aencoder copy \
  --audio-copy-mask ac3,eac3,dts,dtshd \
  --audio-fallback aac \
  --subtitle-lang-list fin,eng \
  --subtitle-default 1 \
  --markers"
```

- [ ] **Step 5: Verifioi enkoodattu tiedosto**

```bash
ssh brainbin "ls -lh /mnt/lacie2/vids/dvd-rip/OUTPUT.mkv"
ssh brainbin "ffprobe /mnt/lacie2/vids/dvd-rip/OUTPUT.mkv 2>&1 | grep -E '(Video|Audio|Subtitle)'"
```

Odotettu tuloste: tiedosto on olemassa (koko 1–3 GB tyypillisesti), video H.265, ääni AC3/AAC, tekstitykset näkyvissä.

- [ ] **Step 6: Siirrä valmis tiedosto oikeaan Jellyfin-kansioon**

Elokuva:
```bash
ssh brainbin "mv /mnt/lacie2/vids/dvd-rip/OUTPUT.mkv '/mnt/lacie2/vids/movies/Elokuvan Nimi (2005)/Elokuvan Nimi (2005).mkv'"
```

Sarja (esim. kausi 1, jakso 1):
```bash
ssh brainbin "mv /mnt/lacie2/vids/dvd-rip/OUTPUT.mkv '/mnt/lacie2/vids/series/Sarjan Nimi/Season 01/Sarjan Nimi S01E01.mkv'"
```

- [ ] **Step 7: Poista raakakopiot levytilan säästämiseksi**

```bash
ssh brainbin "rm -rf /mnt/lacie2/vids/dvd-rip/<levyn-nimi>/"
```

- [ ] **Step 8: Käynnistä Jellyfin-skannaus**

Vasta kun tiedosto on oikeassa kansiossa:

```bash
ssh brainbin "curl -s -X POST 'http://localhost:8096/Library/Refresh' -H 'X-Emby-Token: <JELLYFIN-API-KEY>' || echo 'käynnistä skannaus manuaalisesti Jellyfin-käyttöliittymästä'"
```

Tai manuaalisesti Jellyfinin webkäyttöliittymästä: Dashboard → Libraries → Scan All Libraries.

---

## Viitetieto

- MakeMKV beta-lisenssiavain: https://forum.makemkv.com/forum/viewtopic.php?t=1053
- MakeMKV lataukset: https://www.makemkv.com/download/
- HandBrake PPA: `ppa:stebbins/handbrake-releases`
- Jellyfin hakemistonimeämiskonventiot: `movies/Nimi (vuosi)/Nimi (vuosi).mkv` ja `series/Nimi/Season XX/Nimi SXXEXX.mkv`
