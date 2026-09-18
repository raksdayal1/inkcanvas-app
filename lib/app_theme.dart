import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6A5ACD)),
    );
    return base.copyWith(
      appBarTheme: base.appBarTheme.copyWith(centerTitle: false, elevation: 0),
    );
  }

  /// Fixed palette used by the color picker throughout the app — kept
  /// small and deliberate rather than a full HSV picker, matching
  /// Samsung Notes / OneNote's quick-pick swatch rows.
  static const List<Color> palette = [
    Colors.black,
    Color(0xFF3B3B3B),
    Colors.white,
    Color(0xFFD32F2F), // red
    Color(0xFFF57C00), // orange
    Color(0xFFFBC02D), // yellow
    Color(0xFF388E3C), // green
    Color(0xFF1976D2), // blue
    Color(0xFF7B1FA2), // purple
    Color(0xFF6D4C41), // brown
  ];

  static const List<Color> notebookColors = [
    Color(0xFF6A5ACD),
    Color(0xFFD32F2F),
    Color(0xFFF57C00),
    Color(0xFF388E3C),
    Color(0xFF1976D2),
    Color(0xFF7B1FA2),
    Color(0xFF00838F),
  ];
}
