import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/notebook.dart';
import '../models/page.dart';
import '../models/section.dart';
import '../state/library_controller.dart';
import '../sync/sync_engine.dart';
import 'page_screen.dart';
import 'widgets/notebook_dialogs.dart';

/// OneNote-style layout: a colored section rail, a page list for the
/// selected section, and the canvas for the selected page. On narrow
/// (phone/tablet-portrait) screens the rail and page list collapse into a
/// drawer so the canvas gets the full width, matching how OneNote's
/// mobile app behaves versus its desktop layout.
class NotebookScreen extends StatelessWidget {
  const NotebookScreen({super.key});

  static const double _wideBreakpoint = 900;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    context.watch<SyncEngine>(); // rebuild rail/page-list when connection status changes
    final notebook = library.selectedNotebook;
    if (notebook == null) return const SizedBox.shrink();
    final readOnly = !library.canEdit(notebook.id);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;
        if (wide) {
          return Scaffold(
            body: Row(
              children: [
                SizedBox(width: 200, child: _SectionRail(notebook: notebook, library: library, readOnly: readOnly)),
                SizedBox(width: 220, child: _PageList(notebook: notebook, library: library, readOnly: readOnly)),
                const VerticalDivider(width: 1),
                Expanded(child: _CanvasArea(notebook: notebook, library: library)),
              ],
            ),
          );
        }
        // Narrow layout: no app bar of its own — a nested Scaffold inside
        // PageScreen already provides one (page title, background-style
        // menu), and stacking a second bar on top of it would waste half
        // the screen on a phone. Instead we grab this Scaffold's own
        // drawer control via Builder and hand it down so PageScreen's app
        // bar can open it with a normal hamburger button.
        return Scaffold(
          // Explicit width: Flutter's default Drawer width (~304dp) was
          // fine back when the rail was a narrow 56dp icon-only column,
          // but now that it needs real room for notebook/section names
          // (see _SectionRail), the default left almost nothing for the
          // page list beside it - its header text and page titles were
          // getting squeezed down to nothing. Wide enough for the rail's
          // 200 plus a page list that can still show a full page title.
          drawer: Drawer(
            width: 440,
            child: Row(
              children: [
                SizedBox(width: 200, child: _SectionRail(notebook: notebook, library: library, readOnly: readOnly)),
                Expanded(child: _PageList(notebook: notebook, library: library, readOnly: readOnly)),
              ],
            ),
          ),
          body: Builder(
            builder: (drawerContext) => _CanvasArea(
              notebook: notebook,
              library: library,
              onOpenDrawer: () => Scaffold.of(drawerContext).openDrawer(),
            ),
          ),
        );
      },
    );
  }
}

class _SectionRail extends StatefulWidget {
  const _SectionRail({required this.notebook, required this.library, required this.readOnly});

  final Notebook notebook;
  final LibraryController library;
  final bool readOnly;

  @override
  State<_SectionRail> createState() => _SectionRailState();
}

class _SectionRailState extends State<_SectionRail> {
  // Which notebooks currently show their sections - OneNote-style, more
  // than one notebook can be expanded at once. The currently open
  // notebook starts expanded so its sections are visible right away.
  // Session-only: resets if NotebookScreen itself gets torn down and
  // rebuilt (e.g. going Home and back in), which is a reasonable
  // default rather than something worth persisting to disk.
  final Set<String> _expandedNotebookIds = {};

