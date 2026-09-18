import 'canvas_element.dart';

enum PageBackground { plain, lined, grid }

/// A single OneNote-style page: one infinite canvas full of elements.
class NotePage {
  NotePage({
    required this.id,
    required this.title,
    List<CanvasElement>? elements,
    this.background = PageBackground.plain,
    DateTime? lastModified,
  })  : elements = elements ?? [],
        lastModified = lastModified ?? DateTime.now();

  final String id;
  String title;
  final List<CanvasElement> elements;
  PageBackground background;
  DateTime lastModified;

  void touch() => lastModified = DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'background': background.name,
        'lastModified': lastModified.toIso8601String(),
        'elements': elements.map((e) => e.toJson()).toList(),
      };

  static NotePage fromJson(Map<String, dynamic> json) {
    return NotePage(
      id: json['id'] as String,
      title: json['title'] as String,
      background: PageBackground.values.byName(json['background'] as String? ?? 'plain'),
      lastModified: DateTime.parse(json['lastModified'] as String),
      elements: (json['elements'] as List)
          .map((e) => CanvasElement.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
