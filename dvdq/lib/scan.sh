#!/usr/bin/env bash
# dvdq/lib/scan.sh — skannaus (§6.2) + raitapolitiikka (§8.3). Kaksivaiheinen:
#   1) lsdvd-ENUMEROINTI (nopea, ei dekoodaa) → tittelinumerot. Enumerointi epäonnistuu → disc:-broken.
#   2) per-titteli HandBrakeCLI --scan --json (timeout) → tarkka metadata.
# Tulos persistoidaan $STATE/scans/<sha1(disc_key)>.json:iin (§5.5, GUI-aukko c) + JSONL-edistyminen
# stdoutiin (GUI-aukko b). Työkalut abstrahoitu (stubattavissa) — oikea DVD-polku todennetaan brainbinilla.
# Sourcaa common.sh + jobs.sh ensin.
set -uo pipefail

# --- vaihe 1: enumerointi (lsdvd) --------------------------------------------------------------
# scan_enumerate <dvd_dir> → tittelinumerot (yksi per rivi). Tyhjä + rc≠0 jos enumerointi epäonnistuu.
scan_enumerate() {
  if [ -n "${DVDQ_STUB_LSDVD:-}" ]; then                    # stub: tiedosto jossa tittelinumerot
    [ -f "$DVDQ_STUB_LSDVD" ] && { grep -E '^[0-9]+$' "$DVDQ_STUB_LSDVD"; return 0; }
    return 1
  fi
  command -v lsdvd >/dev/null 2>&1 || return 1
  lsdvd "$1" 2>/dev/null | sed -n 's/^Title: 0*\([0-9]\+\),.*/\1/p' | grep -E '^[0-9]+$'
}