  @override
  void initState() {
    super.initState();
    _expandedNotebookIds.add(widget.notebook.id);
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.home),
              title: const Text('All notebooks'),
              onTap: library.goHome,
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: library.notebooks.length,
                itemBuilder: (context, index) {
                  final nb = library.notebooks[index];
                  final isOpen = nb.id == widget.notebook.id;
                  final expanded = _expandedNotebookIds.contains(nb.id);
                  final nbReadOnly = !library.canEdit(nb.id);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _NotebookRow(
                        notebook: nb,
                        isOpen: isOpen,
                        expanded: expanded,
                        canRename: !nbReadOnly,
                        canDelete: library.canDeleteNotebook(nb.id),
                        onToggleExpand: () => setState(() {
                          if (!_expandedNotebookIds.add(nb.id)) _expandedNotebookIds.remove(nb.id);
                        }),
                        onOpen: () {
                          if (!isOpen) library.openNotebook(nb.id);
                          setState(() => _expandedNotebookIds.add(nb.id));
                        },
                        onRename: () => renameNotebookFlow(context, library, nb),
                        onDelete: () => deleteNotebookFlow(context, library, nb),
                      ),
                      if (expanded)
                        for (final section in nb.sections)
                          _SectionRow(
                            section: section,
                            selected: isOpen && section.id == library.selectedSectionId,
                            readOnly: nbReadOnly,
                            onTap: () {
                              if (!isOpen) library.openNotebook(nb.id);
                              library.openSection(section.id);
                            },
                            onRename: () => _renameSection(context, library, nb, section),
                            onChangeColor: () => _changeSectionColor(context, library, nb, section),
                            onDelete: () => library.deleteSection(nb.id, section.id),
                          ),
                      if (expanded && !nbReadOnly) _AddSectionRow(onTap: () => _createSection(context, library, nb)),
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

  Future<void> _createSection(BuildContext context, LibraryController library, Notebook nb) async {
    final title = await promptForText(context, title: 'New section', initial: 'Section ${nb.sections.length + 1}');
    if (title == null || title.isEmpty) return;
    final defaultColor = AppTheme.notebookColors[nb.sections.length % AppTheme.notebookColors.length];
    if (!context.mounted) return;
    final color = await promptForColor(context, title: 'Section color', initial: defaultColor) ?? defaultColor;
    final section = await library.createSection(nb.id, title, color);
    if (nb.id != widget.notebook.id) library.openNotebook(nb.id);
    library.openSection(section.id);
  }

  Future<void> _changeSectionColor(
    BuildContext context,
    LibraryController library,
    Notebook nb,
    NoteSection section,
  ) async {
    final color = await promptForColor(context, title: 'Section color', initial: section.color);
    if (color != null) {
      await library.changeSectionColor(nb.id, section.id, color);
    }
  }

  Future<void> _renameSection(
    BuildContext context,
    LibraryController library,
    Notebook nb,
    NoteSection section,
  ) async {
    final title = await promptForText(context, title: 'Rename section', initial: section.title);
    if (title != null && title.isNotEmpty) {
      await library.renameSection(nb.id, section.id, title);
    }
  }
}

/// One notebook's header row in the rail: its name (not just a colored
/// icon, unlike the old icon-only rail) plus a chevron to expand/collapse
/// its sections without switching to it, and long-press/right-click for
/// Rename/Delete - matches OneNote desktop's look of a notebook list
/// with each one's sections nested directly underneath it.
class _NotebookRow extends StatelessWidget {
  const _NotebookRow({
    required this.notebook,
    required this.isOpen,
    required this.expanded,
    required this.canRename,
    required this.canDelete,
    required this.onToggleExpand,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final Notebook notebook;
  final bool isOpen;
  final bool expanded;
  final bool canRename;
  final bool canDelete;
  final VoidCallback onToggleExpand;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      onLongPress: () => _showMenu(context, _globalCenterOf(context)),
      onSecondaryTapDown: (details) => _showMenu(context, details.globalPosition),
      child: Container(
        color: isOpen ? Theme.of(context).colorScheme.surfaceContainerHigh : null,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            IconButton(
              icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 20),
              tooltip: expanded ? 'Collapse' : 'Expand',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: onToggleExpand,
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(color: notebook.color, borderRadius: BorderRadius.circular(4)),
              child: const Icon(Icons.book, color: Colors.white, size: 14),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                notebook.title,
                style: const TextStyle(fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Offset _globalCenterOf(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox;
    return renderBox.localToGlobal(renderBox.size.center(Offset.zero));
  }

  void _showMenu(BuildContext context, Offset globalPosition) {
    showMenu(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & MediaQuery.sizeOf(context),
      ),
      items: [
        if (canRename) PopupMenuItem(onTap: onRename, child: const Text('Rename')),
        if (canDelete) PopupMenuItem(onTap: onDelete, child: const Text('Delete')),
        if (!canRename && !canDelete)
          const PopupMenuItem(enabled: false, child: Text('Read-only — connect to edit')),
      ],
    );
  }
}

/// One section row, nested under its notebook's [_NotebookRow] - shown
/// with its name (not just a colored folder icon, unlike the old rail)
/// and indented to read as belonging to the notebook above it.
class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.section,
    required this.selected,
    required this.readOnly,
    required this.onTap,
    required this.onRename,
    required this.onChangeColor,
    required this.onDelete,
  });

  final NoteSection section;
  final bool selected;
  final bool readOnly;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onChangeColor;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: () => _showMenu(context, _globalCenterOf(context)),
      onSecondaryTapDown: (details) => _showMenu(context, details.globalPosition),
      child: Container(
        color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
        padding: const EdgeInsets.only(left: 44, right: 8, top: 6, bottom: 6),
        child: Row(
          children: [
            Container(width: 4, height: 16, color: section.color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                section.title,
                style: TextStyle(fontWeight: selected ? FontWeight.bold : FontWeight.normal),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Offset _globalCenterOf(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox;
    return renderBox.localToGlobal(renderBox.size.center(Offset.zero));
  }

  void _showMenu(BuildContext context, Offset globalPosition) {
    showMenu(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & MediaQuery.sizeOf(context),
      ),
      items: [
        if (!readOnly) PopupMenuItem(onTap: onRename, child: const Text('Rename')),
        if (!readOnly) PopupMenuItem(onTap: onChangeColor, child: const Text('Change color')),
        if (!readOnly) PopupMenuItem(onTap: onDelete, child: const Text('Delete')),
        if (readOnly) const PopupMenuItem(enabled: false, child: Text('Read-only — connect to edit')),
      ],
    );
  }
}

/// The "+ New Section" link at the bottom of an expanded notebook's own
/// section list - matches OneNote's inline per-notebook add-section
/// affordance, replacing the old rail's single add button that only
/// ever worked on whichever notebook happened to be open.
class _AddSectionRow extends StatelessWidget {
  const _AddSectionRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: 44, right: 8, top: 6, bottom: 10),
        child: Row(
          children: [
            Icon(Icons.add, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text('New Section', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ],
        ),
      ),
    );
  }
}

class _PageList extends StatelessWidget {
  const _PageList({required this.notebook, required this.library, required this.readOnly});

