import 'package:flutter/material.dart';

/// The pan/zoom state of an [InfiniteCanvas]: maps between screen-space
/// pixels (what the user sees/touches) and canvas-space coordinates (what
/// elements are stored in). This is what makes the canvas "infinite" — pan
/// and scale are just two numbers with no inherent bounds, so there's no
/// fixed-size widget backing the canvas at all.
///
/// Relationship: screen = canvas * scale + pan.
class CanvasViewport {
  CanvasViewport({this.pan = Offset.zero, this.scale = 1.0});

  Offset pan;
  double scale;

  static const double minScale = 0.05;
  static const double maxScale = 12.0;

  Offset canvasToScreen(Offset canvasPoint) => canvasPoint * scale + pan;

  Offset screenToCanvas(Offset screenPoint) => (screenPoint - pan) / scale;

  Rect canvasRectToScreen(Rect r) => Rect.fromLTWH(
        r.left * scale + pan.dx,
        r.top * scale + pan.dy,
        r.width * scale,
        r.height * scale,
      );

  Rect screenRectToCanvas(Rect r) => Rect.fromLTWH(
        (r.left - pan.dx) / scale,
        (r.top - pan.dy) / scale,
        r.width / scale,
        r.height / scale,
      );

  /// Applies a new scale while keeping [screenFocalPoint] pinned to the
  /// same canvas point it was over before the zoom (standard "zoom under
  /// the cursor/fingers" behavior).
  void zoomTo(double newScale, Offset screenFocalPoint) {
    final clamped = newScale.clamp(minScale, maxScale);
    final canvasPoint = screenToCanvas(screenFocalPoint);
    scale = clamped;
    pan = screenFocalPoint - canvasPoint * scale;
  }

  /// Moves [oldScreenFocal] to [newScreenFocal] while simultaneously
  /// scaling by [scaleFactor] around the same anchor. Used for combined
  /// one-finger-pan / two-finger-pinch handling: pass scaleFactor = 1 for
  /// pure panning.
  void applyIncrementalGesture({
    required Offset oldScreenFocal,
    required Offset newScreenFocal,
    required double scaleFactor,
  }) {
    final canvasUnderOldFocal = screenToCanvas(oldScreenFocal);
    final newScale = (scale * scaleFactor).clamp(minScale, maxScale);
    scale = newScale;
    pan = newScreenFocal - canvasUnderOldFocal * newScale;
  }

  CanvasViewport copy() => CanvasViewport(pan: pan, scale: scale);
}
