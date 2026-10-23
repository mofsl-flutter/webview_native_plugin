# ios_webview_plugin_example

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.


## Recovery suite

Exercises the plugin's self-healing primitives on a real device, with no token and no network (the
page under test is served from a `data:` URL on Android and a loopback HTTP server on iOS):

| Group | What it checks |
|---|---|
| **P** Probe | healthy page, page without the chart app, destroyed WebView, hung renderer, page that no view hosts |
| **E** Event path | a second Flutter engine (what `firebase_messaging` starts for a background push) taking or not taking the events, `claimDelegate`, which calls reclaim the delegate, `loadRequested` timing |
| **V** Views | dispose/remount, and an older view being disposed while a newer one hosts the WebView |
| **R** Rebuild | destroy + prewarm + remount, the stale-view trap, a crashed renderer |

Open it from the first screen (**Recovery suite**), or run it unattended:

```sh
# Android (device or emulator)
tool/run_recovery.sh                 # every case
ONLY="E1 V2" tool/run_recovery.sh    # some of them
DEVICE=emulator-5554 tool/run_recovery.sh

# iOS simulator: build with the request baked in, then read the HBRESULT lines from the log
flutter build ios --simulator --debug --config-only --dart-define=RECOVERY=all
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 -derivedDataPath build/ios_dd build
xcrun simctl install booted build/ios_dd/Build/Products/Debug-iphonesimulator/Runner.app
xcrun simctl launch booted com.example.iosWebviewPluginExample
xcrun simctl spawn booted log show --last 5m --style compact \
  --predicate 'process == "Runner" AND eventMessage CONTAINS "HBRESULT"'
```

Cases needing a second engine or a renderer crash (E1, E2, E2b, E8, E9, R3, P3) are Android only and
report `SKIP` elsewhere; E3, E4, E6, E7, E8 need a debug build. A failing case prints what it saw,
including the platform-view event order for the view cases. `Xcode 27` needs the example's iOS
deployment target at 15 or above, which `ios/Podfile` sets.
