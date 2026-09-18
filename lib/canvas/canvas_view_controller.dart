import 'package:flutter/material.dart';

import 'canvas_viewport.dart';

/// Thin wrapper so the toolbar (zoom buttons, zoom-percent readout) and
/// the [InfiniteCanvas] widget can share one [CanvasViewport] and rebuild
/// when it changes, without the canvas needing to know about the toolbar.
class CanvasViewController extends ChangeNotifier {
  final CanvasViewport viewport = CanvasViewport();
  Size? _lastKnownSize;

  /// True once this controller has centered itself on the first real
  /// size it was given (see [reportSize]) - after that, resizes (e.g.
  /// the window being resized) shouldn't re-center and throw away
  /// wherever the user has since panned/zoomed to.
  bool _didInitialCentering = false;

  void reportSize(Size size) {
    _lastKnownSize = size;
    if (_didInitialCentering || size == Size.zero) return;
    _didInitialCentering = true;
    // Center canvas-origin on screen at 100% zoom, right from the very
    // first frame - exactly what [resetZoom] below does. Without this,
    // a freshly-opened page starts with the viewport's raw default
    // (pan = Offset.zero, i.e. canvas-origin pinned to the screen's
    // top-left corner) instead, so "Reset zoom" looked like it was
    // resetting to a *different* place than where the page actually
    // opens.
    viewport.pan = Offset(size.width / 2, size.height / 2);
  }

  Offset get _screenCenter =>
      _lastKnownSize == null ? Offset.zero : Offset(_lastKnownSize!.width / 2, _lastKnownSize!.height / 2);

  Offset get canvasCenter => viewport.screenToCanvas(_screenCenter);

  double get scale => viewport.scale;

  void notifyChanged() => notifyListeners();

  void zoomIn() {
    viewport.zoomTo(viewport.scale * 1.25, _screenCenter);
    notifyListeners();
  }

  void zoomOut() {
    viewport.zoomTo(viewport.scale / 1.25, _screenCenter);
    notifyListeners();
  }

  void resetZoom() {
    viewport.scale = 1.0;
    viewport.pan = _screenCenter;
    notifyListeners();
  }
}
