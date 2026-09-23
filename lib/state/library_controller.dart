import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/canvas_element.dart';
import '../models/notebook.dart';
import '../models/page.dart';
import '../models/section.dart';
import '../storage/local_store.dart';
import '../storage/page_change_set.dart';
import '../sync/device_identity.dart';
import '../sync/sync_engine.dart';

const _uuid = Uuid();

/// Thrown when a mutation is attempted on a notebook this device cannot
/// currently edit - i.e. a notebook owned by the other device while we're
/// not actively connected to it. UI code should catch this and show a
/// "read-only while disconnected" message rather than letting it crash.
class NotebookReadOnlyException implements Exception {
  NotebookReadOnlyException(this.notebookId);
  final String notebookId;
  @override
  String toString() =>
      'Notebook $notebookId is read-only on this device right now (owned by another device, not connected).';
}

/// Thrown by [LibraryController.deleteNotebook] when this device isn't
/// the notebook's owner. Unlike editing (which a connected non-owner
/// can do), deleting a whole notebook is owner-only, always - there's
/// no tombstone concept for "undo this delete", so letting a temporary
/// guest connection delete someone else's notebook would be one
/// careless tap away from actually destroying it everywhere.
class NotYourNotebookException implements Exception {
  NotYourNotebookException(this.notebookId);
  final String notebookId;
  @override
  String toString() => 'Only the device that owns notebook $notebookId can delete it.';
}

/// Owns the whole library (all notebooks) plus which notebook/section/page
/// is currently open. This is the single source of truth the UI screens
/// read from and mutate through — every mutation persists to disk via
/// [LocalStore] right after updating in-memory state, and (if a peer is
/// connected) pushes the changed notebook out via [syncEngine] immediately.
class LibraryController extends ChangeNotifier {
  LibraryController(this._store, this.identity);

  final LocalStore _store;
  final DeviceIdentity identity;

  /// Set once, right after construction in main(), before the first
  /// [load]. Nullable only so this class doesn't have to know about
  /// SyncEngine at construction time (SyncEngine itself needs a
  /// LibraryController to be built first).
  SyncEngine? syncEngine;

  // --- Debounced disk saves -------------------------------------------
  //
  // See _scheduleSave/_schedulePageSave/flushPendingSave below. Two
  // things used to make saving expensive: every mutation wrote to disk
  // immediately (fixed by debouncing - see _saveDebounceTimer), and
  // every write re-encoded the ENTIRE library, every page's ink
  // included, even for a single pen stroke on one page (fixed by
  // LocalStore's manifest+pages format - see its class doc comment -
  // plus _dirtyPages below, which is what lets a page-scoped edit only
  // ever touch that one page's own file rather than every page that
  // happens to exist).
  Timer? _saveDebounceTimer;
  bool _saveDirty = false;
  static const _saveDebounceDelay = Duration(milliseconds: 500);

  /// Pages with a pending, not-yet-flushed content edit (pen strokes,
  /// mainly), keyed by id so scheduling the same page's save twice in
  /// one debounce window doesn't queue it twice. Holds the actual
  /// [NotePage] object (mutated in place elsewhere - see
  /// StaticContentPainter's doc comment for why that matters) rather
  /// than just its id, so [flushPendingSave] can read its current
  /// elements directly without a separate lookup. Cleared (without
  /// individually flushing each one) whenever a full [_saveDirty] save
  /// happens instead, since that already covers every page.
  final Map<String, NotePage> _dirtyPages = {};

  /// Accumulated element-level changes for each page in [_dirtyPages],
  /// keyed by page id - see [PageChangeSet]. Merged (not overwritten)
  /// across multiple edits inside one debounce window via
  /// [PageChangeSet.applyNewer], so a burst of pen strokes ends up
  /// appending records for every one of them, not just the last.
  /// Absent (or empty) for a page whose only pending change is metadata
  /// the manifest already covers (e.g. a background change, or
  /// PageEditController.recordEmbeddedLink) - see [flushPendingSave].
  final Map<String, PageChangeSet> _dirtyPageChangeSets = {};

  @override
  void dispose() {
    _saveDebounceTimer?.cancel();
    super.dispose();
  }

