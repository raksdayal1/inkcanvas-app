import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_file/open_file.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/canvas_element.dart';
import '../state/app_settings.dart';
import 'canvas_painter.dart';
import 'canvas_tools.dart';
import 'canvas_view_controller.dart';
import 'canvas_viewport.dart';
import 'link_detection.dart';
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
///   finger arriving mid-gesture still takes over as pinch-zoom), *and*
///   except that a finger held still on an image starts a long-press
///   timer (see [_longPressTimer]) that pops up a Cut/Copy/Delete menu
///   underneath it.
/// - Mouse: primary-button drag performs the active tool's action;
///   middle-button drag pans; the scroll wheel zooms (holding Ctrl) or
///   pans (plain scroll); right-click opens a context menu (Paste on
///   empty canvas, or Cut/Copy/Delete on an image) instead of panning or
///   drawing.
class InfiniteCanvas extends StatefulWidget {
  const InfiniteCanvas({
    super.key,
    required this.editController,
    required this.viewController,
    this.onRequestPasteAt,
    this.resolveEmbeddedLink,
  });

  final PageEditController editController;
  final CanvasViewController viewController;

  /// Called with a canvas-space point when the user picks "Paste" from
  /// the right-click context menu on empty canvas. Handling paste here
  /// (rather than inside this widget) is what lets it fall back to
  /// reading the OS clipboard - that needs the same file-import/
  /// aspect-ratio-decoding machinery [PageScreen] already has for the
  /// file-picker/Ctrl+V paths, which this widget has no reason to
  /// duplicate.
  final void Function(Offset canvasPoint)? onRequestPasteAt;

  /// Given a tapped local-file link's raw target text (see
  /// findUrls/DetectedUrl.target in link_detection.dart), returns the
  /// path of an embedded copy of that file on THIS device, if
  /// PageScreen has one on record (NotePage.embeddedLinks) and it's
  /// actually present in local storage right now - or null if there's
  /// no embedded copy, in which case _openLocalFile falls back to
  /// resolving the raw target itself, exactly as before this existed.
  /// Kept as an injected callback (rather than this widget reaching
  /// into LocalStore/NotePage itself) so this file doesn't need to
  /// know anything about how or where embedding is implemented.
  final Future<String?> Function(String rawTarget)? resolveEmbeddedLink;

  @override
  State<InfiniteCanvas> createState() => _InfiniteCanvasState();
}

/// A [TextEditingController] that renders auto-detected URLs (see
/// [findUrls] in link_detection.dart) in a distinct, underlined style -
/// purely a visual cue. Deliberately does NOT attach a
/// [TextSpan.recognizer] to those spans: Flutter's own issue tracker
/// (flutter/flutter#97433) documents recognizers inside an editable
/// field's buildTextSpan as unreliable, since they fight the field's
/// own tap-to-place-cursor handling and can even throw. Actually
/// opening a link is handled separately, from real pointer events in
/// this file - see _urlAtLocalScreenPoint and its two call sites.
class _LinkHighlightingController extends TextEditingController {
  _LinkHighlightingController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final urls = findUrls(text);
    if (urls.isEmpty) {
      return TextSpan(text: text, style: style);
    }
    final linkStyle = (style ?? const TextStyle()).copyWith(
      color: Colors.blue.shade700,
      decoration: TextDecoration.underline,
    );
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final url in urls) {
      if (url.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, url.start), style: style));
      }
      spans.add(TextSpan(text: text.substring(url.start, url.end), style: linkStyle));
      cursor = url.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: style));
    }
    return TextSpan(style: style, children: spans);
  }
}

