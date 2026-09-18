// Local, on-device JSON storage. No network, no cloud, no sync — each
// device (Windows PC, Android device) keeps its own library on disk, per
// the "local only for now" scope for this MVP. A future sync layer (either
// the same direct USB-C/Wi-Fi approach used by Notes Ink, or a cloud
// backend) can be dropped in later without touching the models above it,
// since it would just need to read/write the same Notebook list.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/notebook.dart';

/// What [LocalStore.loadLibrary]/[LocalStore.saveLibrary] carry: the
/// notebooks themselves, plus tombstones for whole notebooks their
/// owning device has deleted (id -> when). See
/// LibraryController.deletedNotebookIds for the full reasoning - in
/// short, without this a peer that still has the old copy would just
/// hand it right back on the next sync.
class LibraryData {
  LibraryData({required this.notebooks, required this.deletedNotebookIds});

  factory LibraryData.empty() => LibraryData(notebooks: [], deletedNotebookIds: {});

  final List<Notebook> notebooks;
  final Map<String, DateTime> deletedNotebookIds;
}

class LocalStore {
  static const _libraryFileName = 'library.dat';
  static const _legacyLibraryFileName = 'library.json';
  static const _legacyEncFileName = 'library.enc';
  static const _imagesDirName = 'images';

  /// Everything the app owns lives under one folder named after the app,
  /// so it's obvious what's ours on disk - especially on Windows, where
  /// `getApplicationDocumentsDirectory()` resolves to the user's actual
  /// Documents folder (not a private per-app folder like Android's),
  /// meaning library.json/images/ used to sit loose in there next to
  /// whatever else the user keeps in Documents.
  static const _appFolderName = 'Na-Pustakam';

  Directory? _appDir;

  Future<Directory> _dir() async {
    if (_appDir != null) return _appDir!;
    final docs = await getApplicationDocumentsDirectory();
    final appDir = Directory('${docs.path}/$_appFolderName');
    if (!await appDir.exists()) {
      await appDir.create(recursive: true);
    }
    await _migrateFromFlatLayoutIfNeeded(docs, appDir);
    if (Platform.isWindows) {
      // Documents is somewhere the user normally browses - hide this
      // folder from a plain Explorer view so it isn't something someone
      // stumbles across and deletes without realizing what it is.
      // Purely cosmetic (anyone who turns on "Show hidden items", or
      // just types the path, sees it exactly as before) and best-effort
      // - a failure here shouldn't block the app from starting.
      try {
        await Process.run('attrib', ['+h', appDir.path]);
      } catch (e) {
        // ignore: avoid_print
        print('LocalStore: could not mark ${appDir.path} hidden: $e');
      }
    }
    return _appDir = appDir;
  }

  /// Older builds wrote library.json (and the images/ folder) directly
  /// into [oldDir] instead of the new [_appFolderName] subfolder. The
  /// first time the app runs after upgrading, copy anything found in
  /// that old flat location into the new one so existing notebooks don't
  /// appear to vanish. Runs on every launch but is a no-op once it's
  /// already happened (or on a fresh install with nothing old to find) -
  /// and it only ever copies, never deletes, the old files, so a
  /// migration that fails partway through can't lose data.
  Future<void> _migrateFromFlatLayoutIfNeeded(Directory oldDir, Directory newDir) async {
    final newDatFile = File('${newDir.path}/$_libraryFileName');
    final newLegacyFile = File('${newDir.path}/$_legacyLibraryFileName');
    final newLegacyEncFile = File('${newDir.path}/$_legacyEncFileName');
    if (await newDatFile.exists() || await newLegacyFile.exists() || await newLegacyEncFile.exists()) {
      return; // already migrated (or fresh install)
    }
    final oldLibraryFile = File('${oldDir.path}/$_legacyLibraryFileName');
    if (!await oldLibraryFile.exists()) return; // nothing old to migrate
    try {
      await oldLibraryFile.copy(newLegacyFile.path);
      final oldImagesDir = Directory('${oldDir.path}/$_imagesDirName');
      if (await oldImagesDir.exists()) {
        final newImagesDir = Directory('${newDir.path}/$_imagesDirName');
        await newImagesDir.create(recursive: true);
        await for (final entity in oldImagesDir.list()) {
          if (entity is File) {
            await entity.copy('${newImagesDir.path}/${entity.uri.pathSegments.last}');
          }
        }
      }
      // The old library.json's ImageElements still reference the old
      // images/ folder by absolute path, and we've left those files in
      // place (only copied, not moved) - so those images keep loading
      // correctly even though we didn't rewrite every path. Only newly
      // added images from here on land in the new folder.
      // ignore: avoid_print
      print('LocalStore: migrated library from ${oldDir.path} to ${newDir.path}');
    } catch (e) {
      // ignore: avoid_print
      print('LocalStore: migration from old flat layout failed: $e');
    }
  }