  List<Notebook> notebooks = [];
  /// Tombstones for whole notebooks deleted by their owning device -
  /// see the class doc on LibraryData for why these need to be kept
  /// (and kept propagating to other peers) rather than just vanishing
  /// along with the notebook itself.
  Map<String, DateTime> deletedNotebookIds = {};

  /// Page ids whose *content* was just overwritten by an incoming sync
  /// merge (see _mergeNotebookInPlace) since the last time something
  /// checked - drained (consumed) by [consumeSyncedPageUpdate].
  ///
  /// This exists because PageScreen needs to tell two very different
  /// situations apart, both of which show up as the same thing (the open
  /// page's `lastModified` no longer matching what PageScreen last saw):
  /// a peer's edit landing on the page that's open right now (where the
  /// canvas needs a hard refresh - undo/redo history and any in-progress
  /// stroke are meaningless once the content underneath them just got
  /// replaced), versus this device's *own* local drawing, which also
  /// bumps `lastModified` on every stroke but must never trigger that
  /// same reset - doing so was wiping out whatever stroke the user was
  /// mid-drawing the moment some unrelated rebuild (e.g. SyncEngine's
  /// periodic discovery tick) happened to notice the now-stale
  /// `lastModified` from the stroke *before* it.
  final Set<String> _syncedPageIds = {};

  /// True (once) if [pageId]'s content was just overwritten by a sync
  /// merge since the last call - see [_syncedPageIds]. Consuming it
  /// clears the flag, so a page's own next local edit doesn't re-trigger
  /// the same "external update" handling in PageScreen.
  bool consumeSyncedPageUpdate(String pageId) => _syncedPageIds.remove(pageId);

  bool _loaded = false;
  bool get loaded => _loaded;

  String? selectedNotebookId;
  String? selectedSectionId;
  String? selectedPageId;

