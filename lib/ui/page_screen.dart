import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../canvas/canvas_view_controller.dart';
import '../canvas/infinite_canvas.dart';
import '../canvas/page_edit_controller.dart';
import '../models/page.dart';
import '../state/library_controller.dart';
import '../storage/local_store.dart';
import '../sync/sync_engine.dart';
import 'widgets/connection_indicator.dart';
import 'widgets/toolbar.dart';

/// Hosts one page's [InfiniteCanvas] plus its toolbar and app bar. Given a
/// [ValueKey(page.id)] by its caller, so Flutter tears down and rebuilds
/// this whole State (and therefore gets a fresh [PageEditController] /
/// [CanvasViewController]) whenever the user switches pages.
class PageScreen extends StatefulWidget {
  const PageScreen({
    super.key,
    required this.notebookId,
    required this.sectionId,
    required this.page,
    this.onOpenDrawer,
  });

  final String notebookId;
  final String sectionId;
  final NotePage page;

  /// Set on narrow (phone) layouts so the app bar can show a normal
  /// hamburger button that opens the *outer* Scaffold's drawer (sections +
  /// pages) — this Scaffold has no drawer of its own. Null on wide
  /// (desktop) layouts, where sections/pages already have their own rail.
  final VoidCallback? onOpenDrawer;

  @override
  State<PageScreen> createState() => _PageScreenState();
}

class _PageScreenState extends State<PageScreen> {
  late final PageEditController _editController;
  late final CanvasViewController _viewController;
  final LocalStore _localStore = LocalStore();
  late final TextEditingController _titleController;
  final FocusNode _titleFocusNode = FocusNode();
  late DateTime _lastKnownPageModified;

  @override
  void initState() {
    super.initState();
    final library = context.read<LibraryController>();
    _editController = PageEditController(
      widget.page,
      onContentChanged: () => library.persistPageEdit(widget.notebookId, widget.sectionId, widget.page.id),
    );
    _viewController = CanvasViewController();
    _titleController = TextEditingController(text: widget.page.title);
    _lastKnownPageModified = widget.page.lastModified;
    // onSubmitted/onEditingComplete below only fire on an explicit Enter
    // press - tapping away to the canvas instead (very much the normal
    // way to finish here) never fired either one, so a typed rename was
    // silently discarded the moment focus left the field. Commit on
    // losing focus too, same as the canvas's own text boxes already do.
    _titleFocusNode.addListener(_onTitleFocusChanged);
  }

  void _onTitleFocusChanged() {
    if (!_titleFocusNode.hasFocus) _renamePage(_titleController.text);
  }

