import 'package:flutter/material.dart';

import '../../app_theme.dart';

/// Small fixed swatch row shown in a popover from the toolbar's color
/// button — deliberately not a full HSV picker, matching Samsung
/// Notes/OneNote's quick-pick swatches.
class ColorPalettePopup extends StatelessWidget {
  const ColorPalettePopup({super.key, required this.current, required this.onSelected});

  final Color current;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: AppTheme.palette.map((c) {
          final selected = c.toARGB32() == current.toARGB32();
          return GestureDetector(
            onTap: () => onSelected(c),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(color: selected ? Colors.blue : Colors.grey.shade400, width: selected ? 2 : 1),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