  Future<void> load() async {
    final data = await _store.loadLibrary();
    notebooks = data.notebooks;
    deletedNotebookIds = data.deletedNotebookIds;
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist({String? notebookId}) async {
    if (notebookId != null) {
      // Fire-and-forget: propagate the change to any connected peer right
      // away instead of waiting for the next periodic manifest exchange.
      // Reads straight off the in-memory `notebooks` list, so this is
      // unaffected by the disk save below being debounced - a connected
      // peer still sees every edit immediately, only this device's own
      // disk write is coalesced.
      unawaited(syncEngine?.pushNotebook(notebookId));
    }
    _scheduleSave();
  }

  /// Coalesces rapid-fire saves - one per pen stroke while actively
  /// drawing is the extreme case - into a single disk write after a
  /// short pause in editing, instead of paying the full-library
  /// encode+compress+write cost on every single one. If another edit
  /// lands before the timer fires, it just resets - so a long burst of
  /// strokes (or any other rapid edits) ends up doing exactly one write
  /// shortly after you stop, not one per edit.
  ///
  /// This only delays when the write happens, never whether it does -
  /// [flushPendingSave] is the other half, forcing it to happen right
  /// now instead of waiting out the timer, for anywhere that needs a
  /// guarantee the latest edits are actually on disk first (the app
  /// backgrounding/losing focus - see main.dart's lifecycle observer).
  void _scheduleSave() {
    _saveDirty = true;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(_saveDebounceDelay, () {
      unawaited(flushPendingSave());
    });
  }

  /// The fast path for a page-content edit (a pen stroke, mainly):
  /// schedules just [page]'s own file to be rewritten, plus the (much
  /// cheaper, ink-free) manifest, instead of going through
  /// [_scheduleSave]'s full-library rewrite - see LocalStore's
  /// saveManifest/savePageFile for why that's the whole point. Shares
  /// the same debounce timer as [_scheduleSave]: whichever one last
  /// scheduled something is what the timer waits out, and
  /// [flushPendingSave] below handles either kind (or both at once)
  /// correctly regardless of which fired it.
  void _schedulePageSave(NotePage page, PageChangeSet? changes) {
    _dirtyPages[page.id] = page;
    if (changes != null && !changes.isEmpty) {
      final existing = _dirtyPageChangeSets[page.id];
      if (existing == null) {
        _dirtyPageChangeSets[page.id] = PageChangeSet()..applyNewer(changes);
      } else {
        existing.applyNewer(changes);
      }
    }
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(_saveDebounceDelay, () {
      unawaited(flushPendingSave());
    });
  }

  /// Writes out whatever [_scheduleSave]/[_schedulePageSave] left
  /// pending, right now, rather than waiting for the timer - a no-op
  /// if nothing's pending. Safe to call as often as needed; only
  /// actually touches disk when there's something to flush.
  ///
  /// A pending full save (from [_scheduleSave]) always wins over and
  /// clears any pending page-only saves, since saveLibrary() already
  /// rewrites every page's file anyway - there's nothing left for the
  /// page-scoped saves to add once that's happened.
  Future<void> flushPendingSave() async {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    if (_saveDirty) {
      _saveDirty = false;
      _dirtyPages.clear();
      _dirtyPageChangeSets.clear();
      await _store.saveLibrary(notebooks, deletedNotebookIds);
      return;
    }
    if (_dirtyPages.isEmpty) return;
    final pages = _dirtyPages.values.toList(growable: false);
    final changeSets = Map<String, PageChangeSet>.of(_dirtyPageChangeSets);
    _dirtyPages.clear();
    _dirtyPageChangeSets.clear();
    await _store.saveManifest(notebooks, deletedNotebookIds);
    for (final page in pages) {
      final changes = changeSets[page.id];
      if (changes == null || changes.isEmpty) {
        // Nothing at the element level changed for this page - just a
        // metadata edit the manifest above already covers (a
        // background change, or PageEditController.recordEmbeddedLink).
        // No page-file work needed at all.
        continue;
      }
      await _store.appendPageChanges(page.id, page.elements, changes);
    }
  }

  // --- Ownership / read-only ------------------------------------------

  /// Whether this device may currently edit the given notebook: true if
  /// we own it (or it predates the ownership field), or if the other
  /// device owns it but we're live-connected to it right now.
  bool canEdit(String notebookId) {
    final notebook = notebooks.where((n) => n.id == notebookId).firstOrNull;
    if (notebook == null) return true; // let the caller's own lookup fail with a clearer error
    if (notebook.isOwnedBy(identity.id)) return true;
    final ownerId = notebook.ownerDeviceId;
    return ownerId != null && (syncEngine?.isConnectedTo(ownerId) ?? false);
  }

  void _assertEditable(String notebookId) {
    if (!canEdit(notebookId)) throw NotebookReadOnlyException(notebookId);
  }

  /// Deleting a whole notebook is stricter than editing it: only the
  /// device that owns it may delete it, connected or not (see
  /// NotYourNotebookException) - UNLESS the owning device's identity no
  /// longer exists anywhere we'd recognize it (e.g. that device's app
  /// data was wiped/reinstalled and it now has a fresh id). In that case
  /// the notebook would otherwise be permanently undeletable by anyone,
  /// since no device's [identity.id] can ever match the dead owner id
  /// again. We treat "no longer trusted" as the signal for "gone", as
  /// opposed to merely offline right now (which keeps it in the trusted
  /// list and should NOT unlock deletion). UI code (the notebook grid)
  /// uses this to decide whether to even offer the delete affordance.
  bool canDeleteNotebook(String notebookId) {
    final notebook = notebooks.where((n) => n.id == notebookId).firstOrNull;
    if (notebook == null) return false;
    if (notebook.isOwnedBy(identity.id)) return true;
    final ownerId = notebook.ownerDeviceId;
    if (ownerId != null &&
        syncEngine != null &&
        !syncEngine!.pairingStore.isTrusted(ownerId)) {
      return true;
    }
    return false;
  }

  /// Called by [SyncEngine] when a notebook arrives from a peer. Merges
  /// it into whatever's already here *in place* - rather than swapping in
  /// the whole incoming object graph - for two reasons:
  ///  - Per-page last-write-wins: the peer sends its whole notebook, but
  ///    only pages that are actually fresher here should overwrite this
  ///    device's copy of them, or a page edited more recently here could
  ///    be clobbered by a stale copy of it from the peer.
  ///  - Object identity: a currently-open page's PageEditController holds
  ///    a direct reference to its NotePage object. Mutating that same
  ///    object's fields in place (when it's fresher) means the canvas
  ///    picks the change up immediately; replacing it with a brand-new
  ///    object would silently orphan the controller from the library's
  ///    copy - new local edits would land on the orphaned object and
  ///    never get saved or pushed back out.
  /// Deliberately does NOT push back out to syncEngine - that would just
  /// bounce the same data right back to whoever just sent it.
  Future<void> applySyncedNotebook(Notebook incoming) async {
    final index = notebooks.indexWhere((n) => n.id == incoming.id);
    if (index < 0) {
      // Never seen this notebook before (created on the other device) -
      // nothing local references it yet, so there's no identity to
      // preserve; just add it as-is.
      notebooks.add(incoming);
    } else {
      final removedPages = _mergeNotebookInPlace(notebooks[index], incoming);
      _dropSelectionOfAnythingJustRemoved(notebooks[index]);
      for (final page in removedPages) {
        await _deleteImagesOnPage(page);
      }
    }
    await _store.saveLibrary(notebooks, deletedNotebookIds);
    notifyListeners();
  }

  /// Called by [SyncEngine] when a peer reports that a whole notebook
  /// was deleted - either immediately (a live "notebook-deleted" push
  /// right when it happened) or later, from a tombstone carried in a
  /// manifest exchange (for whenever this device wasn't connected at
  /// the time). Deleting a whole notebook is owner-only and final -
  /// there's no "edited after the delete" recreation case to weigh here
  /// the way there is for a section/page, since only the owner could
  /// ever have touched it in the first place, and the owner just
  /// deleted it - so this always wins outright.
  Future<void> applyNotebookDeletion(String notebookId, DateTime deletedAt) async {
    final alreadyKnown = deletedNotebookIds[notebookId];
    if (alreadyKnown != null && !deletedAt.isAfter(alreadyKnown)) {
      return; // already recorded this deletion (or a newer one) - nothing to do
    }
    deletedNotebookIds[notebookId] = deletedAt;
    final removedNotebook = notebooks.where((n) => n.id == notebookId).firstOrNull;
    notebooks.removeWhere((n) => n.id == notebookId);
    if (removedNotebook != null && selectedNotebookId == notebookId) goHome();
    await _store.saveLibrary(notebooks, deletedNotebookIds);
    if (removedNotebook != null) await _deleteImagesInNotebook(removedNotebook);
    notifyListeners();
  }

  /// Merges [incoming] into [local] in place. Returns every [NotePage]
  /// this merge just removed locally - a section or page tombstone
  /// taking effect - so [applySyncedNotebook] can clean up their image
  /// files afterward; this method stays synchronous (deleting files
  /// is not) and leaves that part to the caller.
  List<NotePage> _mergeNotebookInPlace(Notebook local, Notebook incoming) {
    final removedPages = <NotePage>[];
    local.title = incoming.title;
    local.color = incoming.color;
    local.ownerDeviceId = incoming.ownerDeviceId;
    local.ownerDeviceName = incoming.ownerDeviceName;
    local.lastModified = local.lastModified.isAfter(incoming.lastModified) ? local.lastModified : incoming.lastModified;

    // --- Deletions first: adopt the peer's tombstones (so they keep
    // propagating to whoever else this device syncs with), then apply
    // them here - unless this device has a newer edit of that exact
    // item than the delete itself, in which case treat the edit as an
    // intentional recreation and keep it instead of dropping it.
    for (final entry in incoming.deletedSectionIds.entries) {
      final existing = local.deletedSectionIds[entry.key];
      if (existing == null || entry.value.isAfter(existing)) {
        local.deletedSectionIds[entry.key] = entry.value;
      }
    }
    for (final entry in incoming.deletedPageIds.entries) {
      final existing = local.deletedPageIds[entry.key];
      if (existing == null || entry.value.isAfter(existing)) {
        local.deletedPageIds[entry.key] = entry.value;
      }
    }
    final removedSections = local.sections.where((section) {
      final deletedAt = local.deletedSectionIds[section.id];
      return deletedAt != null && !_sectionActivity(section).isAfter(deletedAt);
    }).toList();
    for (final section in removedSections) {
      removedPages.addAll(section.pages);
    }
    local.sections.removeWhere(removedSections.contains);
    for (final section in local.sections) {
      final removedFromThisSection = section.pages.where((page) {
        final deletedAt = local.deletedPageIds[page.id];
        return deletedAt != null && !page.lastModified.isAfter(deletedAt);
      }).toList();
      removedPages.addAll(removedFromThisSection);
      section.pages.removeWhere(removedFromThisSection.contains);
    }

    // --- Then merge in whatever the peer has that we don't, or that's
    // fresher than our copy of it.
    for (final incomingSection in incoming.sections) {
      final sectionDeletedAt = local.deletedSectionIds[incomingSection.id];
      if (sectionDeletedAt != null && !_sectionActivity(incomingSection).isAfter(sectionDeletedAt)) {
        continue; // tombstoned here, and the peer's copy isn't newer than that delete
      }
      final localSection = local.sections.where((s) => s.id == incomingSection.id).firstOrNull;
      if (localSection == null) {
        local.sections.add(incomingSection); // a new section created on the peer
        continue;
      }
      localSection.title = incomingSection.title;
      localSection.color = incomingSection.color;
      for (final incomingPage in incomingSection.pages) {
        final pageDeletedAt = local.deletedPageIds[incomingPage.id];
        if (pageDeletedAt != null && !incomingPage.lastModified.isAfter(pageDeletedAt)) {
          continue; // tombstoned here, and the peer's copy isn't newer than that delete
        }
        final localPage = localSection.pages.where((p) => p.id == incomingPage.id).firstOrNull;
        if (localPage == null) {
          localSection.pages.add(incomingPage); // a new page created on the peer
          continue;
        }
        if (!incomingPage.lastModified.isAfter(localPage.lastModified)) {
          continue; // our copy of this specific page is already as fresh or fresher
        }
        localPage.title = incomingPage.title;
        localPage.background = incomingPage.background;
        localPage.lastModified = incomingPage.lastModified;
        localPage.elements
          ..clear()
          ..addAll(incomingPage.elements);
        _syncedPageIds.add(localPage.id);
      }
    }
    return removedPages;
  }

  // --- Local image file cleanup ---------------------------------------

  /// True if some [ImageElement] still in the library points at
  /// [filePath]. Since [LocalStore.importImageBytes] names each image
  /// file after a hash of its bytes, two unrelated elements that happen
  /// to hold byte-for-byte identical images (e.g. the same picture
  /// inserted on two different pages, or re-inserted after being
  /// deleted once already) can end up sharing the exact same file on
  /// disk - so before deleting a file, every call site below has
  /// already removed the page/section/notebook that used to reference
  /// it from [notebooks], and this checks whether anything ELSE still
  /// does.
  bool _imagePathStillReferenced(String filePath) {
    for (final notebook in notebooks) {
      for (final section in notebook.sections) {
        for (final page in section.pages) {
          for (final element in page.elements) {
            if (element is ImageElement && element.filePath == filePath) return true;
          }
        }
      }
    }
    return false;
  }

  /// Deletes [filePath] from local storage, unless [_imagePathStillReferenced]
  /// says some other, still-live element needs it. Best-effort either
  /// way: see LocalStore.deleteImageFile.
  Future<void> _deleteImageIfUnreferenced(String filePath) async {
    if (_imagePathStillReferenced(filePath)) return;
    await _store.deleteImageFile(filePath);
  }

  /// Same idea as [_imagePathStillReferenced], for an embedded local-file
  /// link's basename (NotePage.embeddedLinks values) rather than an
  /// ImageElement's full path.
  bool _embeddedLinkFileStillReferenced(String basename) {
    for (final notebook in notebooks) {
      for (final section in notebook.sections) {
        for (final page in section.pages) {
          if (page.embeddedLinks.values.contains(basename)) return true;
        }
      }
    }
    return false;
  }

  /// Deletes an embedded-link file (see NotePage.embeddedLinks) from
  /// local storage, unless [_embeddedLinkFileStillReferenced] says some
  /// other, still-live page needs it. [basename] is resolved against
  /// LocalStore's images/ folder (the same folder importLinkedFile
  /// wrote it into) before deleting, since embeddedLinks only stores a
  /// basename, not a full path.
  Future<void> _deleteEmbeddedLinkFileIfUnreferenced(String basename) async {
    if (_embeddedLinkFileStillReferenced(basename)) return;
    final imagesDir = await _store.imagesDirectory();
    await _store.deleteImageFile('${imagesDir.path}/$basename');
  }

  /// Deletes every image file [page]'s elements point at from local
  /// storage (skipping any still referenced elsewhere - see
  /// [_deleteImageIfUnreferenced]). Called wherever a page stops
  /// existing on THIS device - deleted directly ([deletePage]), inside
  /// a deleted section or notebook, or removed here because a peer's
  /// tombstone says it was deleted on the device that owns it - so that
  /// inserting an image and later deleting the page it's on doesn't
  /// just leak the file on disk forever.
  ///
  /// Does NOT (yet) cover a page whose *content* gets overwritten by a
  /// fresher synced copy that simply no longer includes some image
  /// (see the elements..clear()..addAll(...) below) - that image is
  /// still an orphan on disk afterward. Worth revisiting, but it's a
  /// different problem (general unreferenced-image garbage collection)
  /// from "the note that owned this image was deleted", which is what
  /// this is scoped to for now.
  Future<void> _deleteImagesOnPage(NotePage page) async {
    for (final element in page.elements) {
      if (element is ImageElement) {
        await _deleteImageIfUnreferenced(element.filePath);
      }
    }
    for (final basename in page.embeddedLinks.values) {
      await _deleteEmbeddedLinkFileIfUnreferenced(basename);
    }
    // The page's own pages/<id>.dat file (see LocalStore's format doc
    // comment) is just as much this page's data as its images are -
    // same reasoning, same place, so it doesn't leak on disk forever
    // either. Also drop any not-yet-flushed save for it - nothing left
    // to write once the page itself is gone.
    _dirtyPages.remove(page.id);
    _dirtyPageChangeSets.remove(page.id);
    await _store.deletePageFile(page.id);
  }

  Future<void> _deleteImagesInSection(NoteSection section) async {
    for (final page in section.pages) {
      await _deleteImagesOnPage(page);
    }
  }

  Future<void> _deleteImagesInNotebook(Notebook notebook) async {
    for (final section in notebook.sections) {
      await _deleteImagesInSection(section);
    }
  }

  /// A section/page merged away by [_mergeNotebookInPlace] might be the
  /// one currently open - if so, back the selection out to something
  /// that still exists instead of leaving it pointing at a ghost.
  void _dropSelectionOfAnythingJustRemoved(Notebook notebook) {
    if (selectedNotebookId != notebook.id) return;
    final section = notebook.sections.where((s) => s.id == selectedSectionId).firstOrNull;
    if (section == null) {
      selectedSectionId = notebook.sections.isNotEmpty ? notebook.sections.first.id : null;
      selectedPageId = null;
      return;
    }
    final page = section.pages.where((p) => p.id == selectedPageId).firstOrNull;
    if (page == null) {
      selectedPageId = section.pages.isNotEmpty ? section.pages.first.id : null;
    }
  }

  /// A section has no lastModified of its own (only its pages do) - this
  /// is its implicit "last touched" time, used to decide whether a
  /// tombstone for it should stick or whether a newer edit elsewhere
  /// means it was intentionally recreated after being deleted.
  DateTime _sectionActivity(NoteSection section) {
    var latest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final page in section.pages) {
      if (page.lastModified.isAfter(latest)) latest = page.lastModified;
    }
    return latest;
  }

