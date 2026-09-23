import 'dart:io' show File, Platform;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../canvas/canvas_tools.dart';
import '../canvas/canvas_view_controller.dart';
import '../canvas/infinite_canvas.dart';
import '../canvas/link_detection.dart';
import '../canvas/page_edit_controller.dart';
import '../models/canvas_element.dart';
import '../models/page.dart';
import '../state/app_settings.dart';
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
      onContentChanged: (changes) =>
          library.persistPageEdit(widget.notebookId, widget.sectionId, widget.page.id, changes: changes),
      onTextCommitted: _embedLocalLinksIn,
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
        // The page's own title now lives in [_buildTitleHeader], as a big
        // OneNote-style heading above the canvas rather than squeezed
        // into this bar. This bar's title slot is otherwise empty space,
        // so that's where the font controls go instead - visible right
        // up top exactly when there's a text box selected/being edited,
        // rather than pushing the canvas down with a row of their own.
        titleSpacing: 0,
        title: AnimatedBuilder(
          animation: _editController,
          builder: (context, _) {
            final box = _selectedTextBox;
            return box == null ? const SizedBox.shrink() : _buildFormattingBar(context, box, readOnly);
          },
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
        child: Column(
          children: [
            _buildTitleHeader(context, readOnly),
            Expanded(
              child: Builder(
                builder: (context) {
                  // The canvas itself stays full-bleed (a drawing surface
                  // should use every pixel), but the floating toolbar and
                  // zoom controls need to stay clear of the system nav
                  // bar / gesture area at the bottom of the screen -
                  // otherwise they end up partly behind it, looking like
                  // they're "overlapping" system UI.
                  final bottomInset = MediaQuery.paddingOf(context).bottom;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: InfiniteCanvas(
                          editController: _editController,
                          viewController: _viewController,
                          onRequestPasteAt: _pasteAt,
                          resolveEmbeddedLink: _resolveEmbeddedFilePath,
                        ),
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        bottom: 8 + bottomInset,
                        // Collapsed to a slim edge handle (see
                        // CollapsedToolbarHandle) frees up the strip of
                        // page along the right edge the full toolbar
                        // would otherwise sit on top of - moved here
                        // (from the left) so writing on the left side
                        // of the page - where it tends to start - has
                        // the toolbar out of the way without needing to
                        // collapse it. context.watch here (not just
                        // inside the toolbar) because collapsing swaps
                        // out the whole widget, not just something
                        // inside it.
                        child: context.watch<AppSettings>().toolbarCollapsed
                            ? CollapsedToolbarHandle(
                                onExpand: () => context.read<AppSettings>().setToolbarCollapsed(false),
                              )
                            : IgnorePointer(
                                ignoring: readOnly,
                                child: Opacity(
                                  opacity: readOnly ? 0.4 : 1.0,
                                  child: CanvasToolbar(
                                    editController: _editController,
                                    onInsertImage: _pickAndInsertImage,
                                  ),
                                ),
                              ),
                      ),
                      Positioned(
                        left: 12,
                        bottom: 12 + bottomInset,
                        child: _ZoomControls(viewController: _viewController),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _weekdayNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];
  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  /// Formats like OneNote's page-info line: "Monday, February 24, 2025
  /// 12:24 PM". Uses lastModified rather than a separate created-at
  /// (which this app doesn't track) - close enough to OneNote's date
  /// line for a note-taking app that's usually looked at read fairly
  /// soon after it's written or edited.
  String _formatPageDate(DateTime dt) {
    final weekday = _weekdayNames[dt.weekday - 1];
    final month = _monthNames[dt.month - 1];
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$weekday, $month ${dt.day}, ${dt.year}    $hour12:$minute $ampm';
  }

  /// The page's title as a big heading anchored at the top of the page,
  /// with an underline and a "last edited" line beneath it - the same
  /// shape as OneNote's own page header, and (together with the
  /// panning limits in CanvasViewport) what makes the title read as the
  /// page's fixed anchor point rather than just another toolbar.
  Widget _buildTitleHeader(BuildContext context, bool readOnly) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
            ),
            padding: const EdgeInsets.only(bottom: 6),
            child: TextField(
              controller: _titleController,
              focusNode: _titleFocusNode,
              readOnly: readOnly,
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: 'Untitled page',
              ),
              style: theme.textTheme.headlineSmall,
              onSubmitted: _renamePage,
              onEditingComplete: () => _renamePage(_titleController.text),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatPageDate(widget.page.lastModified),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// The single selected [TextBoxElement], if there's exactly one - both
  /// an active selection (Select tool) and actively typing into a box
  /// (Text tool - see InfiniteCanvas's focus-gained handling) put it
  /// here, which is what lets [_buildFormattingBar] act on whichever one
  /// you're actually working with.
  TextBoxElement? get _selectedTextBox {
    if (_editController.selectedElementIds.length != 1) return null;
    final id = _editController.selectedElementIds.first;
    for (final el in _editController.page.elements) {
      if (el.id == id) return el is TextBoxElement ? el : null;
    }
    return null;
  }

  /// A slim OneNote-style formatting bar - font family and size - shown
  /// right below the title header whenever [box] is the one selected/
  /// being-edited text box, instead of buried in the side toolbar's
  /// popups.
  Widget _buildFormattingBar(BuildContext context, TextBoxElement box, bool readOnly) {
    // box.fontFamily is null for a text box that predates the font
    // feature (or was never explicitly restyled) - kDefaultTextFont is
    // what null effectively renders as (see PageEditController and
    // kTextFontChoices), so that's what the dropdown should show
    // selected rather than a value that isn't one of its own items.
    final currentFamily = box.fontFamily ?? kDefaultTextFont;
    return IgnorePointer(
      ignoring: readOnly,
      child: Opacity(
        opacity: readOnly ? 0.4 : 1.0,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.text_fields, size: 18),
            const SizedBox(width: 8),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: currentFamily,
                isDense: true,
                items: kTextFontChoices.entries
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.value,
                        child: Text(e.key, style: GoogleFonts.getFont(e.value)),
                      ),
                    )
                    .toList(),
                onChanged: (family) {
                  if (family != null) _editController.setFontFamily(family);
                },
              ),
            ),
            const SizedBox(width: 16),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              iconSize: 20,
              tooltip: 'Smaller',
              onPressed: () => _editController.setFontSize((box.fontSize - 2).clamp(10, 72)),
            ),
            SizedBox(width: 26, child: Text('${box.fontSize.round()}', textAlign: TextAlign.center)),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              iconSize: 20,
              tooltip: 'Larger',
              onPressed: () => _editController.setFontSize((box.fontSize + 2).clamp(10, 72)),
            ),
          ],
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
    // shortcut) - but only when this page-level FocusNode itself is the
    // one holding focus (node.hasPrimaryFocus), not some descendant like
    // a text box's own TextField. A text box being actively typed into is
    // now *also* added to selectedElementIds (so the font controls can
    // reach it - see the FocusNode listener in infinite_canvas.dart), so
    // checking selectedElementIds alone is no longer enough to tell "a
    // box is selected" apart from "a box is being typed into" - without
    // this check, every Backspace while typing was deleting the whole
    // box instead of a character. node.hasPrimaryFocus is false whenever
    // a descendant (the TextField) actually has focus, so this shortcut
    // naturally steps aside and lets normal text editing happen.
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.delete ||
            event.logicalKey == LogicalKeyboardKey.backspace) &&
        node.hasPrimaryFocus &&
        _editController.selectedElementIds.isNotEmpty) {
      _editController.deleteSelection();
      return KeyEventResult.handled;
    }
    if (!Platform.isWindows) return KeyEventResult.ignored;
    // node.hasPrimaryFocus (see the comment above) is what actually
    // makes good on this method's doc comment - without it, this was
    // stealing every Ctrl+V, including ones meant for a text box's own
    // paste (e.g. pasting a copied link/path into a note), before the
    // TextField ever saw the keystroke: this handler found no image on
    // the clipboard for plain text, did nothing, and returned handled
    // anyway, silently swallowing the paste.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        node.hasPrimaryFocus) {
      _pasteAt(_viewController.canvasCenter);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Scans a text box's just-committed content (see
  /// PageEditController.onTextCommitted) for local-file links (findUrls,
  /// LinkKind.localFile) this device hasn't already embedded for this
  /// page, and - if the referenced file actually exists right here right
  /// now - copies it into local storage via the same content-hash dedup
  /// LocalStore already uses for images (LocalStore.importLinkedFile),
  /// then records the mapping on the page (PageEditController.
  /// recordEmbeddedLink) so the note can still open it later from a
  /// *different* device, where the original path (often a Windows-only
  /// "C:\..." one) doesn't exist at all - see NotePage.embeddedLinks.
  /// Best-effort and silent: a path that doesn't resolve on this device
  /// (typed by hand, or simply unreachable) is just left as a plain,
  /// path-only link, exactly as before this existed.
  Future<void> _embedLocalLinksIn(String newText) async {
    final localLinks = findUrls(newText).where((u) => u.kind == LinkKind.localFile);
    for (final link in localLinks) {
      if (widget.page.embeddedLinks.containsKey(link.target)) continue;
      final basename = await _localStore.importLinkedFile(resolveLocalFilePath(link.target));
      if (basename != null && mounted) {
        _editController.recordEmbeddedLink(link.target, basename);
      }
    }
  }

  /// Given a tapped local-file link's raw target text, returns the path
  /// of an embedded copy of it on this device (see
  /// [_embedLocalLinksIn]/NotePage.embeddedLinks), if one is on record
  /// for this page AND actually present in local storage right now - or
  /// null if there's no embedded copy (an old link, or one that's never
  /// resolved on any device), in which case InfiniteCanvas falls back to
  /// the raw target itself, exactly as before embedding existed.
  Future<String?> _resolveEmbeddedFilePath(String rawTarget) async {
    final basename = widget.page.embeddedLinks[rawTarget];
    if (basename == null) return null;
    final imagesDir = await _localStore.imagesDirectory();
    final embeddedPath = '${imagesDir.path}/$basename';
    return await File(embeddedPath).exists() ? embeddedPath : null;
  }

  /// Pastes an image at [canvasPoint] - used by both Ctrl+V (pastes at
  /// the canvas center) and the canvas's right-click "Paste" menu item
  /// (pastes right where you clicked). Tries the in-app clipboard first
  /// (whatever was last Cut/Copied on the canvas itself, on this page or
  /// another one), and only falls back to the OS clipboard - the
  /// original Ctrl+V behavior, for pasting in a screenshot or an image
  /// copied from another app - if nothing's been cut/copied in-app.
  Future<void> _pasteAt(Offset canvasPoint) async {
    if (_editController.hasClipboardImage) {
      _editController.pasteClipboardImageAt(canvasPoint);
      return;
    }
    final bytes = await Pasteboard.image;
    if (bytes == null) return; // clipboard has no image on it (e.g. plain text) - nothing to do
    if (!mounted) return;
    final storedPath = await _localStore.importImageBytes(bytes, 'pasted.png');
    final aspectRatio = await _decodeAspectRatio(bytes);
    if (!mounted) return;
    _editController.addImageAt(canvasPoint, storedPath, aspectRatio: aspectRatio);
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
