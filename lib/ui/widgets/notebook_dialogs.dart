// Notebook rename/delete flows, shared by the notebook grid
// (home_screen.dart) and the in-notebook notebook-switcher strip
// (notebook_screen.dart's _SectionRail) so both surfaces show the exact
// same dialogs and behave identically, rather than each screen growing
// its own slightly-different copy.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../models/notebook.dart';
import '../../state/library_controller.dart';

/// Generic "type a name" dialog - also used by section/page rename and
/// create flows in notebook_screen.dart, not just notebooks. Returns the
/// trimmed text, or null if cancelled.
Future<String?> promptForText(BuildContext context, {required String title, required String initial}) {
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

/// Prompts for a new title and renames [notebook] - a no-op if the
/// dialog is cancelled or the trimmed result is empty. Doesn't check
/// [LibraryController.canEdit] itself; callers gate whether to even
/// offer this action on that (see both call sites).
/// The same "pick one of the app's colors" swatch grid
/// _NewNotebookDialog uses for a new notebook's color - reused here so
/// creating or recoloring a section (see notebook_screen.dart's
/// _SectionRailState) offers the identical picker instead of a second,
/// slightly-different one growing separately. Returns the tapped color,
/// or null if the dialog is dismissed without picking one.
Future<Color?> promptForColor(BuildContext context, {required String title, required Color initial}) {
  return showDialog<Color>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: AppTheme.notebookColors.map((c) {
              final selected = c.toARGB32() == initial.toARGB32();
              return GestureDetector(
                onTap: () => Navigator.pop(context, c),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: c,
                  child: selected ? const Icon(Icons.check, color: Colors.white) : null,
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
      ],
    ),
  );
}

Future<void> renameNotebookFlow(BuildContext context, LibraryController library, Notebook notebook) async {
  final title = await promptForText(context, title: 'Rename notebook', initial: notebook.title);
  if (title != null && title.isNotEmpty) {
    await library.renameNotebook(notebook.id, title);
  }
}

/// Confirms, then deletes [notebook] - showing a snackbar instead of
/// crashing if it turns out this device isn't allowed to (a
/// [NotYourNotebookException], e.g. the ownership situation changed
/// between the button being shown and actually being pressed).
Future<void> deleteNotebookFlow(BuildContext context, LibraryController library, Notebook notebook) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete "${notebook.title}"?'),
      content: const Text("This deletes all sections and pages inside it. This can't be undone."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await library.deleteNotebook(notebook.id);
  } on NotYourNotebookException {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Only the device that owns this notebook can delete it.")),
      );
    }
  }
}
