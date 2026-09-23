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
    Map<String, String>? embeddedLinks,
  })  : elements = elements ?? [],
        embeddedLinks = embeddedLinks ?? {},
        lastModified = lastModified ?? DateTime.now();

  final String id;
  String title;
  final List<CanvasElement> elements;
  PageBackground background;
  DateTime lastModified;

  /// Maps a local-file link's exact raw text (as findUrls matched it -
  /// e.g. "file:///C:/Users/raksh/OneDrive/.../note.html") to the
  /// basename of a copy of that file this device made in LocalStore's
  /// images/ folder (the same content-hash-named storage/dedup images
  /// already use - see LocalStore.importLinkedFile). This is what
  /// lets a local-file link still be opened from a *different* device,
  /// where the original path is meaningless (a Windows "C:\..." path
  /// doesn't exist on Android, and vice versa) - see
  /// InfiniteCanvas._openLocalFile and PageScreen._embedLocalLinksIn,
  /// which populates this opportunistically whenever a local-file link
  /// is typed/pasted and the referenced file actually exists on
  /// whichever device is editing at the time. Empty for a link no
  /// device has ever been able to read yet, and for every page saved
  /// before this existed.
  final Map<String, String> embeddedLinks;

  void touch() => lastModified = DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'background': background.name,
        'lastModified': lastModified.toIso8601String(),
        'elements': elements.map((e) => e.toJson()).toList(),
        if (embeddedLinks.isNotEmpty) 'embeddedLinks': embeddedLinks,
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
      embeddedLinks: (json['embeddedLinks'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v as String)) ?? {},
    );
  }
}
