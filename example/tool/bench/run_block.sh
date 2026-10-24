#!/usr/bin/env bash
# One block of timing runs of one build on one EMULATOR.
#
#   run_block.sh --device emulator-5556 --apk app.apk --variant bundled_pre --block B1 \
#                --out results/ [--scenario O1] [--cold 4] [--warm 4] [--prime 1]
#
# Installs the APK, then launches the app once per run with a regression case (default `O1`: open
# the chart named by CHART_SYMBOL and look at it), collecting the HBRESULT log lines of each launch:
#   cold   app data cleared (`pm clear`) before the launch
#   prime  one launch whose only job is to fill the cache; analyze.mjs never counts it
#   warm   cache kept, app stopped and relaunched
# Files: <out>/<block>__<variant>__<scenario>__<cache>__<n>.tsv, plus <block>__<variant>__<scenario>.meta
# (WebView version, free memory, APK checksum). Interleave variants across blocks (H1 B1 B2 H2) so a
# slow stretch of the emulator or the network lands on both.
#
# Refuses any device that is not an emulator: a phone attached by USB is never touched.
set -u
export LC_ALL=C

DEVICE=""; APK=""; VARIANT=""; BLOCK=""; OUT=""; SCENARIO="O1"; COLD=4; WARM=4; PRIME=1
PKG=com.example.ios_webview_plugin_example

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2;; --apk) APK="$2"; shift 2;; --variant) VARIANT="$2"; shift 2;;
    --block) BLOCK="$2"; shift 2;; --out) OUT="$2"; shift 2;; --scenario) SCENARIO="$2"; shift 2;;
    --cold) COLD="$2"; shift 2;; --warm) WARM="$2"; shift 2;; --prime) PRIME="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
for v in DEVICE APK VARIANT BLOCK OUT; do
  [ -n "${!v}" ] || { echo "missing --$(echo $v | tr 'A-Z' 'a-z')" >&2; exit 2; }
done
case "$DEVICE" in emulator-[0-9]*) ;; *) echo "refusing: '$DEVICE' is not an emulator serial" >&2; exit 2;; esac
[ -f "$APK" ] || { echo "no such apk: $APK" >&2; exit 2; }
case "$VARIANT$BLOCK$SCENARIO" in *__*|*/*|*" "*) echo "variant, block and scenario must not contain '__', '/' or spaces" >&2; exit 2;; esac
[ "$(adb -s "$DEVICE" get-state 2>/dev/null)" = "device" ] || { echo "$DEVICE is not ready" >&2; exit 2; }
mkdir -p "$OUT" || exit 2

adb -s "$DEVICE" install -r "$APK" >/dev/null 2>&1 || { echo "install failed" >&2; exit 3; }

{
  echo "device=$DEVICE"
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "webview=$(adb -s "$DEVICE" shell dumpsys webviewupdate 2>/dev/null | tr -d '\r' | sed -n 's/.*Current WebView package (name, version): (\(.*\)).*/\1/p' | head -1)"
  echo "memAvailableKB=$(adb -s "$DEVICE" shell grep MemAvailable /proc/meminfo | tr -d '\r' | awk '{print $2}')"
  echo "apkMd5=$(md5 -q "$APK" 2>/dev/null || md5sum "$APK" | cut -d' ' -f1)"
} > "$OUT/${BLOCK}__${VARIANT}__${SCENARIO}.meta"

one() { # CACHE N
  local cache="$1" n="$2"
  local file="$OUT/${BLOCK}__${VARIANT}__${SCENARIO}__${cache}__${n}.tsv"
  adb -s "$DEVICE" shell am force-stop "$PKG"
  if [ "$cache" = cold ]; then adb -s "$DEVICE" shell pm clear "$PKG" >/dev/null; fi
  sleep 1
  adb -s "$DEVICE" logcat -c
  adb -s "$DEVICE" shell am start -n "$PKG/.MainActivity" --es scenario "$SCENARIO" --ez autorun true >/dev/null
  local end=$((SECONDS + 170))
  : > "$file"
  while [ $SECONDS -lt $end ]; do
    adb -s "$DEVICE" logcat -d -s flutter 2>/dev/null | sed -n 's/.*HBRESULT\t/HBRESULT\t/p' > "$file.tmp" || true
    cp "$file.tmp" "$file"
    grep -q "__DONE__" "$file" && break
    sleep 2
  done
  rm -f "$file.tmp"
  echo "$BLOCK $VARIANT $SCENARIO $cache $n: $(grep -c . "$file") lines, done=$(grep -c __DONE__ "$file")"
}

for ((n = 1; n <= COLD; n++)); do one cold "$n"; done
for ((n = 0; n < PRIME; n++)); do one prime "$n"; done
for ((n = 1; n <= WARM; n++)); do one warm "$n"; done
echo "BLOCK $BLOCK $VARIANT $SCENARIO FINISHED"
