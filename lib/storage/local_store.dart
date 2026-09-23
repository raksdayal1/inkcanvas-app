// Local, on-device JSON storage. No network, no cloud, no sync — each
// device (Windows PC, Android device) keeps its own library on disk, per
// the "local only for now" scope for this MVP. A future sync layer (either
// the same direct USB-C/Wi-Fi approach used by Notes Ink, or a cloud
// backend) can be dropped in later without touching the models above it,
// since it would just need to read/write the same Notebook list.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:path_provider/path_provider.dart';

import '../models/canvas_element.dart';
import '../models/notebook.dart';
import 'binary_page_codec.dart';
import 'page_change_set.dart';

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

  /// The current on-disk format: [_manifestFileName] holds the whole
  /// notebook/section/page tree - titles, timestamps, ownership,
  /// tombstones - with every page's `elements` blanked out, and each
  /// page's actual ink lives in its own binary revision log under
  /// [_pagesDirName] (pages/<pageId>.npbs - see binary_page_codec.dart).
  /// This replaces the older single-blob [_libraryFileName] (kept around
  /// read-only as a fallback - see [loadLibrary]) specifically so that
  /// saving one page's stroke doesn't require re-encoding every OTHER
  /// page/notebook that happens to exist too - see [saveManifest].
  /// Within one page, that same "don't touch what didn't change" idea
  /// goes one step further: an ordinary edit appends just that one
  /// element's record to the log (see [appendPageChanges]) instead of
  /// re-encoding the whole page, which pages/<pageId>.dat (a single
  /// JSON blob per page, still readable as an even older fallback - see
  /// [_readPageFileJsonLegacy]) always had to do.
  static const _manifestFileName = 'manifest.dat';
  static const _pagesDirName = 'pages';

  /// How many revision-log records have been appended to a page's
  /// pages/<id>.npbs file since it was last compacted (rewritten down
  /// to just its currently-live elements - see [_writeFreshPageLog]),
  /// keyed by page id. In-memory only, reset on every app launch -
  /// worst case that just means compaction happens a bit later than
  /// ideal after a restart, never incorrectly. See [appendPageChanges]
  /// and [_readPageFileBinary] for the two places that consult it.
  final Map<String, int> _recordsSinceCompact = {};

  /// Once a page's log has grown past both of these relative to its
  /// live element count, it gets rewritten down to just what's
  /// actually there now - bounds how much now-superseded history (old
  /// positions from a move, earlier text from an edit, tombstones for
  /// deleted elements) can pile up in one file over a long editing
  /// session, the same way OneNote periodically consolidates its own
  /// revision chains.
  static const int _compactionRecordThreshold = 150;

  /// Everything the app owns lives under one folder named after the app,
  /// so it's obvious what's ours on disk. On Windows this folder sits
  /// next to the .exe itself (see [_dir]) rather than in the user's
  /// Documents, so the whole install - program plus its data - stays
  /// one self-contained thing that can be copied, moved, or backed up
  /// as a unit. It used to live in Documents instead (still handled by
  /// [_migrateFromOldWindowsDocumentsLocationIfNeeded], so nobody
  /// upgrading loses what's already there); Android keeps using its
  /// own private per-app folder via getApplicationDocumentsDirectory()
  /// as before, since that's not something app code gets to relocate
  /// anyway (see [clearAllData]'s doc comment on why an Android
  /// uninstall wipes it regardless of any of this).
  static const _appFolderName = 'Na-Pustakam';

  Directory? _appDir;

  Future<Directory> _dir() async {
    if (_appDir != null) return _appDir!;
    Directory appDir;
    if (Platform.isWindows) {
      // Next to the .exe rather than in Documents - see _appFolderName's
      // doc comment for why. Platform.resolvedExecutable is the actual
      // running .exe's path (the real install location in a release
      // build, or the build output folder under `flutter run`), so this
      // always sits alongside whichever binary is actually executing.
      final exeDir = File(Platform.resolvedExecutable).parent;
      appDir = Directory('${exeDir.path}/$_appFolderName');
    } else {
      final docs = await getApplicationDocumentsDirectory();
      appDir = Directory('${docs.path}/$_appFolderName');
    }
    if (!await appDir.exists()) {
      await appDir.create(recursive: true);
    }
    if (Platform.isWindows) {
      await _migrateFromOldWindowsDocumentsLocationIfNeeded(appDir);
    }
    final docs = await getApplicationDocumentsDirectory();
    await _migrateFromFlatLayoutIfNeeded(docs, appDir);
    if (Platform.isWindows) {
      // The install folder isn't somewhere most people poke around in,
      // but hide this subfolder anyway, same as before the move out of
      // Documents - cheap insurance against someone browsing the
      // install folder and deleting what looks like a stray folder.
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

  Future<bool> _hasAnyLibraryFile(Directory dir) async {
    return await File('${dir.path}/$_libraryFileName').exists() ||
        await File('${dir.path}/$_legacyLibraryFileName').exists() ||
        await File('${dir.path}/$_legacyEncFileName').exists();
  }

  /// Windows only. Before this build, the whole app folder lived under
  /// the user's Documents instead of next to the .exe (see
  /// [_appFolderName]'s doc comment) - so on the first run after
  /// upgrading, if the new next-to-the-exe folder is still empty but
  /// the old Documents Na-Pustakam folder has a real library in it,
  /// copy everything over: the library file, images/, this device's
  /// identity, its trusted-peers list, settings - the whole folder, not
  /// just the library/images the older [_migrateFromFlatLayoutIfNeeded]
  /// handles - so nothing already on disk appears to have vanished.
  /// Copy-only, same as that other migration: the old folder is never
  /// touched or deleted, so a failure partway through can't lose data,
  /// it just leaves a harmless leftover copy in the old spot.
  Future<void> _migrateFromOldWindowsDocumentsLocationIfNeeded(Directory newDir) async {
    if (await _hasAnyLibraryFile(newDir)) return; // already migrated, or fresh install
    final docs = await getApplicationDocumentsDirectory();
    final oldAppDir = Directory('${docs.path}/$_appFolderName');
    if (oldAppDir.path == newDir.path) return; // exe happens to live in Documents itself
    if (!await oldAppDir.exists() || !await _hasAnyLibraryFile(oldAppDir)) {
      return; // nothing old to migrate
    }
    try {
      await _copyDirectoryContents(oldAppDir, newDir);
      // ignore: avoid_print
      print('LocalStore: migrated app folder from ${oldAppDir.path} to ${newDir.path}');
    } catch (e) {
      // ignore: avoid_print
      print('LocalStore: migration from old Documents location failed: $e');
    }
  }

  Future<void> _copyDirectoryContents(Directory source, Directory destination) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }
    await for (final entity in source.list()) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final newPath = '${destination.path}/$name';
      if (entity is Directory) {
        await _copyDirectoryContents(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
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
  /// cleanup - this data just sits on disk (next to the .exe; see
  /// [_dir]) until something deletes it, which is why this exists - see
  /// SyncScreen's "Clear all data" action, the only caller). A running process can't un-cache the
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
    final manifestFile = File('${dir.path}/$_manifestFileName');
    if (await manifestFile.exists()) {
      return _loadFromManifest(manifestFile);
    }

    // --- Below: the pre-manifest-format install path. Read from
    // whichever of the older single-blob formats is actually present
    // (library.dat, or a still-older plaintext library.json), then -
    // once that succeeds - convert to the manifest+pages format below
    // so every future launch takes the fast path above instead. ---
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
      // compressed copy now (in whichever format saveLibrary currently
      // writes - see its own doc comment), then remove the plaintext
      // file so it stops sitting there readable. Only deletes it after
      // that write has actually succeeded, so a failure here can't
      // lose data.
      try {
        await saveLibrary(data.notebooks, data.deletedNotebookIds);
        await File('${dir.path}/$_legacyLibraryFileName').delete();
        // ignore: avoid_print
        print('LocalStore: migrated library.json to the current format');
      } catch (e) {
        // ignore: avoid_print
        print('LocalStore: failed to migrate legacy library.json: $e');
      }
    } else {
      // Loaded successfully from the older library.dat single-blob
      // format (not the even-older plaintext legacy file handled
      // above) - convert to the manifest+pages format now so every
      // future launch takes loadLibrary's fast path instead of coming
      // through here again. Deliberately does NOT delete library.dat
      // afterward (unlike the legacy-plaintext case above): this is a
      // much newer, less-proven format change, so leaving library.dat
      // in place, frozen/unread from now on, is a free safety net -
      // it costs a bit of disk space and nothing else. If this
      // conversion fails, nothing is lost either way; it'll just try
      // again next launch.
      try {
        await saveLibrary(data.notebooks, data.deletedNotebookIds);
        // ignore: avoid_print
        print('LocalStore: converted library.dat to the manifest+pages format');
      } catch (e) {
        // ignore: avoid_print
        print('LocalStore: failed to convert to the manifest+pages format, will retry next launch: $e');
      }
    }

    return data;
  }

  Future<Directory> _pagesDir() async {
    final dir = await _dir();
    final pagesDir = Directory('${dir.path}/$_pagesDirName');
    if (!await pagesDir.exists()) {
      await pagesDir.create(recursive: true);
    }
    return pagesDir;
  }

  /// The manifest's JSON shape: exactly what saveLibrary used to write
  /// wholesale, except every page's `elements` list is blanked out to
  /// `[]` - see the class's format doc comment above _manifestFileName.
  /// Built by calling each model's own toJson() (so this can't drift
  /// from what fromJson() below actually expects) and then stripping
  /// elements back out of the resulting plain JSON, rather than adding
  /// a second, parallel serialization path to the model classes
  /// themselves.
  Map<String, dynamic> _manifestJson(List<Notebook> notebooks, Map<String, DateTime> deletedNotebookIds) {
    final notebooksJson = notebooks.map((n) {
      final notebookJson = n.toJson();
      for (final sectionJson in notebookJson['sections'] as List) {
        for (final pageJson in (sectionJson as Map<String, dynamic>)['pages'] as List) {
          (pageJson as Map<String, dynamic>)['elements'] = <dynamic>[];
        }
      }
      return notebookJson;
    }).toList();
    return {
      'notebooks': notebooksJson,
      'deletedNotebookIds': deletedNotebookIds.map((id, at) => MapEntry(id, at.toIso8601String())),
    };
  }

  /// Writes just the manifest (see [_manifestJson]) - cheap no matter
  /// how much ink exists anywhere, since none of it is in here. Called
  /// on every edit, including a single pen stroke (see
  /// LibraryController._schedulePageSave/flushPendingSave), which is
  /// exactly the point: this used to mean re-encoding the *entire*
  /// library, ink included, on every stroke.
  Future<void> saveManifest(List<Notebook> notebooks, Map<String, DateTime> deletedNotebookIds) async {
    final dir = await _dir();
    final file = File('${dir.path}/$_manifestFileName');
    final plainBytes = utf8.encode(jsonEncode(_manifestJson(notebooks, deletedNotebookIds)));
    await file.writeAsBytes(gzip.encode(plainBytes));
  }

  /// Writes [pageId]'s complete pages/<pageId>.npbs revision log from
  /// scratch - one PUT record per element in [elements], in order, no
  /// history. Used for a full-library rewrite ([saveLibrary] - creating/
  /// deleting a notebook, a sync merge, a rename; none of those happen
  /// anywhere near once-per-stroke) and for compaction ([appendPageChanges]/
  /// [_readPageFileBinary]), never for an ordinary pen-stroke save - that
  /// goes through [appendPageChanges] instead, which is the whole point
  /// of this format: touching only the one element that actually
  /// changed, not re-encoding every element on the page.
  Future<void> _writeFreshPageLog(String pageId, List<CanvasElement> elements) async {
    final pagesDir = await _pagesDir();
    final file = File('${pagesDir.path}/$pageId.npbs');
    final w = BinaryWriter();
    w.writeBytes(npbsHeader);
    for (final el in elements) {
      w.writeBytes(PageLogRecord.put(el.id, el).encode());
    }
    await file.writeAsBytes(w.toBytes(), flush: true);
    _recordsSinceCompact[pageId] = 0;
  }

  /// Same contract as before this format existed (full-page rewrite from
  /// [elements]) - see [_writeFreshPageLog], which now does the actual
  /// work. Kept as its own method (rather than inlining it into
  /// [saveLibrary]) so that method doesn't need to change at all.
  Future<void> savePageFile(String pageId, List<CanvasElement> elements) => _writeFreshPageLog(pageId, elements);

  /// The fast, scoped save an ordinary edit (a pen stroke, a move, an
  /// erase) actually triggers: appends just the PUT/DELETE records
  /// [changes] describes to pages/<pageId>.npbs, instead of rewriting
  /// the whole file - see this class's format doc comment. [elements] is
  /// the page's current (full) element list, used only to look up the
  /// current content of whatever ids [changes.put] names; ids that were
  /// added and then deleted again before ever being flushed (e.g. a
  /// stroke drawn and immediately erased inside one debounce window)
  /// simply aren't found here and are silently skipped, which is
  /// correct - there's nothing left to persist for them. Cost depends
  /// only on how many elements actually changed, never on how many
  /// other elements already exist on the page.
  Future<void> appendPageChanges(String pageId, List<CanvasElement> elements, PageChangeSet changes) async {
    if (changes.isEmpty) return;
    final pagesDir = await _pagesDir();
    final file = File('${pagesDir.path}/$pageId.npbs');
    final isNew = !await file.exists();
    final w = BinaryWriter();
    if (isNew) w.writeBytes(npbsHeader);
    var appended = 0;
    for (final id in changes.deleted) {
      w.writeBytes(PageLogRecord.delete(id).encode());
      appended++;
    }
    for (final id in changes.put) {
      final el = _findElementById(elements, id);
      if (el == null) continue;
      w.writeBytes(PageLogRecord.put(id, el).encode());
      appended++;
    }
    if (appended == 0) return;
    final sink = file.openWrite(mode: FileMode.append);
    try {
      sink.add(w.toBytes());
      await sink.flush();
    } finally {
      await sink.close();
    }
    final since = (_recordsSinceCompact[pageId] ?? 0) + appended;
    if (since > _compactionRecordThreshold && since > elements.length * 3) {
      // Bloated relative to how much content is actually live - rewrite
      // down to just that now, same idea as _readPageFileBinary's
      // load-time check below, just triggered by write volume instead
      // of by reopening the page.
      await _writeFreshPageLog(pageId, elements);
    } else {
      _recordsSinceCompact[pageId] = since;
    }
  }

  CanvasElement? _findElementById(List<CanvasElement> elements, String id) {
    for (final e in elements) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Removes pages/<pageId>.npbs (and any leftover legacy .dat) -
  /// called wherever a page stops existing on this device, alongside
  /// the equivalent image cleanup (see LibraryController._deleteImagesOnPage).
  /// Best-effort: a failure here just leaves a harmless orphaned file
  /// behind, same as every other cleanup in this class.
  Future<void> deletePageFile(String pageId) async {
    final pagesDir = await _pagesDir();
    // Both the current binary log and any leftover legacy JSON file (a
    // page converted by _readPageFile below keeps the old .dat file
    // around as an untouched fallback - see its doc comment - so it can
    // still exist alongside the .npbs file and needs cleaning up too).
    for (final extension in const ['npbs', 'dat']) {
      final file = File('${pagesDir.path}/$pageId.$extension');
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (e) {
          // ignore: avoid_print
          print('LocalStore: failed to delete page file ($extension) for $pageId: $e');
        }
      }
    }
    _recordsSinceCompact.remove(pageId);
  }

  /// Loads [pageId]'s elements, preferring the current binary revision
  /// log (pages/<id>.npbs - see this class's format doc comment) and
  /// falling back to the older per-page JSON format (pages/<id>.dat,
  /// from the manifest+pages redesign) for a page that hasn't been
  /// touched since before this format existed. On that fallback path,
  /// opportunistically writes out an equivalent .npbs file afterward so
  /// every future load of this page takes the fast binary path instead -
  /// same one-time-conversion idea as loadLibrary's library.dat handling,
  /// and just as deliberately non-destructive: the old .dat file is
  /// never deleted here, only left alone as a free safety net.
  Future<List<CanvasElement>> _readPageFile(String pageId) async {
    final pagesDir = await _pagesDir();
    final npbsFile = File('${pagesDir.path}/$pageId.npbs');
    if (await npbsFile.exists()) {
      return _readPageFileBinary(pageId, npbsFile);
    }
    final elements = await _readPageFileJsonLegacy(pageId);
    if (elements.isNotEmpty) {
      try {
        await _writeFreshPageLog(pageId, elements);
        // ignore: avoid_print
        print('LocalStore: converted page $pageId to the binary revision-log format');
      } catch (e) {
        // ignore: avoid_print
        print('LocalStore: failed to convert page $pageId to binary log, will retry next load: $e');
      }
    }
    return elements;
  }

  /// Reads and replays pages/<pageId>.npbs (see [replayPageLog]).
  /// Corrupt/unreadable content is handled the same way as every other
  /// corrupt-file case in this class: don't crash, start that one page
  /// empty, leave the bad file on disk in case it's recoverable by
  /// hand. A log that's grown large relative to how much it actually
  /// holds live (lots of superseded history from moves/edits/deletes)
  /// gets compacted right away - see [_writeFreshPageLog] - so a page
  /// that's been heavily edited across many sessions doesn't just keep
  /// accumulating history forever every time it's reopened.
  Future<List<CanvasElement>> _readPageFileBinary(String pageId, File file) async {
    try {
      final bytes = await file.readAsBytes();
      final result = replayPageLog(bytes);
      if (result.recordCount > 40 && result.recordCount > result.elements.length * 4) {
        try {
          await _writeFreshPageLog(pageId, result.elements);
        } catch (e) {
          // ignore: avoid_print
          print('LocalStore: failed to compact page log for $pageId: $e');
        }
      } else {
        _recordsSinceCompact[pageId] = result.recordCount;
      }
      return result.elements;
    } catch (e) {
      // ignore: avoid_print
      print('LocalStore: failed to read binary page log for $pageId, starting it empty: $e');
      return [];
    }
  }

  /// The older per-page JSON format (pages/<pageId>.dat, gzip-compressed) -
  /// read-only from here on (see [_readPageFile]'s doc comment). Nothing
  /// writes this format anymore; it only still exists on disk for
  /// devices that saved a page before the binary revision log existed.
  Future<List<CanvasElement>> _readPageFileJsonLegacy(String pageId) async {
    final pagesDir = await _pagesDir();
    final file = File('${pagesDir.path}/$pageId.dat');
    if (!await file.exists()) return [];
    try {
      final jsonString = utf8.decode(gzip.decode(await file.readAsBytes()));
      final map = jsonDecode(jsonString) as Map<String, dynamic>;
      return (map['elements'] as List).map((e) => CanvasElement.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      // ignore: avoid_print
      print('LocalStore: failed to read legacy page file for $pageId, starting it empty: $e');
      return [];
    }
  }

  Future<LibraryData> _loadFromManifest(File manifestFile) async {
    Map<String, dynamic> map;
    try {
      final jsonString = utf8.decode(gzip.decode(await manifestFile.readAsBytes()));
      map = jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      // ignore: avoid_print
      print('LocalStore: failed to read manifest.dat: $e');
      return LibraryData.empty();
    }
    try {
      final notebooks =
          (map['notebooks'] as List).map((n) => Notebook.fromJson(n as Map<String, dynamic>)).toList();
      final deletedNotebookIds = (map['deletedNotebookIds'] as Map<String, dynamic>?)
              ?.map((id, at) => MapEntry(id, DateTime.parse(at as String))) ??
          <String, DateTime>{};
      // Every page's `elements` came back empty from the manifest by
      // design (see _manifestJson) - fill each one back in from its
      // own file now.
      for (final notebook in notebooks) {
        for (final section in notebook.sections) {
          for (final page in section.pages) {
            page.elements.addAll(await _readPageFile(page.id));
          }
        }
      }
      return LibraryData(notebooks: notebooks, deletedNotebookIds: deletedNotebookIds);
    } catch (e) {
      // ignore: avoid_print
      print('LocalStore: failed to parse manifest.dat: $e');
      return LibraryData.empty();
    }
  }

  /// Persists the whole library from scratch: the manifest plus every
  /// single page's own file. Used for the mutations that aren't a
  /// single page's pen stroke - creating/deleting a notebook, a sync
  /// merge, a rename, a reorder - where redoing everything is simple
  /// and safe, and cheap enough since none of those happen anywhere
  /// near once-per-stroke. A pen stroke itself goes through
  /// [saveManifest] + [savePageFile] instead (see
  /// LibraryController._schedulePageSave), touching only the one page
  /// that actually changed - the whole reason this format exists: the
  /// old version of this method re-encoded EVERY page's ink on every
  /// single call, however small the actual edit was.
  Future<void> saveLibrary(List<Notebook> notebooks, Map<String, DateTime> deletedNotebookIds) async {
    await saveManifest(notebooks, deletedNotebookIds);
    for (final notebook in notebooks) {
      for (final section in notebook.sections) {
        for (final page in section.pages) {
          await savePageFile(page.id, page.elements);
        }
      }
    }
  }

  /// Copies an externally-picked image file into this app's own storage
  /// directory (so it survives the source file being moved/deleted) and
  /// returns the new absolute path to store on an [ImageElement]. Kept
  /// around for any future flow that already has a real on-disk path
  /// (e.g. a device-to-device sync layer); file_picker's current API
  /// hands back bytes instead, so image insertion uses
  /// [importImageBytes] below - this just reads the file and defers to
  /// that, so both share the same content-hash dedup behavior.
  Future<String> importImage(String sourcePath) async {
    return importImageBytes(await File(sourcePath).readAsBytes(), sourcePath);
  }

  /// Writes picked image bytes into this app's own storage directory and
  /// returns the new absolute path to store on an [ImageElement].
  /// [originalFileName] is only used to preserve the file extension.
  /// Stored exactly as received, byte for byte - an earlier version of
  /// this recompressed/downscaled images on the way in, but that's
  /// reverted for now (see git history / conversation if it's revisited
  /// later) in favor of just keeping storage simple and predictable.
  ///
  /// Named after a SHA-256 hash of [bytes] rather than an import
  /// timestamp: importing the exact same picture twice (e.g. after
  /// deleting the note that had it, then adding the same photo back)
  /// lands on the same path and skips the write entirely instead of
  /// creating a second copy. This does mean two different [ImageElement]s
  /// can end up pointing at the same file on disk when their content is
  /// identical - LibraryController's delete-cleanup accounts for that by
  /// checking the rest of the library before actually removing a file,
  /// so deleting one of them never pulls the file out from under the
  /// other.
  Future<String> importImageBytes(Uint8List bytes, String originalFileName) async {
    final imagesDir = await _imagesDir();
    final ext = originalFileName.contains('.') ? originalFileName.split('.').last : 'png';
    final hash = sha256.convert(bytes).toString();
    final destPath = '${imagesDir.path}/$hash.$ext';
    final destFile = File(destPath);
    if (!await destFile.exists()) {
      await destFile.writeAsBytes(bytes);
    }
    return destPath;
  }

  /// Copies the file at [sourcePath] into this app's own storage
  /// directory - the same images/ folder and content-hash dedup
  /// [importImageBytes] already uses for pictures - and returns just
  /// the resulting basename (e.g. "3fae2c....html"), not a full path.
  /// A basename (rather than a full path, unlike [importImage]) is
  /// what NotePage.embeddedLinks stores, since a full path would be
  /// exactly the kind of device-specific string this exists to get
  /// away from - see the doc comment there. Returns null if
  /// [sourcePath] can't be read on this device at all (doesn't exist,
  /// or no permission) - callers treat that as "nothing to embed yet",
  /// not an error.
  Future<String?> importLinkedFile(String sourcePath) async {
    try {
      final file = File(sourcePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final destPath = await importImageBytes(bytes, sourcePath);
      return destPath.substring(destPath.lastIndexOf('/') + 1);
    } catch (_) {
      return null;
    }
  }

  /// Deletes an image file previously written by [importImage]/
  /// [importImageBytes] - called by LibraryController wherever an
  /// [ImageElement] pointing at it stops existing (the page/section/
  /// notebook it was on got deleted, locally or via a synced
  /// tombstone), so a deleted note doesn't leave its images behind on
  /// disk forever. Best-effort: a file that's already gone (nothing to
  /// do) or any other failure (permissions, a locked file, a bad path)
  /// is swallowed rather than thrown - a failed cleanup attempt should
  /// never block or crash the deletion that triggered it.
  /// Every distinct image file referenced by [notebooks]' pages (by
  /// [ImageElement.filePath]) that still exists on disk right now,
  /// keyed by its basename - the inverse of [restoreImageBytes], used
  /// by LibraryController.exportBackupBytes to bundle actual image
  /// bytes into a backup file instead of just a path that won't exist
  /// on whatever device/install restores it later. Best-effort: an
  /// image file that's gone missing (shouldn't normally happen, but
  /// isn't this method's job to fix) is silently skipped rather than
  /// failing the whole export.
  Future<Map<String, Uint8List>> collectReferencedImageBytes(List<Notebook> notebooks) async {
    final result = <String, Uint8List>{};
    for (final notebook in notebooks) {
      for (final section in notebook.sections) {
        for (final page in section.pages) {
          for (final el in page.elements) {
            if (el is! ImageElement) continue;
            final basename = el.filePath.substring(el.filePath.lastIndexOf('/') + 1);
            if (result.containsKey(basename)) continue; // already collected (content-hash dedup - see importImageBytes)
            try {
              final file = File(el.filePath);
              if (await file.exists()) {
                result[basename] = await file.readAsBytes();
              }
            } catch (e) {
              // ignore: avoid_print
              print('LocalStore: failed to read image $basename for backup: $e');
            }
          }
        }
      }
    }
    return result;
  }

  /// Writes one image bundled inside an imported backup file (see
  /// [collectReferencedImageBytes]/library_backup_codec.dart) into this
  /// device's own images/ folder under the same [filename] it was
  /// exported with - ImageElement.filePath is an absolute path, and
  /// LibraryController.importBackup rewrites each restored element's
  /// filePath to point at this device's own imagesDir + filename before
  /// this is called, so the two stay in sync. Skips writing if a file
  /// with that name already exists (the same content-hash dedup
  /// [importImageBytes] uses - a restore after a partial/failed earlier
  /// import, or importing the same backup twice, won't duplicate work).
  Future<void> restoreImageBytes(String filename, Uint8List bytes) async {
    final imagesDir = await _imagesDir();
    final file = File('${imagesDir.path}/$filename');
    if (!await file.exists()) {
      await file.writeAsBytes(bytes);
    }
  }

  Future<void> deleteImageFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort - see doc comment above.
    }
  }
}
