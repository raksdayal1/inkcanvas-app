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
    // Kept current on every layout (not just the first), since
    // CanvasViewport.pan's clamping (see its class doc - the page can't
    // be panned above/left of its own top-left origin) needs to know how
    // big the viewport is, and that changes whenever the window is
    // resized.
    if (size != Size.zero) viewport.viewportSize = size;
    if (_didInitialCentering || size == Size.zero) return;
    _didInitialCentering = true;
    // Open right on the page's origin at 100% zoom, right from the very
    // first frame - exactly what [resetZoom] below does. The title lives
    // at canvas (0, 0) and content only ever grows right/down from
    // there, OneNote-style, so - unlike before this existed - there's no
    // "center of the page" to open on; the top-left corner (with a
    // small margin - see CanvasViewport.originMargin) is the one fixed
    // point that always makes sense.
    viewport.pan = const Offset(CanvasViewport.originMargin, CanvasViewport.originMargin);
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
    viewport.pan = const Offset(CanvasViewport.originMargin, CanvasViewport.originMargin);
    notifyListeners();
  }
}
