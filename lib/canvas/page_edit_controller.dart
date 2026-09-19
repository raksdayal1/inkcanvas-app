import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/canvas_element.dart';
import '../models/page.dart';
import 'canvas_tools.dart';

const _uuid = Uuid();

/// Owns one page's content (elements) and the current tool/selection state
/// for editing it. Repaint-relevant state changes call [notifyListeners]
/// immediately (cheap, in-memory); [onContentChanged] fires only when a
/// gesture actually completes, so the caller can persist to disk without
/// writing on every single pointer-move event.
class PageEditController extends ChangeNotifier {
  PageEditController(this.page, {this.onContentChanged});

  final NotePage page;
  final VoidCallback? onContentChanged;

  /// True when this page's notebook can't be edited from this device
  /// right now (owned by the other device, and not currently connected
  /// to it). Set by the screen that hosts this controller; every
  /// gesture entry point below checks it so a stray touch can't sneak
  /// in an edit while a notebook is meant to be read-only.
  bool _readOnly = false;
  bool get readOnly => _readOnly;
  set readOnly(bool value) {
    if (_readOnly == value) return;
    _readOnly = value;
    notifyListeners();
  }

  CanvasTool tool = CanvasTool.pen;
  ShapeKind activeShapeKind = ShapeKind.rectangle;
  Color activeColor = Colors.black;
  double activeStrokeWidth = 3.0;
  double activeFontSize = 18.0;
  String? activeFontFamily = kDefaultTextFont; // see kTextFontChoices
  static const double eraserRadius = 12.0;

  final Set<String> selectedElementIds = {};

  // --- Draft state (in-progress gesture, not yet committed) --------------
  InkStrokeElement? draftStroke;
  Rect? draftShapeRect;
  List<Offset>? draftLasso;
  Set<String> _eraseGestureRemovedIds = {};
  List<CanvasElement> _eraseGestureRemovedElements = [];

  final List<_UndoableAction> _undoStack = [];
  final List<_UndoableAction> _redoStack = [];
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void setTool(CanvasTool t) {
    tool = t;
    if (t != CanvasTool.select) selectedElementIds.clear();
    notifyListeners();
  }

  void setActiveShapeKind(ShapeKind k) {
    activeShapeKind = k;
    notifyListeners();
  }

  void setColor(Color c) {
    activeColor = c;
    notifyListeners();
  }

  void setStrokeWidth(double w) {
    activeStrokeWidth = w;
    notifyListeners();
  }

  /// Sets the font size used for *new* text boxes, and - if a text box is
  /// currently selected - restyles it too, so picking a size while
  /// editing existing text changes that text immediately rather than
  /// only affecting whatever gets typed next.
  void setFontSize(double size) {
    activeFontSize = size;
    _applyToSelectedTextBoxes((t) => t.fontSize = size);
  }

  /// Same idea as [setFontSize], for the font family.
  void setFontFamily(String? family) {
    activeFontFamily = family;
    _applyToSelectedTextBoxes((t) => t.fontFamily = family);
  }

  void _applyToSelectedTextBoxes(void Function(TextBoxElement) apply) {
    var changed = false;
    for (final el in page.elements) {
      if (el is TextBoxElement && selectedElementIds.contains(el.id)) {
        apply(el);
        changed = true;
      }
    }
    if (changed) {
      _commit();
    } else {
      notifyListeners();
    }
  }

  // --- Ink -----------------------------------------------------------

  void startStroke(Offset canvasPoint, double pressure) {
    if (_readOnly) return;
    draftStroke = InkStrokeElement(
      id: _uuid.v4(),
      createdAt: DateTime.now(),
      points: [canvasPoint],
      pressures: [pressure],
      color: tool == CanvasTool.highlighter ? activeColor.withValues(alpha: 0.35) : activeColor,
      strokeWidth: tool == CanvasTool.highlighter ? activeStrokeWidth * 4 : activeStrokeWidth,
      kind: tool == CanvasTool.highlighter ? StrokeKind.highlighter : StrokeKind.pen,
    );
    notifyListeners();
  }