# --- vaihe 2: per-titteli-skannaus (HandBrake --scan --json) -----------------------------------
# scan_title <dvd_dir> <title> → OMAN SKEEMAN titteli-JSON, tai {"title":N,"status":"broken",...}.
# Timeout-wrapattu (§6.2). Stub: DVDQ_STUB_SCANTITLE = skripti joka tulostaa valmiin titteli-JSONin.
scan_title() {
  local dir=$1 t=$2
  if [ -n "${DVDQ_STUB_SCANTITLE:-}" ]; then "$DVDQ_STUB_SCANTITLE" "$dir" "$t"; return 0; fi
  local raw
  raw=$(timeout "${CFG[SCAN_TIMEOUT]}" HandBrakeCLI --scan --json -i "$dir" --title "$t" 2>/dev/null \
        | sed -n '/^JSON Title Set:/,$p' | sed '1s/^JSON Title Set: //')
  if [ -z "$raw" ] || ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    jq -cn --argjson t "$t" '{title:$t,status:"broken",reason:"scan_timeout_tai_virhe"}'; return 0
  fi
  # HandBraken JSON → oma skeema (best-effort; kentät voivat vaihdella HB-versioittain → validoitava)
  printf '%s' "$raw" | jq -c --argjson t "$t" '
    (.TitleList[0] // {}) as $ti |
    ($ti.Duration // {}) as $d |
    {title:$t, status:"ok",
     duration_s: (( ($d.Hours//0)*3600 + ($d.Minutes//0)*60 + ($d.Seconds//0) )),
     width:  ($ti.Geometry.Width  // null),
     height: ($ti.Geometry.Height // null),
     fps: (if ($ti.FrameRate.Den//0)>0 then (($ti.FrameRate.Num/($ti.FrameRate.Den))|floor) else null end),
     interlaced: ($ti.InterlaceDetected // false),
     crop: (if ($ti.Crop|type=="array") then ($ti.Crop|map(tostring)|join(":")) else null end),
     src_audio: [ ($ti.AudioList // [])[] | (.LanguageCode // "und") ],
     src_subs:  [ ($ti.SubtitleList // [])[] | (.LanguageCode // "und") ] }
    | .dar = (if .width and .height and .height>0 then ((.width/.height*100|floor)/100|tostring) else null end)
    | .format = (if .fps==25 then "PAL" elif .fps==null then null else "NTSC" end)'
}

# --- pääelokuvan tunnistus (§7) ----------------------------------------------------------------
# scan_pick_main <titles_json_array> → {main:<title|null>, confidence:"high|low", alt:[...]}.
# Heuristiikka: pisin = pää. Useampi lähes yhtä pitkä (>= 90 % pisimmästä) → confidence=low + alt[].
scan_pick_main() {
  printf '%s' "$1" | jq -c '
    map(select(.status=="ok")) as $ok |
    if ($ok|length)==0 then {main:null,confidence:"low",alt:[]}
    else ($ok|max_by(.duration_s // 0)) as $m |
      ($ok|map(select((.duration_s//0) >= (($m.duration_s//0)*0.9) and .title != $m.title))|map(.title)) as $alts |
      {main:$m.title, confidence:(if ($alts|length)>0 then "low" else "high" end), alt:$alts}
    end'
}

# --- §8.3 raitapolitiikka: want_audio / want_subs ---------------------------------------------
# derive_want_audio <src_audio_json> → valitut ääniraidat AUDIO_POLICYn mukaan. R8: kommentti on
# HEURISTIIKKA (toinen samankielinen raita) — verifioinnin alaraja pysyy "original"-määrässä (§8.4a).
derive_want_audio() {
  local pol="${CFG[AUDIO_POLICY]}"
  case $pol in
    all) printf '%s' "$1" ;;
    original) printf '%s' "$1" | jq -c 'if length>0 then [.[0]] else [] end' ;;    # 1. raita = alkuperäinen
    original+commentary) printf '%s' "$1" | jq -c '
        if length==0 then [] else
          .[0] as $orig | [$orig] + [ .[1:][] | select(. == $orig) ]   # original + samankieliset (heur. kommentti)
        end' ;;
    *) printf '%s' "$1" ;;
  esac
}
derive_want_subs() {
  local pol="${CFG[SUB_POLICY]}"
  case $pol in
    all)  printf '%s' "$1" ;;
    none) printf '[]' ;;
    *)    printf '%s' "$1" | jq -c --arg langs "$pol" '($langs|split(",")) as $L | map(select(. as $s|$L|index($s)))' 2>/dev/null || printf '%s' "$1" ;;
  esac
}

# --- cmd_scan ---------------------------------------------------------------------------------
_scan_path() { printf '%s/scans/%s.json' "$STATE" "$(_sha1_12 "$1")"; }
# cmd_scan <dvd_dir> [--source S] — kaksivaiheinen skannaus. disc_key = dvd_dir (oletus). JSONL-
# edistyminen stdoutiin, lopputulos scans/<sha1>.json:iin. Enumerointi feilaa → disc:-broken (§5.1).
cmd_scan() {
  local dir=${1-}; [ -n "$dir" ] || { err_out bad_state args "" "dvd_dir pakollinen"; return 1; }
  local disc_key=$dir source="$dir/VIDEO_TS"
  local titles; titles=$(scan_enumerate "$dir") || true
  if [ -z "$titles" ]; then
    # levytason vika (ei titteliä → disc:-id, §5.1) → problematic/
    local did; did=$(disc_id "$disc_key")
    job_put "$did" "$(jq -cn --arg id "$did" --arg dk "$disc_key" --arg src "$source" \
      '{id:$id,seq:0,rev:0,disc_key:$dk,source:$src,title:null,status:"broken",
        fail_reason:"enumerointi epäonnistui (lukukelvoton levy)",kind:"misc",role:"main",
        name:"(broken disc)",dest_dir:"",out_name:"",skip_requested:false,thermal_kill:false,warnings:[]}')" >/dev/null 2>&1
    err_out disc_broken disc_key "$disc_key" "enumerointi epäonnistui"; return 1
  fi
  local total; total=$(printf '%s\n' "$titles" | grep -c .)
  local arr="[]" n=0 t tj
  while read -r t; do
    [ -n "$t" ] || continue
    tj=$(scan_title "$dir" "$t")
    arr=$(printf '%s' "$arr" | jq -c --argjson tj "$tj" '. + [$tj]')
    n=$((n+1))
    jq -cn --arg d "$disc_key" --argjson title "$t" --argjson done "$n" --argjson total "$total" \
      '{scan:$d,title:$title,done:$done,total:$total}'   # JSONL-edistyminen (GUI-aukko b)
  done <<< "$titles"
  local pick; pick=$(scan_pick_main "$arr")
  local out; out=$(jq -cn --arg dk "$disc_key" --arg src "$source" --arg scanned "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson titles "$arr" --argjson pick "$pick" \
    '{disc_key:$dk,source:$src,scanned:$scanned,titles:$titles,
      main_suggestion:$pick.main,confidence:$pick.confidence,alt_main_titles:$pick.alt,
      enqueued:[],confirmed:false}')
  printf '%s' "$out" | write_json_atomic "$(_scan_path "$disc_key")"
  ok_out "$(printf '"disc_key":"%s","titles":%s,"main_suggestion":%s,"confidence":"%s"' \
    "$disc_key" "$total" "$(printf '%s' "$pick"|jq -c .main)" "$(printf '%s' "$pick"|jq -r .confidence)")"
}
