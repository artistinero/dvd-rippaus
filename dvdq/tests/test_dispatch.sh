#!/usr/bin/env bash
# test_dispatch.sh — ajaa dispatcher-osiotestit KUKIN OMANA prosessinaan (dt_*.sh).
# Erilliset prosessit välttävät kumulatiivisen fd/tila-vuodon yhden pitkän skriptin sisällä.
# HUOM: worker_run päästä-päähän (oikea taustaprosessi + setsid-enkooderi) todennetaan
# brainbin-integraatiossa (§12 kohta 9); tässä logiikka katetaan synkronisesti.
HERE=$(cd "$(dirname "$0")" && pwd)
rc=0
for s in dt_slots dt_recover dt_commit dt_gates; do
  echo "== $s =="
  timeout 30 bash "$HERE/$s.sh" || rc=1
done
echo
[ "$rc" -eq 0 ] && echo "KAIKKI DISPATCHER-OSIOT OK" || echo "JOKIN OSIO EPÄONNISTUI"
exit "$rc"