  void appendStrokePoint(Offset canvasPoint, double pressure) {
    final s = draftStroke;
    if (s == null) return;
    s.points.add(canvasPoint);
    s.pressures.add(pressure);
    notifyListeners();
  }

  void endStroke() {
    final s = draftStroke;
    draftStroke = null;
    if (s == null || s.points.length < 2) {
      notifyListeners();
      return;
    }
    page.elements.add(s);
    _pushUndo(_AddElementsAction([s]));
    _commit();
  }

  // --- Eraser ----------------------------------------------------------

  void beginEraseGesture() {
    if (_readOnly) return;
    _eraseGestureRemovedIds = {};
    _eraseGestureRemovedElements = [];
  }

  void eraseAt(Offset canvasPoint) {
    if (_readOnly) return;
    bool removedAny = false;
    page.elements.removeWhere((el) {
      if (_eraseGestureRemovedIds.contains(el.id)) return false;
      final hit = _isNearElement(el, canvasPoint, eraserRadius);
      if (hit) {
        _eraseGestureRemovedIds.add(el.id);
        _eraseGestureRemovedElements.add(el);
        removedAny = true;
      }
      return hit;
    });
    if (removedAny) notifyListeners();
  }

  void endEraseGesture() {
    if (_eraseGestureRemovedElements.isNotEmpty) {
      _pushUndo(_RemoveElementsAction(List.of(_eraseGestureRemovedElements)));
      _commit();
    }
    _eraseGestureRemovedIds = {};
    _eraseGestureRemovedElements = [];
  }

  bool _isNearElement(CanvasElement el, Offset point, double radius) {
    switch (el) {
      case InkStrokeElement s:
        for (final p in s.points) {
          if ((p - point).distance <= radius + s.strokeWidth / 2) return true;
        }
        return false;
      default:
        return el.bounds.inflate(radius).contains(point);
    }
  }

  // --- Shapes ----------------------------------------------------------

  void startShape(Offset canvasPoint) {
    if (_readOnly) return;
    draftShapeRect = Rect.fromPoints(canvasPoint, canvasPoint);
    notifyListeners();
  }

  void updateShape(Offset startPoint, Offset currentPoint) {
    draftShapeRect = Rect.fromPoints(startPoint, currentPoint);
    notifyListeners();
  }

  void endShape() {
    final rect = draftShapeRect;
    draftShapeRect = null;
    if (rect == null || rect.width.abs() < 2 || rect.height.abs() < 2) {
      notifyListeners();
      return;
    }
    final shape = ShapeElement(
      id: _uuid.v4(),
      createdAt: DateTime.now(),
      rect: rect,
      kind: activeShapeKind,
      color: activeColor,
      strokeWidth: activeStrokeWidth,
      filled: false,
    );
    page.elements.add(shape);
    _pushUndo(_AddElementsAction([shape]));
    _commit();
  }

  // --- Lasso select ------------------------------------------------------

  void startLasso(Offset canvasPoint) {
    draftLasso = [canvasPoint];
    notifyListeners();
  }

  void updateLasso(Offset canvasPoint) {
    draftLasso?.add(canvasPoint);
    notifyListeners();
  }

  void endLasso() {
    final polygon = draftLasso;
    draftLasso = null;
    if (polygon == null || polygon.length < 3) {
      notifyListeners();
      return;
    }
    selectedElementIds.clear();
    for (final el in page.elements) {
      final testPoint = switch (el) {
        InkStrokeElement s => s.points.isNotEmpty ? s.points[s.points.length ~/ 2] : el.bounds.center,
        _ => el.bounds.center,
      };
      if (_pointInPolygon(testPoint, polygon)) {
        selectedElementIds.add(el.id);
      }
    }
    notifyListeners();
  }

