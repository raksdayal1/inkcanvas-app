import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../state/library_controller.dart';
import '../sync/sync_engine.dart';
import 'notebook_screen.dart';
import 'widgets/connection_indicator.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    context.watch<SyncEngine>(); // rebuild notebook cards when connection status changes
    if (library.selectedNotebookId != null && library.selectedNotebook != null) {
      return const NotebookScreen();
    }
    return _NotebookGrid(library: library);
  }
}

class _NotebookGrid extends StatelessWidget {
  const _NotebookGrid({required this.library});

  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Notebooks'),
        toolbarHeight: 68,
        actions: [
          const ConnectionIndicator(large: true),
        ],
      ),
      body: library.notebooks.isEmpty
          ? const Center(
              child: Text(
                'No notebooks yet.\nTap + to create your first one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.8,
                ),
                itemCount: library.notebooks.length,
                itemBuilder: (context, index) {
                  final notebook = library.notebooks[index];
                  final ownedByMe = notebook.isOwnedBy(library.identity.id);
                  final readOnly = !library.canEdit(notebook.id);
                  final canDelete = library.canDeleteNotebook(notebook.id);
                  return _NotebookCard(
                    title: notebook.title,
                    color: notebook.color,
                    readOnly: readOnly,
                    subtitle: ownedByMe ? null : 'Owned by ${notebook.ownerDeviceName ?? 'another device'}',
                    onTap: () => library.openNotebook(notebook.id),
                    onDelete: canDelete ? () => _confirmDelete(context, library, notebook.id, notebook.title) : null,
                  );
                },
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createNotebook(context, library),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _createNotebook(BuildContext context, LibraryController library) async {
    final result = await showDialog<_NewNotebookResult>(
      context: context,
      builder: (context) => const _NewNotebookDialog(),
    );
    if (result != null) {
      await library.createNotebook(result.title, result.color);
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    LibraryController library,
    String notebookId,
    String title,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "$title"?'),
        content: const Text('This deletes all sections and pages inside it. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await library.deleteNotebook(notebookId);
      } on NotYourNotebookException {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Only the device that owns this notebook can delete it.")),
          );
        }
      }
    }
  }
}

class _NotebookCard extends StatelessWidget {
  const _NotebookCard({
    required this.title,
    required this.color,
    required this.readOnly,
    required this.subtitle,
    required this.onTap,
    required this.onDelete,
  });

  final String title;
  final Color color;
  final bool readOnly;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onDelete,
        // Long-press already deletes (touch-friendly), but that's not a
        // discoverable gesture with a mouse - right-click and the small
        // trash icon below give Windows/desktop users an obvious way in.
        onSecondaryTapDown: onDelete == null ? null : (_) => onDelete!(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 90,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                    child: const Align(
                      alignment: Alignment.bottomRight,
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.book, color: Colors.white70),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (subtitle != null)
                    Text(
                      readOnly ? '$subtitle · read-only' : subtitle!,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
              if (onDelete != null)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Tooltip(
                    message: 'Delete notebook',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: onDelete,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.delete_outline, size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                )
              else if (readOnly)
                // Can't edit OR delete this one right now (owned by the
                // other device, not connected to it).
                const Positioned(
                  right: 0,
                  top: 0,
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.lock_outline, size: 16, color: Colors.white70),
                  ),
                )
              else
                // Editable over a live connection, but only its owner
                // may delete it - a subtler hint than the lock icon,
                // since this one isn't actually read-only.
                Positioned(
                  right: 0,
                  top: 0,
                  child: Tooltip(
                    message: "Only ${subtitle ?? 'its owning device'} can delete this notebook",
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.no_accounts_outlined, size: 16, color: Colors.white70),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewNotebookResult {
  _NewNotebookResult(this.title, this.color);
  final String title;
  final Color color;
}

class _NewNotebookDialog extends StatefulWidget {
  const _NewNotebookDialog();

  @override
  State<_NewNotebookDialog> createState() => _NewNotebookDialogState();
}

class _NewNotebookDialogState extends State<_NewNotebookDialog> {
  final _controller = TextEditingController();
  Color _color = AppTheme.notebookColors.first;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New notebook'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Notebook name'),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: AppTheme.notebookColors.map((c) {
              final selected = c == _color;
              return GestureDetector(
                onTap: () => setState(() => _color = c),
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: c,
                  child: selected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                ),
              );
            }).toList(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final title = _controller.text.trim();
            if (title.isEmpty) return;
            Navigator.pop(context, _NewNotebookResult(title, _color));
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
