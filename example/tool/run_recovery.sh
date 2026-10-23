#!/usr/bin/env bash
# Runs the recovery suite on a connected Android device or emulator and prints the verdicts.
#
# The suite needs no token and no network: it loads a data: URL page and drives the plugin's
# self-healing primitives (probe, claimDelegate, destroyWebView, view ownership, a second Flutter
# engine, a crashed renderer). Results come back over logcat under the HBRESULT tag, the same as
# run_regression.sh.
#
#   tool/run_recovery.sh              # every case
#   ONLY="E2 V2" tool/run_recovery.sh # just those
#   DEVICE=emulator-5554 tool/run_recovery.sh
set -uo pipefail

PKG="com.example.ios_webview_plugin_example"
ACT="$PKG/.MainActivity"
DEVICE="${DEVICE:-}"
ONLY="${ONLY:-all}"
TIMEOUT="${TIMEOUT:-240}"
OUT="${OUT:-recovery-results.tsv}"
TAG="HBRESULT"
export LC_ALL=C

adb_() { if [ -n "$DEVICE" ]; then adb -s "$DEVICE" "$@"; else adb "$@"; fi; }
die() { echo "error: $*" >&2; exit 1; }

command -v adb >/dev/null || die "adb not on PATH"
adb_ get-state >/dev/null 2>&1 || die "no device (set DEVICE=<serial> if several are attached)"

CSV="${ONLY// /,}"
echo "device: $(adb_ shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
echo "webview: $(adb_ shell dumpsys package com.google.android.webview 2>/dev/null | sed -n 's/ *versionName=//p' | head -1 | tr -d '\r')"
echo "cases: $CSV"

adb_ shell am force-stop "$PKG" >/dev/null
adb_ logcat -c
adb_ shell am start -n "$ACT" --es recovery "$CSV" --ez autorun true >/dev/null

deadline=$(( SECONDS + TIMEOUT ))
done=0
while [ $SECONDS -lt $deadline ]; do
  if adb_ logcat -d 2>/dev/null | grep -aq "__DONE__"; then done=1; break; fi
  sleep 3
done

adb_ logcat -d 2>/dev/null | grep -a "$TAG" | sed -e "s/.*$TAG$(printf '\t')//" | grep -av '^__DONE__' > "$OUT"

if [ $done -eq 1 ]; then
  adb_ logcat -d 2>/dev/null | grep -a '__DONE__' | tail -1 | sed -e "s/.*__DONE__$(printf '\t')/  /"
else
  echo "  TIMEOUT after ${TIMEOUT}s: partial results kept"
fi

echo
awk -F'\t' '{printf "%-5s %-5s %s\n", $1, $2, $3}' "$OUT"
echo
echo "results -> $OUT"
if grep -aE "$(printf '\t')(FAIL|ERROR)$(printf '\t')" "$OUT" >/dev/null 2>&1; then
  echo; echo "failures:"
  awk -F'\t' '$2=="FAIL"||$2=="ERROR"{print "  " $1 "  " $4}' "$OUT"
  exit 1
fi
