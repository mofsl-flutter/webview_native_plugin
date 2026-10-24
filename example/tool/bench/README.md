# Timing the chart's open

Tools for comparing how long the chart takes to open between builds (hosted page or bundled page,
with or without a change), on an **Android emulator**. Everything here refuses a device that is not
an emulator, so a phone attached by USB is never touched.

## Why it is built this way

- **One launch per run.** The app is launched with a regression case (`--es scenario O1 --ez autorun
  true`), prints `HBRESULT` lines, and is stopped. `O1` opens the chart named by `CHART_SYMBOL`;
  `O2` is the same with the opening data prefetched from Dart.
- **Cold and warm.** `cold` clears the app's data before the launch; `warm` keeps the cache and just
  relaunches. A `prime` launch fills the cache first and is never counted.
- **Interleave.** Run the variants in alternating blocks (`H1 B1 B2 H2`), so a slow stretch of the
  emulator or the network lands on every variant, and read `byBlock` to see how far blocks drift.
- **Say what you ran on.** Each block writes a `.meta` file with the WebView version, free memory and
  the APK's checksum. Timings depend on those, and the emulator itself drifts: the same build opened in
  3 to 5 s on one emulator in the morning and in 0.8 to 0.9 s on it later that day, with about the same
  free memory both times, so RAM was not the cause and the cause is unknown. Compare variants run in the
  same sitting, never against numbers from another one.
- **WebView version matters for the code cache.** WebView 133 gives even the hosted page no V8 code
  cache; WebView 156 gives it one from its third load of a script. A code-cache question has to be
  judged on the newer WebView.
- **Check where requests went.** `netcap.mjs` records every request the WebView makes and `hosts.mjs`
  fails the capture on a UAT host, a plain-http request or an unknown host, so "the charting library
  uses production for everything" is asserted, not eyeballed.

## Use

```sh
# builds (hosted page, and bundled page); same Dart in both
flutter build apk --debug --dart-define=CHART_SYMBOL=IDX:1:SENSEX
flutter build apk --debug --dart-define=CHART_SYMBOL=IDX:1:SENSEX --dart-define=CHART_LOCAL=true

# one block of one variant: 4 cold, 1 priming, 4 warm launches
tool/bench/run_block.sh --device emulator-5556 --apk app.apk --variant bundled --block B1 \
    --scenario O1 --out results/

# tables: medians, min/max, median without the slowest run, every value, per-block drift
node tool/bench/analyze.mjs results/

# where did the requests go?  (writes capture.json, then checks it)
node tool/bench/netcap.mjs --device emulator-5556 --out capture.json --label bundled_cold --cold
node tool/bench/hosts.mjs capture.json
```

## Reading the numbers

`e2e` is the time from the chart controller starting the page load until the chart reports that its
candles are drawn (the harness's `endToEnd`). `nav` is the time until navigation starts, `doc` the
document load, `jsBoot` the time until the page's globals exist, `render` the time from asking for the
chart until it is drawn. They overlap; they are not parts of a sum.

The hosted page's result line says `FAIL` for case `O1`, because the case also checks that the build
was started with `CHART_LOCAL=true`. The open itself is judged by its `outcome` (`chartSuccess`), which
is what `analyze.mjs` uses.

Opening a chart records it as the account's last-viewed one and saves the layout, so use a test
client, or `CHART_SYMBOL` set to what the account was on, and compare the account's saved layout
before and after.

## Not covered

Real devices, iOS timing, and a real market session. An emulator's absolute numbers say little about a
phone; the comparison between variants run the same way is what these tools are for.