  final Notebook notebook;
  final LibraryController library;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final section = library.selectedSection;
    if (section == null) {
      return const Center(child: Text('Select a section'));
    }
    // SafeArea to match _SectionRail right next to it - without this,
    // the header below started right at y=0 while the rail's Home
    // button (inside its own SafeArea) started below any top system
    // inset, throwing the two out of line with each other.
    return SafeArea(
      child: Column(
      children: [
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  section.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.note_add),
                tooltip: readOnly ? 'Read-only — connect to edit' : 'New page',
                onPressed: readOnly
                    ? null
                    : () async {
                      final page = await library.createPage(notebook.id, section.id, 'Page ${section.pages.length + 1}');
                      library.openPage(page.id);
                      },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          // Read-only notebooks can't be reordered either (there's
          // nowhere to persist the change to), so they keep the plain
          // non-reorderable list.
          child: readOnly
              ? ListView.builder(
                  itemCount: section.pages.length,
                  itemBuilder: (context, index) => _pageTile(context, section.pages[index]),
                )
              : ReorderableListView.builder(
                  itemCount: section.pages.length,
                  // We supply our own long-press-anywhere-on-the-tile
                  // drag start below via ReorderableDelayedDragStartListener,
                  // instead of the default handle Flutter would otherwise
                  // stack on the trailing edge on desktop - that would sit
                  // right on top of the "more options" button below.
                  buildDefaultDragHandles: false,
                  onReorder: (oldIndex, newIndex) {
                    unawaited(library.reorderPage(notebook.id, section.id, oldIndex, newIndex));
                  },
                  itemBuilder: (context, index) {
                    final page = section.pages[index];
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(page.id),
                      index: index,
                      child: _pageTile(context, page),
                    );
                  },
                ),
        ),
      ],
      ),
    );
  }

  // Rename/delete live in the _pageMenu popup (reached below), not a
  // permanently-visible trailing button next to the icon - so the row
  // still reads as just a name plus the "more options" button. Holding
  // down anywhere else on the tile is reserved for drag-to-reorder (see
  // the ReorderableDelayedDragStartListener wrapping this in build()),
  // so unlike before, long-press no longer opens this menu - right-click
  // (mouse) still does, alongside the button.
  Widget _pageTile(BuildContext context, NotePage page) {
    final selected = page.id == library.selectedPageId;
    return GestureDetector(
      onSecondaryTap: readOnly ? null : () => _pageMenu(context, page.id, page.title),
      child: ListTile(
        dense: true,
        selected: selected,
        leading: const Icon(Icons.description_outlined),
        title: Text(page.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: readOnly
            ? null
            : IconButton(
                icon: const Icon(Icons.more_vert),
                tooltip: 'Page options',
                onPressed: () => _pageMenu(context, page.id, page.title),
              ),
        onTap: () {
          library.openPage(page.id);
          if (Scaffold.of(context).isDrawerOpen) Navigator.pop(context);
        },
      ),
    );
  }

  Future<void> _pageMenu(BuildContext context, String pageId, String title) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 'rename'), child: const Text('Rename')),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Delete')),
        ],
      ),
    );
    final section = library.selectedSection;
    if (section == null) return;
    if (action == 'rename') {
      final newTitle = await promptForText(context, title: 'Rename page', initial: title);
      if (newTitle != null && newTitle.isNotEmpty) {
        await library.renamePage(notebook.id, section.id, pageId, newTitle);
      }
    } else if (action == 'delete') {
      await library.deletePage(notebook.id, section.id, pageId);
    }
  }
}

class _CanvasArea extends StatelessWidget {
  const _CanvasArea({required this.notebook, required this.library, this.onOpenDrawer});

  final Notebook notebook;
  final LibraryController library;
  final VoidCallback? onOpenDrawer;

  @override
  Widget build(BuildContext context) {
    final section = library.selectedSection;
    final page = library.selectedPage;
    if (section == null || page == null) {
      return const Center(child: Text('Select or create a page'));
    }
    return PageScreen(
      key: ValueKey(page.id),
      notebookId: notebook.id,
      sectionId: section.id,
      page: page,
      onOpenDrawer: onOpenDrawer,
    );
  }
}