  // --- Lookups -------------------------------------------------------

  Notebook? get selectedNotebook =>
      notebooks.where((n) => n.id == selectedNotebookId).firstOrNull;

  NoteSection? get selectedSection =>
      selectedNotebook?.sections.where((s) => s.id == selectedSectionId).firstOrNull;

  NotePage? get selectedPage =>
      selectedSection?.pages.where((p) => p.id == selectedPageId).firstOrNull;

  // --- Navigation ------------------------------------------------------

  void openNotebook(String notebookId) {
    selectedNotebookId = notebookId;
    final notebook = selectedNotebook;
    selectedSectionId = notebook != null && notebook.sections.isNotEmpty
        ? notebook.sections.first.id
        : null;
    final section = selectedSection;
    selectedPageId = section != null && section.pages.isNotEmpty
        ? section.pages.first.id
        : null;
    notifyListeners();
  }

  void openSection(String sectionId) {
    selectedSectionId = sectionId;
    final section = selectedSection;
    selectedPageId = section != null && section.pages.isNotEmpty
        ? section.pages.first.id
        : null;
    notifyListeners();
  }

  void openPage(String pageId) {
    selectedPageId = pageId;
    notifyListeners();
  }

  void goHome() {
    selectedNotebookId = null;
    selectedSectionId = null;
    selectedPageId = null;
    notifyListeners();
  }

