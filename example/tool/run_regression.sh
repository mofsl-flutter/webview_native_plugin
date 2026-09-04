#!/usr/bin/env bash
# Drives the chart regression suite on a connected Android device.
#
# Each case that needs an external precondition (process death, offline, a full data wipe) is
# launched in its own app start, with the precondition set by adb first. Cases without a
# precondition run together in one launch.
#
# Results come back over logcat under the HBRESULT tag. Nothing here depends on synthetic taps:
# UI coordinates proved fragile, and input lands in whatever app is foreground.
set -uo pipefail

PKG="com.example.ios_webview_plugin_example"
ACT="$PKG/.MainActivity"
DEVICE="${DEVICE:-}"
TIMEOUT="${TIMEOUT:-180}"
# The in-app batch runs every no-precondition case sequentially inside one launch, so it needs
# a longer budget than a single case does.
BATCH_TIMEOUT="${BATCH_TIMEOUT:-420}"
OUT="${OUT:-regression-results.tsv}"
RESULT_TAG="HBRESULT"

# logcat output is not guaranteed to be valid UTF-8; without this, sed/grep abort with
# "illegal byte sequence" on some locales.
export LC_ALL=C

adb_() { if [ -n "$DEVICE" ]; then adb -s "$DEVICE" "$@"; else adb "$@"; fi; }

die() { echo "error: $*" >&2; exit 1; }

command -v adb >/dev/null || die "adb not on PATH"
adb_ get-state >/dev/null 2>&1 || die "no device (set DEVICE=<serial> if several are attached)"

# Cases needing a host-set precondition, and which lever each needs.
declare -a HOST_CASES=(
  "A1:fullCold"
  "A3:backgrounded"
  "A5:vmCrash"
  "G2:offline"
)
# Everything else runs without host involvement, split across two launches.
#
# Split deliberately: a single batch of every case has hit its budget on every run so far, and
# the tail of the list (F3 in particular) was never reached at all. Two launches give each half
# its own full budget, so one slow case can no longer starve everything after it.
declare -a INAPP_BATCH_1=(D0 I2 B2 B9 C2 C3 C4 C4b C5)
declare -a INAPP_BATCH_2=(C9 C7 C13 E3 E4 D2 D2b D8 H3 F3)

reset_network() {
  adb_ shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
  sleep 3
}

apply_precondition() {
  case "$1" in
    fullCold)
      echo "  · pm clear (wipes cache, storage, cookies)"
      adb_ shell pm clear "$PKG" >/dev/null
      ;;
    processDeath)
      echo "  · backgrounding then am kill"
      adb_ shell input keyevent KEYCODE_HOME >/dev/null
      sleep 2
      adb_ shell am kill "$PKG" >/dev/null
      sleep 1
      [ -z "$(adb_ shell pidof "$PKG" 2>/dev/null)" ] \
        && echo "    process confirmed dead" \
        || echo "    warning: process still alive; result may not reflect a cold start"
      ;;
    vmCrash)
      echo "  · am crash"
      adb_ shell am crash "$PKG" >/dev/null 2>&1 || true
      sleep 3
      ;;
    memoryPressure)
      echo "  · am kill-all"
      adb_ shell am kill-all >/dev/null 2>&1 || true
      ;;
    offline)
      echo "  · airplane mode on"
      adb_ shell cmd connectivity airplane-mode enable >/dev/null
      sleep 4
      ;;
    backgrounded)
      echo "  · HOME then resume"
      adb_ shell input keyevent KEYCODE_HOME >/dev/null
      sleep 3
      ;;
    *) ;;
  esac
}

# Launch and collect HBRESULT lines until __DONE__ or the timeout.
run_launch() {
  local label="$1"; shift
  echo "→ $label"
  adb_ logcat -c
  adb_ shell am start -n "$ACT" "$@" >/dev/null

  local deadline=$(( SECONDS + TIMEOUT ))
  local done=0
  while [ $SECONDS -lt $deadline ]; do
    if adb_ logcat -d 2>/dev/null | grep -q "__DONE__"; then done=1; break; fi
    sleep 3
  done

  adb_ logcat -d 2>/dev/null \
    | grep -a "$RESULT_TAG" \
    | sed -e "s/.*$RESULT_TAG$(printf '\t')//" \
    | grep -av '^__DONE__' >> "$OUT"

  if [ $done -eq 1 ]; then
    adb_ logcat -d 2>/dev/null | grep -a '__DONE__' | tail -1 \
      | sed -e "s/.*__DONE__$(printf '\t')/  /"
  else
    echo "  TIMEOUT after ${TIMEOUT}s — partial results kept"
  fi
}

: > "$OUT"
echo "device: $(adb_ shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
echo "webview: $(adb_ shell dumpsys package com.google.android.webview 2>/dev/null | sed -n 's/ *versionName=//p' | head -1 | tr -d '\r')"
echo

reset_network

# In-app batches: no external precondition, each launch runs its whole list sequentially.
#
# Each batch must be a single `am start` for its whole list, not one per case: `singleTop` means
# every launch after the first is delivered to the already-running instance's `onNewIntent`, so a
# per-case loop would run only the first case and silently drop the rest. A per-*batch* launch is
# fine — the Dart side handles onNewIntent by pushing a fresh regression screen.
run_inapp_batch() {
  local label="$1"; shift
  local -a cases=("$@")
  IFS=','; local csv="${cases[*]}"; unset IFS
  local saved="$TIMEOUT"
  TIMEOUT="$BATCH_TIMEOUT"
  run_launch "$label (${#cases[@]} cases)" --es scenario "$csv" --ez autorun true
  TIMEOUT="$saved"
}

run_inapp_batch "in-app batch 1" "${INAPP_BATCH_1[@]}"
run_inapp_batch "in-app batch 2" "${INAPP_BATCH_2[@]}"

# Host-driven cases, each in its own launch.
for entry in "${HOST_CASES[@]}"; do
  id="${entry%%:*}"; pre="${entry##*:}"
  echo "→ $id (precondition: $pre)"
  apply_precondition "$pre"
  run_launch "$id" --es scenario "$id" --ez autorun true
  [ "$pre" = "offline" ] && reset_network
done

reset_network

echo
echo "results → $OUT"
awk -F'\t' '{print $2}' "$OUT" | sort | uniq -c | sed 's/^/  /'
echo
grep -P '\tFAIL|\tERROR' "$OUT" 2>/dev/null || grep -E "$(printf '\t')(FAIL|ERROR)" "$OUT" || echo "  no failures"