  @override
  void dispose() {
    _titleFocusNode.removeListener(_onTitleFocusChanged);
    _editController.dispose();
    _viewController.dispose();
    _titleController.dispose();
    _titleFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    context.watch<SyncEngine>(); // rebuild this page when connection status changes
    final readOnly = !library.canEdit(widget.notebookId);
    _editController.readOnly = readOnly;
    // A sync update merges fresh content into this exact NotePage object
    // in place (see LibraryController.applySyncedNotebook), so it won't
    // show up as a *new* widget.page - only as a changed lastModified on
    // the same one. Catch that here and push it into the canvas right
    // away instead of only catching up once the user navigates away and
    // back to this page.
    //
    // lastModified alone can't tell a peer's edit apart from this
    // device's own drawing, though - a completed stroke bumps it too,
    // and this build() re-runs on every unrelated rebuild (e.g.
    // SyncEngine's periodic discovery tick), so gate the actual refresh
    // on library.consumeSyncedPageUpdate - it only answers true right
    // after a genuine sync merge touched this exact page. Otherwise
    // calling applyExternalUpdate for our own edits was wiping out
    // whatever stroke the user was mid-drawing at the time.
    if (widget.page.lastModified != _lastKnownPageModified) {
      _lastKnownPageModified = widget.page.lastModified;
      if (library.consumeSyncedPageUpdate(widget.page.id)) {
        _editController.applyExternalUpdate(widget.page);
        if (!_titleFocusNode.hasFocus) _titleController.text = widget.page.title;
      }
    }
    return Scaffold(
      appBar: AppBar(
        // The app-wide theme turns AppBar elevation off entirely (see
        // AppTheme), which combined with the default background being
        // barely distinguishable from a plain white page left this
        // looking like loose icons floating over the canvas rather than
        // an actual toolbar. Giving it the same tint as the section
        // rail/page-list header plus a sliver of shadow makes it read
        // as one cohesive bar again.
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        elevation: 2,
        leading: widget.onOpenDrawer == null
            ? null
            : IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer),
        title: TextField(
          controller: _titleController,
          focusNode: _titleFocusNode,
          readOnly: readOnly,
          decoration: const InputDecoration(border: InputBorder.none),
          style: Theme.of(context).textTheme.titleMedium,
          onSubmitted: _renamePage,
          onEditingComplete: () => _renamePage(_titleController.text),
        ),
        actions: [
          const ConnectionIndicator(),
          PopupMenuButton<PageBackground>(
            enabled: !readOnly,
            tooltip: 'Page style',
            icon: const Icon(Icons.grid_on),
            initialValue: widget.page.background,
            onSelected: (bg) {
              setState(() => widget.page.background = bg);
              context.read<LibraryController>().persistPageEdit(widget.notebookId, widget.sectionId, widget.page.id);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: PageBackground.plain, child: Text('Plain')),
              PopupMenuItem(value: PageBackground.lined, child: Text('Lined')),
              PopupMenuItem(value: PageBackground.grid, child: Text('Grid')),
            ],
          ),
        ],
        bottom: readOnly
            ? PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Container(
                  width: double.infinity,
                  color: Colors.orange.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: const Text(
                    'Read-only — connect to the owning device to edit',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              )
            : null,
      ),
      body: Focus(
        // Grabs keyboard focus for the page by default so Ctrl+V has
        // somewhere to land even before the user has tapped anything.
        // This never fights a text box's own focus: Flutter delivers key
        // events to whichever widget currently holds focus first, and a
        // focused TextField's built-in paste handling consumes Ctrl+V
        // itself (pasting text, as normal) before it would ever bubble up
        // to this ancestor.
        autofocus: true,
        onKeyEvent: _handlePageKeyEvent,
        child: Builder(
          builder: (context) {
            // The canvas itself stays full-bleed (a drawing surface should
            // use every pixel), but the floating toolbar and zoom controls
            // need to stay clear of the system nav bar / gesture area at
            // the bottom of the screen - otherwise they end up partly
            // behind it, looking like they're "overlapping" system UI.
            final bottomInset = MediaQuery.paddingOf(context).bottom;
            return Stack(
              children: [
                Positioned.fill(
                  child: InfiniteCanvas(editController: _editController, viewController: _viewController),
                ),
                Positioned(
                  left: 8,
                  top: 8,
                  bottom: 8 + bottomInset,
                  child: IgnorePointer(
                    ignoring: readOnly,
                    child: Opacity(
                      opacity: readOnly ? 0.4 : 1.0,
                      child: CanvasToolbar(editController: _editController, onInsertImage: _pickAndInsertImage),
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 12 + bottomInset,
                  child: _ZoomControls(viewController: _viewController),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Ctrl+V anywhere on the page (as long as no text box has stolen focus
  /// for its own paste handling — see the [Focus] widget above) reads an
  /// image straight off the system clipboard and drops it onto the
  /// canvas, alongside the existing file-picker-based "Insert image".
  /// Windows-only for now: clipboard *image* reading needs no extra setup
  /// there, but on Android it needs FileProvider/manifest wiring we
  /// haven't added, and Android has no Ctrl+V gesture to trigger this
  /// from in the first place.
  KeyEventResult _handlePageKeyEvent(FocusNode node, KeyEvent event) {
    // Delete/Backspace removes the current selection (a selected text
    // box or image, grabbed via the Select tool or the mouse edge-grab
    // shortcut) - as long as nothing has stolen keyboard focus for its
    // own use. A text box actively being edited holds that focus itself,
    // so its own Delete/Backspace handling (editing its text) always
    // gets first crack and this is never reached while typing - only
    // when something is selected but not being typed into.
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.delete ||
            event.logicalKey == LogicalKeyboardKey.backspace) &&
        _editController.selectedElementIds.isNotEmpty) {
      _editController.deleteSelection();
      return KeyEventResult.handled;
    }
    if (!Platform.isWindows) return KeyEventResult.ignored;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed) {
      _pasteImageFromClipboard();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _pasteImageFromClipboard() async {
    final bytes = await Pasteboard.image;
    if (bytes == null) return; // clipboard has no image on it (e.g. plain text) - nothing to do
    if (!mounted) return;
    final storedPath = await _localStore.importImageBytes(bytes, 'pasted.png');
    final aspectRatio = await _decodeAspectRatio(bytes);
    if (!mounted) return;
    _editController.addImageAt(_viewController.canvasCenter, storedPath, aspectRatio: aspectRatio);
  }

  /// The source image's real width/height ratio, so the box it's dropped
  /// into (and any later resize of it) matches the picture's actual
  /// proportions instead of a generic fixed box - see the comment on
  /// [ImageElement.aspectRatio] for why that matters. Returns null (and
  /// [PageEditController.addImageAt] falls back to its old fixed shape)
  /// if the bytes can't be decoded as an image for any reason.
  Future<double?> _decodeAspectRatio(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final width = frame.image.width;
      final height = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (width <= 0 || height <= 0) return null;
      return width / height;
    } catch (_) {
      return null;
    }
  }

  void _renamePage(String value) {
    final title = value.trim();
    if (title.isEmpty) {
      _titleController.text = widget.page.title; // don't let an empty field stick around unsaved
      return;
    }
    if (title == widget.page.title) return;
    context.read<LibraryController>().renamePage(widget.notebookId, widget.sectionId, widget.page.id, title);
  }

  Future<void> _pickAndInsertImage() async {
    // file_picker 12+ dropped FilePicker.platform / FilePickerResult in
    // favor of static methods returning PlatformFile directly, with
    // bytes read via readAsBytes() instead of relying on a real file
    // path (which isn't meaningful on every platform).
    // On Windows, file_picker's dialog defaults to not being owned by the
    // app's window (WindowsOptions.lockParentWindow defaults to false) - it
    // can then open without focus behind the main window, which looks
    // exactly like "nothing happened" when you click the button. Locking it
    // to the parent window makes sure it actually comes to the front.
    final picked = await FilePicker.pickFile(
      type: FileType.image,
      windowsOptions: const WindowsOptions(lockParentWindow: true),
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final storedPath = await _localStore.importImageBytes(bytes, picked.name);
    final aspectRatio = await _decodeAspectRatio(bytes);
    if (!mounted) return;
    _editController.addImageAt(_viewController.canvasCenter, storedPath, aspectRatio: aspectRatio);
  }
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({required this.viewController});

  final CanvasViewController viewController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: viewController,
      builder: (context, _) {
        // Wrapping in an opaque Listener guarantees this whole control -
        // not just the icon glyphs themselves - claims any pointer that
        // comes down inside its bounds, so a tap that's a few pixels off
        // (easy to do with a stylus tip, especially near a screen corner)
        // can never fall through to the canvas underneath and start a
        // pen stroke instead of changing the zoom.
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) {},
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(Icons.remove), onPressed: viewController.zoomOut),
                  SizedBox(
                    width: 52,
                    child: Text('${(viewController.scale * 100).round()}%', textAlign: TextAlign.center),
                  ),
                  IconButton(icon: const Icon(Icons.add), onPressed: viewController.zoomIn),
                  IconButton(
                    icon: const Icon(Icons.center_focus_strong),
                    tooltip: 'Reset zoom',
                    onPressed: viewController.resetZoom,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