  // --- Mutations ---------------------------------------------------------

  Future<Notebook> createNotebook(String title, Color color) async {
    final notebook = Notebook(
      id: _uuid.v4(),
      title: title,
      color: color,
      ownerDeviceId: identity.id,
      ownerDeviceName: identity.name,
    );
    // Every notebook starts with one section and one page so it's
    // immediately usable, matching OneNote's "new notebook" behavior.
    final page = NotePage(id: _uuid.v4(), title: 'Page 1');
    final section = NoteSection(
      id: _uuid.v4(),
      title: 'Section 1',
      color: color,
      pages: [page],
    );
    notebook.sections.add(section);
    notebooks.add(notebook);
    await _persist(notebookId: notebook.id);
    notifyListeners();
    return notebook;
  }

  Future<void> deleteNotebook(String notebookId) async {
    if (!canDeleteNotebook(notebookId)) throw NotYourNotebookException(notebookId);
    final removedNotebook = notebooks.where((n) => n.id == notebookId).firstOrNull;
    final deletedAt = DateTime.now();
    deletedNotebookIds[notebookId] = deletedAt;
    notebooks.removeWhere((n) => n.id == notebookId);
    if (selectedNotebookId == notebookId) goHome();
    await _store.saveLibrary(notebooks, deletedNotebookIds);
    // Push immediately to whoever's connected right now, rather than
    // waiting for the next periodic manifest exchange - same idea as
    // _persist()'s pushNotebook, just the deletion equivalent.
    unawaited(syncEngine?.pushNotebookDeletion(notebookId, deletedAt));
    if (removedNotebook != null) await _deleteImagesInNotebook(removedNotebook);
    notifyListeners();
  }

