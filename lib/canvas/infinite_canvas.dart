import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/canvas_element.dart';
import 'canvas_painter.dart';
import 'canvas_tools.dart';
import 'canvas_view_controller.dart';
import 'canvas_viewport.dart';
import 'page_edit_controller.dart';

/// The OneNote-style infinite pan/zoom canvas.
///
/// Input routing rules (see README for the full rationale):
/// - Stylus (pen) always performs the active tool's action (draw, erase,
///   shape, lasso, text, select-and-move). Holding the pen's eraser
///   button always erases, regardless of the selected tool — see
///   [_isEraserSignal] for why that's checked two different ways.
/// - Touch (finger): one finger pans, two-or-more fingers pinch-pan-zoom —
///   always, regardless of tool — *except* when the Select tool is active,
///   where one finger taps/drags to select and move content (a second
///   finger arriving mid-gesture still takes over as pinch-zoom).
/// - Mouse: primary-button drag performs the active tool's action; middle-
///   or right-button drag pans; the scroll wheel zooms (holding Ctrl) or
///   pans (plain scroll).
class InfiniteCanvas extends StatefulWidget {
  const InfiniteCanvas({
    super.key,
    required this.editController,
    required this.viewController,
  });

  final PageEditController editController;
  final CanvasViewController viewController;

  @override
  State<InfiniteCanvas> createState() => _InfiniteCanvasState();
}

enum _GestureMode { none, draw, erase, shape, lasso, select, resize, pan, textPending }

class _InfiniteCanvasState extends State<InfiniteCanvas> {
  _GestureMode _mode = _GestureMode.none;
  int? _primaryPointerId;
  bool _selectIsMoving = false;
  Offset? _shapeStartCanvasPoint;
  Offset? _downLocal;

  /// Set by [_beginBorderGrabIfHit] to whatever element it just grabbed,
  /// so that on pointer-up, if this turns out to have been a plain tap
  /// (not a drag), [_registerBorderGrabTapAndMaybeEditText] can check it
  /// against the previous tap to recognize a double-click.
  String? _borderGrabTapCandidateId;

  /// id/position/time of the most recent double-click-eligible tap (a
  /// border-grab tap on a text box), so the *next* one landing soon
  /// after and near the same spot can be recognized as its match - see
  /// [_registerBorderGrabTapAndMaybeEditText].
  String? _lastTapTextBoxId;
  Offset? _lastTapScreenPos;
  DateTime? _lastTapTime;

  final Set<int> _touchPointerIds = {};
  final Map<int, Offset> _touchPositions = {};
  Offset? _lastFocal;
  double? _lastSpan;

  final Map<String, TextEditingController> _textControllers = {};
  final Map<String, FocusNode> _textFocusNodes = {};
  String? _autofocusTextId;

