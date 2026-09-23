// A self-contained "export/import library" backup file format.
//
// Unlike the on-disk manifest+pages format (see LocalStore's doc
// comment), which is split across many small files for cheap
// incremental saves, a backup is a single portable file the user
// explicitly creates and can move anywhere: another folder, a USB
// drive, a cloud-synced folder, another device entirely. It exists
// specifically to survive things the normal on-disk storage can't -
// an Android uninstall (which wipes the app's entire private data
// directory, backup format notwithstanding - see AndroidManifest.xml's
// allowBackup="false") or a forced reinstall from a signing-key
// mismatch between debug and release builds.
//
// Deliberately reuses BinaryWriter/BinaryReader from
// binary_page_codec.dart (little-endian, length-prefixed strings/byte
// blobs) rather than pulling in a zip library: one full JSON snapshot
// of the whole notebook tree (WITH elements, unlike the on-disk
// manifest which blanks them out - see LocalStore._manifestJson) plus
// every referenced image's raw bytes, back to back in one file.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/notebook.dart';
import 'binary_page_codec.dart';

/// 'N','P','L','B' (Na-Pustakam Library Backup) + format version 1.
final Uint8List _backupHeader = Uint8List.fromList([0x4E, 0x50, 0x4C, 0x42, 0x01]);

/// What [decodeLibraryBackup] hands back: the notebooks and tombstones
/// exactly as [encodeLibraryBackup] was given them, plus every image
/// that was bundled alongside, keyed by the filename it should be
/// written back to disk under (see LocalStore.restoreImageBytes).
class LibraryBackupContents {
  LibraryBackupContents({required this.notebooks, required this.deletedNotebookIds, required this.images});

  final List<Notebook> notebooks;
  final Map<String, DateTime> deletedNotebookIds;
  final Map<String, Uint8List> images;
}

/// Builds one backup file's bytes from the current in-memory library
/// plus whichever image files [images] (see
/// LocalStore.collectReferencedImageBytes) are actually referenced by
/// it. [notebooks]' full elements are included (via Notebook.toJson(),
/// unblanked) - this is meant to be a complete, standalone snapshot,
/// not a diff against anything already on disk.
Uint8List encodeLibraryBackup({
  required List<Notebook> notebooks,
  required Map<String, DateTime> deletedNotebookIds,
  required Map<String, Uint8List> images,
}) {
  final manifestJson = jsonEncode({
    'notebooks': notebooks.map((n) => n.toJson()).toList(),
    'deletedNotebookIds': deletedNotebookIds.map((id, at) => MapEntry(id, at.toIso8601String())),
  });
  final manifestGz = gzip.encode(utf8.encode(manifestJson));

  final w = BinaryWriter();
  w.writeBytes(_backupHeader);
  w.writeUint32(manifestGz.length);
  w.writeBytes(manifestGz);
  w.writeUint32(images.length);
  for (final entry in images.entries) {
    w.writeString(entry.key);
    w.writeUint32(entry.value.length);
    w.writeBytes(entry.value);
  }
  return w.toBytes();
}

/// Reverses [encodeLibraryBackup]. Throws [FormatException] if [bytes]
/// doesn't start with the expected header (wrong file picked, or not a
/// Na-Pustakam backup at all) - callers show that to the user rather
/// than silently importing nothing.
LibraryBackupContents decodeLibraryBackup(Uint8List bytes) {
  final r = BinaryReader(bytes);
  final header = r.readBytes(_backupHeader.length);
  for (var i = 0; i < _backupHeader.length; i++) {
    if (header[i] != _backupHeader[i]) {
      throw const FormatException("This doesn't look like a Na-Pustakam library backup file.");
    }
  }
  final manifestGzLength = r.readUint32();
  final manifestGz = r.readBytes(manifestGzLength);
  final manifestJson = utf8.decode(gzip.decode(manifestGz));
  final map = jsonDecode(manifestJson) as Map<String, dynamic>;
  final notebooks = (map['notebooks'] as List).map((n) => Notebook.fromJson(n as Map<String, dynamic>)).toList();
  final deletedNotebookIds = (map['deletedNotebookIds'] as Map<String, dynamic>?)
          ?.map((id, at) => MapEntry(id, DateTime.parse(at as String))) ??
      <String, DateTime>{};

  final imageCount = r.readUint32();
  final images = <String, Uint8List>{};
  for (var i = 0; i < imageCount; i++) {
    final filename = r.readString();
    final length = r.readUint32();
    images[filename] = r.readBytes(length);
  }

  return LibraryBackupContents(notebooks: notebooks, deletedNotebookIds: deletedNotebookIds, images: images);
}