  Future<Directory> _imagesDir() async {
    final dir = await _dir();
    final imagesDir = Directory('${dir.path}/$_imagesDirName');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    return imagesDir;
  }

  /// Public access to the same app folder (and its images/ subfolder)
  /// LocalStore itself uses, so the sync layer (device identity,
  /// pairing store, image transfer) reads/writes files alongside
  /// library.json instead of resolving its own separate path.
  Future<Directory> appDirectory() => _dir();
  Future<Directory> imagesDirectory() => _imagesDir();

  /// Wipes every file this app has ever written - the library, all
  /// images, this device's identity, and its list of trusted peers - so
  /// the next launch starts exactly like a fresh install (which is also
  /// what actually happens on Android when the app is uninstalled: its
  /// private storage is wiped by the OS. Windows has no such automatic
  /// cleanup since this data lives in the user's own Documents folder,
  /// which is why this exists - see SyncScreen's "Clear all data"
  /// action, the only caller). A running process can't un-cache the
  /// DeviceIdentity/PairingStore/LibraryController it already loaded
  /// into memory, so the caller is expected to close the app right
  /// after this returns rather than continue using it.
  Future<void> clearAllData() async {
    final dir = await _dir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Loads the whole library (all notebooks, plus tombstones for
  /// whole notebooks deleted by their owning device - see
  /// LibraryController.deletedNotebookIds for why those need to be kept
  /// around). Returns an empty library if nothing has been saved yet
  /// (first run).
  Future<LibraryData> loadLibrary() async {
    final dir = await _dir();
    final datFile = File('${dir.path}/$_libraryFileName');
    String? jsonString;
    var migratingFromLegacy = false;

    if (await datFile.exists()) {
      try {
        jsonString = utf8.decode(gzip.decode(await datFile.readAsBytes()));
      } catch (e) {
        // Corrupt/unreadable file: don't crash the app on startup, just
        // start from an empty library, same as any other corrupt-file
        // case here. The bad file is left on disk in case it's
        // recoverable by hand.
        // ignore: avoid_print
        print('LocalStore: failed to read library.dat: $e');
        return LibraryData.empty();
      }
    } else {
      final legacyEncFile = File('${dir.path}/$_legacyEncFileName');
      if (await legacyEncFile.exists()) {
        // Left over from a brief earlier build that AES-encrypted this
        // file instead of just gzip-compressing it - that approach was
        // reverted before it ever shipped, so there's no key left to
        // read this with. Leave it alone rather than guess at deleting
        // it; fall through below in case a plaintext/legacy copy is
        // also still around to load from instead.
        // ignore: avoid_print
        print(
          'LocalStore: found library.enc (from a reverted encrypted build) - '
          "can't read it without the AES code that made it; leaving it on disk untouched",
        );
      }
      // No library.dat yet - either a fresh install, or one from
      // before at-rest compression existed, still holding a plaintext
      // library.json. Read that once; the migration block below then
      // compresses it into library.dat and removes the plaintext copy
      // so it stops sitting there readable.
      final legacyFile = File('${dir.path}/$_legacyLibraryFileName');
      if (await legacyFile.exists()) {
        try {
          jsonString = await legacyFile.readAsString();
          migratingFromLegacy = true;
        } catch (e) {
          // ignore: avoid_print
          print('LocalStore: failed to read legacy library.json: $e');
          return LibraryData.empty();
        }
      }
    }

    if (jsonString == null || jsonString.trim().isEmpty) return LibraryData.empty();

    LibraryData data;
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is List) {
        // Old format, from before whole-notebook delete tombstones
        // existed: a bare JSON array of notebooks, nothing else.
        data = LibraryData(
          notebooks: decoded.map((n) => Notebook.fromJson(n as Map<String, dynamic>)).toList(),
          deletedNotebookIds: {},
        );
      } else {
        final map = decoded as Map<String, dynamic>;
        final notebooks =
            (map['notebooks'] as List).map((n) => Notebook.fromJson(n as Map<String, dynamic>)).toList();
        final deletedNotebookIds = (map['deletedNotebookIds'] as Map<String, dynamic>?)
                ?.map((id, at) => MapEntry(id, DateTime.parse(at as String))) ??
            <String, DateTime>{};
        data = LibraryData(notebooks: notebooks, deletedNotebookIds: deletedNotebookIds);
      }
    } catch (e) {
      // Corrupt or unreadable content: don't crash the app on startup,
      // just start from an empty library. The bad file is left on disk
      // in case the user wants to recover it by hand.
      // ignore: avoid_print
      print('LocalStore: failed to parse library data: $e');
      return LibraryData.empty();
    }

    if (migratingFromLegacy) {
      // One-time upgrade from a pre-compression install: write the
      // compressed copy now, then remove the plaintext file so it stops
      // sitting there readable. Only deletes it after the compressed
      // write has actually succeeded, so a failure here can't lose data.
      try {
        await saveLibrary(data.notebooks, data.deletedNotebookIds);
        await File('${dir.path}/$_legacyLibraryFileName').delete();
        // ignore: avoid_print
        print('LocalStore: migrated library.json to compressed library.dat');
      } catch (e) {
        // ignore: avoid_print
        print('LocalStore: failed to migrate legacy library.json to library.dat: $e');
      }
    }

    return data;
  }

