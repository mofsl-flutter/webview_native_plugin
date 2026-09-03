import "dart:convert";

import "package:flutter/services.dart";

/// Name of the event channel every native WebView event arrives on.
const String kWebViewEventChannelName = "webview_plugin_events";

const EventChannel _eventChannel = EventChannel(kWebViewEventChannelName);

/// A single event emitted by the native WebView.
///
/// Every native event carries a discriminator plus the clocks stamped at the point of capture,
/// so intervals can be computed without trusting when Dart happened to observe them.
sealed class WebViewEvent {
  /// Creates an event with its captured clocks.
  const WebViewEvent({
    required this.raw,
    this.ts,
    this.tsMono,
    this.loadId,
  });

  /// The undecoded platform payload, retained for diagnostics.
  final Object? raw;

  /// Wall clock (milliseconds since epoch) at the point of capture.
  ///
  /// Shares an origin with [DateTime.now], so it is directly comparable to Dart timestamps.
  final int? ts;

  /// Monotonic clock (`SystemClock.elapsedRealtime`) at the point of capture.
  ///
  /// Immune to wall-clock adjustment, so this is the authority for native-to-native intervals.
  /// Its origin is device boot, unrelated to any Dart clock.
  final int? tsMono;

  /// Load generation this event belongs to, or `-1` before any load.
  final int? loadId;