  Future<void> renameNotebook(String notebookId, String title) async {
    _assertEditable(notebookId);
    final notebook = selectedNotebookOrThrow(notebookId);
    notebook.title = title;
    notebook.touch();
    await _persist(notebookId: notebookId);
    notifyListeners();
  }

  Future<NoteSection> createSection(String notebookId, String title, Color color) async {
    _assertEditable(notebookId);
    final notebook = selectedNotebookOrThrow(notebookId);
    final page = NotePage(id: _uuid.v4(), title: 'Page 1');
    final section = NoteSection(id: _uuid.v4(), title: title, color: color, pages: [page]);
    notebook.sections.add(section);
    notebook.touch();
    await _persist(notebookId: notebookId);
    notifyListeners();
    return section;
  }

  Future<void> deleteSection(String notebookId, String sectionId) async {
    _assertEditable(notebookId);
    final notebook = selectedNotebookOrThrow(notebookId);
    final removedSection = notebook.sections.where((s) => s.id == sectionId).firstOrNull;
    notebook.deletedSectionIds[sectionId] = DateTime.now();
    notebook.sections.removeWhere((s) => s.id == sectionId);
    notebook.touch();
    if (selectedSectionId == sectionId) {
      selectedSectionId = notebook.sections.isNotEmpty ? notebook.sections.first.id : null;
      selectedPageId = null;
    }
    if (removedSection != null) await _deleteImagesInSection(removedSection);
    await _persist(notebookId: notebookId);
    notifyListeners();
  }

