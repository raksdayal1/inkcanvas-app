import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../state/library_controller.dart';
import '../sync/sync_engine.dart';
import 'notebook_screen.dart';
import 'widgets/connection_indicator.dart';
import 'widgets/notebook_dialogs.dart';

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
          PopupMenuButton<String>(
            tooltip: 'Library backup',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'export') {
                unawaited(_exportBackup(context, library));
              } else if (value == 'import') {
                unawaited(_importBackup(context, library));
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'export', child: Text('Export library backup')),
              PopupMenuItem(value: 'import', child: Text('Import library backup')),
            ],
          ),
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
                    onRename: readOnly ? null : () => renameNotebookFlow(context, library, notebook),
                    onDelete: canDelete ? () => deleteNotebookFlow(context, library, notebook) : null,
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

  /// Saves the whole library (every notebook, section, page, and every
  /// image any of them reference - see LibraryController.exportBackupBytes)
  /// to a file the user picks, via file_picker's native save dialog -
  /// this is a plain file on disk, independent of Android's own backup
  /// system (which android:allowBackup="false" in AndroidManifest.xml
  /// deliberately turns off) and of this device's signing key, so it
  /// survives a forced uninstall/reinstall that wipes everything else.
  Future<void> _exportBackup(BuildContext context, LibraryController library) async {
    try {
      final bytes = await library.exportBackupBytes();
      final timestamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final uri = await FilePicker.saveFile(
        fileName: 'na-pustakam-backup-$timestamp.npbk',
        bytes: bytes,
        dialogTitle: 'Save Na-Pustakam library backup',
        // Without this, the save dialog can open behind the main window
        // on Windows and look like nothing happened - see the identical
        // fix on the image-insertion picker in page_screen.dart.
        windowsOptions: const WindowsOptions(lockParentWindow: true),
      );
      if (!context.mounted || uri == null) return; // uri is null if the user cancelled
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Library backup saved.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  /// Restores notebooks from a file previously written by [_exportBackup] -
  /// see LibraryController.importBackup for exactly what "restore" means
  /// here (additive, never overwrites or deletes anything already
  /// present).
  Future<void> _importBackup(BuildContext context, LibraryController library) async {
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: 'Select a Na-Pustakam library backup',
        windowsOptions: const WindowsOptions(lockParentWindow: true),
      );
      if (picked == null) return; // cancelled
      final bytes = await picked.readAsBytes();
      final result = await library.importBackup(bytes);
      if (!context.mounted) return;
      final parts = <String>[];
      if (result.imported > 0) parts.add('restored ${result.imported} notebook(s)');
      if (result.alreadyPresent > 0) parts.add('${result.alreadyPresent} already present');
      if (result.skippedDeleted > 0) parts.add('${result.skippedDeleted} skipped (previously deleted here)');
      final message = parts.isEmpty ? 'Nothing to import - the backup had no notebooks.' : '${parts.join(', ')}.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on FormatException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
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
    required this.onRename,
    required this.onDelete,
  });

  final String title;
  final Color color;
  final bool readOnly;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onRename;
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
        // Long-press/right-click open a Rename/Delete menu (mirroring
        // _SectionTab/_NotebookTab in notebook_screen.dart) rather than
        // firing delete straight away - the small trash icon below is
        // still there for a one-tap delete once you know it's there.
        onLongPress: () => _showMenu(context, _globalCenterOf(context)),
        onSecondaryTapDown: (details) => _showMenu(context, details.globalPosition),
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
        if (onRename != null) PopupMenuItem(onTap: onRename, child: const Text('Rename')),
        if (onDelete != null) PopupMenuItem(onTap: onDelete, child: const Text('Delete')),
        if (onRename == null && onDelete == null)
          const PopupMenuItem(enabled: false, child: Text('Read-only — connect to edit')),
      ],
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
