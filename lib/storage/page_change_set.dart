/// Which element ids on one page were added/changed ("put") or removed
/// ("deleted") since the last time storage consumed this - the unit
/// PageEditController hands to LibraryController/LocalStore so a page's
/// binary revision log (see local_store.dart's format doc comment) can
/// append records for just those elements instead of rewriting the
/// whole page. An id is always in exactly one of [put]/[deleted] at a
/// time - [markPut]/[markDeleted] each remove it from the other set
/// first, so a "moved then erased before the next flush" sequence
/// collapses to a single delete rather than a pointless put-then-delete.
class PageChangeSet {
  final Set<String> put = {};
  final Set<String> deleted = {};

  void markPut(String id) {
    deleted.remove(id);
    put.add(id);
  }

  void markDeleted(String id) {
    put.remove(id);
    deleted.add(id);
  }

  bool get isEmpty => put.isEmpty && deleted.isEmpty;

  /// Folds a chronologically-later change set on top of this one - used
  /// when several edits land inside the same debounce window (see
  /// LibraryController._schedulePageSave) and need to collapse into one
  /// set of records to append. Same per-id exclusivity as
  /// markPut/markDeleted, just applied in bulk.
  void applyNewer(PageChangeSet newer) {
    for (final id in newer.put) {
      markPut(id);
    }
    for (final id in newer.deleted) {
      markDeleted(id);
    }
  }
}