  Future<void> renameSection(String notebookId, String sectionId, String title) async {
    _assertEditable(notebookId);
    _findSection(notebookId, sectionId).title = title;
    selectedNotebookOrThrow(notebookId).touch();
    await _persist(notebookId: notebookId);
    notifyListeners();
  }

  Future<NotePage> createPage(String notebookId, String sectionId, String title) async {
    _assertEditable(notebookId);
    final section = _findSection(notebookId, sectionId);
    final page = NotePage(id: _uuid.v4(), title: title);
    section.pages.add(page);
    selectedNotebookOrThrow(notebookId).touch();
    await _persist(notebookId: notebookId);
    notifyListeners();
    return page;
  }

  Future<void> deletePage(String notebookId, String sectionId, String pageId) async {
    _assertEditable(notebookId);
    final notebook = selectedNotebookOrThrow(notebookId);
    final section = _findSection(notebookId, sectionId);
    final removedPage = section.pages.where((p) => p.id == pageId).firstOrNull;
    notebook.deletedPageIds[pageId] = DateTime.now();
    section.pages.removeWhere((p) => p.id == pageId);
    notebook.touch();
    if (selectedPageId == pageId) {
      selectedPageId = section.pages.isNotEmpty ? section.pages.first.id : null;
    }
    if (removedPage != null) await _deleteImagesOnPage(removedPage);
    await _persist(notebookId: notebookId);
    notifyListeners();
  }

