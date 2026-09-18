import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/canvas_element.dart';
import '../models/page.dart';
import 'canvas_viewport.dart';
import 'page_edit_controller.dart';

/// Paints the page background (plain/lined/grid), all ink strokes and
/// shapes, the in-progress draft stroke/shape/lasso, and selection
/// highlights. Text boxes and images are real widgets layered on top by
/// [InfiniteCanvas] instead of being painted here, so they can host a
/// live [TextField] / [Image] and their own gesture detectors.
class NoteCanvasPainter extends CustomPainter {
  NoteCanvasPainter({
    required this.viewport,
    required this.page,
    required this.editController,
  }) : super(repaint: editController);

  final CanvasViewport viewport;
  final NotePage page;
  final PageEditController editController;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size);

    for (final el in page.elements) {
      switch (el) {
        case InkStrokeElement s:
          _paintStroke(canvas, s);
        case ShapeElement s:
          _paintShape(canvas, s);
        case TextBoxElement _:
        case ImageElement _:
          break; // rendered as widgets, not painted
      }
    }

    final draft = editController.draftStroke;
    if (draft != null) _paintStroke(canvas, draft);

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

  void _paintBackground(Canvas canvas, Size size) {
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

  void _paintStroke(Canvas canvas, InkStrokeElement s) {
    if (s.points.length < 2) return;
    final paint = Paint()
      ..color = s.color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = s.strokeWidth * viewport.scale;
    if (s.kind == StrokeKind.highlighter) {
      paint.blendMode = BlendMode.multiply;
    }
    final path = Path();
    final first = viewport.canvasToScreen(s.points.first);
    path.moveTo(first.dx, first.dy);
    for (final p in s.points.skip(1)) {
      final sp = viewport.canvasToScreen(p);
      path.lineTo(sp.dx, sp.dy);
    }
    canvas.drawPath(path, paint);
  }

  void _paintShape(Canvas canvas, ShapeElement s) {
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

  @override
  bool shouldRepaint(covariant NoteCanvasPainter oldDelegate) => true;
}

extension _FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
