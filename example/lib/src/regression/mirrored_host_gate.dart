import 'package:ios_webview_plugin/ios_webview_plugin.dart';
import 'package:ios_webview_plugin/webview_events.dart';

import '../model/chart_messages.dart';
import '../service/webview_bridge.dart';

/// Mirrors the host app's JavaScript-injection gate.
///
/// The host tracks a chart state and refuses to inject unless that state has reached
/// `pageLoaded`; on a skip it logs a debug line and returns null, so callers `await` it and
/// cannot tell success from a no-op. Crucially, a reload drops the state back *below* the
/// threshold — and the host reloads on every app resume, which opens a window where everything
/// it pushes is discarded.
///
/// The harness has to reproduce that gate, not just the page, or the cases that pin the defect
/// would inject successfully and report a false pass. (They did exactly that until this existed.)
class MirroredHostGate {
  /// Starts tracking page messages.
  MirroredHostGate() {
    WebViewBridge.instance.addSink(_onEvent);
  }

  ChartState _state = ChartState.initial;

  /// Injections that the gate refused, for assertions to inspect.
  final List<String> skipped = <String>[];

  /// The mirrored state.
  ChartState get state => _state;

  /// Whether an injection would be allowed right now.
  ///
  /// Note `chartError` sits numerically *above* `pageLoaded` in the host's ordering, so
  /// injection is permitted while the chart is in an error state — reproduced here rather than
  /// corrected, because that is the behaviour under test.
  bool get allowsInjection => _state.value >= ChartState.pageLoaded.value;

  /// Marks a navigation as started, which is what closes the gate.
  void onLoadRequested() => _state = ChartState.pageLoading;

  /// Resets to the initial state, between scenarios.
  void reset() {
    _state = ChartState.initial;
    skipped.clear();
  }

  /// Runs [script] only if the gate allows it, mirroring the host.
  ///
  /// Returns true when the script was injected, false when it was skipped.
  Future<bool> runJavaScript(String script, {String label = 'script'}) async {
    if (!allowsInjection) {
      skipped.add(label);
      return false;
    }
    await IosWebViewPlugin.runJavaScript(script);
    return true;
  }

  void _onEvent(WebViewEvent event) {
    if (event is WebViewPageStartedEvent) {
      _state = ChartState.pageLoading;
      return;
    }
    if (event is! WebViewChannelMessageEvent) return;
    final Map<String, Object?>? decoded = event.decoded;
    if (decoded == null) return;
    final ChannelResponse? r = ChannelResponse.tryParse(decoded);
    if (r == null) return;
    switch (r.context) {
      case 'PageReady':
        if (r.success != null) _state = ChartState.pageLoaded;
      case 'Chart':
        _state = r.success != null ? ChartState.chartLoaded : ChartState.chartError;
      default:
        break;
    }
  }

  /// Stops tracking.
  void dispose() => WebViewBridge.instance.removeSink(_onEvent);
}
