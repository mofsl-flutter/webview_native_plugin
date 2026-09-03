import "package:flutter/foundation.dart";
import "package:flutter/gestures.dart";
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter/widgets.dart";

/// Platform-view type registered by the native side.
const String kWebViewMoFlutterViewType = "web_view_mo_flutter";

/// How the Android platform view is composited into the Flutter scene.
enum WebViewCompositionMode {
  /// Texture Layer Hybrid Composition, with automatic fallback to hybrid composition.
  ///
  /// The default and the right choice for a WebView: the real `View` is in the hierarchy so it
  /// receives genuine `MotionEvent`s, which is what pan and pinch need.
  textureLayerWithFallback,

  /// Always full hybrid composition.
  ///
  /// Documented as expensive on Android 9 (API 28) and earlier. Useful only for A/B comparison.
  hybrid,

  /// Virtual-display texture mode.
  ///
  /// Provided for comparison only. It has **no** safe fallback: if the WebView tree ever contains
  /// a `SurfaceView` (a fullscreen `<video>`, some composited layers) the engine renders
  /// incorrectly rather than degrading.
  virtualDisplay,
}

/// Embeds the native singleton WebView.
///
/// The widget only puts the view on screen; the page is navigated separately over the method
/// channel. Mount this before calling a load, or use the pre-warm entry point.
class WebViewMoFlutterView extends StatefulWidget {
  /// Creates a platform view hosting the native WebView.
  const WebViewMoFlutterView({
    super.key,
    this.backgroundColor,
    this.compositionMode = WebViewCompositionMode.textureLayerWithFallback,
    this.gestureRecognizers = const <Factory<OneSequenceGestureRecognizer>>{},
    this.onPlatformViewCreated,
  });

  /// Painted behind the WebView.
  ///
  /// The native WebView is deliberately transparent so the Flutter side supplies the themed
  /// background; leaving this null shows whatever is behind the widget.
  final Color? backgroundColor;

  /// How the platform view is composited.
  final WebViewCompositionMode compositionMode;

  /// Gesture recognizers competing with the platform view.
  ///
  /// Defaults to empty, delegating all touch handling to the WebView — which is what a
  /// full-screen chart wants. Supplying an `EagerGestureRecognizer` makes the WebView claim the
  /// arena immediately; note that also prevents any Flutter parent from ever winning, which
  /// breaks a surrounding `PageView` or drawer swipe.
  final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers;

  /// Called with the platform view id once the native view exists.
  ///
  /// By the time this fires the native WebView has been constructed, so it is a sound gate for
  /// issuing a load.
  final void Function(int id)? onPlatformViewCreated;

  @override
  State<WebViewMoFlutterView> createState() => _WebViewMoFlutterViewState();
}

class _WebViewMoFlutterViewState extends State<WebViewMoFlutterView> {
  @override
  Widget build(BuildContext context) {
    final Widget view = defaultTargetPlatform == TargetPlatform.iOS
        ? UiKitView(
            viewType: kWebViewMoFlutterViewType,
            layoutDirection: TextDirection.ltr,
            creationParamsCodec: const StandardMessageCodec(),
            gestureRecognizers: widget.gestureRecognizers,
            onPlatformViewCreated: _handleCreated,
          )
        : _buildAndroidView();

    final Color? background = widget.backgroundColor;
    if (background == null) return view;
    return ColoredBox(color: background, child: view);
  }

  Widget _buildAndroidView() {
    if (widget.compositionMode == WebViewCompositionMode.virtualDisplay) {
      return AndroidView(
        viewType: kWebViewMoFlutterViewType,
        layoutDirection: TextDirection.ltr,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: widget.gestureRecognizers,
        onPlatformViewCreated: _handleCreated,
      );
    }

    return PlatformViewLink(
      viewType: kWebViewMoFlutterViewType,
      surfaceFactory: (BuildContext context, PlatformViewController controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: widget.gestureRecognizers,
        );
      },
      onCreatePlatformView: (PlatformViewCreationParams params) {
        final AndroidViewController controller =
            widget.compositionMode == WebViewCompositionMode.hybrid
                ? PlatformViewsService.initExpensiveAndroidView(
                    id: params.id,
                    viewType: kWebViewMoFlutterViewType,
                    layoutDirection: TextDirection.ltr,
                    creationParamsCodec: const StandardMessageCodec(),
                    onFocus: () => params.onFocusChanged(true),
                  )
                : PlatformViewsService.initSurfaceAndroidView(
                    id: params.id,
                    viewType: kWebViewMoFlutterViewType,
                    layoutDirection: TextDirection.ltr,
                    creationParamsCodec: const StandardMessageCodec(),
                    onFocus: () => params.onFocusChanged(true),
                  );
        return controller
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..addOnPlatformViewCreatedListener(_handleCreated)
          ..create();
      },
    );
  }

  void _handleCreated(int id) {
    widget.onPlatformViewCreated?.call(id);
  }
}