  /// Decodes a platform payload into a typed event.
  ///
  /// Never throws: unrecognised shapes become [WebViewUnknownEvent] and malformed JSON in a
  /// channel message becomes [WebViewChannelMessageEvent] with a null [WebViewChannelMessageEvent.decoded].
  static WebViewEvent fromPlatform(Object? raw) {
    // iOS emits bare strings on this same sink, and Android's legacy `pageDidLoad` sent the
    // literal "pageLoaded". A parser that assumes Map throws inside the stream listener.
    if (raw is String) {
      return WebViewRawStringEvent(raw: raw, value: raw);
    }
    if (raw is! Map) {
      return WebViewUnknownEvent(raw: raw, name: "");
    }

    // Platform-channel maps decode as Map<Object?, Object?>; `as Map<String, dynamic>` throws.
    final Map<String, Object?> map = Map<String, Object?>.from(raw);
    final String name = map["event"]?.toString() ?? "";
    final int? ts = _asInt(map["ts"]);
    final int? tsMono = _asInt(map["tsMono"]);
    final int? loadId = _asInt(map["loadId"]);

    switch (name) {
      case "pageStarted":
        return WebViewPageStartedEvent(
          raw: raw,
          url: map["url"]?.toString() ?? "",
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
      case "pageCommitVisible":
        return WebViewPageCommitVisibleEvent(
          raw: raw,
          url: map["url"]?.toString() ?? "",
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
      case "pageFinished":
        return WebViewPageFinishedEvent(
          raw: raw,
          url: map["url"]?.toString() ?? "",
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
      case "pageProgress":
        return WebViewProgressEvent(
          raw: raw,
          progress: _asInt(map["progress"]) ?? 0,
          url: map["url"]?.toString(),
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
      case "javascriptChannelMessageReceived":
        final String message = map["message"]?.toString() ?? "";
        Map<String, Object?>? decoded;
        try {
          final Object? parsed = jsonDecode(message);
          if (parsed is Map) {
            decoded = Map<String, Object?>.from(parsed);
          }
        } on FormatException {
          decoded = null;
        }
        return WebViewChannelMessageEvent(
          raw: raw,
          channelName: map["channelName"]?.toString() ?? "",
          message: message,
          decoded: decoded,
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
      case "error":
        return WebViewErrorEvent(
          raw: raw,
          errorCode: _asInt(map["errorCode"]),
          description: map["description"]?.toString() ?? map["message"]?.toString() ?? "",
          failingUrl: map["failingUrl"]?.toString(),
          isForMainFrame: map["isForMainFrame"] as bool?,
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
      case "httpError":
        return WebViewHttpErrorEvent(
          raw: raw,
          statusCode: _asInt(map["statusCode"]) ?? 0,
          url: map["url"]?.toString(),
          isForMainFrame: map["isForMainFrame"] as bool? ?? false,
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
      case "consoleMessage":
        return WebViewConsoleEvent(
          raw: raw,
          message: map["message"]?.toString() ?? "",
          level: map["level"]?.toString() ?? "",
          sourceId: map["sourceId"]?.toString(),
          lineNumber: _asInt(map["lineNumber"]),
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
      case "visualStateReady":
        return WebViewVisualStateEvent(
          raw: raw,
          requestId: _asInt(map["requestId"]) ?? 0,
          url: map["url"]?.toString(),
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
      default:
        return WebViewUnknownEvent(
          raw: raw,
          name: name,
          ts: ts,
          tsMono: tsMono,
          loadId: loadId,
        );
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

/// Navigation of the main document began.
final class WebViewPageStartedEvent extends WebViewEvent {
  /// Creates a page-started event.
  const WebViewPageStartedEvent({
    required super.raw,
    required this.url,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// URL whose navigation started.
  final String url;
}

/// The new page painted for the first time.
final class WebViewPageCommitVisibleEvent extends WebViewEvent {
  /// Creates a first-paint event.
  const WebViewPageCommitVisibleEvent({
    required super.raw,
    required this.url,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// URL that became visible.
  final String url;
}

/// The main document finished loading.
///
/// For a JavaScript charting page this fires well before the chart is drawn.
final class WebViewPageFinishedEvent extends WebViewEvent {
  /// Creates a page-finished event.
  const WebViewPageFinishedEvent({
    required super.raw,
    required this.url,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// URL that finished loading.
  final String url;
}

/// Chromium's synthesised load progress.
final class WebViewProgressEvent extends WebViewEvent {
  /// Creates a progress event.
  const WebViewProgressEvent({
    required super.raw,
    required this.progress,
    this.url,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// Progress from 0 to 100.
  final int progress;

  /// URL being loaded, when known.
  final String? url;
}

/// A message posted by page JavaScript through a registered channel.
final class WebViewChannelMessageEvent extends WebViewEvent {
  /// Creates a channel-message event.
  const WebViewChannelMessageEvent({
    required super.raw,
    required this.channelName,
    required this.message,
    this.decoded,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// Channel the message arrived on.
  final String channelName;

  /// Raw message string as posted by the page.
  final String message;

  /// [message] decoded as a JSON object, or null when it is not a JSON object.
  final Map<String, Object?>? decoded;
}

/// A resource or navigation failure.
final class WebViewErrorEvent extends WebViewEvent {
  /// Creates an error event.
  const WebViewErrorEvent({
    required super.raw,
    required this.description,
    this.errorCode,
    this.failingUrl,
    this.isForMainFrame,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// Native error code, or null when the WebView is too old to report one.
  final int? errorCode;

  /// Human-readable description.
  final String description;

  /// URL that failed.
  final String? failingUrl;

  /// Whether the failure was for the main document rather than a subresource.
  final bool? isForMainFrame;
}

/// A non-2xx HTTP response for the document or a subresource.
final class WebViewHttpErrorEvent extends WebViewEvent {
  /// Creates an HTTP error event.
  const WebViewHttpErrorEvent({
    required super.raw,
    required this.statusCode,
    required this.isForMainFrame,
    this.url,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// HTTP status code.
  final int statusCode;

  /// URL that returned the status.
  final String? url;

  /// Whether it was the main document.
  final bool isForMainFrame;
}

/// A `console.*` call from page JavaScript.
final class WebViewConsoleEvent extends WebViewEvent {
  /// Creates a console event.
  const WebViewConsoleEvent({
    required super.raw,
    required this.message,
    required this.level,
    this.sourceId,
    this.lineNumber,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// Console message text.
  final String message;

  /// Severity as reported by Chromium.
  final String level;

  /// Source file, when known.
  final String? sourceId;

  /// Source line, when known.
  final int? lineNumber;
}

/// The renderer reached the requested visual state, i.e. pixels are on screen.
final class WebViewVisualStateEvent extends WebViewEvent {
  /// Creates a visual-state event.
  const WebViewVisualStateEvent({
    required super.raw,
    required this.requestId,
    this.url,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// Identifier passed when the callback was posted.
  final int requestId;

  /// URL that reached the state.
  final String? url;
}

/// A bare string payload, as iOS emits for some messages.
final class WebViewRawStringEvent extends WebViewEvent {
  /// Creates a raw string event.
  const WebViewRawStringEvent({required super.raw, required this.value});

  /// The string as delivered.
  final String value;
}

/// An event this version of the Dart layer does not model.
///
/// Exists so a newer native side never breaks an older consumer.
final class WebViewUnknownEvent extends WebViewEvent {
  /// Creates an unknown event.
  const WebViewUnknownEvent({
    required super.raw,
    required this.name,
    super.ts,
    super.tsMono,
    super.loadId,
  });

  /// Discriminator as reported, possibly empty.
  final String name;
}

Stream<Object?>? _rawEvents;

/// Every native WebView event, as a single shared broadcast stream.
///
/// There must be exactly **one** `receiveBroadcastStream` call for the whole library. Each call
/// creates a new controller whose `onListen` reinstalls the channel's message handler, and there
/// is only one handler per channel name — so a second subscription silently stops the first from
/// receiving anything. This getter memoises that single subscription.
Stream<Object?> get rawWebViewEvents =>
    _rawEvents ??= _eventChannel.receiveBroadcastStream().asBroadcastStream();

Stream<WebViewEvent>? _typedEvents;

/// Every native WebView event, decoded into [WebViewEvent].
Stream<WebViewEvent> get webViewEvents =>
    _typedEvents ??= rawWebViewEvents.map(WebViewEvent.fromPlatform).asBroadcastStream();