enum _GestureMode { none, draw, erase, shape, lasso, select, resize, rotate, pan, textPending, contextMenuPending }

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

  /// Owns the incremental draft-stroke render cache across the many
  /// DraftOverlayPainter instances built while a stroke is in progress
  /// (a fresh painter is constructed every build - see canvas_painter.dart's
  /// DraftStrokeCache doc comment for why a persistent cache is needed
  /// and lives here rather than on the painter itself).
  final DraftStrokeCache _draftStrokeCache = DraftStrokeCache();

  /// Last known mouse position (screen space), used only to preview what
  /// a click would do right now - a move or resize cursor over a
  /// grabbable element/handle. Null on touch/stylus devices, which don't
  /// hover.
  Offset? _hoverLocal;

  /// Armed by a touch pointer landing on an image (see [_onPointerDown]),
  /// and fired after [_longPressDuration] if that finger is still down
  /// and hasn't moved - see [_fireLongPress]. Cancelled by any move past
  /// [_longPressMoveTolerance], a second finger joining, or lifting the
  /// finger first (a plain tap/select, handled normally).
  Timer? _longPressTimer;
  String? _longPressElementId;
  Offset? _longPressDownLocal;
  static const _longPressDuration = Duration(milliseconds: 500);
  static const _longPressMoveTolerance = 12.0;

  @override
  void dispose() {
    _longPressTimer?.cancel();
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
    // Watched here (not deeper in the tree) so toggling it rebuilds this
    // whole widget and constructs fresh painters with the new value -
    // CustomPainter has no BuildContext of its own to watch this
    // directly. StaticContentPainter's shouldRepaint compares it
    // explicitly (see canvas_painter.dart) so a toggle still repaints
    // committed ink immediately, not just newly-drawn strokes.
    final smoothingEnabled = context.watch<AppSettings>().inkSmoothingEnabled;
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
                    // Split into two painted layers - see the doc
                    // comments on StaticContentPainter/DraftOverlayPainter
                    // in canvas_painter.dart for why: wrapping only the
                    // committed content in a RepaintBoundary is what lets
                    // Flutter skip re-rasterizing a busy page's existing
                    // ink on every single pointer-move sample of a brand
                    // new stroke, instead of only actually repainting
                    // once that stroke (or any other edit) is committed.
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: StaticContentPainter(
                            viewport: widget.viewController.viewport,
                            page: widget.editController.page,
                            smoothingEnabled: smoothingEnabled,
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: DraftOverlayPainter(
                          viewport: widget.viewController.viewport,
                          page: widget.editController.page,
                          editController: widget.editController,
                          smoothingEnabled: smoothingEnabled,
                          draftStrokeCache: _draftStrokeCache,
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
    if (hover != null &&
        (tool == CanvasTool.select || tool == CanvasTool.lasso) &&
        _hitTestRotateHandle(hover)) {
      return SystemMouseCursors.grab;
    }
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

  /// The style a text box's [fontFamily]/[fontSize]/[color] renders
  /// with - routed through google_fonts for any non-null family (see
  /// kTextFontChoices) so the same font actually looks the same on
  /// Windows and Android, rather than depending on what's installed on
  /// the OS; null falls back to the app's plain default TextStyle.
  TextStyle _fontStyle({required String? fontFamily, required double fontSize, Color? color}) {
    if (fontFamily == null) return TextStyle(fontSize: fontSize, color: color);
    return GoogleFonts.getFont(fontFamily, fontSize: fontSize, color: color);
  }

  /// Measures the canvas-space height needed to fit [text] inside a text
  /// box of the given [canvasWidth]/[fontSize]/[fontFamily], accounting
  /// for the TextField's 4px content padding on each side (see the
  /// TextField's `contentPadding` in _buildOverlayWidgets). Never returns
  /// less than [_minTextBoxHeight].
  ///
  /// [scale] is the current viewport zoom. The TextField's content
  /// padding is a FIXED 4px-per-side on screen, not a canvas-space
  /// amount - it doesn't shrink or grow as you zoom. So in canvas-space
  /// units (which this whole method otherwise works in, matching
  /// [fontSize]/[canvasWidth] being zoom-independent) that fixed padding
  /// is actually `4 / scale` per side, not a flat `4`. Using a flat `8`
  /// regardless of zoom under-reserves padding once zoomed out (scale <
  /// 1), so this method would predict fewer wrapped lines than the real
  /// TextField actually needs on screen, under-allocating the box's
  /// height - which is exactly why text got clipped when zooming out.
  double _measureTextBoxHeight(String text, double canvasWidth, double fontSize, String? fontFamily, double scale) {
    final horizontalPadding = 8.0 / scale; // 4px left + 4px right, in canvas units at this zoom
    final verticalPadding = 8.0 / scale; // 4px top + 4px bottom, in canvas units at this zoom
    final painter = TextPainter(
      text: TextSpan(text: text.isEmpty ? ' ' : text, style: _fontStyle(fontFamily: fontFamily, fontSize: fontSize)),
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
            final c = _LinkHighlightingController(text: t.text);
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
          final neededHeight = _measureTextBoxHeight(controller.text, t.rect.width, t.fontSize, t.fontFamily, viewport.scale);
          if ((t.rect.height - neededHeight).abs() > 0.5) {
            t.rect = Rect.fromLTWH(t.rect.left, t.rect.top, t.rect.width, neededHeight);
          }
          final screenRect = viewport.canvasRectToScreen(t.rect);
          final focusNode = _textFocusNodes.putIfAbsent(t.id, () {
            final node = FocusNode();
            node.addListener(() {
              if (node.hasFocus) {
                // Selecting the box being typed into (not just focusing
                // it) is what lets the font family/size controls - which
                // act on whatever's selected - actually reach it. It's
                // cleared again the moment editing ends, below, by the
                // switch back to the Pen tool.
                widget.editController.selectOnly(t.id);
              } else {
                widget.editController.commitTextEdit(t.id, controller.text);
                // Tapped to place a box, then dismissed the keyboard
                // without typing anything (or deleted everything you'd
                // written)? Don't leave an empty outline behind.
                widget.editController.removeIfEmptyTextBox(t.id);
                // Hop back to the Pen tool the moment you're done editing,
                // so the very next stylus touch draws instead of needing
                // a trip back to the toolbar - you only get a new text
                // box when you deliberately pick the Text tool again.
                // (This is also what clears the selection set above.)
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
                      style: _fontStyle(
                        fontFamily: t.fontFamily,
                        fontSize: t.fontSize * viewport.scale,
                        color: t.color,
                      ),
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
          break; // painted by StaticContentPainter/DraftOverlayPainter
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
          final hitId = _beginSelectGesture(viewport.screenToCanvas(local), local);
          if (hitId != null && _isImageElement(hitId)) {
            _armLongPress(hitId, local);
          }
        } else if (tool == CanvasTool.lasso) {
          // Previously fell through to the generic "pan" branch below,
          // so a single finger with the Lasso tool active just panned
          // the canvas instead of lassoing anything - touch never
          // actually drew a lasso before this. _beginLassoToolGesture
          // also covers the "drag an already-selected item" case (a
          // press landing on something a prior lasso selected moves the
          // whole selection instead of starting a new lasso on top of
          // it), same as the mouse/stylus path.
          _primaryPointerId = event.pointer;
          final hitId = _beginLassoToolGesture(viewport.screenToCanvas(local), local);
          if (hitId != null && _isImageElement(hitId)) {
            _armLongPress(hitId, local);
          }
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
            _beginBorderGrabIfHit(viewport.screenToCanvas(local), local, allowOversizedGrab: false)) {
          // Handled: a finger tap landed right on an existing text box or
          // image, so grab it (select, and move if this turns into a
          // drag) instead of panning - see _canBorderGrabWith for why
          // this is scoped to certain tools. allowOversizedGrab: false
          // here (only here - not for mouse/stylus below) because a
          // one-finger touch drag is also how panning/scrolling works;
          // without this, a swipe meant to scroll through the page that
          // happens to start on top of something big (e.g. a full-page
          // HTML snapshot - see _tooLargeForCasualGrab) drags that
          // element instead of panning underneath it.
          _primaryPointerId = event.pointer;
          _downLocal = local; // needed to tell a tap from a drag on pointer-up
          // Also arm the long-press menu here, not just under the Select
          // tool - Pen/Highlighter are what most people actually have
          // active most of the time, and a long-press on an image should
          // bring up Cut/Copy/Delete no matter which of these it finds
          // active, same as the tap-to-grab shortcut just above already
          // works regardless of tool.
          final grabbedId = _borderGrabTapCandidateId;
          if (grabbedId != null && _isImageElement(grabbedId)) {
            _armLongPress(grabbedId, local);
          }
        } else {
          _mode = _GestureMode.pan;
          _lastFocal = local;
          _lastSpan = null;
        }
      } else {
        // A second finger joining mid-gesture always takes over as
        // pinch-zoom, even if the first finger was mid-long-press on an
        // image - cancel that timer so it can't still fire afterward.
        _cancelLongPress();
        if (_mode == _GestureMode.select) {
          _finishSelectGesture();
          _primaryPointerId = null;
        } else if (_mode == _GestureMode.lasso) {
          // A second finger landing mid-lasso-drag hands off to
          // pinch/pan below - end the in-progress lasso first so its
          // draft outline doesn't linger (it'll have too few points to
          // select anything, per endLasso's own minimum, so this is
          // effectively just a clean cancel).
          widget.editController.endLasso();
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
      if (event.buttons == kSecondaryMouseButton) {
        // Right-click: opens a context menu on release (see
        // _onPointerUp/_showContextMenuAt) instead of panning or
        // performing the active tool's action.
        _mode = _GestureMode.contextMenuPending;
        return;
      }
      if (event.buttons == kMiddleMouseButton || tool == CanvasTool.pan) {
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
  bool _beginBorderGrabIfHit(
    Offset canvasPoint,
    Offset localScreenPoint, {
    bool allowOversizedGrab = true,
  }) {
    final handle = _hitTestResizeHandle(localScreenPoint);
    if (handle != null) {
      _mode = _GestureMode.resize;
      _borderGrabTapCandidateId = null;
      widget.editController.startResizeSelection(handle, canvasPoint);
      return true;
    }
    final id = _hitTestGrabbableElement(localScreenPoint);
    if (id == null) return false;
    if (!allowOversizedGrab && _tooLargeForCasualGrab(id)) return false;
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

  bool _isImageElement(String id) {
    for (final e in widget.editController.page.elements) {
      if (e.id == id) return e is ImageElement;
    }
    return false;
  }

  /// Whether [id]'s element covers most of the viewport on screen right
  /// now - true for something like a full-page HTML-import snapshot,
  /// false for an ordinary pasted photo or icon-sized picture. Used to
  /// scope the "tap/drag anywhere on it, no need to select first" touch
  /// shortcut (see _beginBorderGrabIfHit's allowOversizedGrab) away from
  /// elements big enough that a normal one-finger scroll swipe would
  /// otherwise almost always start on top of them.
  bool _tooLargeForCasualGrab(String id) {
    final el = _findElementById(id);
    if (el == null) return false;
    final viewport = widget.viewController.viewport;
    final viewportSize = viewport.viewportSize;
    if (viewportSize == Size.zero) return false;
    final screenRect = viewport.canvasRectToScreen(el.bounds);
    return screenRect.width > viewportSize.width * 0.6 || screenRect.height > viewportSize.height * 0.6;
  }

  CanvasElement? _findElementById(String id) {
    for (final e in widget.editController.page.elements) {
      if (e.id == id) return e;
    }
    return null;
  }

  // --- Long-press (touch) and right-click (mouse) context menus --------

  /// Starts (or restarts) the long-press timer for [elementId], a touch
  /// pointer that just landed on an image - see [_longPressTimer].
  void _armLongPress(String elementId, Offset downLocal) {
    _longPressTimer?.cancel();
    _longPressElementId = elementId;
    _longPressDownLocal = downLocal;
    final pointerId = _primaryPointerId;
    _longPressTimer = Timer(_longPressDuration, () => _fireLongPress(pointerId));
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressElementId = null;
    _longPressDownLocal = null;
  }

  void _fireLongPress(int? pointerId) {
    _longPressTimer = null;
    final id = _longPressElementId;
    _longPressElementId = null;
    // Bail if the finger already lifted, moved on to a different
    // gesture, or a second finger joined (pinch/pan takes over - see
    // _onPointerDown) since this timer was armed.
    if (id == null || pointerId == null || _primaryPointerId != pointerId) return;
    if (_touchPointerIds.length != 1) return;
    final el = _findElementById(id);
    if (el == null) return;
    // Consume the in-progress select/move gesture (started back in
    // _onPointerDown/_beginSelectGesture) so lifting the finger
    // afterward doesn't also register as a tap or a move - the total
    // delta is zero (the finger never moved, or this wouldn't have
    // fired), so this is a no-op as far as undo history goes.
    widget.editController.endMoveSelection();
    _mode = _GestureMode.none;
    _primaryPointerId = null;
    _touchPointerIds.remove(pointerId);
    _touchPositions.remove(pointerId);
    HapticFeedback.mediumImpact();
    final screenRect = widget.viewController.viewport.canvasRectToScreen(el.bounds);
    final renderBox = context.findRenderObject() as RenderBox;
    final globalAnchor = renderBox.localToGlobal(screenRect.bottomCenter);
    unawaited(_showImageMenu(globalAnchor, id));
  }

  /// Handles a right-click release: selects and shows the Cut/Copy/
  /// Delete menu if it landed on an image, otherwise shows the Paste
  /// menu at that point on empty canvas.
  void _showContextMenuAt(Offset globalPosition, Offset localPosition) {
    final hitId = _hitTestGrabbableElement(localPosition);
    if (hitId != null && _isImageElement(hitId)) {
      if (!widget.editController.selectedElementIds.contains(hitId)) {
        widget.editController.selectOnly(hitId);
      }
      unawaited(_showImageMenu(globalPosition, hitId));
    } else {
      final canvasPoint = widget.viewController.viewport.screenToCanvas(localPosition);
      unawaited(_showPasteMenu(globalPosition, canvasPoint));
    }
  }

  Future<void> _showImageMenu(Offset globalPosition, String elementId) async {
    final overlayBox = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlayBox.size),
      items: const [
        PopupMenuItem(value: 'cut', child: ListTile(leading: Icon(Icons.content_cut), title: Text('Cut'))),
        PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.content_copy), title: Text('Copy'))),
        PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete'))),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case 'cut':
        widget.editController.cutSelectedImage();
      case 'copy':
        widget.editController.copySelectedImage();
      case 'delete':
        widget.editController.deleteSelection();
    }
  }

  Future<void> _showPasteMenu(Offset globalPosition, Offset canvasPoint) async {
    final overlayBox = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlayBox.size),
      items: const [
        PopupMenuItem(value: 'paste', child: ListTile(leading: Icon(Icons.content_paste), title: Text('Paste'))),
      ],
    );
    if (selected == 'paste') {
      widget.onRequestPasteAt?.call(canvasPoint);
    }
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
    final box = _textBoxById(id);
    if (box == null) return; // only text boxes have anything to "edit" (or open)

    // A plain tap landing on an auto-detected URL opens it, instead of
    // registering toward double-click-to-edit below. This is the
    // Select tool, where the box's own TextField is otherwise
    // non-interactive (see _buildOverlayWidgets) - a tap here never
    // meant "place the cursor" anyway, which is what makes it a safe
    // place for "open this link" to live. Still want to edit a URL
    // you've already typed? Tap somewhere in the box that isn't the
    // link itself, or switch to the Text tool and double-tap as usual.
    final link = _urlAtLocalScreenPoint(box, upLocal);
    if (link != null) {
      _openDetectedLink(link);
      return;
    }

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
        _beginLassoToolGesture(canvasPoint, local);
      case CanvasTool.text:
        // See the matching comment in the touch branch of _onPointerDown:
        // don't place a new box on top of one that's already there.
        final existingTextBox = _textBoxAtCanvasPoint(canvasPoint);
        if (existingTextBox != null) {
          _mode = _GestureMode.none;
          // Ctrl+Click a link while actively editing opens it without
          // disturbing the normal click-to-place-cursor handling the
          // TextField does on its own (see _buildOverlayWidgets) - the
          // Select-tool, not-editing equivalent (a plain tap) lives in
          // _registerBorderGrabTapAndMaybeEditText. Touch has no Ctrl
          // key, so this is desktop/mouse-only for now.
          if (HardwareKeyboard.instance.isControlPressed) {
            final link = _urlAtLocalScreenPoint(existingTextBox, local);
            if (link != null) _openDetectedLink(link);
          }
        } else {
          _mode = _GestureMode.textPending;
        }
      case CanvasTool.select:
        _beginSelectGesture(canvasPoint, local);
      case CanvasTool.pan:
        _mode = _GestureMode.pan;
        _lastFocal = local;
        _lastSpan = null;
    }
  }

  /// Returns the id of whatever element got selected (null if this
  /// landed on a resize handle instead, or on empty canvas and started a
  /// lasso) - touch's pointer-down handler uses this to know whether to
  /// arm the long-press timer for an image (see [_armLongPress]).
  String? _beginSelectGesture(Offset canvasPoint, Offset localScreenPoint) {
    if (_hitTestRotateHandle(localScreenPoint)) {
      _mode = _GestureMode.rotate;
      widget.editController.startRotateSelection(canvasPoint);
      return null;
    }
    final handle = _hitTestResizeHandle(localScreenPoint);
    if (handle != null) {
      _mode = _GestureMode.resize;
      widget.editController.startResizeSelection(handle, canvasPoint);
      return null;
    }
    _mode = _GestureMode.select;
    final hitId = widget.editController.hitTestTopmost(canvasPoint);
    if (hitId != null) {
      if (!widget.editController.selectedElementIds.contains(hitId)) {
        widget.editController.selectOnly(hitId);
      }
      _selectIsMoving = true;
      widget.editController.startMoveSelection(canvasPoint);
    } else if (_hitsSelectionBounds(canvasPoint)) {
      // Landed inside the current selection's union bounding box, but
      // not precisely on one of its (often thin/sparse) strokes - see
      // _hitsSelectionBounds. Drag the whole group instead of
      // discarding it to start a new lasso right on top of it.
      _selectIsMoving = true;
      widget.editController.startMoveSelection(canvasPoint);
    } else {
      widget.editController.clearSelection();
      _selectIsMoving = false;
      widget.editController.startLasso(canvasPoint);
    }
    return hitId;
  }

  /// Returns the id of whatever already-selected element got grabbed for
  /// a move (null if this started a fresh lasso, or grabbed a resize
  /// handle instead). Shared by the Lasso tool's mouse/stylus/touch
  /// pointer-down handling - see _beginToolGesture and _onPointerDown.
  String? _beginLassoToolGesture(Offset canvasPoint, Offset localScreenPoint) {
    if (_hitTestRotateHandle(localScreenPoint)) {
      _mode = _GestureMode.rotate;
      widget.editController.startRotateSelection(canvasPoint);
      return null;
    }
    final handle = _hitTestResizeHandle(localScreenPoint);
    if (handle != null) {
      _mode = _GestureMode.resize;
      widget.editController.startResizeSelection(handle, canvasPoint);
      return null;
    }
    // Pressing on something that's already selected (from a prior lasso)
    // drags the whole current selection around, instead of clearing it
    // and starting a new lasso rectangle right on top of it. Pressing on
    // empty canvas - or on an element that *isn't* selected yet - still
    // starts a fresh lasso, same as before: the Lasso tool's job is
    // drawing lassos, not click-to-select-one-thing (that's what the
    // Select tool, and the OneNote-style border-grab shortcut, are for).
    final hitId = widget.editController.hitTestTopmost(canvasPoint);
    if (hitId != null && widget.editController.selectedElementIds.contains(hitId)) {
      _mode = _GestureMode.select;
      _selectIsMoving = true;
      widget.editController.startMoveSelection(canvasPoint);
      return hitId;
    }
    if (hitId == null && _hitsSelectionBounds(canvasPoint)) {
      // Landed inside the current lasso selection's bounding box, but
      // not precisely on one of its strokes - see _hitsSelectionBounds.
      // Pan/drag the whole selected group instead of starting a fresh
      // lasso over top of it.
      _mode = _GestureMode.select;
      _selectIsMoving = true;
      widget.editController.startMoveSelection(canvasPoint);
      return null;
    }
    _mode = _GestureMode.lasso;
    widget.editController.startLasso(canvasPoint);
    return null;
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

  /// The topmost text box whose bounds contain [canvasPoint], if any -
  /// like [_hitsExistingTextBox], but returns the element itself
  /// instead of just whether one was hit (needed to check for a link
  /// under a Ctrl+Click - see _beginToolGesture).
  TextBoxElement? _textBoxAtCanvasPoint(Offset canvasPoint) {
    for (final el in widget.editController.page.elements.reversed) {
      if (el is TextBoxElement && el.rect.contains(canvasPoint)) return el;
    }
    return null;
  }

  /// The [TextBoxElement] with this [id], if it's still on the page and
  /// is in fact a text box. A plain manual loop, matching the lookup
  /// style already used elsewhere in this file (e.g. _hitTestResizeHandle)
  /// rather than reaching for a firstOrNull extension this file doesn't
  /// otherwise define or import.
  TextBoxElement? _textBoxById(String id) {
    for (final el in widget.editController.page.elements) {
      if (el.id == id) return el is TextBoxElement ? el : null;
    }
    return null;
  }

  /// The [DetectedUrl] under [localScreenPoint] (screen space) inside
  /// [box], if any. Lays out the same text/style/width the box's own
  /// TextField actually renders with (see _buildOverlayWidgets and
  /// _fontStyle) so this hit test matches what's visually on screen at
  /// the current zoom level, then maps the tapped point to a character
  /// offset via TextPainter.getPositionForOffset and checks it against
  /// [findUrls].
  DetectedUrl? _urlAtLocalScreenPoint(TextBoxElement box, Offset localScreenPoint) {
    final viewport = widget.viewController.viewport;
    final screenRect = viewport.canvasRectToScreen(box.rect);
    const contentPadding = 4.0; // matches the TextField's contentPadding in _buildOverlayWidgets
    final local = localScreenPoint - screenRect.topLeft - const Offset(contentPadding, contentPadding);
    if (local.dx < 0 || local.dy < 0) return null;
    final text = _textControllers[box.id]?.text ?? box.text;
    final painter = TextPainter(
      text: TextSpan(
        text: text.isEmpty ? ' ' : text,
        style: _fontStyle(fontFamily: box.fontFamily, fontSize: box.fontSize * viewport.scale, color: box.color),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: (screenRect.width - contentPadding * 2).clamp(1.0, double.infinity));
    if (local.dy > painter.height) return null;
    final position = painter.getPositionForOffset(local);
    return urlAt(text, position.offset);
  }

  /// Opens [link], routed by [DetectedUrl.kind] - a web address through
  /// url_launcher, a local file through open_file (see the doc comment
  /// on findUrls in link_detection.dart for why those two can't share
  /// one code path).
  void _openDetectedLink(DetectedUrl link) {
    switch (link.kind) {
      case LinkKind.web:
        unawaited(_openWebLink(link.target));
      case LinkKind.localFile:
        unawaited(_openLocalFile(link.target));
    }
  }

  /// Opens the web address [target] in the system's default browser.
  /// Best-effort: if nothing on the device can handle it, or the
  /// platform launch call itself throws, this tells the user rather
  /// than crashing - same "never let a side action take down the app"
  /// spirit as LocalStore.deleteImageFile elsewhere in this codebase.
  Future<void> _openWebLink(String target) async {
    final uri = Uri.tryParse(target);
    if (uri == null) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $uri')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $uri')));
      }
    }
  }

  /// Opens the local file [rawPath] (a plain OS path, or a "file://"
  /// URI - both are what [findUrls] can hand back) with whatever
  /// application the OS has for it. Checks [widget.resolveEmbeddedLink]
  /// first - if this device (or a peer, via sync) already embedded a
  /// copy of this exact link, that's what actually gets opened, since
  /// [rawPath] itself may be a path from a *different* device (a
  /// Windows "C:\..." path means nothing on Android) - see
  /// NotePage.embeddedLinks. Only falls back to resolving [rawPath]
  /// itself (stripping a leading "file://" down to a normal path -
  /// open_file expects that, not a URI string) when there's no
  /// embedded copy. Best-effort, same spirit as _openWebLink: reports
  /// failure via a SnackBar instead of throwing.
  Future<void> _openLocalFile(String rawPath) async {
    try {
      final embedded = await widget.resolveEmbeddedLink?.call(rawPath);
      final path = embedded ?? resolveLocalFilePath(rawPath);
      final result = await OpenFile.open(path);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open $path${result.message.isEmpty ? '' : ': ${result.message}'}')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $rawPath')));
      }
    }
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

  /// Rotate-handle hit test, in screen space (so, like the resize
  /// handles, it stays a constant on-screen size regardless of zoom
  /// level) - only ever true when
  /// [PageEditController.canRotateSelection] is, since that's also what
  /// tells DraftOverlayPainter whether to draw the handle in the first
  /// place. The handle sits [kRotateHandleOffset] above the selection's
  /// union bounding box, centered on it horizontally - see the painter
  /// for the matching drawing code.
  bool _hitTestRotateHandle(Offset localScreenPoint) {
    final controller = widget.editController;
    if (!controller.canRotateSelection) return false;
    final bounds = controller.selectionBounds;
    if (bounds == null) return false;
    final screenRect = widget.viewController.viewport.canvasRectToScreen(bounds);
    final handleCenter = screenRect.topCenter - const Offset(0, kRotateHandleOffset);
    return (handleCenter - localScreenPoint).distance <= kRotateHandleHitRadius;
  }

  /// How far outside the selection's exact union bounding box a press
  /// still counts as "grabbing the selection" for [_hitsSelectionBounds] -
  /// canvas-space, same idea as the screen-space hit radii above but for
  /// a whole-selection drag rather than a small handle.
  static const double _selectionGrabMargin = 8.0;

  /// True when [canvasPoint] falls within the current selection's union
  /// bounding box (see [PageEditController.selectionBounds]), inflated
  /// by a small margin. A lasso-selected group of ink is often sparse -
  /// most of its bounding box is blank canvas between strokes - so
  /// without this, dragging to move the whole group meant landing
  /// precisely on one of the actual stroke pixels (via
  /// [PageEditController.hitTestTopmost]) or it would tear down the
  /// selection and start a brand new lasso instead. This gives the
  /// selection a pan/move grab area the same way the rotate handle
  /// already gives it a rotate one - see _beginSelectGesture/
  /// _beginLassoToolGesture, the only callers.
  bool _hitsSelectionBounds(Offset canvasPoint) {
    final controller = widget.editController;
    if (controller.selectedElementIds.isEmpty) return false;
    final bounds = controller.selectionBounds;
    if (bounds == null) return false;
    return bounds.inflate(_selectionGrabMargin).contains(canvasPoint);
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
      if (_longPressTimer != null &&
          _primaryPointerId == event.pointer &&
          (local - _longPressDownLocal!).distance > _longPressMoveTolerance) {
        // Moved enough that this is a drag, not a hold - let the normal
        // select/move handling below take it from here.
        _cancelLongPress();
      }
      if (_mode == _GestureMode.pan) {
        _updateTouchPan();
      } else if (_mode == _GestureMode.select && _primaryPointerId == event.pointer) {
        _updateSelectOrLasso(viewport.screenToCanvas(local));
      } else if (_mode == _GestureMode.lasso && _primaryPointerId == event.pointer) {
        widget.editController.updateLasso(viewport.screenToCanvas(local));
      } else if (_mode == _GestureMode.resize && _primaryPointerId == event.pointer) {
        widget.editController.updateResizeSelection(viewport.screenToCanvas(local));
      } else if (_mode == _GestureMode.rotate && _primaryPointerId == event.pointer) {
        widget.editController.updateRotateSelection(viewport.screenToCanvas(local));
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
      case _GestureMode.rotate:
        widget.editController.updateRotateSelection(viewport.screenToCanvas(local));
      case _GestureMode.pan:
        _updateMousePan(local);
      case _GestureMode.textPending:
      case _GestureMode.contextMenuPending:
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
      if (_longPressTimer != null && _primaryPointerId == event.pointer) {
        // Lifted before the long-press fired - a plain tap/select, which
        // the branches below already handle normally.
        _cancelLongPress();
      }
      if (_mode == _GestureMode.select && _primaryPointerId == event.pointer) {
        _finishSelectGesture();
        _registerBorderGrabTapAndMaybeEditText(event.localPosition);
        _mode = _GestureMode.none;
        _primaryPointerId = null;
      } else if (_mode == _GestureMode.lasso && _primaryPointerId == event.pointer) {
        widget.editController.endLasso();
        _mode = _GestureMode.none;
        _primaryPointerId = null;
      } else if (_mode == _GestureMode.resize && _primaryPointerId == event.pointer) {
        widget.editController.endResizeSelection();
        _mode = _GestureMode.none;
        _primaryPointerId = null;
      } else if (_mode == _GestureMode.rotate && _primaryPointerId == event.pointer) {
        widget.editController.endRotateSelection();
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
      case _GestureMode.rotate:
        widget.editController.endRotateSelection();
      case _GestureMode.textPending:
        _finishTextPlacement(event.localPosition, viewport);
      case _GestureMode.contextMenuPending:
        if ((event.localPosition - (_downLocal ?? event.localPosition)).distance <= 12) {
          _showContextMenuAt(event.position, event.localPosition);
        }
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
