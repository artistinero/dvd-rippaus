#!/usr/bin/env python3
"""Nopea tekstitysirrotus VOB-tiedostoista ffmpegillä + oikea kielikartoitus.
Käyttö: extract_subs_fast.py <VIDEO_TS-kansio> <VTS-numero> <ulostulo.mkv> <kieli1,kieli2,...>
Kielet annetaan JÄRJESTYKSESSÄ raita1..raitaN (HandBraken JSON-skannauksesta saatu järjestys).
"""
import subprocess, sys, json, re, glob, os

def main():
    video_ts, vts_num, out_path, langs_csv = sys.argv[1:5]
    langs = langs_csv.split(",")  # index 0 = raita 1, jne.

    vob_files = sorted(glob.glob(os.path.join(video_ts, f"VTS_{int(vts_num):02d}_*.VOB")))
    # Jätä pois _0.VOB (menu/IFO-data, ei sisältöä)
    vob_files = [f for f in vob_files if not re.search(r"_00?\.VOB$", f, re.IGNORECASE) and not f.endswith("_0.VOB")]
    if not vob_files:
        print("EI VOB-tiedostoja löytynyt", file=sys.stderr)
        sys.exit(1)
    concat = "concat:" + "|".join(vob_files)
    print(f"Käytetään {len(vob_files)} VOB-tiedostoa: {[os.path.basename(f) for f in vob_files]}", file=sys.stderr)

    # 1. Selvitä subtitle-virtojen indeksi->ID kartoitus ffprobella
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-probesize", "2G", "-analyzeduration", "2G",
         "-show_entries", "stream=index,id,codec_type", "-of", "csv=p=0", concat],
        capture_output=True, text=True, timeout=180
    )
    stream_ids = []  # (input_index, hex_id) järjestyksessä sellaisena kuin ffprobe listaa
    for line in probe.stdout.splitlines():
        parts = line.split(",")
        if len(parts) == 3 and parts[1] == "subtitle":
            idx, _, hexid = parts
            stream_ids.append((int(idx), int(hexid, 16)))
    if not stream_ids:
        print("EI tekstitysvirtoja löytynyt", file=sys.stderr)
        sys.exit(1)
    print(f"Löytyi {len(stream_ids)} tekstitysvirtaa: {stream_ids}", file=sys.stderr)

    # 2. Laske jokaiselle sen raitanumero (DVD-spesifikaatio: ID 0x20 = raita 1)
    #    ja siitä kieli annetusta listasta.
    track_langs = []  # output-järjestyksessä (= input-indeksin nouseva järjestys)
    for idx, hexid in stream_ids:
        track_num = hexid - 0x20 + 1
        if 1 <= track_num <= len(langs):
            lang = langs[track_num - 1]
        else:
            lang = "und"
            print(f"VAROITUS: raitanumero {track_num} (ID 0x{hexid:x}) ylittää kielilistan pituuden — merkitty 'und'", file=sys.stderr)
        track_langs.append(lang)
    print(f"Kielikartoitus (tulostiedoston raitajärjestyksessä): {track_langs}", file=sys.stderr)

    # 3. Aja ffmpeg-kopiointi väliaikaistiedostoon
    tmp_out = out_path + ".tmp.mkv"
    r = subprocess.run(
        ["ffmpeg", "-y", "-probesize", "2G", "-analyzeduration", "2G",
         "-i", concat, "-map", "0:s", "-c:s", "copy", "-f", "matroska", tmp_out],
        capture_output=True, text=True, timeout=600
    )
    if r.returncode != 0:
        print("ffmpeg epaonnistui:", r.stderr[-2000:], file=sys.stderr)
        sys.exit(1)

    # 4. Tarkista tulostiedoston raitamäärä täsmää odotettuun
    j = subprocess.run(["mkvmerge", "-J", tmp_out], capture_output=True, text=True, timeout=60)
    info = json.loads(j.stdout)
    n_tracks = len(info["tracks"])
    if n_tracks != len(track_langs):
        print(f"VIRHE: tulostiedostossa {n_tracks} raitaa, odotettiin {len(track_langs)} — kielikartoitus ei täsmää!", file=sys.stderr)
        sys.exit(1)

    # 5. Aseta kielitunnisteet mkvpropeditilla ja siirrä lopulliseen sijaintiin
    edit_cmd = ["mkvpropedit", tmp_out]
    for i, lang in enumerate(track_langs):
        edit_cmd += ["--edit", f"track:s{i+1}", "--set", f"language={lang}"]
    r2 = subprocess.run(edit_cmd, capture_output=True, text=True, timeout=60)
    if r2.returncode != 0:
        print("mkvpropedit epaonnistui:", r2.stderr, file=sys.stderr)
        sys.exit(1)

    os.rename(tmp_out, out_path)
    print(f"VALMIS: {out_path} ({n_tracks} raitaa, kielet: {track_langs})", file=sys.stderr)

if __name__ == "__main__":
    main()