  Future<void> renamePage(String notebookId, String sectionId, String pageId, String title) async {
    _assertEditable(notebookId);
    final page = _findPage(notebookId, sectionId, pageId);
    page.title = title;
    page.touch();
    selectedNotebookOrThrow(notebookId).touch();
    await _persist(notebookId: notebookId);
    notifyListeners();
  }

  /// Reorders a page within its section: removes it from [oldIndex] and
  /// reinserts it at [newIndex], using the same index semantics as
  /// [ReorderableListView]'s onReorder callback (newIndex is where the
  /// item would land if inserted *before* being removed from oldIndex,
  /// so a downward move needs one subtracted off to land in the right
  /// slot afterward - the standard adjustment that callback always
  /// needs).
  ///
  /// Purely a local reorder of the in-memory list: page order isn't
  /// itself synced between devices today (_mergeNotebookInPlace only
  /// ever updates existing pages in place and never touches list
  /// position), so each device's page order stays independent until
  /// sync gains an explicit ordering field.
  Future<void> reorderPage(String notebookId, String sectionId, int oldIndex, int newIndex) async {
    _assertEditable(notebookId);
    final section = _findSection(notebookId, sectionId);
    if (oldIndex < 0 || oldIndex >= section.pages.length) return;
    final adjustedNewIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final page = section.pages.removeAt(oldIndex);
    section.pages.insert(adjustedNewIndex.clamp(0, section.pages.length), page);
    selectedNotebookOrThrow(notebookId).touch();
    await _persist(notebookId: notebookId);
    notifyListeners();
  }

  /// Called by the canvas controller after any edit to a page's elements.
  /// The canvas controller owns the live edit session; this just persists
  /// the result and marks the page as modified.
  Future<void> persistPageEdit(String notebookId, String sectionId, String pageId, {PageChangeSet? changes}) async {
    _assertEditable(notebookId);
    final page = _findPage(notebookId, sectionId, pageId);
    page.touch();
    selectedNotebookOrThrow(notebookId).touch();
    // Same immediate fire-and-forget push _persist() does for other
    // mutations - reads straight off the in-memory model, so it's
    // unaffected by the page-scoped disk save below being debounced.
    unawaited(syncEngine?.pushNotebook(notebookId));
    _schedulePageSave(page, changes);
    // No notifyListeners() here on purpose: the canvas widget already
    // rebuilds itself from its own controller on every stroke, and
    // rebuilding the whole navigation tree on every pen movement would be
    // wasteful. Screens that show "last modified" should listen to the
    // canvas controller instead, or this can be revisited later.
  }

  /// Wipes all local data (notebooks, images, this device's identity,
  /// its trusted-peer list) via [LocalStore.clearAllData] - see there for
  /// why this exists (Windows has no OS-level "clear app data" the way
  /// Android does on uninstall). Doesn't touch in-memory state itself;
  /// the caller (SyncScreen) is expected to close the app immediately
  /// afterward rather than keep using this now-stale controller.
  Future<void> clearAllData() => _store.clearAllData();

  // --- Internal helpers -----------------------------------------------

  Notebook selectedNotebookOrThrow(String notebookId) =>
      notebooks.firstWhere((n) => n.id == notebookId, orElse: () => throw StateError('Notebook not found'));

  NoteSection _findSection(String notebookId, String sectionId) {
    final notebook = selectedNotebookOrThrow(notebookId);
    return notebook.sections.firstWhere(
      (s) => s.id == sectionId,
      orElse: () => throw StateError('Section not found'),
    );
  }

  NotePage _findPage(String notebookId, String sectionId, String pageId) {
    final section = _findSection(notebookId, sectionId);
    return section.pages.firstWhere(
      (p) => p.id == pageId,
      orElse: () => throw StateError('Page not found'),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
