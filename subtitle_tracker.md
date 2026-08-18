# Tekstitys-synkkaongelman kirjanpito

Tausta: 2026-08-18 löytyi että DVD-ripatun sisällön VobSub-tekstitysraidat voivat
hypätä ajallisesti kesken pitkän elokuvan/dokumentin (kuva pysyy oikein,
tekstitys ei) — todennäköinen syy on HandBraken `libdvdnav`-DVD-lukukirjasto,
joka on epäluotettavampi juuri monikerroslevyillä/solunavigoinnissa kuin
vaihtoehtoinen `libdvdread`. Tarkat tekniset yksityiskohdat ja tutkimushistoria:
ks. Claude-muistin `project_dvd_rippaus_tila.md` (2026-08-18-osiot).

**Skriptiin on jo lisätty korjaus UUSILLE rippauksille** (`--no-dvdnav`,
committi `c21075d`) — tämä lista koskee vain jo AIEMMIN ripattua sisältöä.

## `subtitle_tracker.csv` — sarakkeiden selitys

| Sarake | Selitys |
|---|---|
| `teos` | Elokuvan/dokumentin nimi (kansion nimi terastationilla) |
| `kesto_min` | Kesto minuutteina (vain yli 75min pitkät on listattu — lyhyemmillä levykerrosvaihto on epätodennäköinen) |
| `tila` | `RIKKI` (vahvistettu), `TARKISTAMATON` (ei vielä tiedetä), `KUNNOSSA` (vahvistettu toimivaksi) |
| `korjattu_levylta` | `EI` / `KYLLÄ` — onko tekstitys irrotettu uudelleen levyltä `--no-dvdnav`:illa ja remuxattu |
| `huomiot` | Vapaa teksti |
| `tiedostopolku` | Täysi polku terastationilla |

**52/54 on tällä hetkellä TARKISTAMATON** — automaattinen tunnistus osoittautui
epäluotettavaksi (nopeatempoinen dialogi peittää signaalin, ks. muisti), joten
ainoa luotettava tapa on joko käyttäjän oma katselu/kuuntelu TAI tekstityksen
irrotus uudelleen levyltä varmuuden vuoksi.

## Työnkulku ("mitä seuraavaksi")

Kun sinulla on jokin fyysinen DVD käsillä (tai haluat tarkistaa jonkin nimikkeen):

1. Kysy Claudelta: **"onko [nimi] tekstitys-tarkistuslistalla, mikä sen tila on"**
   — Claude etsii rivin ja kertoo tilanteen.
2. Jos haluat merkitä jonkin tarkistetuksi (katsoit/kuuntelit ja se on kunnossa
   tai rikki), kerro Claudelle — se päivittää `tila`-sarakkeen ja committaa.
3. Jos haluat korjata rikki-merkityn teoksen: laita levy asemaan ja kerro
   Claudelle — se irrottaa tekstitysraidan uudelleen `--no-dvdnav`:illa ja
   remuxaa sen olemassa olevaan MKV-tiedostoon (video ei muutu, ei tarvitse
   ripata/enkoodata koko levyä uudelleen). Päivittää `korjattu_levylta=KYLLÄ`.

Ei tarvitse itse pitää kirjaa mistään — pelkkä "mitä seuraavaksi" riittää.
