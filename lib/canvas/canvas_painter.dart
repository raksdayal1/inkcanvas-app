import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/canvas_element.dart';
import '../models/page.dart';
import 'canvas_tools.dart';
import 'canvas_viewport.dart';
import 'page_edit_controller.dart';

/// Paints the page background plus every *committed* ink stroke and
/// shape (page.elements) - the "expensive, but rarely-changing" layer.
/// [InfiniteCanvas] wraps this one in a RepaintBoundary and gives it no
/// `repaint:` Listenable of its own, relying purely on [shouldRepaint]
/// comparing page.lastModified/pan/scale/smoothingEnabled below - see
/// there for why. A live gesture (drawing a new stroke, dragging a
/// selection) fires PageEditController.notifyListeners() on every
/// single pointer-move sample; before this was split out, that meant
/// the whole page - background, plus EVERY existing stroke's every
/// point re-transformed and its path rebuilt from scratch - got fully
/// repainted on each one of those samples. Fine on an empty page, but
/// on a page with a lot of ink already on it, that turned into a
/// growing, often-noticeable delay between the pen tip moving and the
/// new ink actually appearing - worse on a phone/tablet than the
/// (generally faster) machine this was originally written on, which
/// is presumably why it wasn't obvious until testing on real Android
/// hardware with a busy page. See [DraftOverlayPainter] below for the
/// small, cheap, still-every-frame layer this was split from: this one
/// now only actually repaints once a gesture is *committed*
/// (PageEditController._commit(), which bumps page.lastModified), not
/// on every intermediate point of one still in progress.
class StaticContentPainter extends CustomPainter {
  StaticContentPainter({
    required this.viewport,
    required this.page,
    required this.smoothingEnabled,
  })  : _pan = viewport.pan,
        _scale = viewport.scale,
        _lastModified = page.lastModified;

  final CanvasViewport viewport;
  final NotePage page;
  final bool smoothingEnabled;

  // Snapshotted at construction time purely so shouldRepaint below can
  // compare *values* across builds. CanvasViewport is one mutable
  // object reused for the whole canvas's lifetime (see
  // CanvasViewController.viewport), and NotePage is likewise the same
  // object every rebuild (mutated in place, never replaced - see
  // PageEditController.applyExternalUpdate) - comparing either of them,
  // or a field read live off of them, by reference or `==` would never
  // see a change at all, since oldDelegate.page and page (or
  // oldDelegate.viewport and viewport) are literally the same object,
  // so reading a field off of "the old one" and "the new one" reads
  // the SAME live value both times. That's exactly what silently broke
  // this the first time around: comparing oldDelegate.page.lastModified
  // to page.lastModified looked like a before/after check but was
  // actually comparing today's value to itself, so a freshly-committed
  // stroke never triggered a repaint here at all - only a pan/zoom
  // (which WAS captured into real snapshot fields below) made it appear,
  // by coincidence, since that legitimately differed across builds.
  final Offset _pan;
  final double _scale;
  final DateTime _lastModified;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size, viewport, page);
    // Viewport culling: skip elements that can't possibly be visible.
    // On a page with a lot of scattered ink, this paint() runs every
    // single frame during an active pan/zoom (see shouldRepaint below
    // and the class doc), so without this the per-frame cost scaled
    // with *total* page content instead of what's actually on screen -
    // the more you'd written, the worse every future pan/zoom/draw
    // frame got, regardless of where on the page you currently are.
    // Inflate by a margin so content just off-screen doesn't visibly
    // pop in/out at the edge as you pan.
    final visibleRect = viewport
        .screenRectToCanvas(Rect.fromLTWH(0, 0, size.width, size.height))
        .inflate(150);
    for (final el in page.elements) {
      switch (el) {
        case InkStrokeElement s:
          if (!s.bounds.overlaps(visibleRect)) continue;
          _paintStroke(canvas, s, viewport, smoothingEnabled);
        case ShapeElement s:
          if (!s.bounds.overlaps(visibleRect)) continue;
          _paintShape(canvas, s, viewport);
        case TextBoxElement _:
        case ImageElement _:
          break; // rendered as widgets, not painted
      }
    }
  }

  @override
  bool shouldRepaint(covariant StaticContentPainter oldDelegate) {
    return !identical(oldDelegate.page, page) ||
        oldDelegate._lastModified != _lastModified ||
        oldDelegate._pan != _pan ||
        oldDelegate._scale != _scale ||
        oldDelegate.smoothingEnabled != smoothingEnabled;
  }
}

