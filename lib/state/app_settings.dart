import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// App-wide user preferences that aren't tied to any one notebook/page.
/// Currently just one: whether ink strokes get curve-smoothed as they're
/// drawn (see canvas_painter.dart's _paintStroke/_buildStrokePath) - on by
/// default, since it's a pure rendering improvement with no downside,
/// but toggleable from the canvas toolbar for anyone who wants their raw,
/// unsmoothed line back (e.g. very small/precise writing, where curve
/// fitting can round off corners that were meant to be sharp).
///
/// Persisted next to device.json in the same Na-Pustakam app folder
/// LocalStore uses, following the same load-once/save-on-change pattern
/// as DeviceIdentity.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._inkSmoothingEnabled, this._toolbarCollapsed, this._file);

  bool _inkSmoothingEnabled;

  /// Whether ink strokes (pen + highlighter) are curve-smoothed at paint
  /// time. Purely a rendering choice - toggling this never touches the
  /// actual stored stroke points, so it's always instantly reversible.
  bool get inkSmoothingEnabled => _inkSmoothingEnabled;

  bool _toolbarCollapsed;

  /// Whether the floating canvas toolbar (pen/highlighter/eraser/...) is
  /// collapsed down to a small edge handle, freeing up the strip of page
  /// along the left edge it would otherwise sit on top of - mainly for
  /// smaller tablet screens, where that strip is exactly where writing
  /// tends to start. Remembered across app launches like every other
  /// setting here, rather than resetting every time a page is reopened.
  bool get toolbarCollapsed => _toolbarCollapsed;

  final File _file;

  static AppSettings? _cached;

  static Future<AppSettings> load(Directory appDir) async {
    final cached = _cached;
    if (cached != null) return cached;

    final file = File('${appDir.path}/settings.json');
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final settings = AppSettings._(
          json['inkSmoothingEnabled'] as bool? ?? true,
          json['toolbarCollapsed'] as bool? ?? false,
          file,
        );
        return _cached = settings;
      } catch (e) {
        // ignore: avoid_print
        print('AppSettings: failed to read settings.json, using defaults: $e');
      }
    }

    final settings = AppSettings._(true, false, file);
    await settings._save();
    return _cached = settings;
  }

  Future<void> setInkSmoothingEnabled(bool enabled) async {
    if (enabled == _inkSmoothingEnabled) return;
    _inkSmoothingEnabled = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setToolbarCollapsed(bool collapsed) async {
    if (collapsed == _toolbarCollapsed) return;
    _toolbarCollapsed = collapsed;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    await _file.writeAsString(jsonEncode({
      'inkSmoothingEnabled': _inkSmoothingEnabled,
      'toolbarCollapsed': _toolbarCollapsed,
    }));
  }
}