  bool _pointInPolygon(Offset point, List<Offset> polygon) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final pi = polygon[i];
      final pj = polygon[j];
      final intersects = ((pi.dy > point.dy) != (pj.dy > point.dy)) &&
          (point.dx < (pj.dx - pi.dx) * (point.dy - pi.dy) / (pj.dy - pi.dy) + pi.dx);
      if (intersects) inside = !inside;
    }
    return inside;
  }

  // --- Tap-to-select (select tool, single finger/mouse) ------------------

  String? hitTestTopmost(Offset canvasPoint) {
    for (final el in page.elements.reversed) {
      if (_isNearElement(el, canvasPoint, 6.0)) return el.id;
    }
    return null;
  }

  void selectOnly(String? elementId) {
    selectedElementIds.clear();
    if (elementId != null) selectedElementIds.add(elementId);
    notifyListeners();
  }

  Offset? _moveGestureStart;
  Offset _moveGestureTotalDelta = Offset.zero;

  String? _resizeElementId;
  ResizeHandle? _resizeHandle;
  Rect? _resizeStartRect;

  void startMoveSelection(Offset canvasPoint) {
    if (_readOnly) return;
    _moveGestureStart = canvasPoint;
    _moveGestureTotalDelta = Offset.zero;
  }

  void updateMoveSelection(Offset canvasPoint) {
    final start = _moveGestureStart;
    if (start == null || selectedElementIds.isEmpty) return;
    final delta = canvasPoint - start;
    _moveGestureStart = canvasPoint;
    _moveGestureTotalDelta += delta;
    _applyDelta(selectedElementIds, delta);
    notifyListeners();
  }

  void endMoveSelection() {
    _moveGestureStart = null;
    if (_moveGestureTotalDelta != Offset.zero && selectedElementIds.isNotEmpty) {
      _pushUndo(_MoveElementsAction(Set.of(selectedElementIds), _moveGestureTotalDelta));
      _commit();
    }
    _moveGestureTotalDelta = Offset.zero;
  }

  void _applyDelta(Set<String> ids, Offset delta) {
    for (final el in page.elements) {
      if (!ids.contains(el.id)) continue;
      switch (el) {
        case InkStrokeElement s:
          for (var i = 0; i < s.points.length; i++) {
            s.points[i] = s.points[i] + delta;
          }
        case TextBoxElement t:
          t.rect = t.rect.shift(delta);
        case ImageElement img:
          img.rect = img.rect.shift(delta);
        case ShapeElement sh:
          sh.rect = sh.rect.shift(delta);
      }
    }
  }

  // --- Resize (drag a selected image/text box's corner handle) ----------

  /// Only a single selected, resizable element can be resized at a time.
  /// Images and text boxes are the resizable element kinds (see
  /// [ResizeHandle] callers in the canvas widget, which only offer
  /// handles when exactly one [ImageElement] or [TextBoxElement] is
  /// selected).
  void startResizeSelection(ResizeHandle handle, Offset canvasPoint) {
    if (_readOnly) return;
    if (selectedElementIds.length != 1) return;
    final id = selectedElementIds.first;
    final el = _findElement(id);
    if (el == null) return;
    _resizeElementId = id;
    _resizeHandle = handle;
    _resizeStartRect = el.bounds;
  }

  void updateResizeSelection(Offset canvasPoint) {
    final id = _resizeElementId;
    final handle = _resizeHandle;
    final startRect = _resizeStartRect;
    if (id == null || handle == null || startRect == null) return;
    final el = _findElement(id);
    if (el == null) return;
    // A mid-edge handle (top/bottom/left/right) only ever touches one
    // axis in the first place, so keeping it locked to the image's
    // aspect ratio left it unable to do anything a corner handle
    // couldn't already do - the other axis just silently followed
    // along. Matching the usual PowerPoint/OneNote convention: corner
    // handles still resize proportionally, but grabbing an edge handle
    // now freely stretches that one dimension, same as it already does
    // for text boxes and shapes.
    final isEdgeHandle = switch (handle) {
      ResizeHandle.top || ResizeHandle.bottom || ResizeHandle.left || ResizeHandle.right => true,
      ResizeHandle.topLeft || ResizeHandle.topRight || ResizeHandle.bottomLeft || ResizeHandle.bottomRight => false,
    };
    final newRect = (el is ImageElement && el.aspectRatio != null && !isEdgeHandle)
        ? _rectForHandleDragKeepingAspectRatio(startRect, handle, canvasPoint, el.aspectRatio!)
        : (el is TextBoxElement)
            ? _rectForHandleDragWidthOnly(startRect, handle, canvasPoint)
            : _rectForHandleDrag(startRect, handle, canvasPoint);
    _setElementRect(el, newRect);
    notifyListeners();
  }

  void endResizeSelection() {
    final id = _resizeElementId;
    final startRect = _resizeStartRect;
    _resizeElementId = null;
    _resizeHandle = null;
    _resizeStartRect = null;
    if (id == null || startRect == null) return;
    final el = _findElement(id);
    if (el == null) return;
    final endRect = el.bounds;
    if (endRect != startRect) {
      _pushUndo(_ResizeElementAction(id, startRect, endRect));
      _commit();
    }
  }

  CanvasElement? _findElement(String id) => page.elements.where((e) => e.id == id).firstOrNull;

  /// A minimum size so a fast/overshot drag can't collapse the element to
  /// nothing (or flip it inside-out) before the user notices.
  static const double _minResizeSize = 24.0;

  Rect _rectForHandleDrag(Rect start, ResizeHandle handle, Offset canvasPoint) {
    double left = start.left, top = start.top, right = start.right, bottom = start.bottom;
    switch (handle) {
      case ResizeHandle.topLeft:
        left = canvasPoint.dx;
        top = canvasPoint.dy;
      case ResizeHandle.topRight:
        right = canvasPoint.dx;
        top = canvasPoint.dy;
      case ResizeHandle.bottomLeft:
        left = canvasPoint.dx;
        bottom = canvasPoint.dy;
      case ResizeHandle.bottomRight:
        right = canvasPoint.dx;
        bottom = canvasPoint.dy;
      case ResizeHandle.left:
        left = canvasPoint.dx;
      case ResizeHandle.right:
        right = canvasPoint.dx;
      case ResizeHandle.top:
        top = canvasPoint.dy;
      case ResizeHandle.bottom:
        bottom = canvasPoint.dy;
    }
    if (right - left < _minResizeSize) {
      final movesLeftEdge = handle == ResizeHandle.topLeft || handle == ResizeHandle.bottomLeft || handle == ResizeHandle.left;
      if (movesLeftEdge) {
        left = right - _minResizeSize;
      } else {
        right = left + _minResizeSize;
      }
    }
    if (bottom - top < _minResizeSize) {
      final movesTopEdge = handle == ResizeHandle.topLeft || handle == ResizeHandle.topRight || handle == ResizeHandle.top;
      if (movesTopEdge) {
        top = bottom - _minResizeSize;
      } else {
        bottom = top + _minResizeSize;
      }
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// A text box's height auto-fits its text content (see InfiniteCanvas's
  /// auto-grow logic in _buildOverlayWidgets), so dragging one of its
  /// corner handles only changes its width - the corresponding left or
  /// right edge moves with the pointer, and top/height are left as they
  /// were; they get recalculated for the new width on the very next
  /// build.
  Rect _rectForHandleDragWidthOnly(Rect start, ResizeHandle handle, Offset canvasPoint) {
    final draggingRightEdge = handle == ResizeHandle.topRight || handle == ResizeHandle.bottomRight || handle == ResizeHandle.right;
    final draggingLeftEdge = handle == ResizeHandle.topLeft || handle == ResizeHandle.bottomLeft || handle == ResizeHandle.left;
    if (!draggingRightEdge && !draggingLeftEdge) return start; // top/bottom: not offered for text boxes anyway
    double left = start.left;
    double right = start.right;
    if (draggingRightEdge) {
      right = canvasPoint.dx;
    } else {
      left = canvasPoint.dx;
    }
    if (right - left < _minResizeSize) {
      if (draggingRightEdge) {
        right = left + _minResizeSize;
      } else {
        left = right - _minResizeSize;
      }
    }
    return Rect.fromLTRB(left, start.top, right, start.bottom);
  }

  /// Same idea as [_rectForHandleDrag], but keeps the dragged handle's
  /// opposite side(s) fixed and derives the box's size from
  /// [aspectRatio] instead of the raw pointer position, so a picture
  /// never ends up letterboxed inside its own box. For a corner handle,
  /// whichever axis (width or height) the drag moved further (relative
  /// to the box's starting size) drives the resize and the other axis
  /// is computed from the ratio; a mid-edge handle (left/right/top/
  /// bottom) always drives from its own axis instead, since that's the
  /// one edge the user actually grabbed.
  Rect _rectForHandleDragKeepingAspectRatio(
    Rect start,
    ResizeHandle handle,
    Offset canvasPoint,
    double aspectRatio,
  ) {
    final anchor = switch (handle) {
      ResizeHandle.topLeft => start.bottomRight,
      ResizeHandle.topRight => start.bottomLeft,
      ResizeHandle.bottomLeft => start.topRight,
      ResizeHandle.bottomRight => start.topLeft,
      ResizeHandle.left => Offset(start.right, start.top),
      ResizeHandle.right => Offset(start.left, start.top),
      ResizeHandle.top => Offset(start.left, start.bottom),
      ResizeHandle.bottom => Offset(start.left, start.top),
    };
    double w = (canvasPoint.dx - anchor.dx).abs();
    double h = (canvasPoint.dy - anchor.dy).abs();
    final bool widthMovedMore = switch (handle) {
      ResizeHandle.left || ResizeHandle.right => true,
      ResizeHandle.top || ResizeHandle.bottom => false,
      _ => (w - start.width).abs() >= (h - start.height).abs(),
    };
    if (widthMovedMore) {
      w = w < _minResizeSize ? _minResizeSize : w;
      h = w / aspectRatio;
    } else {
      h = h < _minResizeSize ? _minResizeSize : h;
      w = h * aspectRatio;
    }
    if (h < _minResizeSize) {
      h = _minResizeSize;
      w = h * aspectRatio;
    }
    if (w < _minResizeSize) {
      w = _minResizeSize;
      h = w / aspectRatio;
    }
    final dx = canvasPoint.dx >= anchor.dx ? 1.0 : -1.0;
    final dy = canvasPoint.dy >= anchor.dy ? 1.0 : -1.0;
    final draggedCorner = Offset(anchor.dx + dx * w, anchor.dy + dy * h);
    return Rect.fromPoints(anchor, draggedCorner);
  }

  void _setElementRect(CanvasElement el, Rect rect) {
    switch (el) {
      case ImageElement img:
        img.rect = rect;
      case ShapeElement sh:
        sh.rect = rect;
      case TextBoxElement t:
        t.rect = rect;
      case InkStrokeElement _:
        break; // ink strokes have no single rect to resize
    }
  }

  void deleteSelection() {
    if (_readOnly || selectedElementIds.isEmpty) return;
    final removed = page.elements.where((e) => selectedElementIds.contains(e.id)).toList();
    page.elements.removeWhere((e) => selectedElementIds.contains(e.id));
    selectedElementIds.clear();
    _pushUndo(_RemoveElementsAction(removed));
    _commit();
  }

  void clearSelection() {
    if (selectedElementIds.isEmpty) return;
    selectedElementIds.clear();
    notifyListeners();
  }

  // --- Text --------------------------------------------------------------

  TextBoxElement addTextBoxAt(Offset canvasPoint) {
    final box = TextBoxElement(
      id: _uuid.v4(),
      createdAt: DateTime.now(),
      rect: Rect.fromLTWH(canvasPoint.dx, canvasPoint.dy, 220, 60),
      text: '',
      color: activeColor,
      fontSize: activeFontSize,
      fontFamily: activeFontFamily,
    );
    page.elements.add(box);
    _pushUndo(_AddElementsAction([box]));
    _commit();
    notifyListeners();
    return box;
  }

  void commitTextEdit(String id, String newText) {
    if (_readOnly) return;
    final el = page.elements.whereType<TextBoxElement>().where((t) => t.id == id).firstOrNull;
    if (el == null || el.text == newText) return;
    final before = el.text;
    el.text = newText;
    _pushUndo(_EditTextAction(id, before, newText));
    _commit();
  }

  /// Cleans up a text box that ended up with nothing in it - placed, then
  /// the keyboard was dismissed without typing anything (or everything
  /// that was typed got deleted again). Left alone, that's just an
  /// invisible, forgotten box outline sitting on the page; this quietly
  /// removes it instead. Pushes a normal remove-undo entry, so if you
  /// really did type something and want it back, Undo still gets you
  /// there (first restoring the box, then - one more Undo - its text).
  void removeIfEmptyTextBox(String id) {
    if (_readOnly) return;
    final el = page.elements.whereType<TextBoxElement>().where((t) => t.id == id).firstOrNull;
    if (el == null || el.text.trim().isNotEmpty) return;
    page.elements.removeWhere((e) => e.id == id);
    selectedElementIds.remove(id);
    _pushUndo(_RemoveElementsAction([el]));
    _commit();
  }

  // --- Images --------------------------------------------------------

  void addImageAt(Offset canvasCenter, String filePath, {double? aspectRatio, double maxDimension = 280}) {
    if (_readOnly) return;
    double width, height;
    if (aspectRatio != null && aspectRatio > 0) {
      if (aspectRatio >= 1) {
        width = maxDimension;
        height = maxDimension / aspectRatio;
      } else {
        height = maxDimension;
        width = maxDimension * aspectRatio;
      }
    } else {
      // Unknown ratio (decoding the source file failed) - fall back to
      // the old fixed box shape rather than leaving it undefined.
      width = maxDimension;
      height = maxDimension * 200 / 280;
    }
    final rect = Rect.fromCenter(center: canvasCenter, width: width, height: height);
    final img = ImageElement(
      id: _uuid.v4(),
      createdAt: DateTime.now(),
      rect: rect,
      filePath: filePath,
      aspectRatio: aspectRatio,
    );
    page.elements.add(img);
    _pushUndo(_AddElementsAction([img]));
    _commit();
  }

  /// The most recently cut/copied image - a simple in-app clipboard
  /// rather than routing through the OS clipboard, since Windows image
  /// clipboard writes aren't reliably supported by the packages this app
  /// already depends on. Static (shared by every open page's controller)
  /// so a cut/copy on one page can be pasted on another. In-memory only -
  /// no need to survive an app restart.
  static _ClipboardImage? _clipboardImage;

  bool get hasClipboardImage => _clipboardImage != null;

  /// Copies the single selected image (a no-op if nothing, or something
  /// other than exactly one image, is selected).
  void copySelectedImage() {
    if (selectedElementIds.length != 1) return;
    final el = _findElement(selectedElementIds.first);
    if (el is! ImageElement) return;
    _clipboardImage = _ClipboardImage(
      filePath: el.filePath,
      aspectRatio: el.aspectRatio,
      width: el.rect.width,
      height: el.rect.height,
    );
  }

  /// Copies the selected image, then removes it from the page - same as
  /// [copySelectedImage] followed by [deleteSelection].
  void cutSelectedImage() {
    if (_readOnly) return;
    copySelectedImage();
    deleteSelection();
  }

  /// Pastes whatever [copySelectedImage]/[cutSelectedImage] last copied,
  /// centered on [canvasCenter], at its original size - a no-op if
  /// nothing's been copied yet. The pasted copy shares the same
  /// underlying image file as the original; that's safe because nothing
  /// in this app ever deletes an image file out from under a still-live
  /// element, only the page element referencing it.
  void pasteClipboardImageAt(Offset canvasCenter) {
    if (_readOnly) return;
    final clip = _clipboardImage;
    if (clip == null) return;
    final rect = Rect.fromCenter(center: canvasCenter, width: clip.width, height: clip.height);
    final img = ImageElement(
      id: _uuid.v4(),
      createdAt: DateTime.now(),
      rect: rect,
      filePath: clip.filePath,
      aspectRatio: clip.aspectRatio,
    );
    page.elements.add(img);
    _pushUndo(_AddElementsAction([img]));
    _commit();
  }

  // --- Undo/redo ---------------------------------------------------------

  void _pushUndo(_UndoableAction action) {
    _undoStack.add(action);
    _redoStack.clear();
  }

  void undo() {
    if (_readOnly || _undoStack.isEmpty) return;
    final action = _undoStack.removeLast();
    action.undo(this);
    _redoStack.add(action);
    _commit();
  }

  void redo() {
    if (_readOnly || _redoStack.isEmpty) return;
    final action = _redoStack.removeLast();
    action.redo(this);
    _undoStack.add(action);
    _commit();
  }

  // --- External updates (sync) ------------------------------------------

  /// Called when a fresher copy of this exact page arrives from another
  /// device while it's the one open here - see PageScreen.didUpdateWidget,
  /// which is what notices a sync-driven Notebook replacement swapped in a
  /// new NotePage object for the page this controller was built around.
  /// Replaces this controller's content in place (rather than requiring a
  /// full teardown/rebuild of the page) so the canvas repaints immediately
  /// instead of only catching up once the user navigates away and back.
  void applyExternalUpdate(NotePage fresh) {
    // LibraryController.applySyncedNotebook merges synced data into the
    // *existing* NotePage object in place whenever it can, specifically so
    // this - [page] - already IS [fresh] by the time this runs, with its
    // elements already updated. Only copy if they're genuinely different
    // objects (e.g. a caller that didn't go through that merge path).
    if (!identical(page, fresh)) {
      page.elements
        ..clear()
        ..addAll(fresh.elements);
      page.background = fresh.background;
      page.title = fresh.title;
      page.lastModified = fresh.lastModified;
    }
    // Any in-progress local gesture/selection referencing the old element
    // ids is meaningless now that the elements themselves may have been
    // replaced.
    draftStroke = null;
    draftShapeRect = null;
    draftLasso = null;
    selectedElementIds.clear();
    _undoStack.clear();
    _redoStack.clear();
    notifyListeners();
  }

  void _commit() {
    page.touch();
    notifyListeners();
    onContentChanged?.call();
  }
}

extension _FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

// --- Undo command objects -------------------------------------------------

abstract class _UndoableAction {
  void undo(PageEditController c);
  void redo(PageEditController c);
}

class _AddElementsAction extends _UndoableAction {
  _AddElementsAction(this.elements);
  final List<CanvasElement> elements;

  @override
  void undo(PageEditController c) {
    final ids = elements.map((e) => e.id).toSet();
    c.page.elements.removeWhere((e) => ids.contains(e.id));
  }

  @override
  void redo(PageEditController c) {
    c.page.elements.addAll(elements);
  }
}

class _RemoveElementsAction extends _UndoableAction {
  _RemoveElementsAction(this.elements);
  final List<CanvasElement> elements;

  @override
  void undo(PageEditController c) {
    c.page.elements.addAll(elements);
  }

  @override
  void redo(PageEditController c) {
    final ids = elements.map((e) => e.id).toSet();
    c.page.elements.removeWhere((e) => ids.contains(e.id));
  }
}

class _MoveElementsAction extends _UndoableAction {
  _MoveElementsAction(this.ids, this.delta);
  final Set<String> ids;
  final Offset delta;

  @override
  void undo(PageEditController c) => c._applyDelta(ids, -delta);

  @override
  void redo(PageEditController c) => c._applyDelta(ids, delta);
}

class _ResizeElementAction extends _UndoableAction {
  _ResizeElementAction(this.id, this.before, this.after);
  final String id;
  final Rect before;
  final Rect after;

  @override
  void undo(PageEditController c) {
    final el = c._findElement(id);
    if (el != null) c._setElementRect(el, before);
  }

  @override
  void redo(PageEditController c) {
    final el = c._findElement(id);
    if (el != null) c._setElementRect(el, after);
  }
}

class _EditTextAction extends _UndoableAction {
  _EditTextAction(this.id, this.before, this.after);
  final String id;
  final String before;
  final String after;

  TextBoxElement? _find(PageEditController c) =>
      c.page.elements.whereType<TextBoxElement>().where((t) => t.id == id).firstOrNull;

  @override
  void undo(PageEditController c) {
    _find(c)?.text = before;
  }

  @override
  void redo(PageEditController c) {
    _find(c)?.text = after;
  }
}

/// What [PageEditController.copySelectedImage]/[cutSelectedImage] stash
/// away - enough to recreate an equivalent [ImageElement] on paste,
/// including its size (rather than falling back to [addImageAt]'s
/// default box, which would silently resize the pasted copy).
class _ClipboardImage {
  _ClipboardImage({
    required this.filePath,
    required this.aspectRatio,
    required this.width,
    required this.height,
  });

  final String filePath;
  final double? aspectRatio;
  final double width;
  final double height;
}
