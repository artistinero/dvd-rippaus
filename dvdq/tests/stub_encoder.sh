#!/usr/bin/env bash
# stub-enkooderi testeille. Argumentit: <id> <source> <title> <out_tmp>
# Ympäristö: STUB_PRE (sleep ennen kirjoitusta), STUB_SLEEP (sleep kirjoituksen jälk.),
#            STUB_NOWRITE=1 (älä kirjoita → verify hylkää), STUB_RC (paluuarvo).
tmp=$4
sleep "${STUB_PRE:-0}"
[ "${STUB_NOWRITE:-0}" = 1 ] || printf 'STUBDATA-%s' "$1" > "$tmp"
sleep "${STUB_SLEEP:-0}"
exit "${STUB_RC:-0}"
