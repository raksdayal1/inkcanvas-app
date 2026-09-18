import 'dart:ui';

import 'section.dart';

/// Top-level container: Notebook > Section > Page, same shape as OneNote.
class Notebook {
  Notebook({
    required this.id,
    required this.title,
    required this.color,
    this.ownerDeviceId,
    this.ownerDeviceName,
    List<NoteSection>? sections,
    DateTime? lastModified,
    Map<String, DateTime>? deletedSectionIds,
    Map<String, DateTime>? deletedPageIds,
  })  : sections = sections ?? [],
        lastModified = lastModified ?? DateTime.now(),
        deletedSectionIds = deletedSectionIds ?? {},
        deletedPageIds = deletedPageIds ?? {};

  final String id;
  String title;
  Color color;
  final List<NoteSection> sections;

  /// Bumped on ANY change to this notebook or anything inside it (a
  /// rename, a section/page created/renamed/deleted, a canvas edit) -
  /// see [touch]. This, not some derived "newest page" scan, is what
  /// SyncEngine compares to decide which side's copy of a notebook is
  /// fresher and needs pushing/pulling - see sync_engine.dart's
  /// _freshness. Anything that changes notebook state and wants that
  /// change to actually reach the other device MUST call [touch]
  /// (LibraryController does this for every mutation).
  DateTime lastModified;

  /// Tombstones for sections/pages deleted from this notebook, keyed by
  /// their id, valued by when the delete happened. Needed because the
  /// sync merge (LibraryController._mergeNotebookInPlace) is otherwise
  /// purely additive - without a record that something was
  /// *intentionally* removed, a peer that still has the old copy would
  /// just hand it right back on the next sync and resurrect it. A
  /// tombstone only loses to a genuinely newer edit of that same item
  /// (edit-after-delete-elsewhere wins, on the theory that editing it
  /// means the user wants to keep it) - see the merge logic for exactly
  /// how that's decided. Page ids are unique across the whole notebook
  /// (not just within one section), so a single flat map works for
  /// [deletedPageIds] without needing to nest it under each section.
  final Map<String, DateTime> deletedSectionIds;
  final Map<String, DateTime> deletedPageIds;

  void touch() => lastModified = DateTime.now();

  /// Which device created this notebook (see lib/sync/) - null means it
  /// was created before sync existed, which every ownership check below
  /// treats the same as "this device owns it". The owning device can
  /// always edit its own notebook; on any other device it's read-only
  /// unless there's a live sync connection to the owner right now.
  String? ownerDeviceId;

  /// Display-only (e.g. "Rakshit's Tablet") - never used for the
  /// ownership check itself, just so a read-only banner can name whose
  /// notebook this is instead of a raw device id.
  String? ownerDeviceName;

  bool isOwnedBy(String deviceId) => ownerDeviceId == null || ownerDeviceId == deviceId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'color': color.toARGB32(),
        'ownerDeviceId': ownerDeviceId,
        'ownerDeviceName': ownerDeviceName,
        'lastModified': lastModified.toIso8601String(),
        'deletedSectionIds': deletedSectionIds.map((id, at) => MapEntry(id, at.toIso8601String())),
        'deletedPageIds': deletedPageIds.map((id, at) => MapEntry(id, at.toIso8601String())),
        'sections': sections.map((s) => s.toJson()).toList(),
      };

  static Notebook fromJson(Map<String, dynamic> json) {
    return Notebook(
      id: json['id'] as String,
      title: json['title'] as String,
      color: Color(json['color'] as int),
      ownerDeviceId: json['ownerDeviceId'] as String?,
      ownerDeviceName: json['ownerDeviceName'] as String?,
      lastModified: json['lastModified'] != null ? DateTime.parse(json['lastModified'] as String) : null,
      deletedSectionIds: (json['deletedSectionIds'] as Map<String, dynamic>?)
          ?.map((id, at) => MapEntry(id, DateTime.parse(at as String))),
      deletedPageIds: (json['deletedPageIds'] as Map<String, dynamic>?)
          ?.map((id, at) => MapEntry(id, DateTime.parse(at as String))),
      sections: (json['sections'] as List)
          .map((s) => NoteSection.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}
