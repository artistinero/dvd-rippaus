# Ekstrojen nimeämis-/sijoitteluaudit 2026-08-24 (ODOTTAA KÄYTTÄJÄN HYVÄKSYNTÄÄ)

Ongelma: ~30 `/movies/`-kansiota on "Part NN"-muodossa. Osa on väärin nimettyjä ekstroja
(lyhyet bonukset kohdeltu elokuvan osina). Kesto-audit ffprobe:lla erottaa elokuvan ekstroista.

**Konventio (sovittu):** pääelokuva → `Nimi.mkv` (pois "- Part 01"), ekstrat → `Nimi - Extra NN-extra.mkv`.

## A) SELKEÄT — Part 01 = elokuva, loput = ekstrat (korjaa nämä)
(suluissa: elokuvan kesto; loput osat ovat lyhyempiä ekstroja, myös pitkät dokumentit ovat ekstroja)
- 12 apinaa (P01=124min; P02=88min on "Hamster Factor"-doku=EKSTRA, P03/04 lyhyet)
- 1984 (106), 2001 Avaruusseikkailu (143), Amarcord (119), American Beauty (P01=117; P05=61min doku=ekstra)
- Barton Fink (112), Being John Malkovich (108), Brazil (P01=137; P04=28min ekstra), Circus (92)
- Contact (144), Aikakone (92), Eräs rakkaus tarina (114), 2046 (P01=123; loput ekstroja)
- Arthur's Dyke (104), Everything You Always… (84), Fargo (94), Freejack (105), Infernal Affairs (97)
- The Astronaut Farmer (100), The Dead Zone (99)
- Futurama - Bender's Game (P01=84), Beast With a Billion Backs (P01=85), Into the Wild Green Yonder (P01=86)

## B) ERIKOISTAPAUS — pääelokuva EI ole Part 01 (varo! nimeäisi väärin ilman tätä)
- **The Astronaut's Wife (1999):** elokuva = Part 03 (105min). Part01=2min, Part02=9min ovat ekstroja.
- **Toisen kerroksen lauluja (2000):** elokuva = Part 02 (95min). Part01=2min on ekstra.

## C) JÄTÄ RAUHAAN (rikki / luovutettu / epäselvä / ei elokuva)
- **District 9:** luovutettu --skip 2026-08-18, vaurioitunut, ~26min puuttuu pysyvästi. Osat=elokuvan paloja.
- **Burn After Reading:** EI täyspitkää osaa (kaikki 0-12min) → pääelokuva puuttuu/pilkottu (vaurio). Selvitä erikseen.
- **Futurama - Bender's Big Score:** EI täyspitkää osaa → pääelokuva puuttuu/pilkottu.
- **The Darjeeling Limited:** KAKSI 92min osaa (P01 ja P02) — epäselvä kumpi on elokuva, tarkista ennen nimeämistä.
- **WaterRower Home Training DVD:** ei elokuva → siirrä **misc-kansioon** (ks. [[project-dvd-rippaus-tila]] misc).

## Jo tehty
- **Big Lebowski (1998):** ekstrat nimetty (Part02/03 → Extra 01/02-extra) 2026-08-24. MUTTA pääelokuva
  jäi vielä nimellä "Big Lebowski - Part 01.mkv" → pitää vielä korjata → "Big Lebowski.mkv".
