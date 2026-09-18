import 'dart:ui';

import 'page.dart';

/// A OneNote-style section: a colored tab holding an ordered list of pages.
class NoteSection {
  NoteSection({
    required this.id,
    required this.title,
    required this.color,
    List<NotePage>? pages,
  }) : pages = pages ?? [];

  final String id;
  String title;
  Color color;
  final List<NotePage> pages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'color': color.toARGB32(),
        'pages': pages.map((p) => p.toJson()).toList(),
      };

  static NoteSection fromJson(Map<String, dynamic> json) {
    return NoteSection(
      id: json['id'] as String,
      title: json['title'] as String,
      color: Color(json['color'] as int),
      pages: (json['pages'] as List)
          .map((p) => NotePage.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }
}
