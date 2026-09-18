import 'package:flutter/material.dart';

import '../../canvas/canvas_tools.dart';
import '../../canvas/page_edit_controller.dart';
import '../../models/canvas_element.dart';
import 'color_palette.dart';

/// The floating tool strip alongside the canvas: tool selection, color,
/// stroke width, shape kind, undo/redo, delete-selection and insert-image.
class CanvasToolbar extends StatelessWidget {
  const CanvasToolbar({
    super.key,
    required this.editController,
    required this.onInsertImage,
  });

  final PageEditController editController;
  final VoidCallback onInsertImage;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: editController,
      builder: (context, _) {
        return Card(
          elevation: 4,
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _toolButton(context, CanvasTool.pen, Icons.edit, 'Pen'),
                _toolButton(context, CanvasTool.highlighter, Icons.brush, 'Highlighter'),
                _toolButton(context, CanvasTool.eraser, Icons.auto_fix_normal, 'Eraser'),
                _shapeButton(context),
                _toolButton(context, CanvasTool.lasso, Icons.gesture, 'Lasso select'),
                _toolButton(context, CanvasTool.text, Icons.text_fields, 'Text box'),
                _toolButton(context, CanvasTool.select, Icons.near_me, 'Select / move'),
                _toolButton(context, CanvasTool.pan, Icons.pan_tool, 'Pan (hand)'),
                const Divider(height: 12),
                _colorButton(context),
                _strokeWidthButton(context),
                const Divider(height: 12),
                IconButton(
                  icon: const Icon(Icons.image_outlined),
                  tooltip: 'Insert image',
                  onPressed: onInsertImage,
                ),
                IconButton(
                  icon: const Icon(Icons.undo),
                  tooltip: 'Undo',
                  onPressed: editController.canUndo ? editController.undo : null,
                ),
                IconButton(
                  icon: const Icon(Icons.redo),
                  tooltip: 'Redo',
                  onPressed: editController.canRedo ? editController.redo : null,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete selection',
                  onPressed: editController.selectedElementIds.isEmpty ? null : editController.deleteSelection,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _toolButton(BuildContext context, CanvasTool tool, IconData icon, String tooltip) {
    final selected = editController.tool == tool;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      color: selected ? Theme.of(context).colorScheme.primary : null,
      style: selected
          ? IconButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12))
          : null,
      onPressed: () => editController.setTool(tool),
    );
  }

  Widget _shapeButton(BuildContext context) {
    final selected = editController.tool == CanvasTool.shape;
    return PopupMenuButton<ShapeKind>(
      tooltip: 'Shapes',
      icon: Icon(
        _iconForShape(editController.activeShapeKind),
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      onSelected: (kind) {
        editController.setActiveShapeKind(kind);
        editController.setTool(CanvasTool.shape);
      },
      itemBuilder: (context) => ShapeKind.values
          .map((k) => PopupMenuItem(value: k, child: Row(children: [Icon(_iconForShape(k)), const SizedBox(width: 8), Text(k.name)])))
          .toList(),
    );
  }

  IconData _iconForShape(ShapeKind kind) {
    switch (kind) {
      case ShapeKind.rectangle:
        return Icons.crop_square;
      case ShapeKind.ellipse:
        return Icons.circle_outlined;
      case ShapeKind.line:
        return Icons.horizontal_rule;
      case ShapeKind.arrow:
        return Icons.arrow_forward;
    }
  }

  Widget _colorButton(BuildContext context) {
    return PopupMenuButton<void>(
      tooltip: 'Color',
      icon: CircleAvatar(radius: 11, backgroundColor: editController.activeColor),
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: ColorPalettePopup(
            current: editController.activeColor,
            onSelected: (c) {
              editController.setColor(c);
              Navigator.pop(context);
            },
          ),
        ),
      ],
    );
  }

  Widget _strokeWidthButton(BuildContext context) {
    return PopupMenuButton<void>(
      tooltip: 'Pen thickness',
      icon: const Icon(Icons.line_weight),
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: StatefulBuilder(
            builder: (context, setPopupState) {
              return SizedBox(
                width: 220,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Thickness: ${editController.activeStrokeWidth.toStringAsFixed(0)}'),
                    // Live preview line at the current thickness.
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Center(
                        child: Container(
                          width: 120,
                          height: editController.activeStrokeWidth,
                          decoration: BoxDecoration(
                            color: editController.activeColor,
                            borderRadius: BorderRadius.circular(editController.activeStrokeWidth / 2),
                          ),
                        ),
                      ),
                    ),
                    Slider(
                      min: 1,
                      max: 20,
                      divisions: 19,
                      value: editController.activeStrokeWidth.clamp(1, 20),
                      onChanged: (w) {
                        editController.setStrokeWidth(w);
                        // The Slider lives inside a PopupMenuButton's own
                        // route, which doesn't rebuild just because the
                        // controller notifies its normal listeners — this
                        // local setState keeps the preview/live label in
                        // sync with the drag while the popup stays open.
                        setPopupState(() {});
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