  /// Last known mouse position (screen space), used only to preview what
  /// a click would do right now - a move or resize cursor over a
  /// grabbable element/handle. Null on touch/stylus devices, which don't
  /// hover.
  Offset? _hoverLocal;

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    for (final f in _textFocusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        widget.viewController.reportSize(constraints.biggest);
        return AnimatedBuilder(
          animation: Listenable.merge([widget.editController, widget.viewController]),
          builder: (context, _) => Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            onPointerSignal: _onPointerSignal,
            child: MouseRegion(
              cursor: _cursorForTool(),
              onHover: (event) => setState(() => _hoverLocal = event.localPosition),
              onExit: (event) => setState(() => _hoverLocal = null),
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: NoteCanvasPainter(
                          viewport: widget.viewController.viewport,
                          page: widget.editController.page,
                          editController: widget.editController,
                        ),
                      ),
                    ),
                    ..._buildOverlayWidgets(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  MouseCursor _cursorForTool() {
    final tool = widget.editController.tool;
    final hover = _hoverLocal;
    if (hover != null && (tool == CanvasTool.select || _canBorderGrabWith(tool))) {
      final handle = _hitTestResizeHandle(hover);
      if (handle != null) {
        // Diagonal cursors for corners (matching which pair they belong
        // to), straight cursors for mid-edge handles.
        return switch (handle) {
          ResizeHandle.topLeft || ResizeHandle.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
          ResizeHandle.topRight || ResizeHandle.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
          ResizeHandle.left || ResizeHandle.right => SystemMouseCursors.resizeLeftRight,
          ResizeHandle.top || ResizeHandle.bottom => SystemMouseCursors.resizeUpDown,
        };
      }
      final overGrabbable = tool == CanvasTool.select
          ? widget.editController.hitTestTopmost(widget.viewController.viewport.screenToCanvas(hover)) != null
          : _hitTestGrabbableElement(hover) != null;
      if (overGrabbable) return SystemMouseCursors.move;
    }
    switch (tool) {
      case CanvasTool.pan:
        return SystemMouseCursors.grab;
      case CanvasTool.text:
        return SystemMouseCursors.text;
      case CanvasTool.select:
        return SystemMouseCursors.basic;
      default:
        return SystemMouseCursors.precise;
    }
  }

  /// Minimum canvas-space height for a text box, so an empty or
  /// single-short-line box still keeps a comfortable minimum size to tap.
  static const double _minTextBoxHeight = 32.0;

  /// Measures the canvas-space height needed to fit [text] inside a text
  /// box of the given [canvasWidth] and [fontSize], accounting for the
  /// TextField's 4px content padding on each side (see the TextField's
  /// `contentPadding` in _buildOverlayWidgets). Never returns less than
  /// [_minTextBoxHeight].
  double _measureTextBoxHeight(String text, double canvasWidth, double fontSize) {
    const horizontalPadding = 8.0; // 4px left + 4px right
    const verticalPadding = 8.0; // 4px top + 4px bottom
    final painter = TextPainter(
      text: TextSpan(text: text.isEmpty ? ' ' : text, style: TextStyle(fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: (canvasWidth - horizontalPadding).clamp(1.0, double.infinity));
    return (painter.height + verticalPadding).clamp(_minTextBoxHeight, double.infinity);
  }

  List<Widget> _buildOverlayWidgets() {
    final viewport = widget.viewController.viewport;
    final tool = widget.editController.tool;
    final widgets = <Widget>[];
    for (final el in widget.editController.page.elements) {
      switch (el) {
        case TextBoxElement t:
          final controller = _textControllers.putIfAbsent(t.id, () {
            final c = TextEditingController(text: t.text);
            // Re-measure/auto-grow (see below) and repaint on every
            // keystroke, not just when focus changes - otherwise the box
            // stays its old height while you're actively typing a long
            // note and only "snaps" to the right size after you tap away.
            c.addListener(() {
              if (mounted) setState(() {});
            });
            return c;
          });
          if (controller.text != t.text && !(_textFocusNodes[t.id]?.hasFocus ?? false)) {
            controller.text = t.text;
          }
          // Auto-grow the box's height to fit its current text so long
          // text is never hidden/clipped inside a fixed-size box. Width is
          // deliberately left alone - only height follows the content,
          // OneNote-style. This mutates the model directly (skipping the
          // undo stack) since it's a passive visual follow-of-content, not
          // a discrete user edit.
          final neededHeight = _measureTextBoxHeight(controller.text, t.rect.width, t.fontSize);
          if ((t.rect.height - neededHeight).abs() > 0.5) {
            t.rect = Rect.fromLTWH(t.rect.left, t.rect.top, t.rect.width, neededHeight);
          }
          final screenRect = viewport.canvasRectToScreen(t.rect);
          final focusNode = _textFocusNodes.putIfAbsent(t.id, () {
            final node = FocusNode();
            node.addListener(() {
              if (!node.hasFocus) {
                widget.editController.commitTextEdit(t.id, controller.text);
                // Tapped to place a box, then dismissed the keyboard
                // without typing anything (or deleted everything you'd
                // written)? Don't leave an empty outline behind.
                widget.editController.removeIfEmptyTextBox(t.id);
                // Hop back to the Pen tool the moment you're done editing,
                // so the very next stylus touch draws instead of needing
                // a trip back to the toolbar - you only get a new text
                // box when you deliberately pick the Text tool again.
                if (widget.editController.tool == CanvasTool.text) {
                  widget.editController.setTool(CanvasTool.pen);
                }
              }
              // Repaint so the placeholder border (below) appears/disappears
              // as focus changes, and so a freshly-placed empty box shows
              // its border immediately even before the keyboard callback
              // below actually lands the focus.
              if (mounted) setState(() {});
            });
            return node;
          });
          // Only the Text tool makes a text box interactive (tappable to
          // reposition the cursor / resume typing). The Select tool used
          // to also be included here, but that meant tapping a text box
          // to select-and-delete it also grabbed keyboard focus and
          // popped the keyboard up - annoying, and on a phone/tablet it
          // could even cover the toolbar's Delete button. Under Select,
          // a text box is now select-and-move/delete only, exactly like
          // images - to resume editing its text, switch to the Text tool.
          final interactive = tool == CanvasTool.text;
          // Give an empty or actively-focused text box a faint outline.
          // Without this, a brand-new text box (no text yet, and — if
          // autofocus/requestFocus hasn't landed the very first frame yet —
          // not focused either) is completely invisible: no border, no
          // fill, no cursor. That made it look like tapping with the Text
          // tool "did nothing" even when a box was in fact created.
          final showPlaceholderBorder = controller.text.isEmpty || focusNode.hasFocus;
          widgets.add(
            Positioned.fromRect(
              rect: screenRect,
              child: IgnorePointer(
                ignoring: !interactive,
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    decoration: showPlaceholderBorder
                        ? BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).colorScheme.primary.withOpacity(0.45),
                            ),
                            borderRadius: BorderRadius.circular(4),
                          )
                        : null,
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: _autofocusTextId == t.id,
                      maxLines: null,
                      style: TextStyle(fontSize: t.fontSize * viewport.scale, color: t.color),
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        case ImageElement img:
          final screenRect = viewport.canvasRectToScreen(img.rect);
          widgets.add(
            Positioned.fromRect(
              rect: screenRect,
              child: IgnorePointer(
                // BoxFit.contain would keep the image's own aspect ratio and
                // pad out any leftover space in the box with whitespace -
                // exactly the "box stretches, image doesn't" look. The corner
                // handles already keep the box itself at the image's aspect
                // ratio, so free stretching only ever happens via the edge
                // handles, where the point is for the image to distort to
                // fill the new box exactly.
                child: Image.file(File(img.filePath), fit: BoxFit.fill),
              ),
            ),
          );
        case InkStrokeElement _:
        case ShapeElement _:
          break; // painted by NoteCanvasPainter
      }
    }
    return widgets;
  }

  // --- Pointer routing -----------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    final local = event.localPosition;
    final viewport = widget.viewController.viewport;

    if (event.kind == PointerDeviceKind.touch) {
      _touchPointerIds.add(event.pointer);
      _touchPositions[event.pointer] = local;
      if (_touchPointerIds.length == 1) {
        final tool = widget.editController.tool;
        if (tool == CanvasTool.select) {
          _primaryPointerId = event.pointer;
          _beginSelectGesture(viewport.screenToCanvas(local), local);
        } else if (tool == CanvasTool.text) {
          // Single-finger tap places a text box too (not just stylus/mouse),
          // since a touch-only tablet has no other way to add one. But if
          // the tap landed on an existing text box, don't stack a new
          // empty one on top of it - that existing TextField is already
          // interactive in Text-tool mode (see _buildOverlayWidgets) and
          // will take the tap itself to resume editing.
          if (_hitsExistingTextBox(viewport.screenToCanvas(local))) {
            _mode = _GestureMode.none;
          } else {
            _primaryPointerId = event.pointer;
            _downLocal = local;
            _mode = _GestureMode.textPending;
          }
        } else if (_canBorderGrabWith(tool) &&
            _beginBorderGrabIfHit(viewport.screenToCanvas(local), local)) {
          // Handled: a finger tap landed right on an existing text box or
          // image, so grab it (select, and move if this turns into a
          // drag) instead of panning - see _canBorderGrabWith for why
          // this is scoped to certain tools.
          _primaryPointerId = event.pointer;
          _downLocal = local; // needed to tell a tap from a drag on pointer-up
        } else {
          _mode = _GestureMode.pan;
          _lastFocal = local;
          _lastSpan = null;
        }
      } else {
        if (_mode == _GestureMode.select) {
          _finishSelectGesture();
          _primaryPointerId = null;
        }
        _mode = _GestureMode.pan;
        _recomputeTouchFocalAndSpan();
      }
      return;
    }

    if (_mode != _GestureMode.none) return;

    if (event.kind == PointerDeviceKind.stylus || event.kind == PointerDeviceKind.invertedStylus) {
      _primaryPointerId = event.pointer;
      _downLocal = local;
      final forceEraser = _isEraserSignal(event);
      final tool = widget.editController.tool;
      if (!forceEraser &&
          _canBorderGrabWith(tool) &&
          _beginBorderGrabIfHit(viewport.screenToCanvas(local), local)) {
        // Handled: the pen tip landed right on an existing text box or
        // image, so grab it instead of drawing - see _canBorderGrabWith.
      } else {
        _beginToolGesture(local, forceEraser: forceEraser, pressure: event.pressure == 0 ? 1.0 : event.pressure);
      }
      return;
    }

    if (event.kind == PointerDeviceKind.mouse) {
      _primaryPointerId = event.pointer;
      _downLocal = local;
      final tool = widget.editController.tool;
      final isPanButton = event.buttons == kMiddleMouseButton || event.buttons == kSecondaryMouseButton;
      if (isPanButton || tool == CanvasTool.pan) {
        _mode = _GestureMode.pan;
        _lastFocal = local;
        _lastSpan = null;
      } else if (_canBorderGrabWith(tool) &&
          _beginBorderGrabIfHit(viewport.screenToCanvas(local), local)) {
        // Handled: grabbed an existing text box's/image's edge (or, if it
        // was already selected, one of its resize handles) directly -
        // see _beginBorderGrabIfHit for why this is scoped to the mouse
        // and to these specific tools.
      } else {
        _beginToolGesture(local, forceEraser: false, pressure: 1.0);
      }
    }
  }

  /// Which tools this OneNote-style "just click it" shortcut is safe to
  /// kick in for, on any input device (mouse, touch, or stylus).
  /// Deliberately narrow: Select and Text already have their own
  /// well-defined tap behavior for existing content, and Eraser/Lasso/
  /// Shape are drag gestures where a click on an element should still do
  /// what the tool says (erase, lasso, or start drawing a new shape)
  /// rather than silently grabbing something instead.
  bool _canBorderGrabWith(CanvasTool tool) =>
      tool == CanvasTool.pen || tool == CanvasTool.highlighter;

  /// OneNote-style shortcut: with the mouse, clicking anywhere on an
  /// existing text box or image (or, once it's selected, one of its
  /// resize handles) selects/moves/resizes it directly, without switching
  /// to the Select tool first. Returns true if it handled the down
  /// event, in which case the active tool's own action (drawing a
  /// stroke, say) does not also happen for this click.
  bool _beginBorderGrabIfHit(Offset canvasPoint, Offset localScreenPoint) {
    final handle = _hitTestResizeHandle(localScreenPoint);
    if (handle != null) {
      _mode = _GestureMode.resize;
      _borderGrabTapCandidateId = null;
      widget.editController.startResizeSelection(handle, canvasPoint);
      return true;
    }
    final id = _hitTestGrabbableElement(localScreenPoint);
    if (id == null) return false;
    _mode = _GestureMode.select;
    if (!widget.editController.selectedElementIds.contains(id)) {
      widget.editController.selectOnly(id);
    }
    _selectIsMoving = true;
    widget.editController.startMoveSelection(canvasPoint);
    _borderGrabTapCandidateId = id;
    return true;
  }

  bool _isTextBoxElement(String id) {
    for (final e in widget.editController.page.elements) {
      if (e.id == id) return e is TextBoxElement;
    }
    return false;
  }

  /// Called whenever a border-grab gesture (see [_beginBorderGrabIfHit])
  /// ends. A single tap only selects, exactly like the Select tool - to
  /// actually start typing, double-click/double-tap a text box within
  /// [_doubleClickWindow] and [_doubleClickMaxDistance] of the previous
  /// tap, OneNote-style. A drag (move) never counts as a tap here, so it
  /// can't accidentally register as half of a double-click.
  static const _doubleClickWindow = Duration(milliseconds: 400);
  static const _doubleClickMaxDistance = 24.0;

  void _registerBorderGrabTapAndMaybeEditText(Offset upLocal) {
    final id = _borderGrabTapCandidateId;
    _borderGrabTapCandidateId = null;
    if (id == null) return;
    final downLocal = _downLocal;
    if (downLocal != null && (upLocal - downLocal).distance > 12) return; // was a drag, not a tap
    if (!_isTextBoxElement(id)) return; // only text boxes have anything to "edit"

    final now = DateTime.now();
    final isDoubleClick = _lastTapTextBoxId == id &&
        _lastTapScreenPos != null &&
        (upLocal - _lastTapScreenPos!).distance <= _doubleClickMaxDistance &&
        _lastTapTime != null &&
        now.difference(_lastTapTime!) <= _doubleClickWindow;

    if (isDoubleClick) {
      _lastTapTextBoxId = null;
      _lastTapScreenPos = null;
      _lastTapTime = null;
      widget.editController.setTool(CanvasTool.text);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _textFocusNodes[id]?.requestFocus();
      });
    } else {
      _lastTapTextBoxId = id;
      _lastTapScreenPos = upLocal;
      _lastTapTime = now;
    }
  }

  /// True when [localScreenPoint] lands anywhere within an existing text
  /// box or image (a small outward margin included, for an easier grab
  /// near the edge), in screen space so that margin stays a constant
  /// on-screen width regardless of zoom. Checked topmost-first, same as
  /// [PageEditController.hitTestTopmost].
  String? _hitTestGrabbableElement(Offset localScreenPoint) {
    const margin = 6.0;
    for (final el in widget.editController.page.elements.reversed) {
      if (el is! TextBoxElement && el is! ImageElement) continue;
      final screenRect = widget.viewController.viewport.canvasRectToScreen(el.bounds).inflate(margin);
      if (screenRect.contains(localScreenPoint)) return el.id;
    }
    return null;
  }

  /// True when this stylus pointer should erase instead of performing the
  /// active tool's normal action. Different Android/stylus combinations
  /// report a physical eraser-button press two different ways: some
  /// report the pointer itself as [PointerDeviceKind.invertedStylus]
  /// (Android's TOOL_TYPE_ERASER, e.g. flipping a Surface-style pen), and
  /// some instead keep reporting a normal stylus pointer but set a
  /// stylus button bit (Android's BUTTON_STYLUS_PRIMARY/SECONDARY — this
  /// is how a single-button S Pen's side button tends to show up).
  /// Checking both means the pen's button reliably forces the eraser
  /// regardless of which path the device/OS combination takes.
  bool _isEraserSignal(PointerEvent event) {
    if (event.kind == PointerDeviceKind.invertedStylus) return true;
    if (event.kind == PointerDeviceKind.stylus) {
      return (event.buttons & kPrimaryStylusButton) != 0 ||
          (event.buttons & kSecondaryStylusButton) != 0;
    }
    return false;
  }

  void _beginToolGesture(Offset local, {required bool forceEraser, required double pressure}) {
    final viewport = widget.viewController.viewport;
    final canvasPoint = viewport.screenToCanvas(local);
    final tool = forceEraser ? CanvasTool.eraser : widget.editController.tool;
    switch (tool) {
      case CanvasTool.pen:
      case CanvasTool.highlighter:
        _mode = _GestureMode.draw;
        widget.editController.startStroke(canvasPoint, pressure);
      case CanvasTool.eraser:
        _mode = _GestureMode.erase;
        widget.editController.beginEraseGesture();
        widget.editController.eraseAt(canvasPoint);
      case CanvasTool.shape:
        _mode = _GestureMode.shape;
        _shapeStartCanvasPoint = canvasPoint;
        widget.editController.startShape(canvasPoint);
      case CanvasTool.lasso:
        _mode = _GestureMode.lasso;
        widget.editController.startLasso(canvasPoint);
      case CanvasTool.text:
        // See the matching comment in the touch branch of _onPointerDown:
        // don't place a new box on top of one that's already there.
        _mode = _hitsExistingTextBox(canvasPoint) ? _GestureMode.none : _GestureMode.textPending;
      case CanvasTool.select:
        _beginSelectGesture(canvasPoint, local);
      case CanvasTool.pan:
        _mode = _GestureMode.pan;
        _lastFocal = local;
        _lastSpan = null;
    }
  }

  void _beginSelectGesture(Offset canvasPoint, Offset localScreenPoint) {
    final handle = _hitTestResizeHandle(localScreenPoint);
    if (handle != null) {
      _mode = _GestureMode.resize;
      widget.editController.startResizeSelection(handle, canvasPoint);
      return;
    }
    _mode = _GestureMode.select;
    final hitId = widget.editController.hitTestTopmost(canvasPoint);
    if (hitId != null) {
      if (!widget.editController.selectedElementIds.contains(hitId)) {
        widget.editController.selectOnly(hitId);
      }
      _selectIsMoving = true;
      widget.editController.startMoveSelection(canvasPoint);
    } else {
      widget.editController.clearSelection();
      _selectIsMoving = false;
      widget.editController.startLasso(canvasPoint);
    }
  }

  /// True when [canvasPoint] lands inside an already-placed text box.
  /// Used to stop the Text tool from dropping a brand-new empty box right
  /// on top of one that's already there (see the two call sites above) -
  /// the existing box's own TextField is what should take the tap.
  bool _hitsExistingTextBox(Offset canvasPoint) {
    for (final el in widget.editController.page.elements.reversed) {
      if (el is TextBoxElement && el.rect.contains(canvasPoint)) return true;
    }
    return false;
  }

  /// Resize-handle hit test, in screen space (so the hit target stays a
  /// constant on-screen size regardless of zoom level), for the single
  /// currently-selected element, if it's a kind that supports resizing
  /// (images and text boxes).
  ResizeHandle? _hitTestResizeHandle(Offset localScreenPoint) {
    final selected = widget.editController.selectedElementIds;
    if (selected.length != 1) return null;
    final id = selected.first;
    CanvasElement? el;
    for (final e in widget.editController.page.elements) {
      if (e.id == id) {
        el = e;
        break;
      }
    }
    // Checking against two subtypes here (rather than one, as before)
    // means Dart can no longer narrow `el`'s type on its own, so the
    // null check has to be spelled out explicitly.
    if (el == null || (el is! ImageElement && el is! TextBoxElement)) return null;
    final screenRect = widget.viewController.viewport.canvasRectToScreen(el.bounds);
    const hitRadius = 18.0;
    // Text boxes only ever resize by width (their height auto-fits the
    // text - see InfiniteCanvas), so top/bottom handles are only offered
    // for images.
    final handles = <ResizeHandle, Offset>{
      ResizeHandle.topLeft: screenRect.topLeft,
      ResizeHandle.topRight: screenRect.topRight,
      ResizeHandle.bottomLeft: screenRect.bottomLeft,
      ResizeHandle.bottomRight: screenRect.bottomRight,
      ResizeHandle.left: screenRect.centerLeft,
      ResizeHandle.right: screenRect.centerRight,
      if (el is ImageElement) ResizeHandle.top: screenRect.topCenter,
      if (el is ImageElement) ResizeHandle.bottom: screenRect.bottomCenter,
    };
    for (final entry in handles.entries) {
      if ((entry.value - localScreenPoint).distance <= hitRadius) return entry.key;
    }
    return null;
  }

  void _finishSelectGesture() {
    if (_selectIsMoving) {
      widget.editController.endMoveSelection();
    } else {
      widget.editController.endLasso();
    }
  }

  void _recomputeTouchFocalAndSpan() {
    final positions = _touchPositions.values.toList();
    if (positions.isEmpty) return;
    Offset sum = Offset.zero;
    for (final p in positions) {
      sum += p;
    }
    _lastFocal = sum / positions.length.toDouble();
    if (positions.length >= 2) {
      _lastSpan = (positions[0] - positions[1]).distance;
    } else {
      _lastSpan = null;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    final local = event.localPosition;
    final viewport = widget.viewController.viewport;

    if (event.kind == PointerDeviceKind.touch) {
      if (!_touchPointerIds.contains(event.pointer)) return;
      _touchPositions[event.pointer] = local;
      if (_mode == _GestureMode.pan) {
        _updateTouchPan();
      } else if (_mode == _GestureMode.select && _primaryPointerId == event.pointer) {
        _updateSelectOrLasso(viewport.screenToCanvas(local));
      } else if (_mode == _GestureMode.resize && _primaryPointerId == event.pointer) {
        widget.editController.updateResizeSelection(viewport.screenToCanvas(local));
      }
      return;
    }

    if (_primaryPointerId != event.pointer) return;

    switch (_mode) {
      case _GestureMode.draw:
        widget.editController.appendStrokePoint(
          viewport.screenToCanvas(local),
          event.pressure == 0 ? 1.0 : event.pressure,
        );
      case _GestureMode.erase:
        widget.editController.eraseAt(viewport.screenToCanvas(local));
      case _GestureMode.shape:
        widget.editController.updateShape(_shapeStartCanvasPoint!, viewport.screenToCanvas(local));
      case _GestureMode.lasso:
        widget.editController.updateLasso(viewport.screenToCanvas(local));
      case _GestureMode.select:
        _updateSelectOrLasso(viewport.screenToCanvas(local));
      case _GestureMode.resize:
        widget.editController.updateResizeSelection(viewport.screenToCanvas(local));
      case _GestureMode.pan:
        _updateMousePan(local);
      case _GestureMode.textPending:
      case _GestureMode.none:
        break;
    }
  }

  void _updateSelectOrLasso(Offset canvasPoint) {
    if (_selectIsMoving) {
      widget.editController.updateMoveSelection(canvasPoint);
    } else {
      widget.editController.updateLasso(canvasPoint);
    }
  }

  void _updateTouchPan() {
    final oldFocal = _lastFocal;
    final oldSpan = _lastSpan;
    _recomputeTouchFocalAndSpan();
    if (oldFocal == null) return;
    final newFocal = _lastFocal!;
    final scaleFactor = (oldSpan != null && _lastSpan != null && oldSpan > 0) ? _lastSpan! / oldSpan : 1.0;
    widget.viewController.viewport.applyIncrementalGesture(
      oldScreenFocal: oldFocal,
      newScreenFocal: newFocal,
      scaleFactor: scaleFactor,
    );
    widget.viewController.notifyChanged();
  }

  void _updateMousePan(Offset newLocal) {
    final oldFocal = _lastFocal;
    if (oldFocal == null) {
      _lastFocal = newLocal;
      return;
    }
    widget.viewController.viewport.applyIncrementalGesture(
      oldScreenFocal: oldFocal,
      newScreenFocal: newLocal,
      scaleFactor: 1.0,
    );
    _lastFocal = newLocal;
    widget.viewController.notifyChanged();
  }

  void _onPointerUp(PointerEvent event) {
    final viewport = widget.viewController.viewport;

    if (event.kind == PointerDeviceKind.touch) {
      _touchPointerIds.remove(event.pointer);
      _touchPositions.remove(event.pointer);
      if (_mode == _GestureMode.select && _primaryPointerId == event.pointer) {
        _finishSelectGesture();
        _registerBorderGrabTapAndMaybeEditText(event.localPosition);
        _mode = _GestureMode.none;
        _primaryPointerId = null;
      } else if (_mode == _GestureMode.resize && _primaryPointerId == event.pointer) {
        widget.editController.endResizeSelection();
        _mode = _GestureMode.none;
        _primaryPointerId = null;
      } else if (_mode == _GestureMode.textPending && _primaryPointerId == event.pointer) {
        _finishTextPlacement(event.localPosition, viewport);
        _mode = _GestureMode.none;
        _primaryPointerId = null;
      } else if (_mode == _GestureMode.pan) {
        if (_touchPointerIds.isEmpty) {
          _mode = _GestureMode.none;
          _lastFocal = null;
          _lastSpan = null;
        } else {
          _recomputeTouchFocalAndSpan();
        }
      }
      return;
    }

    if (_primaryPointerId != event.pointer) return;

    switch (_mode) {
      case _GestureMode.draw:
        widget.editController.endStroke();
      case _GestureMode.erase:
        widget.editController.endEraseGesture();
      case _GestureMode.shape:
        widget.editController.endShape();
      case _GestureMode.lasso:
        widget.editController.endLasso();
      case _GestureMode.select:
        _finishSelectGesture();
        _registerBorderGrabTapAndMaybeEditText(event.localPosition);
      case _GestureMode.resize:
        widget.editController.endResizeSelection();
      case _GestureMode.textPending:
        _finishTextPlacement(event.localPosition, viewport);
      case _GestureMode.pan:
      case _GestureMode.none:
        break;
    }

    _mode = _GestureMode.none;
    _primaryPointerId = null;
    _shapeStartCanvasPoint = null;
    _lastFocal = null;
    _lastSpan = null;
  }

  void _finishTextPlacement(Offset upLocal, CanvasViewport viewport) {
    if (widget.editController.readOnly) return;
    final downLocal = _downLocal ?? upLocal;
    if ((upLocal - downLocal).distance > 12) return; // was a drag, not a tap; ignore
    final canvasPoint = viewport.screenToCanvas(downLocal);
    final box = widget.editController.addTextBoxAt(canvasPoint);
    setState(() => _autofocusTextId = box.id);
    // `autofocus: true` on the TextField isn't reliable here: this
    // TextField is inserted into the tree from an async pointer-event
    // callback (via setState), not present when the widget tree first
    // builds, and in practice that meant the soft keyboard on Android
    // often never appeared even though the text box itself was created.
    // Explicitly request focus once the frame that creates the FocusNode
    // has actually built and landed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _textFocusNodes[box.id]?.requestFocus();
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final ctrlHeld = HardwareKeyboard.instance.isControlPressed;
    final viewport = widget.viewController.viewport;
    if (ctrlHeld) {
      final factor = event.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1;
      viewport.zoomTo(viewport.scale * factor, event.localPosition);
    } else {
      viewport.pan -= event.scrollDelta;
    }
    widget.viewController.notifyChanged();
  }
}