/// Paints everything that changes on every single frame of a live
/// gesture: the in-progress draft stroke/shape/lasso, and the
/// selection highlight/resize/rotate overlays while one of those is
/// being dragged. Deliberately kept as its own layer, outside the
/// RepaintBoundary [InfiniteCanvas] puts around [StaticContentPainter]
/// (see its doc comment for the full story) - repainting every frame
/// is fine here because this only ever draws the handful of things
/// actually moving right now, never the rest of the page, so its cost
/// doesn't grow with how much ink/shapes/etc. the page already has.
class DraftOverlayPainter extends CustomPainter {
  DraftOverlayPainter({
    required this.viewport,
    required this.page,
    required this.editController,
    required this.smoothingEnabled,
    required this.draftStrokeCache,
  }) : super(repaint: editController);

  final CanvasViewport viewport;
  final NotePage page;
  final PageEditController editController;
  final bool smoothingEnabled;

  /// Owned by InfiniteCanvas's State (persists across the many
  /// DraftOverlayPainter instances built while a stroke is in
  /// progress - see its own doc comment for why this matters and
  /// _InfiniteCanvasState._draftStrokeCache for how it's wired in).
  final DraftStrokeCache draftStrokeCache;

  @override
  void paint(Canvas canvas, Size size) {
    final draft = editController.draftStroke;
    if (draft != null && draft.points.length >= 2) {
      draftStrokeCache.paint(canvas, _strokePaint(draft, viewport), draft, viewport, smoothingEnabled);
    }

    final draftRect = editController.draftShapeRect;
    if (draftRect != null) {
      _paintShape(
        canvas,
        ShapeElement(
          id: 'draft',
          createdAt: DateTime.now(),
          rect: draftRect,
          kind: editController.activeShapeKind,
          color: editController.activeColor,
          strokeWidth: editController.activeStrokeWidth,
          filled: false,
        ),
        viewport,
      );
    }

    final lasso = editController.draftLasso;
    if (lasso != null && lasso.length > 1) {
      final path = Path()..moveTo(viewport.canvasToScreen(lasso.first).dx, viewport.canvasToScreen(lasso.first).dy);
      for (final p in lasso.skip(1)) {
        final sp = viewport.canvasToScreen(p);
        path.lineTo(sp.dx, sp.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.blue.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // Selection highlight rectangles - dashed, OneNote-style, rather than
    // a solid line, so a selection outline never reads as "this is just
    // part of the drawing".
    final selectedIds = editController.selectedElementIds;
    for (final id in selectedIds) {
      final el = page.elements.where((e) => e.id == id).firstOrNull;
      if (el == null) continue;
      final screenRect = viewport.canvasRectToScreen(el.bounds);
      _drawDashedRect(
        canvas,
        screenRect,
        Paint()
          ..color = Colors.blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      // Resize handles - only when this is the single selected element
      // and it's a kind that supports resizing (images and text boxes;
      // see PageEditController.startResizeSelection). Images get all 8
      // (4 corners + 4 mid-edge) since both dimensions can be resized;
      // text boxes only get the 6 that affect width - their height
      // always auto-fits their text (see InfiniteCanvas), so top/bottom
      // handles would have nothing to do.
      if (selectedIds.length == 1 && (el is ImageElement || el is TextBoxElement)) {
        _paintResizeHandles(canvas, screenRect, includeTopBottom: el is ImageElement);
      }
    }

    // Rotate handle - a lasso-selected group of ink strokes (or a
    // single stroke) gets one outline around the whole selection, plus
    // a handle floating above it to drag-rotate the group, instead of
    // (or on top of) the per-element boxes just drawn above. See
    // PageEditController.canRotateSelection for exactly which
    // selections qualify, and InfiniteCanvas._hitTestRotateHandle for
    // the matching hit test this has to stay in visual sync with.
    if (editController.canRotateSelection) {
      final bounds = editController.selectionBounds;
      if (bounds != null) {
        final screenRect = viewport.canvasRectToScreen(bounds);
        if (selectedIds.length > 1) {
          _drawDashedRect(
            canvas,
            screenRect,
            Paint()
              ..color = Colors.blue
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        }
        final handleCenter = screenRect.topCenter - const Offset(0, kRotateHandleOffset);
        canvas.drawLine(
          screenRect.topCenter,
          handleCenter,
          Paint()
            ..color = Colors.blue
            ..strokeWidth = 1.5,
        );
        const handleRadius = 9.0;
        canvas.drawCircle(handleCenter, handleRadius, Paint()..color = Colors.blue);
        canvas.drawCircle(
          handleCenter,
          handleRadius,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        // A tiny curved-arrow glyph inside the handle so it reads as
        // "rotate" rather than just another resize/move dot.
        final arrowRect = Rect.fromCircle(center: handleCenter, radius: handleRadius - 2.5);
        canvas.drawArc(arrowRect, -math.pi * 0.65, math.pi * 1.1, false, Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4);
      }
    }
  }

  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint, {double dashLength = 5, double gapLength = 4}) {
    final corners = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft, rect.topLeft];
    for (var i = 0; i < 4; i++) {
      _drawDashedLine(canvas, corners[i], corners[i + 1], paint, dashLength, gapLength);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint, double dashLength, double gapLength) {
    final totalLength = (end - start).distance;
    if (totalLength == 0) return;
    final direction = (end - start) / totalLength;
    var drawn = 0.0;
    while (drawn < totalLength) {
      final segmentEnd = math.min(drawn + dashLength, totalLength);
      canvas.drawLine(start + direction * drawn, start + direction * segmentEnd, paint);
      drawn += dashLength + gapLength;
    }
  }

  void _paintResizeHandles(Canvas canvas, Rect screenRect, {required bool includeTopBottom}) {
    const handleSize = 10.0;
    final fillPaint = Paint()..color = Colors.blue;
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final point in [
      screenRect.topLeft,
      screenRect.topRight,
      screenRect.bottomLeft,
      screenRect.bottomRight,
      screenRect.centerLeft,
      screenRect.centerRight,
      if (includeTopBottom) screenRect.topCenter,
      if (includeTopBottom) screenRect.bottomCenter,
    ]) {
      final handleRect = Rect.fromCenter(center: point, width: handleSize, height: handleSize);
      canvas.drawRect(handleRect, fillPaint);
      canvas.drawRect(handleRect, borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant DraftOverlayPainter oldDelegate) => true;
}

// --- Shared paint helpers --------------------------------------------
//
// Free functions rather than methods on either painter above, since
// both StaticContentPainter (committed strokes/shapes) and
// DraftOverlayPainter (the draft stroke/shape currently being drawn)
// need to draw a stroke/shape the exact same way.

void _paintBackground(Canvas canvas, Size size, CanvasViewport viewport, NotePage page) {
  canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
  if (page.background == PageBackground.plain) return;

  final gridColor = Colors.blueGrey.withValues(alpha: 0.18);
  const baseSpacing = 28.0; // canvas-space spacing between lines
  final spacing = baseSpacing * viewport.scale;
  if (spacing < 4) return; // too dense to bother drawing when zoomed out

  // Anchor the grid to canvas-space (0,0) so it stays put under content
  // as you pan, rather than sliding relative to the page.
  final originScreen = viewport.canvasToScreen(Offset.zero);
  final startX = originScreen.dx % spacing;
  final startY = originScreen.dy % spacing;

  final linePaint = Paint()
    ..color = gridColor
    ..strokeWidth = 1;

  if (page.background == PageBackground.grid) {
    for (double x = startX; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }
  }
  for (double y = startY; y < size.height; y += spacing) {
    canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
  }
}

/// The Paint a stroke [s] draws with at the current [viewport] zoom -
/// shared by the one-shot path builder below and [DraftStrokeCache],
/// so both draw identically.
Paint _strokePaint(InkStrokeElement s, CanvasViewport viewport) {
  final paint = Paint()
    ..color = s.color
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = s.strokeWidth * viewport.scale;
  if (s.kind == StrokeKind.highlighter) {
    paint.blendMode = BlendMode.multiply;
  }
  return paint;
}

void _paintStroke(Canvas canvas, InkStrokeElement s, CanvasViewport viewport, bool smoothingEnabled) {
  if (s.points.length < 2) return;
  final screenPoints = [for (final p in s.points) viewport.canvasToScreen(p)];
  canvas.drawPath(_buildStrokePath(screenPoints, smoothingEnabled), _strokePaint(s, viewport));
}

/// Builds the path connecting [screenPoints] (already viewport-
/// transformed) - either straight segments (smoothing off, or too few
/// points for a meaningful curve), or a Catmull-Rom spline through
/// them, turned into cubic Bezier segments one gap at a time. Fitting
/// a curve *through* every sampled point (rather than approximating
/// them) is what makes this "smoothing out hand tremor" instead of
/// "redrawing what you wrote" - nothing about the actual stroke path
/// you drew is lost, the jaggedness between samples is just replaced
/// with a curve instead of straight jumps.
///
/// Used for one-shot builds (committed strokes, painted rarely by
/// StaticContentPainter). The in-progress draft stroke uses
/// [DraftStrokeCache] instead, which reuses the same per-segment math
/// ([_appendSmoothedSegment]) but incrementally, since this full
/// rebuild-from-scratch is too expensive to run on every single
/// pointer-move sample of a long stroke - see DraftStrokeCache's doc
/// comment.
Path _buildStrokePath(List<Offset> screenPoints, bool smoothingEnabled) {
  final path = Path()..moveTo(screenPoints.first.dx, screenPoints.first.dy);
  if (!smoothingEnabled || screenPoints.length < 3) {
    for (final p in screenPoints.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }
  for (var i = 0; i < screenPoints.length - 1; i++) {
    _appendSmoothedSegment(path, screenPoints, i);
  }
  return path;
}

/// Appends the single Catmull-Rom-derived cubic segment connecting
/// screenPoints[i] to screenPoints[i + 1] onto [path], which must
/// already be positioned at screenPoints[i] (via a prior moveTo/
/// cubicTo/lineTo ending there). Pulled out of [_buildStrokePath] so
/// [DraftStrokeCache] can bake the exact same per-segment math in
/// incrementally instead of only ever as part of a full rebuild.
void _appendSmoothedSegment(Path path, List<Offset> screenPoints, int i) {
  final p0 = i == 0 ? screenPoints[i] : screenPoints[i - 1];
  final p1 = screenPoints[i];
  final p2 = screenPoints[i + 1];
  final p3 = (i + 2 < screenPoints.length) ? screenPoints[i + 2] : p2;
  final control1 = p1 + (p2 - p0) / 6;
  final control2 = p2 - (p3 - p1) / 6;
  path.cubicTo(control1.dx, control1.dy, control2.dx, control2.dy, p2.dx, p2.dy);
}

/// Incremental cache for the ink stroke currently being drawn, so each
/// pointer-move frame only does O(1) amortized work instead of
/// re-transforming and re-smoothing every point of the stroke so far.
///
/// Before this existed, DraftOverlayPainter just called the same
/// one-shot [_buildStrokePath] used for committed strokes - fine for
/// those (painted rarely, only on commit), but the draft stroke is
/// repainted on every single pointer-move sample while it's being
/// drawn. Rebuilding its *entire* path from scratch each time meant
/// the cost of drawing frame N was proportional to N (transforming and
/// re-smoothing all N points collected so far, not just the newest
/// one) - so a single continuous stroke got progressively slower and
/// laggier the longer it went on, most noticeable as more and more
/// points piled up partway through writing a line or word (e.g. the
/// pen visibly falling behind "further to the right" partway through
/// a long stroke, or curves getting coarser/more angular under that
/// accumulating lag).
///
/// The fix relies on Catmull-Rom's segments each only ever depending
/// on one point *ahead* of themselves: segment i (connecting point i
/// to i+1) uses p3 = point[i+2] if that point exists yet, or a
/// duplicate of point[i+1] as a stand-in if it doesn't. Every segment
/// except the very last one already has a real point[i+2] and so is
/// permanent - it will *never* be redrawn differently no matter how
/// many more points arrive later. Only the single most-recent segment
/// is ever still tentative. So each new point only ever requires
/// baking in ONE newly-final segment (into [_bakedPath], extended in
/// place and never revisited) plus redrawing that one tentative tail
/// segment (into a fresh, tiny, single-segment path each frame) -
/// O(1) amortized work per frame, however long the stroke gets.
///
/// One instance is meant to live for a whole InfiniteCanvas widget,
/// not just one stroke - see [paint]'s `sameContext` check, which
/// detects a new stroke (a different [InkStrokeElement.id]) and resets
/// itself automatically, so nothing needs to explicitly recreate it
/// per-stroke. It also resets itself if the smoothing setting or the
/// viewport's pan/scale change out from under it mid-stroke (pan/zoom
/// while actively drawing is a rare edge case; paying the full rebuild
/// cost once for that is fine).
class DraftStrokeCache {
  String? _strokeId;
  bool? _smoothingEnabled;
  Offset? _pan;
  double? _scale;

  final List<Offset> _screenPoints = [];
  final Path _bakedPath = Path();
  bool _pathStarted = false;
  bool? _bakedAsSmoothed;
  int _bakedSegments = 0; // segments [0, _bakedSegments) are permanently in _bakedPath

  void _reset(String strokeId, bool smoothingEnabled, Offset pan, double scale) {
    _strokeId = strokeId;
    _smoothingEnabled = smoothingEnabled;
    _pan = pan;
    _scale = scale;
    _screenPoints.clear();
    _bakedPath.reset();
    _pathStarted = false;
    _bakedAsSmoothed = null;
    _bakedSegments = 0;
  }

  /// Updates the cache for [s]'s current points (transforming only
  /// whatever points are new since the last call) and draws the
  /// result onto [canvas] with [paint]. Call once per frame from
  /// [DraftOverlayPainter.paint] - the caller is responsible for the
  /// `s.points.length < 2` early-out (nothing to draw yet).
  void paint(Canvas canvas, Paint paint, InkStrokeElement s, CanvasViewport viewport, bool smoothingEnabled) {
    final sameContext = s.id == _strokeId &&
        smoothingEnabled == _smoothingEnabled &&
        viewport.pan == _pan &&
        viewport.scale == _scale;
    if (!sameContext) {
      _reset(s.id, smoothingEnabled, viewport.pan, viewport.scale);
    }

    for (var i = _screenPoints.length; i < s.points.length; i++) {
      _screenPoints.add(viewport.canvasToScreen(s.points[i]));
    }
    final total = _screenPoints.length;
    if (total == 0) return;

    // Whether there are enough points yet for smoothing to even apply
    // (matches _buildStrokePath's `screenPoints.length < 3` check) can
    // flip from false to true exactly once per stroke, right as the
    // 3rd point arrives - at which point whatever's already baked as
    // a straight segment needs to be redone as a smoothed one, since a
    // one-shot rebuild at that point would smooth it too. That's rare
    // and only ever happens once, so just eating a full re-bake here
    // is fine.
    final useSmoothed = smoothingEnabled && total >= 3;
    if (_bakedAsSmoothed != null && _bakedAsSmoothed != useSmoothed) {
      _bakedPath.reset();
      _pathStarted = false;
      _bakedSegments = 0;
    }
    _bakedAsSmoothed = useSmoothed;

    if (!_pathStarted) {
      _bakedPath.moveTo(_screenPoints[0].dx, _screenPoints[0].dy);
      _pathStarted = true;
    }
    if (total < 2) {
      canvas.drawPath(_bakedPath, paint);
      return;
    }

    if (!useSmoothed) {
      // Straight segments never need revisiting once drawn - bake
      // every new one in permanently.
      while (_bakedSegments < total - 1) {
        final p = _screenPoints[_bakedSegments + 1];
        _bakedPath.lineTo(p.dx, p.dy);
        _bakedSegments++;
      }
      canvas.drawPath(_bakedPath, paint);
      return;
    }

    // Bake every segment except the last one - see the class doc
    // comment for why the last segment is the only one still
    // tentative - then draw that one tentative segment fresh into its
    // own tiny path each frame.
    while (_bakedSegments < total - 2) {
      _appendSmoothedSegment(_bakedPath, _screenPoints, _bakedSegments);
      _bakedSegments++;
    }
    final tail = Path()..moveTo(_screenPoints[_bakedSegments].dx, _screenPoints[_bakedSegments].dy);
    _appendSmoothedSegment(tail, _screenPoints, _bakedSegments);

    canvas.drawPath(_bakedPath, paint);
    canvas.drawPath(tail, paint);
  }
}

void _paintShape(Canvas canvas, ShapeElement s, CanvasViewport viewport) {
  final rect = viewport.canvasRectToScreen(s.rect);
  final paint = Paint()
    ..color = s.color
    ..style = s.filled ? PaintingStyle.fill : PaintingStyle.stroke
    ..strokeWidth = s.strokeWidth * viewport.scale;
  switch (s.kind) {
    case ShapeKind.rectangle:
      canvas.drawRect(rect, paint);
    case ShapeKind.ellipse:
      canvas.drawOval(rect, paint);
    case ShapeKind.line:
      canvas.drawLine(rect.topLeft, rect.bottomRight, paint);
    case ShapeKind.arrow:
      _paintArrow(canvas, rect.topLeft, rect.bottomRight, paint);
  }
}

void _paintArrow(Canvas canvas, Offset from, Offset to, Paint paint) {
  canvas.drawLine(from, to, paint);
  final direction = (to - from);
  if (direction.distance < 1) return;
  final angle = direction.direction;
  const arrowLength = 14.0;
  const arrowAngle = 0.5; // radians
  final p1 = to -
      Offset(arrowLength * math.cos(angle - arrowAngle), arrowLength * math.sin(angle - arrowAngle));
  final p2 = to -
      Offset(arrowLength * math.cos(angle + arrowAngle), arrowLength * math.sin(angle + arrowAngle));
  canvas.drawLine(to, p1, paint);
  canvas.drawLine(to, p2, paint);
}

extension _FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