  /// Persists the whole library, overwriting whatever was there before.
  /// Called after every mutation for MVP simplicity (the library is small
  /// text, so this is cheap); a debounce can be added later if it matters.
  /// Written gzip-compressed rather than as plain JSON, so the file on
  /// disk is both smaller and not something that shows up as readable,
  /// editable text if someone opens it by accident.
  Future<void> saveLibrary(List<Notebook> notebooks, Map<String, DateTime> deletedNotebookIds) async {
    final dir = await _dir();
    final file = File('${dir.path}/$_libraryFileName');
    final data = {
      'notebooks': notebooks.map((n) => n.toJson()).toList(),
      'deletedNotebookIds': deletedNotebookIds.map((id, at) => MapEntry(id, at.toIso8601String())),
    };
    final plainBytes = utf8.encode(jsonEncode(data));
    await file.writeAsBytes(gzip.encode(plainBytes));
  }

  /// Copies an externally-picked image file into this app's own storage
  /// directory (so it survives the source file being moved/deleted) and
  /// returns the new absolute path to store on an [ImageElement]. Kept
  /// around for any future flow that already has a real on-disk path
  /// (e.g. a device-to-device sync layer); file_picker's current API
  /// hands back bytes instead, so image insertion uses
  /// [importImageBytes] below.
  Future<String> importImage(String sourcePath) async {
    final imagesDir = await _imagesDir();
    final ext = sourcePath.contains('.') ? sourcePath.split('.').last : 'png';
    final destName = '${DateTime.now().microsecondsSinceEpoch}.$ext';
    final destPath = '${imagesDir.path}/$destName';
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  /// Writes picked image bytes into this app's own storage directory and
  /// returns the new absolute path to store on an [ImageElement].
  /// [originalFileName] is only used to preserve the file extension.
  /// Stored exactly as received, byte for byte - an earlier version of
  /// this recompressed/downscaled images on the way in, but that's
  /// reverted for now (see git history / conversation if it's revisited
  /// later) in favor of just keeping storage simple and predictable.
  Future<String> importImageBytes(Uint8List bytes, String originalFileName) async {
    final imagesDir = await _imagesDir();
    final ext = originalFileName.contains('.') ? originalFileName.split('.').last : 'png';
    final destName = '${DateTime.now().microsecondsSinceEpoch}.$ext';
    final destPath = '${imagesDir.path}/$destName';
    await File(destPath).writeAsBytes(bytes);
    return destPath;
  }
}
