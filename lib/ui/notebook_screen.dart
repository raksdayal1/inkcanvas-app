import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/notebook.dart';
import '../models/section.dart';
import '../state/library_controller.dart';
import '../sync/sync_engine.dart';
import 'page_screen.dart';

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
                SizedBox(width: 56, child: _SectionRail(notebook: notebook, library: library, readOnly: readOnly)),
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
          drawer: Drawer(
            child: Row(
              children: [
                SizedBox(width: 56, child: _SectionRail(notebook: notebook, library: library, readOnly: readOnly)),
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

class _SectionRail extends StatelessWidget {
  const _SectionRail({required this.notebook, required this.library, required this.readOnly});

  final Notebook notebook;
  final LibraryController library;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      // SafeArea so the "New section" button at the bottom isn't hidden
      // behind Android's system nav bar - the same class of overlap the
      // canvas's zoom controls had before.
      child: SafeArea(
        child: Column(
          children: [
            IconButton(
              icon: const Icon(Icons.home),
              iconSize: 28,
              tooltip: 'All notebooks',
              onPressed: library.goHome,
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: notebook.sections.length,
                itemBuilder: (context, index) {
                  final section = notebook.sections[index];
                  final selected = section.id == library.selectedSectionId;
                  return _SectionTab(
                    section: section,
                    readOnly: readOnly,
                    selected: selected,
                    onTap: () => library.openSection(section.id),
                    onRename: () => _renameSection(context, section),
                    onDelete: () => library.deleteSection(notebook.id, section.id),
                  );
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: readOnly ? 'Read-only — connect to edit' : 'New section',
              onPressed: readOnly ? null : () => _createSection(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createSection(BuildContext context) async {
    final title = await _promptForText(context, title: 'New section', initial: 'Section ${notebook.sections.length + 1}');
    if (title != null && title.isNotEmpty) {
      final color = AppTheme.notebookColors[notebook.sections.length % AppTheme.notebookColors.length];
      final section = await library.createSection(notebook.id, title, color);
      library.openSection(section.id);
    }
  }

  Future<void> _renameSection(BuildContext context, NoteSection section) async {
    final title = await _promptForText(context, title: 'Rename section', initial: section.title);
    if (title != null && title.isNotEmpty) {
      await library.renameSection(notebook.id, section.id, title);
    }
  }
}

class _SectionTab extends StatelessWidget {
  const _SectionTab({
    required this.section,
    required this.selected,
    required this.readOnly,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final NoteSection section;
  final bool selected;
  final bool readOnly;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      // Anchored at the actual press/click point (not a hardcoded guess -
      // that used to put the menu in the top-right corner regardless of
      // where the section tab actually was on screen) so it shows up
      // right by the folder icon you pressed. InkWell's onLongPress
      // doesn't hand us a position (unlike onSecondaryTapDown), so for
      // that one we anchor on the tab's own on-screen position instead.
      onLongPress: () => _showMenu(context, _globalCenterOf(context)),
      onSecondaryTapDown: (details) => _showMenu(context, details.globalPosition),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? section.color : section.color.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.folder, color: Colors.white, size: 20),
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
        if (!readOnly) PopupMenuItem(onTap: onDelete, child: const Text('Delete')),
        if (readOnly) const PopupMenuItem(enabled: false, child: Text('Read-only — connect to edit')),
      ],
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
          child: ListView.builder(
            itemCount: section.pages.length,
            itemBuilder: (context, index) {
              final page = section.pages[index];
              final selected = page.id == library.selectedPageId;
              return ListTile(
                dense: true,
                selected: selected,
                leading: const Icon(Icons.description_outlined),
                title: Text(page.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                // A visible delete button, not just the long-press menu -
                // long-press isn't a discoverable gesture with a mouse.
                trailing: readOnly
                    ? null
                    : IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: 'Delete page',
                      onPressed: () => library.deletePage(notebook.id, section.id, page.id),
                      ),
                onTap: () {
                  library.openPage(page.id);
                  if (Scaffold.of(context).isDrawerOpen) Navigator.pop(context);
                },
                onLongPress: readOnly ? null : () => _pageMenu(context, page.id, page.title),
              );
            },
          ),
        ),
      ],
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
      final newTitle = await _promptForText(context, title: 'Rename page', initial: title);
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

Future<String?> _promptForText(BuildContext context, {required String title, required String initial}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}
