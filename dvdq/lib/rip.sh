#!/usr/bin/env bash
# dvdq/lib/rip.sh — rippaus (§7). Orkestroi: levytila-/velkaesiehto → dvdbackup -M → paikanna
# VIDEO_TS → scan (scans/). Vahvistus + enqueue on KÄYTTÖLIITTYMÄN vastuulla (§1: ydin ei kysy),
# joka lukee scans/<sha1>.json:in ja kutsuu enqueueta. Työkalut stubattavissa (brainbin-toolchain).
# Sourcaa common.sh + jobs.sh + scan.sh (+ cleanup.sh velkamittaria varten) ensin.
set -uo pipefail

# next_disc_dir — seuraava WORK_DIR/disc-NNN (juokseva, nollatäytetty).
next_disc_dir() {
  local wd="${CFG[WORK_DIR]}" max=0 d n
  for d in "$wd"/disc-*; do
    [ -d "$d" ] || continue
    n=$(basename "$d" | sed -n 's/^disc-0*\([0-9]\+\)$/\1/p'); is_uint "$n" && [ "$n" -gt "$max" ] && max=$n
  done
  printf '%s/disc-%03d' "$wd" "$((max+1))"
}

# rip_backup <device> <out_dir> — kopioi levy. Asettaa RIP_READ_ERRORS. Stub: DVDQ_STUB_DVDBACKUP
# (skripti <device> <out_dir> → luo VIDEO_TS + tulostaa lukuvirheiden määrän stdoutiin).
RIP_READ_ERRORS=0
rip_backup() {
  local dev=$1 out=$2
  mkdir -p "$out"
  if [ -n "${DVDQ_STUB_DVDBACKUP:-}" ]; then
    RIP_READ_ERRORS=$("$DVDQ_STUB_DVDBACKUP" "$dev" "$out" 2>/dev/null | grep -E '^[0-9]+$' | head -1)
    is_uint "$RIP_READ_ERRORS" || RIP_READ_ERRORS=0; return 0
  fi
  command -v dvdbackup >/dev/null 2>&1 || return 1
  local err="$out/.dvdbackup.err"
  dvdbackup -M -i "$dev" -o "$out" 2>"$err"
  RIP_READ_ERRORS=$(grep -ciE 'read error|libdvdread.*error' "$err" 2>/dev/null || echo 0)
  is_uint "$RIP_READ_ERRORS" || RIP_READ_ERRORS=0
}

# _ensure_disc <device> — sulje kelkka (jos auki) ja odota kunnes media on luettavissa. Vanha
# korjaa-tekstitys.sh teki `eject -t` alussa; sama tarve tässä. rc≠0 jos ei levyä timeoutin sisällä.
_ensure_disc() {
  local dev=$1 i
  command -v eject >/dev/null 2>&1 && eject -t "$dev" >/dev/null 2>&1   # sulje kelkka (no-op jos jo kiinni)
  for i in $(seq 1 30); do                                             # odota ≤60 s että levy pyörähtää käyntiin
    dd if="$dev" of=/dev/null bs=2048 count=1 >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# cmd_rip <device> — levytila-/velkaesiehto (§7.1), rippaus, VIDEO_TS-paikannus, scan.
cmd_rip() {
  local dev=${1-}; [ -n "$dev" ] || { err_out bad_state args "" "laite pakollinen"; return 1; }
  # --- levytila-esiehdot (tavupohjaiset, §2.4) ---
  local freeb minb
  freeb=$(df --output=avail -B1 "${CFG[WORK_DIR]}" 2>/dev/null | tail -1 | tr -dc '0-9')
  minb=$(gb_to_bytes "${CFG[RIP_MIN_FREE_GB]}")
  num_ge "${freeb:-0}" "$minb" || { err_out bad_state disk "$freeb" "WORK_DIR vapaa < RIP_MIN_FREE_GB"; return 1; }
  # enkoodausvelka per disc_key (§7.1) — vain jos cleanup.sh sourcattu
  if command -v encode_debt_bytes >/dev/null 2>&1; then
    local debtb maxb; debtb=$(encode_debt_bytes); maxb=$(gb_to_bytes "${CFG[RIP_AHEAD_MAX_GB]}")
    num_ge "$debtb" "$maxb" && { err_out bad_state debt "$debtb" "enkoodausvelka > RIP_AHEAD_MAX_GB"; return 1; }
  fi
  # --- kelkan sulku + levyn valmius (paitsi stub-testissä) ---
  if [ -z "${DVDQ_STUB_DVDBACKUP:-}" ]; then
    _ensure_disc "$dev" || { err_out disc_broken device "$dev" "ei luettavaa levyä 60 s:ssa (kelkka auki tai tyhjä?)"; return 1; }
  fi
  # --- rippaus ---
  local discdir; discdir=$(next_disc_dir)
  # Epäonnistunut rippaus siivoaa OMAN hakemistonsa → ei jää tyhjiä disc-NNN-haamunumeroita.
  rip_backup "$dev" "$discdir" || { rm -rf "$discdir"; err_out bad_state dvdbackup "$dev" "dvdbackup epäonnistui"; return 1; }
  local vts; vts=$(find "$discdir" -type d -iname VIDEO_TS 2>/dev/null | head -1)
  [ -n "$vts" ] || { rm -rf "$discdir"; err_out disc_broken device "$dev" "VIDEO_TS ei löytynyt rippauksen jälkeen"; return 1; }
  local disc_key; disc_key=$(dirname "$vts")
  # --- lukuvirheet → levytason broken (§7 kohta 4) ---
  if [ "$RIP_READ_ERRORS" -gt "${CFG[READ_ERROR_MAX]}" ]; then
    local did; did=$(disc_id "$disc_key")
    job_put "$did" "$(jq -cn --arg id "$did" --arg dk "$disc_key" --arg src "$vts" --argjson re "$RIP_READ_ERRORS" \
      '{id:$id,seq:0,rev:0,disc_key:$dk,source:$src,title:null,status:"broken",read_errors:$re,
        fail_reason:"READ_ERROR yli rajan",kind:"misc",role:"main",name:"(broken disc)",
        dest_dir:"",out_name:"",skip_requested:false,thermal_kill:false,warnings:[]}')" >/dev/null 2>&1
    err_out disc_broken disc_key "$disc_key" "READ_ERROR $RIP_READ_ERRORS > ${CFG[READ_ERROR_MAX]}"; return 1
  fi
  # --- skannaus (→ scans/<sha1>.json), UI vahvistaa + enqueuaa ---
  cmd_scan "$disc_key"
}
