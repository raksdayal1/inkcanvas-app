import 'package:flutter/material.dart';

/// The pan/zoom state of an [InfiniteCanvas]: maps between screen-space
/// pixels (what the user sees/touches) and canvas-space coordinates (what
/// elements are stored in). This is what makes the canvas "infinite" — pan
/// and scale are just two numbers with no inherent bounds, so there's no
/// fixed-size widget backing the canvas at all.
///
/// The one exception: the page has a hard top-left origin, same as a
/// OneNote page. [pan] is clamped (see [_clampPan]) so panning can never
/// scroll the viewport above or to the left of canvas point (0, 0) - only
/// right and down from there, where the page title lives and content is
/// meant to grow.
///
/// Relationship: screen = canvas * scale + pan.
class CanvasViewport {
  CanvasViewport({Offset pan = Offset.zero, this.scale = 1.0}) : _pan = pan;

  Offset _pan;
  Offset get pan => _pan;
  set pan(Offset value) => _pan = _clampPan(value, scale);

  double scale;

  static const double minScale = 0.05;
  static const double maxScale = 12.0;

  /// How much blank canvas-space margin is allowed to show above/left of
  /// the page's (0, 0) origin - a small breathing margin around the
  /// title, not truly zero.
  static const double originMargin = 80.0;

  /// The current viewport's on-screen size, kept up to date by
  /// [CanvasViewController.reportSize]. Panning isn't clamped at all
  /// until this is known (still [Size.zero] before the very first
  /// layout), since clamping needs a scale to work in but nothing else
  /// here actually depends on the size itself.
  Size viewportSize = Size.zero;

  /// Caps [proposed] so that the canvas point currently sitting at the
  /// screen's top-left corner - i.e. screenToCanvas(Offset.zero) as it
  /// would be under this pan - never goes below -[originMargin] on
  /// either axis. Solving (0 - pan.dx) / atScale >= -originMargin for
  /// pan.dx gives pan.dx <= originMargin * atScale, and likewise for dy.
  Offset _clampPan(Offset proposed, double atScale) {
    if (viewportSize == Size.zero) return proposed;
    final maxDx = originMargin * atScale;
    final maxDy = originMargin * atScale;
    return Offset(
      proposed.dx > maxDx ? maxDx : proposed.dx,
      proposed.dy > maxDy ? maxDy : proposed.dy,
    );
  }

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

  CanvasViewport copy() => CanvasViewport(pan: pan, scale: scale)..viewportSize = viewportSize;
}
