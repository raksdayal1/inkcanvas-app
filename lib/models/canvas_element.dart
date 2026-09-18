// Canvas element model hierarchy.
//
// All positions/sizes here are in *canvas space* (unbounded logical
// coordinates), never in on-screen pixels. The infinite pan/zoom canvas is
// responsible for converting between canvas space and screen space; these
// models never need to know the current zoom/pan.
import 'dart:ui';

/// Shape drawn with the shape tool.
enum ShapeKind { rectangle, ellipse, line, arrow }

/// Kind of ink stroke, used to pick a [Paint] (highlighter uses translucent
/// color + a wider nib and a "multiply"-ish blend so overlaps look right).
enum StrokeKind { pen, highlighter }

/// Base type for anything that can live on a page's canvas.
sealed class CanvasElement {
  CanvasElement({required this.id, required this.createdAt});

  final String id;
  final DateTime createdAt;

  Map<String, dynamic> toJson();

  static CanvasElement fromJson(Map<String, dynamic> json) {
    switch (json['type'] as String) {
      case 'ink':
        return InkStrokeElement.fromJson(json);
      case 'text':
        return TextBoxElement.fromJson(json);
      case 'image':
        return ImageElement.fromJson(json);
      case 'shape':
        return ShapeElement.fromJson(json);
      default:
        throw FormatException('Unknown canvas element type: ${json['type']}');
    }
  }

  /// Rough bounding box in canvas space, used for hit-testing (lasso
  /// selection, tap-to-select) and for scroll-to-content.
  Rect get bounds;
}

class InkStrokeElement extends CanvasElement {
  InkStrokeElement({
    required super.id,
    required super.createdAt,
    required this.points,
    required this.pressures,
    required this.color,
    required this.strokeWidth,
    required this.kind,
  });

  /// Points in canvas space, in drawing order.
  final List<Offset> points;

  /// Pen pressure per point (0.0-1.0). Same length as [points]. Devices
  /// that don't report pressure just fill this with 1.0.
  final List<double> pressures;

  final Color color;

  /// Base stroke width in canvas-space units (so ink keeps its real size
  /// relative to the page when you zoom, exactly like OneNote).
  final double strokeWidth;

  final StrokeKind kind;

  @override
  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    double minX = points.first.dx, maxX = points.first.dx;
    double minY = points.first.dy, maxY = points.first.dy;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    final pad = strokeWidth;
    return Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'ink',
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'points': points.map((p) => [p.dx, p.dy]).toList(),
        'pressures': pressures,
        'color': color.toARGB32(),
        'strokeWidth': strokeWidth,
        'kind': kind.name,
      };

  static InkStrokeElement fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List;
    return InkStrokeElement(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      points: rawPoints
          .map((p) => Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()))
          .toList(),
      pressures: (json['pressures'] as List).map((v) => (v as num).toDouble()).toList(),
      color: Color(json['color'] as int),
      strokeWidth: (json['strokeWidth'] as num).toDouble(),
      kind: StrokeKind.values.byName(json['kind'] as String),
    );
  }
}

class TextBoxElement extends CanvasElement {
  TextBoxElement({
    required super.id,
    required super.createdAt,
    required this.rect,
    required this.text,
    required this.color,
    required this.fontSize,
  });

  Rect rect;
  String text;
  Color color;
  double fontSize;

  @override
  Rect get bounds => rect;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text',
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'rect': [rect.left, rect.top, rect.width, rect.height],
        'text': text,
        'color': color.toARGB32(),
        'fontSize': fontSize,
      };

  static TextBoxElement fromJson(Map<String, dynamic> json) {
    final r = json['rect'] as List;
    return TextBoxElement(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      rect: Rect.fromLTWH(
        (r[0] as num).toDouble(),
        (r[1] as num).toDouble(),
        (r[2] as num).toDouble(),
        (r[3] as num).toDouble(),
      ),
      text: json['text'] as String,
      color: Color(json['color'] as int),
      fontSize: (json['fontSize'] as num).toDouble(),
    );
  }
}

class ImageElement extends CanvasElement {
  ImageElement({
    required super.id,
    required super.createdAt,
    required this.rect,
    required this.filePath,
    this.aspectRatio,
  });

  Rect rect;

  /// Absolute path to the image file, copied into this app's local storage
  /// directory at insertion time so it survives the source file moving.
  String filePath;

  /// The source image's native width/height ratio, captured once when the
  /// image is inserted. Used to keep [rect] matching the picture's real
  /// proportions while resizing - without it, a free-form drag distorts
  /// the box relative to the image, and since the image itself is drawn
  /// with BoxFit.contain (which never distorts the picture, only the box
  /// around it), that mismatch shows up as blank letterboxing inside the
  /// box. Null for images inserted before this existed, or if decoding
  /// the source file's dimensions failed - those just fall back to the
  /// old free-form resize behavior.
  double? aspectRatio;

  @override
  Rect get bounds => rect;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image',
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'rect': [rect.left, rect.top, rect.width, rect.height],
        'filePath': filePath,
        if (aspectRatio != null) 'aspectRatio': aspectRatio,
      };

  static ImageElement fromJson(Map<String, dynamic> json) {
    final r = json['rect'] as List;
    return ImageElement(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      rect: Rect.fromLTWH(
        (r[0] as num).toDouble(),
        (r[1] as num).toDouble(),
        (r[2] as num).toDouble(),
        (r[3] as num).toDouble(),
      ),
      filePath: json['filePath'] as String,
      aspectRatio: (json['aspectRatio'] as num?)?.toDouble(),
    );
  }
}

class ShapeElement extends CanvasElement {
  ShapeElement({
    required super.id,
    required super.createdAt,
    required this.rect,
    required this.kind,
    required this.color,
    required this.strokeWidth,
    required this.filled,
  });

  Rect rect;
  ShapeKind kind;
  Color color;
  double strokeWidth;
  bool filled;

  @override
  Rect get bounds => rect;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'shape',
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'rect': [rect.left, rect.top, rect.width, rect.height],
        'kind': kind.name,
        'color': color.toARGB32(),
        'strokeWidth': strokeWidth,
        'filled': filled,
      };

  static ShapeElement fromJson(Map<String, dynamic> json) {
    final r = json['rect'] as List;
    return ShapeElement(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      rect: Rect.fromLTWH(
        (r[0] as num).toDouble(),
        (r[1] as num).toDouble(),
        (r[2] as num).toDouble(),
        (r[3] as num).toDouble(),
      ),
      kind: ShapeKind.values.byName(json['kind'] as String),
      color: Color(json['color'] as int),
      strokeWidth: (json['strokeWidth'] as num).toDouble(),
      filled: json['filled'] as bool,
    );
  }
}
