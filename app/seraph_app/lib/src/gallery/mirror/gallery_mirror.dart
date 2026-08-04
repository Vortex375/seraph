import 'package:drift/drift.dart';
import 'package:seraph_app/src/gallery/local/local_media_item.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

/// The name of the (currently only) delta-feed source, used as the key into
/// [SyncCursors]. Kept as a named constant rather than a literal scattered
/// across the sync service and its tests, and because a second source
/// (unrelated to device items, which live in [GalleryItems] itself) is not
/// unthinkable.
const String gallerySyncSource = 'server';

/// [GalleryItems.origin] values. Plain strings on the row (see the column's
/// own doc for why), named here so the mirror and its tests never spell them
/// as bare literals.
const String _originCloud = 'cloud';
const String _originDevice = 'device';
const String _originBoth = 'both';

/// [GalleryItems.uploadState] values (ticket 20) - named here for the same
/// reason the origin values above are. See the column's own doc for what
/// each one means; [GalleryItemDisplay.isAwaitingVerification] in
/// `gallery_item_display.dart` and [GalleryUploadService.retryMismatchedUpload]
/// in `gallery_upload_service.dart` read these same raw strings back (raw
/// literals there too, matching how those files already read [origin]'s raw
/// values rather than importing private constants across files).
///
/// Two pairs, not two values: which pending state a row is in when the
/// upload succeeded is tracked separately from which pending state it moves
/// to on a contradicting feed length, because the two require different
/// recovery actions (ticket 20's rework) - a real PUT can safely have its
/// remote file deleted and retried, but the "assume it is ours" shortcut
/// must never delete a file this device did not write, only fall back to
/// disambiguation.
const String _uploadStateUploaded = 'uploaded';
const String _uploadStateAssumed = 'assumed';
const String _uploadStateMismatch = 'mismatch';
const String _uploadStateAssumedMismatch = 'assumedMismatch';

/// Ticket 22: the fixed id of [SyncRunState]'s single row - see that table's
/// class doc for why there is only ever one.
const String syncRunStateId = 'default';

/// [SyncRunState.status] values - named here for the same reason [origin]'s
/// and [uploadState]'s values are (see those constants' own doc), and read
/// back by [GallerySyncEngine] (`../sync/gallery_sync_engine.dart`) and
/// [GalleryDataSyncController] (`../sync/gallery_data_sync_controller.dart`)
/// as raw strings, matching how those files already read [origin] and
/// [uploadState].
///
/// No `interrupted` value: a `running` row a process did not survive to
/// clear reads back as [syncStatusPaused] once
/// [GalleryDataSyncController]'s startup reconciliation corrects it (see
/// that method's doc) - `paused` is already exactly "not running, but
/// resumable", so a fifth status would only duplicate it.
const String syncStatusIdle = 'idle';
const String syncStatusRunning = 'running';
const String syncStatusPaused = 'paused';
const String syncStatusCompleted = 'completed';
const String syncStatusError = 'error';

/// Ticket 23: the fixed id of [TokenRefreshLock]'s single row - see that
/// table's class doc for why there is only ever one.
const String tokenRefreshLockId = 'default';

/// Ticket 24: the fixed id of [SyncRunLock]'s single row - the same
/// single-well-known-row shape [tokenRefreshLockId] uses, for the same
/// reason: there is only ever one sync run worth serialising against.
const String syncRunLockId = 'default';

/// [SyncCursors.source] value for ticket 17's device-side incremental-scan
/// watermark - the highest MediaStore generation already applied. Reuses the
/// same tiny table the delta feed's [GalleryMirror.since]/[pendingCursor]
/// live in: both are exactly "how far has this device gotten through a
/// change feed", just two different feeds, so a second table would only
/// duplicate [SyncCursors]' shape for no reason.
const String localMediaSource = 'local-media';

/// [SyncCursors.source] value for ticket 30's full-scan cadence: epoch
/// milliseconds at which [GalleryMirror.recordFullScanAt] last recorded a
/// completed full Local Source scan. A third borrower of [SyncCursors]'
/// shape, for the same reason [localMediaSource] is - this is "how far has
/// this device gotten", just measured in wall-clock time rather than a feed
/// position, so a purpose-built table would only duplicate what this one
/// already provides.
const String localFullScanSource = 'local-full-scan';

/// [SyncCursors.source] value for ticket 30's sync throttle: epoch
/// milliseconds at which the last (non-throttled) [GalleryGridController.
/// syncNow] completed. Persisted rather than held in memory because the
/// throttle must survive [GalleryGridController] itself being torn down and
/// recreated - GetX's `fenix: true` rebuilds it on every navigation back to
/// the gallery (see the class doc on [GalleryGridController] for why that
/// registration exists) - and an in-memory-only throttle would reset itself
/// on exactly the navigation pattern it exists to guard against.
const String syncThrottleSource = 'sync-throttle';

/// D21/ticket 29's first-run default: a folder under `DCIM` is selected,
/// every other folder is not - applied only where [LocalFolderSelections] has
/// no explicit row for the folder (see [GalleryMirror.listLocalFolders]'s
/// doc for why that is what makes the seed apply once and never re-derive a
/// choice the user has already made).
bool _defaultFolderSelected(String folderPath) =>
    folderPath == 'DCIM' || folderPath.startsWith('DCIM/');

/// One configured Sync Pair (ticket 18), as the *Sync Pairs* section of the
/// Gallery folders screen shows it - what it maps to and how many photos it
/// currently covers (user story: "the pairs list shows what each pair maps
/// to and how many photos it covers").
///
/// Deliberately a different, richer shape than the database's own
/// `SyncPairRow` (see `@DataClassName` on `SyncPairs` in
/// `gallery_mirror_database.dart`): this is the seam's public model, the raw
/// row is a storage detail.
class SyncPair {
  const SyncPair({
    required this.id,
    required this.localFolderPath,
    required this.spaceProviderId,
    required this.path,
    required this.photoCount,
  });

  final int id;

  /// The device-side Local Source - on Android, MediaStore's `RELATIVE_PATH`
  /// for the folder (e.g. `DCIM/Camera/`), exactly [LocalFolder.path]'s
  /// format, so the same folder identifier means the same thing everywhere
  /// in the mirror.
  final String localFolderPath;

  /// The Seraph folder side, in Space terms - the same
  /// (spaceProviderId, path) pair `GallerySourceFolder` uses, since this
  /// folder IS one (ticket 18's rule: a Sync Pair's Seraph folder
  /// automatically becomes a Gallery Source Folder).
  final String spaceProviderId;
  final String path;

  /// How many gallery items - Device only or Synced alike - currently sit
  /// under [localFolderPath], regardless of whether creating this specific
  /// pair is what matched any of them.
  final int photoCount;

  /// The Seraph side, spelled the way the file browser spells it - space
  /// provider followed by the path inside it.
  String get seraphDisplayPath =>
      path == '/' ? '/$spaceProviderId' : '/$spaceProviderId$path';
}

/// Thrown by [GalleryMirror.createSyncPair] when [localFolderPath] overlaps
/// an existing Sync Pair's Local Source - equal to, a parent of, or a child
/// of it. Ticket 18's rule: **a Local Source may appear in at most one Sync
/// Pair**, because otherwise a photo would have two remote paths and two
/// verification states, and the remote path would stop being a pure function
/// (CONTEXT.md, D18 in `docs/gallery-mode-design-notes.md`). Overlap, not
/// just exact equality, is refused: a pair on `DCIM/` and a second on
/// `DCIM/Camera/` would let the same file be covered by both.
class SyncPairConflictException implements Exception {
  const SyncPairConflictException(
      this.localFolderPath, this.conflictingFolderPath);

  final String localFolderPath;
  final String conflictingFolderPath;

  @override
  String toString() =>
      '"$localFolderPath" is already covered by the Sync Pair for '
      '"$conflictingFolderPath" - a device folder can only be in one Sync '
      'Pair.';
}

/// One folder on the device, as ticket 29's *On this device* section shows
/// it.
class LocalFolder {
  const LocalFolder({
    required this.path,
    required this.photoCount,
    required this.selected,
  });

  /// The device's own folder identifier - on Android, MediaStore's
  /// `RELATIVE_PATH` (e.g. `DCIM/Camera/`), exactly what
  /// [GalleryItems.localRelativePath] stores.
  final String path;

  /// How many device photos currently sit in this folder, regardless of
  /// whether it is selected - user story 106, "choosing from evidence rather
  /// than from a folder name".
  final int photoCount;

  /// Whether this folder's photos currently feed the gallery - an explicit
  /// row in [LocalFolderSelections] if the user has ever toggled this
  /// folder, else [_defaultFolderSelected]. The exact predicate every read
  /// in this class applies, so this can never disagree with what the grid
  /// does with the folder's photos.
  final bool selected;
}

/// How a mirror query is restricted by Availability - the filter ticket 15
/// asks for ("filtered to items that are not backed up, and to Cloud only
/// items"), never affecting ordering, only membership.
enum GalleryAvailabilityFilter {
  /// No restriction - every item, any Availability.
  all,

  /// Device only: photos the device holds that Seraph does not (yet).
  /// "backed up" in the product's language always means Seraph independently
  /// vouching for a copy (D6/D19), which is [_originCloud] or [_originBoth]
  /// here - this filter is everything else.
  notBackedUp,

  /// Cloud only: photos Seraph holds that this device does not (any more, or
  /// never did).
  cloudOnly,
}

/// How many Gallery Items are backed up and how many are not - the single
/// number ticket 15 asks the gallery to show ("one number to trust rather
/// than a feeling", user story 17).
///
/// "Backed up" counts Synced and Cloud only alike: both mean Seraph currently
/// holds a copy. Only Device only items are not backed up. (Once Upload and
/// `verified` exist - phase 3 - this will need revisiting: a Synced item
/// today only means "the mirror matched a device photo to a cloud one by
/// content", not that this device uploaded and Seraph confirmed it. That
/// distinction is out of ticket 15's scope; tracked in the implementer
/// report.)
class GalleryAvailabilitySummary {
  const GalleryAvailabilitySummary({
    required this.deviceOnly,
    required this.synced,
    required this.cloudOnly,
  });

  final int deviceOnly;
  final int synced;
  final int cloudOnly;

  int get backedUp => synced + cloudOnly;
  int get notBackedUp => deviceOnly;
  int get total => deviceOnly + synced + cloudOnly;
}

/// One page of the mirror's Capture-Date-ordered query, together with the
/// total row count - what the (future) UI list, date scrubber and scrollbar
/// all need, and why the mirror is one indexed-queryable table rather than a
/// lazily merged pair of sources (see [GalleryMirrorDatabase] doc).
class GalleryMirrorPage {
  const GalleryMirrorPage({required this.items, required this.totalCount});

  final List<GalleryItem> items;
  final int totalCount;
}

/// The mirror seam: applies delta-feed pages to the local database and
/// answers the queries the (future) gallery UI needs, entirely from local
/// data - no network access happens in this class.
///
/// This is deliberately separate from [GallerySyncService] (which owns
/// talking to the HTTP API and the polling loop): this class is what ticket
/// 12's acceptance criteria mean by "driving the mirror and inspecting what
/// it returns" - applying feed pages and reading them back are both here,
/// independent of how the pages arrived over the wire.
class GalleryMirror {
  GalleryMirror(this._db);

  final GalleryMirrorDatabase _db;

  /// The last sequence value fully applied for [source] - `0` if nothing has
  /// ever been synced. This is what a cold start (no row, defaults to 0)
  /// and a subsequent sync (resumes from here) both read.
  Future<int> since({String source = gallerySyncSource}) async {
    final row = await (_db.select(_db.syncCursors)
          ..where((t) => t.source.equals(source)))
        .getSingleOrNull();
    return row?.since ?? 0;
  }

  /// The in-progress page cursor for [source], or null if no poll is
  /// currently mid-page. Persisted so a sync interrupted mid-page can resume
  /// after an app restart instead of restarting its poll from [since].
  Future<String?> pendingCursor({String source = gallerySyncSource}) async {
    final row = await (_db.select(_db.syncCursors)
          ..where((t) => t.source.equals(source)))
        .getSingleOrNull();
    return row?.pendingCursor;
  }

  /// Applies one delta-feed page: upserts non-tombstone items keyed on
  /// (providerId, path), deletes tombstoned ones, and records sync progress
  /// for [source] - all in one transaction, so a crash or interruption
  /// during `applyPage` leaves either the old state or the fully-applied new
  /// state, never a partial write visible to a reader.
  ///
  /// `page.hasMore` decides what progress gets persisted:
  /// - While a poll is still mid-page (`page.hasMore` true), `page.nextCursor`
  ///   is stored as [SyncCursors.pendingCursor] without moving
  ///   [SyncCursors.since] - so if the app is killed right after, the next
  ///   start resumes this same poll's cursor rather than re-requesting from
  ///   the old `since` (which would re-walk pages already applied - harmless,
  ///   since upserts and deletes are idempotent, but wasted work) or, worse,
  ///   than jumping to a `since` that skips whatever was in flight.
  /// - Once the poll finishes (`page.hasMore` false), `page.nextSince`
  ///   becomes the new [SyncCursors.since], with [SyncCursors.pendingCursor]
  ///   cleared.
  ///
  /// **Dedup with device items runs from this side too** (ticket 15): a cloud
  /// item that does not yet have a row here is checked against Device only
  /// rows before it is inserted as a new one, so which side's event arrives
  /// first - the local scan or the delta feed - never decides whether the
  /// merged gallery ends up with one row for a photo or two. See
  /// [applyLocalScan] for the mirror-image case.
  ///
  /// **Ticket 18 changes what "checked against" means.** A Sync Pair makes
  /// the match deterministic: if [item]'s path falls under a pair's Seraph
  /// folder, the Device only row it would have come from is computable by
  /// path alone ([_localIdentityForRemotePath]), and a match there wins
  /// outright - Capture Date is not even consulted, so a disagreeing one
  /// (server-extracted EXIF vs. the device's own) never blocks the merge.
  /// Only when no pair produces a match does the ticket 15 heuristic run,
  /// and even then it skips any Device only row a *different* pair covers -
  /// once a pair covers a device item, the heuristic never gets a vote on it
  /// (see [_coveringSyncPair]'s callers).
  ///
  /// **Ticket 21: Rule 2 is checked against every Sync Pair a Local Source
  /// has EVER had, not only its current one** ([_allSyncPairs], not
  /// [_activeSyncPairs]) - the spec's "current target for writes, all
  /// targets for lookups" rule. A cloud item arriving at an OLD target - a
  /// folder that remains a Gallery Source Folder after a retarget, still
  /// reported by the delta feed - inverts correctly through the (removed)
  /// pair row that produced it, so the matching Device only row is still
  /// found by path alone rather than falling through to the ticket 15
  /// heuristic (or worse, never matching at all and reading as unprotected).
  Future<void> applyPage(
    GalleryDeltaResponse page, {
    String source = gallerySyncSource,
  }) async {
    await _db.transaction(() async {
      final syncPairs = await _allSyncPairs();

      for (final item in page.items) {
        final existing = await (_db.select(_db.galleryItems)
              ..where((t) =>
                  t.providerId.equals(item.providerId) &
                  t.path.equals(item.path)))
            .getSingleOrNull();

        if (item.tombstone) {
          if (existing == null) {
            continue;
          }
          if (existing.origin == _originBoth) {
            // The cloud copy is gone but the device copy is not - demote to
            // Device only rather than deleting the row. Deleting here would
            // make a photo that is still physically on the phone vanish from
            // the gallery, which breaks "a device photo keeps the same
            // position in the timeline whether it is Device only or Synced".
            await (_db.update(_db.galleryItems)
                  ..where((t) => t.id.equals(existing.id)))
                .write(const GalleryItemsCompanion(
              origin: Value(_originDevice),
              providerId: Value(null),
              path: Value(null),
              seq: Value(null),
            ));
          } else {
            await (_db.delete(_db.galleryItems)
                  ..where((t) => t.id.equals(existing.id)))
                .go();
          }
          continue;
        }

        if (existing != null) {
          // Already a row for this (providerId, path) - cloud-only or
          // already merged with a device row. Update the cloud-derived
          // columns in place; [origin] and any local* columns are left
          // untouched, so a Synced item stays Synced.
          await (_db.update(_db.galleryItems)
                ..where((t) => t.id.equals(existing.id)))
              .write(GalleryItemsCompanion(
            seq: Value(item.seq),
            capturedAt: Value(item.capturedAt),
            capturedAtSource: Value(item.capturedAtSource),
            width: Value(item.width),
            height: Value(item.height),
            orientation: Value(item.orientation),
            size: Value(item.size),
            mime: Value(item.mime),
            unsupported: Value(item.unsupported),
            metadataPending: Value(item.metadataPending),
          ));
          continue;
        }

        // No row for this (providerId, path) yet.
        //
        // Ticket 20 verification: is there a Device only row with an upload
        // pending confirmation at EXACTLY this (providerId, path)? Checked
        // before Rule 2/3 below because it is the strongest possible signal
        // - the literal path [GalleryUploadService] recorded, not a path
        // Rule 2 would have to re-derive from the Sync Pair (which gets a
        // disambiguated upload's real path wrong - ticket 19's "record the
        // path actually used, not a recipe for deriving it").
        final pendingUpload = await (_db.select(_db.galleryItems)
              ..where((t) =>
                  t.origin.equals(_originDevice) &
                  t.uploadTargetProviderId.equals(item.providerId) &
                  t.uploadTargetPath.equals(item.path))
              ..limit(1))
            .getSingleOrNull();

        if (pendingUpload != null) {
          if (item.size == (pendingUpload.localSize ?? -1)) {
            // Verified: Seraph independently reports a file at the expected
            // path with the expected length (CONTEXT.md's **Verified**).
            // This is the ONLY place [origin] flips to `both` on the back of
            // an upload - never [recordUploaded] itself (ticket 20's "no
            // code path marks an item Verified on the basis of the upload
            // response alone").
            await (_db.update(_db.galleryItems)
                  ..where((t) => t.id.equals(pendingUpload.id)))
                .write(GalleryItemsCompanion(
              origin: const Value(_originBoth),
              providerId: Value(item.providerId),
              path: Value(item.path),
              seq: Value(item.seq),
              capturedAtSource: Value(item.capturedAtSource),
              width: Value(item.width),
              height: Value(item.height),
              orientation: Value(item.orientation),
              size: Value(item.size),
              mime: Value(item.mime),
              unsupported: Value(item.unsupported),
              metadataPending: Value(item.metadataPending),
              uploadTargetProviderId: const Value(null),
              uploadTargetPath: const Value(null),
              uploadState: const Value(null),
              // capturedAt deliberately NOT rewritten - same rule as every
              // other merge in this class: the device row that already
              // existed keeps its timeline position.
            ));
          } else {
            // Verification CONTRADICTS what this device expected. [origin]
            // stays `device` either way: still visibly not-backed-up, the
            // safe direction, until a retry succeeds. Which pending state
            // this row was in decides what "retry" is allowed to do
            // (ticket 20's rework - see the class-level doc on the
            // [_uploadStateUploaded]/[_uploadStateAssumed] constants):
            //
            // - `_uploadStateUploaded` (a real PUT): the remote file at
            //   this exact path IS this device's own upload, so it can
            //   safely be deleted and retried -
            //   [GalleryUploadService.retryMismatchedUpload] does that.
            // - `_uploadStateAssumed` (the ticket-19 "same size, assume it
            //   is ours" shortcut): this device never wrote that file, so a
            //   contradicting length only proves the ASSUMPTION was wrong,
            //   never permission to delete someone else's content -
            //   [GalleryUploadService.retryMismatchedUpload] falls back to
            //   disambiguation instead, leaving the file exactly as it was.
            final wasAssumed = pendingUpload.uploadState == _uploadStateAssumed;
            await (_db.update(_db.galleryItems)
                  ..where((t) => t.id.equals(pendingUpload.id)))
                .write(GalleryItemsCompanion(
              uploadState: Value(wasAssumed
                  ? _uploadStateAssumedMismatch
                  : _uploadStateMismatch),
            ));
          }
          continue;
        }

        // Rule 2 (ticket 18): a Sync Pair whose Seraph folder covers
        // [item.path] makes the matching Device only row computable by path
        // alone - try every pair whose provider matches, first match wins
        // (create-time overlap checking keeps this to at most one in
        // practice).
        GalleryItem? pairMatch;
        for (final pair in syncPairs) {
          if (pair.spaceProviderId != item.providerId) {
            continue;
          }
          final identity = _localIdentityForRemotePath(pair, item.path);
          if (identity == null) {
            continue;
          }
          pairMatch = await (_db.select(_db.galleryItems)
                ..where((t) =>
                    t.origin.equals(_originDevice) &
                    t.localRelativePath.equals(identity.$1) &
                    t.localDisplayName.equals(identity.$2) &
                    t.size.equals(item.size))
                ..limit(1))
              .getSingleOrNull();
          if (pairMatch != null) {
            break;
          }
        }

        if (pairMatch != null) {
          await (_db.update(_db.galleryItems)
                ..where((t) => t.id.equals(pairMatch!.id)))
              .write(GalleryItemsCompanion(
            origin: const Value(_originBoth),
            providerId: Value(item.providerId),
            path: Value(item.path),
            seq: Value(item.seq),
            capturedAtSource: Value(item.capturedAtSource),
            width: Value(item.width),
            height: Value(item.height),
            orientation: Value(item.orientation),
            size: Value(item.size),
            mime: Value(item.mime),
            unsupported: Value(item.unsupported),
            metadataPending: Value(item.metadataPending),
            // capturedAt deliberately NOT rewritten - the path+size match is
            // deterministic regardless of whether the two sides agree on
            // Capture Date (ticket 18's disagreeing-date criterion), and the
            // row must not move either way.
          ));
          continue;
        }

        // Rule 3: the ticket 15 heuristic, but only among Device only rows
        // no Sync Pair covers - a covered row already had its one chance at
        // rule 2 above and must not be handed a second, looser one.
        final heuristicCandidates = await (_db.select(_db.galleryItems)
              ..where((t) =>
                  t.origin.equals(_originDevice) &
                  t.size.equals(item.size) &
                  t.capturedAt.equals(item.capturedAt)))
            .get();
        GalleryItem? deviceMatch;
        for (final candidate in heuristicCandidates) {
          if (_coveringSyncPair(
                  syncPairs, candidate.localRelativePath ?? '') ==
              null) {
            deviceMatch = candidate;
            break;
          }
        }

        if (deviceMatch != null) {
          await (_db.update(_db.galleryItems)
                ..where((t) => t.id.equals(deviceMatch!.id)))
              .write(GalleryItemsCompanion(
            origin: const Value(_originBoth),
            providerId: Value(item.providerId),
            path: Value(item.path),
            seq: Value(item.seq),
            capturedAtSource: Value(item.capturedAtSource),
            width: Value(item.width),
            height: Value(item.height),
            orientation: Value(item.orientation),
            size: Value(item.size),
            mime: Value(item.mime),
            unsupported: Value(item.unsupported),
            metadataPending: Value(item.metadataPending),
            // capturedAt deliberately NOT rewritten: it already equals
            // item.capturedAt (that is what made this row match), and never
            // touching it here is what keeps a merged item at the same
            // timeline position it already held.
          ));
          continue;
        }

        await _db.into(_db.galleryItems).insert(
              GalleryItemsCompanion.insert(
                origin: const Value(_originCloud),
                providerId: Value(item.providerId),
                path: Value(item.path),
                seq: Value(item.seq),
                capturedAt: item.capturedAt,
                capturedAtSource: Value(item.capturedAtSource),
                width: Value(item.width),
                height: Value(item.height),
                orientation: Value(item.orientation),
                size: Value(item.size),
                mime: Value(item.mime),
                unsupported: Value(item.unsupported),
                metadataPending: Value(item.metadataPending),
              ),
            );
      }

      final cursorRow = SyncCursorsCompanion(
        source: Value(source),
        since:
            Value(page.hasMore ? await since(source: source) : page.nextSince),
        pendingCursor: Value(page.hasMore ? page.nextCursor : null),
      );
      await _db.into(_db.syncCursors).insertOnConflictUpdate(cursorRow);
    });
  }

  /// Applies one full Local Source scan (ticket 15's correctness anchor) to
  /// the mirror: every currently-visible device photo is upserted by local
  /// identity, and any row previously backed by the device but absent from
  /// [items] is treated as removed from the device.
  ///
  /// **Matching, in order (ticket 18 inserted the new rule 2; the others are
  /// ticket 15's, renumbered):**
  /// 1. A row already carrying this exact local identity - `(relativePath,
  ///    displayName, size, dateTaken)` - is left alone. This is what makes a
  ///    changed (non-durable) media-store id a no-op: identity, not id,
  ///    decides "have we seen this file before".
  /// 2. Otherwise, if a Sync Pair covers [item]'s folder - **ticket 21:
  ///    checked against every target that Local Source has EVER had, not
  ///    only its current one** - each candidate target's expected remote
  ///    path is a pure function of `(pair, relative path)`, and a Cloud only
  ///    row at that exact path, matching size, is merged onto
  ///    deterministically. This is the item's ONLY remaining chance to
  ///    match: rule 3 below never runs for a covered item, matched or not
  ///    (see [_upsertLocalItem]'s doc). Consulting historical targets too is
  ///    what makes "already backed up" survive a retarget: a device photo
  ///    already sitting at the OLD target must still be recognised as
  ///    already-backed-up rather than merely as one no active pair happens
  ///    to explain (which would both duplicate it and, worse, tell the user
  ///    their library is unprotected when it is not).
  /// 3. Otherwise (no pair covers this item), a Cloud only row matching by
  ///    `(size, capturedAt)` is plausibly the same photo arriving from the
  ///    other side - e.g. a photo already in Seraph (copied over SMB,
  ///    uploaded from the web UI, from another phone) that also happens to
  ///    sit on this device, with no Sync Pair covering it. Merging onto that
  ///    row is what makes "a photo present both on the device and in Seraph
  ///    appears exactly once" true even for photos no Sync Pair will ever
  ///    cover. `(size, capturedAt)` rather than a content hash: D19/the
  ///    spec's "no content hashing anywhere" rule applies here too, and this
  ///    ticket has even less to go on than the upload path's path+size
  ///    reconcile, since an uncovered device item's path is never a Seraph
  ///    path. The false-negative failure mode (two distinct photos of
  ///    identical size taken in the same second) produces a harmless
  ///    duplicate row, not a wrong merge. This is explicitly best-effort -
  ///    see [_upsertLocalItem]'s doc for why rule 2 always outranks it.
  /// 4. Otherwise, a new Device only row.
  ///
  /// A row already known to have a device copy ([_originDevice] or
  /// [_originBoth]) whose identity does not appear in this scan has lost its
  /// device copy since the last scan: a [_originDevice] row is deleted
  /// outright, a [_originBoth] row is demoted to [_originCloud] (Cloud only)
  /// rather than deleted - the cloud copy still exists, and the row stays at
  /// its Capture Date position rather than disappearing and (if the same
  /// photo reappears later) reappearing as a new row elsewhere in scroll
  /// order.
  Future<void> applyLocalScan(List<LocalMediaItem> items) async {
    await _db.transaction(() async {
      final syncPairs = await _allSyncPairs();
      final seenIdentities = <String>{};

      for (final item in items) {
        seenIdentities.add(_localIdentityKey(
          relativePath: item.relativePath,
          displayName: item.displayName,
          size: item.size,
          dateTakenMillis: item.dateTakenMillis,
        ));
        await _upsertLocalItem(item, syncPairs);
      }

      final previouslyOnDevice = await (_db.select(_db.galleryItems)
            ..where((t) =>
                t.origin.equals(_originDevice) | t.origin.equals(_originBoth)))
          .get();

      for (final row in previouslyOnDevice) {
        final key = _localIdentityKey(
          relativePath: row.localRelativePath ?? '',
          displayName: row.localDisplayName ?? '',
          size: row.localSize ?? -1,
          dateTakenMillis: row.localDateTaken ?? -1,
        );
        if (seenIdentities.contains(key)) {
          continue;
        }

        if (row.origin == _originDevice) {
          await (_db.delete(_db.galleryItems)
                ..where((t) => t.id.equals(row.id)))
              .go();
        } else {
          await (_db.update(_db.galleryItems)
                ..where((t) => t.id.equals(row.id)))
              .write(const GalleryItemsCompanion(
            origin: Value(_originCloud),
            localRelativePath: Value(null),
            localDisplayName: Value(null),
            localSize: Value(null),
            localDateTaken: Value(null),
          ));
        }
      }
    });
  }

  /// Applies one incremental scan (ticket 17's fast path) to the mirror:
  /// upserts [items] by local identity using exactly [applyLocalScan]'s
  /// matching rules, then persists [generation] as the new watermark.
  ///
  /// **Unlike [applyLocalScan], this never removes or demotes a row.** An
  /// incremental scan only knows what changed since the watermark - it has
  /// no view of the rest of the library, so a row it does not mention says
  /// nothing about whether that photo still exists. Treating "absent from
  /// this batch" as "deleted" would be exactly the mistake the ticket's
  /// governing rule forbids: [applyLocalScan] (the correctness anchor) is
  /// the only place a device photo is ever removed from the mirror.
  Future<void> applyLocalDelta(
    List<LocalMediaItem> items, {
    required int generation,
  }) async {
    await _db.transaction(() async {
      final syncPairs = await _allSyncPairs();
      for (final item in items) {
        await _upsertLocalItem(item, syncPairs);
      }
      await _writeLocalGeneration(generation);
    });
  }

  /// The device-side incremental-scan watermark (ticket 17): the highest
  /// MediaStore generation already applied via [applyLocalDelta], or `0` if
  /// no scan has ever primed it - the same "0 means from the beginning"
  /// convention [since] uses for the delta feed. Persisted in [SyncCursors],
  /// so it survives an app restart exactly as the delta feed's cursor does.
  Future<int> localGeneration() => since(source: localMediaSource);

  /// Sets the incremental-scan watermark directly, without applying any
  /// items - used once, right after [applyLocalScan], to prime it at "now"
  /// (see [LocalSource.currentGeneration]'s doc for why) rather than leaving
  /// it at whatever it was before the full scan ran.
  Future<void> primeLocalGeneration(int generation) async {
    await _writeLocalGeneration(generation);
  }

  Future<void> _writeLocalGeneration(int generation) =>
      _writeCursorSince(localMediaSource, generation);

  /// Epoch milliseconds at which a full Local Source scan last completed, or
  /// `0` if one never has - ticket 30's "nothing has ever scanned" and "the
  /// last full scan is older than the backstop interval" checks both read
  /// this, since `0` means the same "from the beginning" thing here that it
  /// does for [since] and [localGeneration].
  Future<int> lastFullScanAt() => since(source: localFullScanSource);

  /// Records [epochMillis] as the moment a full Local Source scan last
  /// completed. Called only after a full scan itself succeeds - a failed
  /// scan must not push this watermark forward, or a device stuck failing
  /// every scan would never be retried once the backstop interval alone
  /// gated it.
  Future<void> recordFullScanAt(int epochMillis) =>
      _writeCursorSince(localFullScanSource, epochMillis);

  /// Epoch milliseconds at which the last (non-throttled) sync completed,
  /// or `0` if none ever has - what the sync throttle's window is measured
  /// from.
  Future<int> lastSyncedAt() => since(source: syncThrottleSource);

  /// Records [epochMillis] as the moment the last (non-throttled) sync
  /// completed - called once, at the end of a sync that actually ran, never
  /// for one the throttle itself skipped (skipping is the whole point:
  /// recording a throttled call's time would push every subsequent call's
  /// throttle window forward for nothing).
  Future<void> recordSyncedAt(int epochMillis) =>
      _writeCursorSince(syncThrottleSource, epochMillis);

  Future<void> _writeCursorSince(String source, int value) async {
    await _db.into(_db.syncCursors).insertOnConflictUpdate(
          SyncCursorsCompanion(
            source: Value(source),
            since: Value(value),
          ),
        );
  }

  /// The matching rules shared by [applyLocalScan] and [applyLocalDelta]:
  /// a row already carrying [item]'s exact local identity is left alone.
  /// Otherwise, ticket 18's rule order decides what happens next:
  ///
  /// - If a Sync Pair in [syncPairs] covers [item]'s folder
  ///   ([_allCoveringSyncPairs]), each covering pair's expected remote path
  ///   is computed ([_expectedRemotePath]) in turn - current target first,
  ///   see that method's doc - and a Cloud only row there, matching size, is
  ///   merged onto as soon as one is found. **Ticket 21: every target the
  ///   folder has EVER had is tried, not only the current one** - a photo
  ///   already sitting at an old, historical target (from before a
  ///   retarget) still merges deterministically instead of silently
  ///   becoming a second, unmatched Device only row. **Whether or not any
  ///   target matches, this is the item's only chance** - a covered item
  ///   never falls through to the heuristic below, so two burst-shot device
  ///   photos of identical size and Capture Date, both covered by the same
  ///   pair, stay two Device only rows rather than colliding onto one (the
  ///   failure the heuristic was always liable to and ticket 18 exists to
  ///   fix for covered items).
  /// - Otherwise (no pair, current or historical, covers [item]), a Cloud
  ///   only row matching by `(size, capturedAt)` is plausibly the same photo
  ///   arriving from the other side - ticket 15's original best-effort
  ///   heuristic, explicitly named as such and never treated as
  ///   authoritative; merged onto if found.
  /// - Otherwise, a new Device only row.
  ///
  /// Never deletes or demotes anything - that determination needs the whole
  /// scan's result set, which only [applyLocalScan] has.
  Future<void> _upsertLocalItem(
    LocalMediaItem item,
    List<SyncPairRow> syncPairs,
  ) async {
    final existingByIdentity = await (_db.select(_db.galleryItems)
          ..where((t) =>
              t.localRelativePath.equals(item.relativePath) &
              t.localDisplayName.equals(item.displayName) &
              t.localSize.equals(item.size) &
              t.localDateTaken.equals(item.dateTakenMillis))
          ..limit(1))
        .getSingleOrNull();
    if (existingByIdentity != null) {
      return;
    }

    final capturedAt = _capturedAtSeconds(item);
    final capturedAtSource = item.dateTakenMillis > 0 ? 'exif' : 'modTime';

    final coveringPairs = _allCoveringSyncPairs(syncPairs, item.relativePath);

    if (coveringPairs.isNotEmpty) {
      for (final pair in coveringPairs) {
        final expected =
            _expectedRemotePath(pair, item.relativePath, item.displayName);
        final pairMatch = await (_db.select(_db.galleryItems)
              ..where((t) =>
                  t.origin.equals(_originCloud) &
                  t.providerId.equals(expected.$1) &
                  t.path.equals(expected.$2) &
                  t.size.equals(item.size))
              ..limit(1))
            .getSingleOrNull();

        if (pairMatch != null) {
          await (_db.update(_db.galleryItems)
                ..where((t) => t.id.equals(pairMatch.id)))
              .write(GalleryItemsCompanion(
            origin: const Value(_originBoth),
            localRelativePath: Value(item.relativePath),
            localDisplayName: Value(item.displayName),
            localSize: Value(item.size),
            localDateTaken: Value(item.dateTakenMillis),
            // capturedAt deliberately NOT rewritten - the match is on path
            // plus size alone, so a disagreeing Capture Date (ticket 18's
            // criterion) never blocks it, and the row must not move either
            // way.
          ));
          return;
        }
      }

      // Covered (currently or historically) but nothing uploaded to any of
      // those targets yet - a new Device only row. The heuristic below is
      // never reached: once a pair covers an item, it is the only vote
      // (ticket 18, extended by ticket 21 to every target it has ever had).
      await _db.into(_db.galleryItems).insert(
            GalleryItemsCompanion.insert(
              origin: const Value(_originDevice),
              localRelativePath: Value(item.relativePath),
              localDisplayName: Value(item.displayName),
              localSize: Value(item.size),
              localDateTaken: Value(item.dateTakenMillis),
              capturedAt: capturedAt,
              capturedAtSource: Value(capturedAtSource),
              size: Value(item.size),
            ),
          );
      return;
    }

    // No Sync Pair covers this item - ticket 15's original heuristic,
    // unchanged, and still explicitly best-effort: two distinct photos of
    // identical size taken in the same second can still collide here. That
    // is accepted for items nothing will ever compute a deterministic path
    // for.
    final cloudMatch = await (_db.select(_db.galleryItems)
          ..where((t) =>
              t.origin.equals(_originCloud) &
              t.size.equals(item.size) &
              t.capturedAt.equals(capturedAt))
          ..limit(1))
        .getSingleOrNull();

    if (cloudMatch != null) {
      await (_db.update(_db.galleryItems)
            ..where((t) => t.id.equals(cloudMatch.id)))
          .write(GalleryItemsCompanion(
        origin: const Value(_originBoth),
        localRelativePath: Value(item.relativePath),
        localDisplayName: Value(item.displayName),
        localSize: Value(item.size),
        localDateTaken: Value(item.dateTakenMillis),
        // capturedAt deliberately NOT rewritten - see applyPage's mirror
        // case for why: the row must not move.
      ));
      return;
    }

    await _db.into(_db.galleryItems).insert(
          GalleryItemsCompanion.insert(
            origin: const Value(_originDevice),
            localRelativePath: Value(item.relativePath),
            localDisplayName: Value(item.displayName),
            localSize: Value(item.size),
            localDateTaken: Value(item.dateTakenMillis),
            capturedAt: capturedAt,
            capturedAtSource: Value(capturedAtSource),
            size: Value(item.size),
          ),
        );
  }

  static String _localIdentityKey({
    required String relativePath,
    required String displayName,
    required int size,
    required int dateTakenMillis,
  }) =>
      '$relativePath\x00$displayName\x00$size\x00$dateTakenMillis';

  /// Capture Date in epoch SECONDS, matching the unit [GalleryItems.capturedAt]
  /// stores throughout: `dateTaken` when the platform has one, else
  /// `dateModified` - the device-side mirror of the server's EXIF-then-
  /// modification-time fallback chain.
  static int _capturedAtSeconds(LocalMediaItem item) {
    final millis = item.dateTakenMillis > 0
        ? item.dateTakenMillis
        : item.dateModifiedMillis;
    return millis ~/ 1000;
  }

  // --- Ticket 18: Sync Pairs ---

  /// Every currently ACTIVE Sync Pair ([SyncPairRow.removedAt] null),
  /// unordered - the spec's "current target for writes" half. What decides
  /// where a NEW upload goes ([expectedUploadTarget]), what [createSyncPair]
  /// checks its overlap rule against, and what [listSyncPairs] shows. A
  /// removed pair is never a candidate for any of these three, even though
  /// its row is kept around (see [SyncPairs]' class doc) for
  /// [_allSyncPairs]' sake.
  Future<List<SyncPairRow>> _activeSyncPairs() =>
      (_db.select(_db.syncPairs)..where((t) => t.removedAt.isNull())).get();

  /// Every Sync Pair a Local Source has EVER had - active and removed alike
  /// - the spec's "all targets for lookups" half (ticket 21). What
  /// [_upsertLocalItem] and [applyPage] both check a device or cloud item
  /// against before falling back to the ticket 15 heuristic: a photo already
  /// sitting at an old, historical target must still be recognised as
  /// already-backed-up, not just at whichever target happens to be active
  /// right now. Fetched once per [applyLocalScan]/[applyLocalDelta]/
  /// [applyPage] transaction rather than once per item, since the count is
  /// small (a handful of pairs, plus however many times each has been
  /// retargeted - nowhere near per-photo scale) and re-reading it per item
  /// would only add one more query to every single photo for no benefit.
  Future<List<SyncPairRow>> _allSyncPairs() => _db.select(_db.syncPairs).get();

  /// The first Sync Pair in [pairs] covering [relativePath], or null if none
  /// does - first match wins, though create-time overlap checking
  /// ([createSyncPair], scoped to active pairs) is what actually keeps this
  /// to at most one match when [pairs] is [_activeSyncPairs]. Coverage is a
  /// plain string-prefix test: both a Local Folder's path and a
  /// [LocalMediaItem.relativePath] are always trailing-slash-terminated (the
  /// MediaStore `RELATIVE_PATH` convention this whole seam relies on), so
  /// `DCIM/Camera/` can never falsely prefix-match `DCIM/Camera2/`.
  SyncPairRow? _coveringSyncPair(
    List<SyncPairRow> pairs,
    String relativePath,
  ) {
    for (final pair in pairs) {
      if (relativePath == pair.localFolderPath ||
          relativePath.startsWith(pair.localFolderPath)) {
        return pair;
      }
    }
    return null;
  }

  /// Every Sync Pair in [pairs] covering [relativePath] - the ticket 21
  /// counterpart of [_coveringSyncPair] for lookups over [_allSyncPairs]:
  /// a retargeted Local Source can have more than one pair (one active, any
  /// number removed) whose [SyncPairRow.localFolderPath] covers the same
  /// [relativePath], each with a different target to check. Ordered most
  /// recently created first, so the active pair - normally the most recent,
  /// since retargeting is delete-then-create - is tried before older,
  /// historical ones; this is only a tie-break for the vanishingly unlikely
  /// case where more than one target happens to hold a same-size file at the
  /// exact expected path, not a correctness requirement.
  List<SyncPairRow> _allCoveringSyncPairs(
    List<SyncPairRow> pairs,
    String relativePath,
  ) {
    final matches = pairs
        .where((pair) =>
            relativePath == pair.localFolderPath ||
            relativePath.startsWith(pair.localFolderPath))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return matches;
  }

  /// The remote (providerId, path) a device item at [relativePath]/
  /// [displayName] maps to under [pair] - the pure function ticket 18 (and
  /// later ticket 19's actual upload) both rely on: `relativePath` with the
  /// pair's local folder prefix stripped, appended to the pair's Seraph
  /// folder. E.g. `DCIM/Camera/2026/` + `IMG_0001.jpg` under a pair
  /// `DCIM/Camera/ -> /Photos/Phone` yields `/Photos/Phone/2026/IMG_0001.jpg`
  /// - exactly the ticket's own worked example. [pair] may be active or
  /// removed - the function only reads its `(localFolderPath,
  /// spaceProviderId, path)`, so it computes an old, historical target's
  /// expected path exactly as readily as the current one's.
  (String providerId, String path) _expectedRemotePath(
    SyncPairRow pair,
    String relativePath,
    String displayName,
  ) {
    final withinSource = relativePath.startsWith(pair.localFolderPath)
        ? relativePath.substring(pair.localFolderPath.length)
        : '';
    return (pair.spaceProviderId, _joinSeraphPath(pair.path, '$withinSource$displayName'));
  }

  /// The inverse of [_expectedRemotePath]: given a cloud item's [remotePath],
  /// the `(relativePath, displayName)` a device row would need to carry for
  /// [pair] to have produced it - or null if [remotePath] does not fall
  /// under [pair]'s Seraph folder at all. What [applyPage] uses to look up
  /// the matching Device only row directly by its local identity, without
  /// scanning every device row covered by every pair.
  (String relativePath, String displayName)? _localIdentityForRemotePath(
    SyncPairRow pair,
    String remotePath,
  ) {
    final base = pair.path == '/' ? '' : pair.path;
    final prefix = '$base/';
    if (!remotePath.startsWith(prefix)) {
      return null;
    }
    final withinSource = remotePath.substring(prefix.length);
    if (withinSource.isEmpty) {
      return null;
    }
    final slash = withinSource.lastIndexOf('/');
    final displayName =
        slash < 0 ? withinSource : withinSource.substring(slash + 1);
    if (displayName.isEmpty) {
      return null;
    }
    final subDir = slash < 0 ? '' : withinSource.substring(0, slash + 1);
    return ('${pair.localFolderPath}$subDir', displayName);
  }

  /// Joins a Seraph folder [folderPath] (Space terms, e.g. `/Photos/Phone`,
  /// or `/` for the space root) with a [relative] path beneath it, the same
  /// convention [GallerySourceFolder.displayPath] uses for the root case.
  String _joinSeraphPath(String folderPath, String relative) {
    final base = folderPath == '/' ? '' : folderPath;
    return '$base/$relative';
  }

  /// Creates a new Sync Pair mapping [localFolderPath] (a Local Source
  /// identifier - on Android, a folder's MediaStore `RELATIVE_PATH`) to the
  /// Seraph folder ([spaceProviderId], [path]).
  ///
  /// Throws [SyncPairConflictException] if [localFolderPath] overlaps an
  /// existing ACTIVE pair's Local Source (ticket 18's "at most one Sync Pair
  /// per Local Source" rule, scoped by ticket 21 to active pairs only -
  /// [_activeSyncPairs] - so retargeting, a remove immediately followed by a
  /// create for the same folder, is never blocked by the just-removed row it
  /// intentionally leaves behind) - checked and inserted inside the same
  /// transaction, so two concurrent creates can never both pass the check.
  ///
  /// **Does not add the Seraph folder to the user's Gallery Source
  /// Folders.** That is a server-side call (`GalleryService.
  /// addSourceFolder`) this class - which does no network access, see the
  /// class doc - cannot make itself. The caller (the Gallery folders screen)
  /// is responsible for both calls; ticket 18's acceptance criterion is that
  /// the two together leave both true, not that this method alone does.
  ///
  /// **Merges existing counterparts immediately.** Any Device only row
  /// already under [localFolderPath] whose expected remote path (computed
  /// against the pair just created) matches an existing Cloud only row by
  /// path and size is merged onto one Synced row right here - so a Seraph
  /// folder that already held this device's photos, from another client or
  /// a previous install, shows them correctly merged the moment the pair is
  /// configured, without waiting for the next scan or delta poll, and
  /// without any upload happening.
  Future<SyncPair> createSyncPair({
    required String localFolderPath,
    required String spaceProviderId,
    required String path,
  }) async {
    return _db.transaction(() async {
      final existing = await _activeSyncPairs();
      for (final pair in existing) {
        if (localFolderPath == pair.localFolderPath ||
            localFolderPath.startsWith(pair.localFolderPath) ||
            pair.localFolderPath.startsWith(localFolderPath)) {
          throw SyncPairConflictException(
              localFolderPath, pair.localFolderPath);
        }
      }

      final id = await _db.into(_db.syncPairs).insert(
            SyncPairsCompanion.insert(
              localFolderPath: localFolderPath,
              spaceProviderId: spaceProviderId,
              path: path,
              createdAt: Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
      final row = await (_db.select(_db.syncPairs)
            ..where((t) => t.id.equals(id)))
          .getSingle();

      await _mergeExistingCounterparts(row);

      final photoCount = await _countCoveredByLocalFolder(localFolderPath);
      return SyncPair(
        id: row.id,
        localFolderPath: row.localFolderPath,
        spaceProviderId: row.spaceProviderId,
        path: row.path,
        photoCount: photoCount,
      );
    });
  }

  /// Every currently ACTIVE Sync Pair, oldest first, with each one's current
  /// [SyncPair.photoCount] - what the *Sync Pairs* section of the Gallery
  /// folders screen lists. A removed pair (ticket 21: [removeSyncPair] keeps
  /// its row rather than deleting it) never appears here - it is kept purely
  /// as a historical target for dedup/reconcile, not as something the user
  /// still configures.
  Future<List<SyncPair>> listSyncPairs() async {
    final rows = await (_db.select(_db.syncPairs)
          ..where((t) => t.removedAt.isNull())
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
    final pairs = <SyncPair>[];
    for (final row in rows) {
      final photoCount = await _countCoveredByLocalFolder(row.localFolderPath);
      pairs.add(SyncPair(
        id: row.id,
        localFolderPath: row.localFolderPath,
        spaceProviderId: row.spaceProviderId,
        path: row.path,
        photoCount: photoCount,
      ));
    }
    return pairs;
  }

  /// Retires the Sync Pair with [id]. Ticket 18's lifecycle rule (D18 in
  /// `docs/gallery-mode-design-notes.md`): this stops FUTURE dedup
  /// consideration for NEW uploads through [SyncPairRow.localFolderPath] -
  /// it never touches a [GalleryItems] row itself. Every row already merged
  /// via this pair (Synced, `origin == 'both'`) stays exactly as it is.
  ///
  /// **Ticket 21: the row is kept, marked [SyncPairRow.removedAt], never
  /// deleted.** [_activeSyncPairs] (what [expectedUploadTarget] and
  /// [createSyncPair]'s overlap check read) stops finding it immediately -
  /// no new upload targets this Local Source, and the same local folder can
  /// be given a new active pair right away (retargeting). But [_allSyncPairs]
  /// (what [_upsertLocalItem]/[applyPage]'s dedup and reconcile lookups
  /// read) keeps finding it forever, as one more historical target - a photo
  /// this pair already put in Seraph keeps reading as already-backed-up,
  /// retarget or no retarget, reinstall or no reinstall, and a device item
  /// this pair covered still gets its one deterministic path+size chance
  /// against that historical target before anything falls back to the
  /// ticket 15 (size, capturedAt) heuristic. No row is duplicated or dropped
  /// by the removal itself.
  /// **Never removes the Gallery Source Folder** this pair created - that is
  /// separate, server-side configuration the caller does not touch just
  /// because the pair is gone (D18: "the cloud folder remains a Gallery
  /// Source Folder").
  Future<void> removeSyncPair(int id) async {
    await (_db.update(_db.syncPairs)..where((t) => t.id.equals(id))).write(
      SyncPairsCompanion(
        removedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  // --- Ticket 19: upload ---

  /// The remote (providerId, path) [GalleryUploadService](gallery_upload_service.dart)
  /// would upload [item] to - the exact same pure function
  /// ([_coveringSyncPair] + [_expectedRemotePath]) [applyLocalScan] already
  /// uses to dedup a device item against an existing cloud row, reused here
  /// rather than re-derived, so "the path a photo dedups onto" and "the path
  /// it uploads to" can never disagree.
  ///
  /// Null when [item] carries no local identity (a Cloud only row - nothing
  /// to upload) or no Sync Pair covers its folder. The latter is not an
  /// error: this ticket is the manual, one-photo tracer bullet through the
  /// upload path, not the decision of which items are eligible for it -
  /// deciding whether an uncovered item should ever be offered upload UI at
  /// all is ticket 22's (the engine's) job, not this method's.
  Future<(String providerId, String path)?> expectedUploadTarget(
    GalleryItem item,
  ) async {
    final relativePath = item.localRelativePath;
    final displayName = item.localDisplayName;
    if (relativePath == null || displayName == null) {
      return null;
    }
    final pairs = await _activeSyncPairs();
    final pair = _coveringSyncPair(pairs, relativePath);
    if (pair == null) {
      return null;
    }
    return _expectedRemotePath(pair, relativePath, displayName);
  }

  /// Records that [item]'s upload PUT to ([providerId], [path]) succeeded
  /// ([viaPut] true), or that the target path turned out to already hold
  /// this device's own content (ticket 19's "size matches - assume it is
  /// ours, do not upload" rule - [viaPut] false) - either way, an upload
  /// attempt this device made, now awaiting independent confirmation from
  /// the delta feed (ticket 20).
  ///
  /// **[viaPut] decides what a later contradicting feed length is allowed to
  /// do** (ticket 20's rework): [applyPage] only ever deletes a remote file
  /// this device actually PUT ([viaPut] true); for the "assume it is ours"
  /// shortcut ([viaPut] false), a contradicting length proves the assumption
  /// wrong, not that the file is safe to delete - see
  /// [GalleryUploadService.retryMismatchedUpload].
  ///
  /// **Deliberately does NOT mark the row Synced.** [origin] stays `device`
  /// - the item keeps showing as not backed up, "in progress" rather than
  /// done, until [applyPage] sees this exact (providerId, path) come back
  /// through the feed with a matching length. This is ticket 20's central
  /// rule: "no code path marks an item Verified on the basis of the upload
  /// response alone." What this method DOES do is **is** the "record the
  /// remote path the photo actually went to" criterion from ticket 19:
  /// [path] is whatever path the caller actually used - the original target
  /// or a disambiguated one - stored in [GalleryItems.uploadTargetPath] so
  /// [applyPage] can recognise the feed reporting exactly this file, not a
  /// path re-derived from the Sync Pair (which would get a disambiguated
  /// upload wrong).
  ///
  /// The write is conditioned on [item]'s id AND its local identity still
  /// matching exactly what it was when the caller started - not on the id
  /// alone - so a device row deleted or changed by a full scan that raced
  /// this upload (ticket 19's "deleted or modified on the device mid-upload
  /// is not marked synced" criterion) leaves this a no-op: the identity in
  /// the WHERE clause no longer matches the (deleted, or now-different) row,
  /// zero rows are affected, and the return value tells the caller so.
  /// Returns whether the row was actually updated.
  Future<bool> recordUploaded(
    GalleryItem item,
    String providerId,
    String path, {
    required bool viaPut,
  }) async {
    final rows = await (_db.update(_db.galleryItems)
          ..where((t) =>
              t.id.equals(item.id) &
              t.origin.equals(_originDevice) &
              t.localRelativePath.equals(item.localRelativePath ?? '') &
              t.localDisplayName.equals(item.localDisplayName ?? '') &
              t.localSize.equals(item.localSize ?? -1)))
        .write(GalleryItemsCompanion(
      uploadTargetProviderId: Value(providerId),
      uploadTargetPath: Value(path),
      uploadState:
          Value(viaPut ? _uploadStateUploaded : _uploadStateAssumed),
    ));
    return rows > 0;
  }

  /// Every Device only row whose most recent upload's verification came back
  /// CONTRADICTING it - a length mismatch [applyPage] recorded as either
  /// [_uploadStateMismatch] (a real PUT) or [_uploadStateAssumedMismatch]
  /// (the ticket-19 "assume it is ours" shortcut) - for
  /// [GalleryUploadService.retryMismatchedUpload] to work through. This
  /// class makes no network calls itself (see the class doc), so it only
  /// surfaces which rows need that done and which of the two flavours each
  /// one is; it never attempts the deletion or the retry.
  Future<List<GalleryItem>> itemsNeedingUploadRetry() => (_db.select(
          _db.galleryItems)
        ..where((t) =>
            t.origin.equals(_originDevice) &
            (t.uploadState.equals(_uploadStateMismatch) |
                t.uploadState.equals(_uploadStateAssumedMismatch))))
      .get();

  // --- Ticket 22: headless sync engine ---

  /// Every Device only row [GallerySyncEngine] (`../sync/gallery_sync_engine.dart`)
  /// should attempt to upload right now: no verification already pending
  /// ([uploadState] null - a row [itemsNeedingUploadRetry] would return, or
  /// one already awaiting the delta feed's confirmation, is never a second
  /// upload candidate), and covered by an ACTIVE Sync Pair - the same
  /// [_activeSyncPairs] "current target for writes" rule
  /// [expectedUploadTarget] itself applies, reused here rather than
  /// re-derived so "what the engine will attempt" and "what a single upload
  /// call would actually do" can never disagree. A row covered only by a
  /// removed, historical pair is correctly excluded: [expectedUploadTarget]
  /// would return null for it too (nothing NEW should ever be written to a
  /// retired target), so queuing it here would only produce a queue entry
  /// [GalleryUploadService.upload] immediately reports [GalleryUploadResult.
  /// noSyncPair] for.
  ///
  /// Newest [GalleryItem.capturedAt] first - user story 53's "historical
  /// backlog uploaded newest first". **Deliberately not the spec's two
  /// priority classes** ("photos observed after setup preempt the backlog") -
  /// that split, and the failure-list/retry-policy machinery around it, is
  /// ticket 25's job; this is a single, simple queue ordering that already
  /// satisfies the newest-first half of it on its own.
  ///
  /// Filtered in Dart against a fetched row set, the same style
  /// [_countCoveredByLocalFolder]/[_unselectedFolders] already use for a
  /// small, bounded set of Sync Pairs against a larger row set - a purpose-
  /// built SQL `OR` of per-pair prefix conditions would only duplicate what
  /// [_coveringSyncPair] already expresses correctly in Dart. This is a
  /// queue REBUILD, not a per-item probe (D12/the spec's "the queue is
  /// derived state... rebuildable at any time"), so it is expected to run
  /// once per engine run, not once per photo.
  Future<List<GalleryItem>> itemsPendingUpload({int? limit}) async {
    final pairs = await _activeSyncPairs();
    if (pairs.isEmpty) {
      return const [];
    }
    final rows = await (_db.select(_db.galleryItems)
          ..where((t) =>
              t.origin.equals(_originDevice) & t.uploadState.isNull())
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.capturedAt, mode: OrderingMode.desc)
          ]))
        .get();

    final matching = <GalleryItem>[];
    for (final row in rows) {
      if (_coveringSyncPair(pairs, row.localRelativePath ?? '') != null) {
        matching.add(row);
        if (limit != null && matching.length >= limit) {
          break;
        }
      }
    }
    return matching;
  }

  /// The single [SyncRunState] row - [GallerySyncEngine]'s only channel to
  /// the UI (see that table's class doc). An idle, all-zero snapshot when no
  /// run has ever happened, so a fresh install and "nothing to report" read
  /// identically rather than the caller having to null-check.
  Future<SyncRunStateData> syncRunState() async {
    final row = await (_db.select(_db.syncRunState)
          ..where((t) => t.id.equals(syncRunStateId)))
        .getSingleOrNull();
    return row ??
        const SyncRunStateData(
          id: syncRunStateId,
          status: syncStatusIdle,
          totalItems: 0,
          completedItems: 0,
          failedItems: 0,
          totalBytes: 0,
          completedBytes: 0,
          lastError: null,
          updatedAt: 0,
          lastSuccessAt: null,
        );
  }

  /// Overwrites the single [SyncRunState] row - a snapshot, not a log, per
  /// that table's own doc. Called by [GallerySyncEngine] after every item it
  /// processes (so a kill mid-run leaves the last-known-good progress behind,
  /// never a half-written one - the write itself is a single-row upsert,
  /// atomic by construction) and by [GalleryDataSyncController]'s startup
  /// reconciliation to correct a `running` row the process that wrote it did
  /// not survive to clear.
  Future<void> writeSyncRunState({
    required String status,
    required int totalItems,
    required int completedItems,
    required int failedItems,
    required int totalBytes,
    required int completedBytes,
    String? lastError,
    required int updatedAtMillis,
  }) async {
    // Ticket 24: [SyncRunState.lastSuccessAt] only ever moves forward, and
    // only on a write that itself reaches [syncStatusCompleted] - never
    // cleared by a `running`/`paused`/`error` write in between, which is
    // what makes it a record of "the last time backup finished", not "the
    // last time backup was attempted". Read-modify-write rather than a SQL
    // `COALESCE` against the previous row: this table has at most one row
    // ([syncRunStateId]), so the extra read is one indexed lookup, not a
    // scan.
    final previous = await syncRunState();
    final lastSuccessAt = status == syncStatusCompleted
        ? updatedAtMillis
        : previous.lastSuccessAt;
    await _db.into(_db.syncRunState).insertOnConflictUpdate(
          SyncRunStateCompanion(
            id: const Value(syncRunStateId),
            status: Value(status),
            totalItems: Value(totalItems),
            completedItems: Value(completedItems),
            failedItems: Value(failedItems),
            totalBytes: Value(totalBytes),
            completedBytes: Value(completedBytes),
            lastError: Value(lastError),
            updatedAt: Value(updatedAtMillis),
            lastSuccessAt: Value(lastSuccessAt),
          ),
        );
  }

  /// Ticket 23: attempts to acquire the cross-isolate token-refresh lock via
  /// a single atomic UPSERT - see [TokenRefreshLock]'s class doc for why a
  /// lease, not an explicit release, is what actually bounds how long a lock
  /// can be held. The UPSERT's own `WHERE` clause (`expires_at <= ?`) is what
  /// makes "check whether the current holder's lease has expired, then take
  /// the lock if it is free or expired" atomic against a concurrent acquire
  /// from the OTHER isolate's own connection to the same file: SQLite
  /// executes the conflict check and the conditional update as one
  /// indivisible statement, so there is no read-then-write window a second
  /// connection's own UPSERT could land inside and win a lock this call
  /// already believes it holds.
  ///
  /// Returns whether THIS call is the one that (now) holds the lock -
  /// `false` means another isolate's unexpired lease is still standing, and
  /// the caller must not run its own refresh (see `refreshTokenWithLock` in
  /// `../sync/token_refresh_coordination.dart`, the only intended caller of
  /// this method and [releaseTokenRefreshLock] together).
  Future<bool> tryAcquireTokenRefreshLock({
    required String holder,
    required int nowMillis,
    required int leaseMillis,
  }) async {
    final changed = await _db.customUpdate(
      'INSERT INTO token_refresh_lock (id, holder, acquired_at, expires_at) '
      'VALUES (?1, ?2, ?3, ?4) '
      'ON CONFLICT(id) DO UPDATE SET '
      'holder = excluded.holder, '
      'acquired_at = excluded.acquired_at, '
      'expires_at = excluded.expires_at '
      'WHERE token_refresh_lock.expires_at <= ?3',
      variables: [
        Variable<String>(tokenRefreshLockId),
        Variable<String>(holder),
        Variable<int>(nowMillis),
        Variable<int>(nowMillis + leaseMillis),
      ],
      updates: {_db.tokenRefreshLock},
    );
    return changed > 0;
  }

  /// Releases the lock THIS [holder] currently holds - a no-op, not an
  /// error, if [holder] is not (or is no longer) the row's holder, which is
  /// exactly what happens when this isolate's own lease already expired and
  /// the other isolate reclaimed the lock before this call ran: releasing
  /// here must never touch a lock this isolate no longer owns. Called from a
  /// `finally` around every refresh an isolate performs while holding the
  /// lock, success or failure alike, so a failed refresh frees the lock
  /// immediately rather than leaving the next attempt to wait out the whole
  /// lease (this ticket's own "a refresh that fails releases the lock, and
  /// the next attempt is not blocked forever" criterion).
  Future<void> releaseTokenRefreshLock({required String holder}) async {
    await (_db.delete(_db.tokenRefreshLock)
          ..where((t) =>
              t.id.equals(tokenRefreshLockId) & t.holder.equals(holder)))
        .go();
  }

  /// Whether the lock is currently held by an unexpired lease - what a
  /// caller that lost [tryAcquireTokenRefreshLock]'s race polls while
  /// waiting for the winner to finish (see `refreshTokenWithLock` in
  /// `../sync/token_refresh_coordination.dart`). `false` covers both "no one
  /// has ever taken the lock" and "the holder's lease has lapsed" - the two
  /// read identically here, matching [tryAcquireTokenRefreshLock]'s own
  /// treatment of an expired row as free.
  Future<bool> tokenRefreshLockHeld({required int nowMillis}) async {
    final row = await (_db.select(_db.tokenRefreshLock)
          ..where((t) => t.id.equals(tokenRefreshLockId)))
        .getSingleOrNull();
    return row != null && row.expiresAt > nowMillis;
  }

  // --- Ticket 24: sync-run mutual exclusion ---

  /// Attempts to acquire (or, if [holder] already holds it, renew) the
  /// single [SyncRunLock] row - `true` on success, `false` if a DIFFERENT
  /// holder currently holds an unexpired lease. One atomic UPSERT, the same
  /// "acquire-if-free-or-expired" shape [tryAcquireTokenRefreshLock] uses,
  /// with one addition: the WHERE clause also matches when [holder] is
  /// already the row's holder, so the SAME caller can extend its own lease
  /// (`runHeadlessGallerySync` does this on a timer for as long as an engine
  /// run is in progress) without first having to release and re-race for it -
  /// something [TokenRefreshLock] never needed, since a token refresh is one
  /// short call, not a run that can span hours.
  ///
  /// This is what makes "background and foreground runs do not both process
  /// the same photo" (ticket 24's own criterion) true: whichever of the
  /// WorkManager-triggered path or ticket 22's foreground-service path calls
  /// this first gets to construct a [GallerySyncEngine] at all; the loser
  /// gets `false` back and must not touch [GalleryMirror.writeSyncRunState]
  /// itself - the winner is already the only thing writing it.
  Future<bool> tryAcquireSyncRunLock({
    required String holder,
    required int nowMillis,
    required int leaseMillis,
  }) async {
    final changed = await _db.customUpdate(
      'INSERT INTO sync_run_lock (id, holder, acquired_at, expires_at) '
      'VALUES (?1, ?2, ?3, ?4) '
      'ON CONFLICT(id) DO UPDATE SET '
      'holder = excluded.holder, '
      'acquired_at = excluded.acquired_at, '
      'expires_at = excluded.expires_at '
      'WHERE sync_run_lock.expires_at <= ?3 OR sync_run_lock.holder = ?2',
      variables: [
        Variable<String>(syncRunLockId),
        Variable<String>(holder),
        Variable<int>(nowMillis),
        Variable<int>(nowMillis + leaseMillis),
      ],
      updates: {_db.syncRunLock},
    );
    return changed > 0;
  }

  /// Releases the lock THIS [holder] currently holds - a no-op, not an
  /// error, if [holder] is not (or is no longer) the row's holder, exactly
  /// like [releaseTokenRefreshLock]'s own reasoning: this isolate's lease
  /// may already have expired and been reclaimed by the other path before
  /// this call runs, and releasing here must never touch a lock this isolate
  /// no longer owns. Called from a `finally` around every engine run
  /// [runHeadlessGallerySync] performs while holding the lock, success or
  /// failure alike.
  Future<void> releaseSyncRunLock({required String holder}) async {
    await (_db.delete(_db.syncRunLock)
          ..where(
              (t) => t.id.equals(syncRunLockId) & t.holder.equals(holder)))
        .go();
  }

  /// Retroactively merges [pair]'s Local Source against the mirror as it
  /// stands right now - called once, from [createSyncPair], never from the
  /// ongoing scan/delta-feed paths (those apply [pair] to items they see
  /// going forward; this applies it to what is already sitting in the
  /// mirror from before the pair existed).
  ///
  /// Walks every Device only row, skips any not under [pair]'s local folder,
  /// and for the rest, merges onto a Cloud only row at the expected remote
  /// path (matching size) if one exists - deleting that Cloud only row and
  /// promoting the device row to Synced. The device row's id and Capture
  /// Date are kept (never the cloud row's) - the same "the row that already
  /// existed keeps its timeline position" rule every other merge in this
  /// class follows.
  Future<void> _mergeExistingCounterparts(SyncPairRow pair) async {
    final deviceRows = await (_db.select(_db.galleryItems)
          ..where((t) => t.origin.equals(_originDevice)))
        .get();

    for (final row in deviceRows) {
      final relativePath = row.localRelativePath ?? '';
      if (relativePath != pair.localFolderPath &&
          !relativePath.startsWith(pair.localFolderPath)) {
        continue;
      }

      final expected = _expectedRemotePath(
          pair, relativePath, row.localDisplayName ?? '');
      final cloudMatch = await (_db.select(_db.galleryItems)
            ..where((t) =>
                t.origin.equals(_originCloud) &
                t.providerId.equals(expected.$1) &
                t.path.equals(expected.$2) &
                t.size.equals(row.localSize ?? -1))
            ..limit(1))
          .getSingleOrNull();
      if (cloudMatch == null) {
        continue;
      }

      // The delete MUST run before the update: [GalleryItems.uniqueKeys]
      // enforces (providerId, path) as a pair, and the update below gives
      // the device row exactly the (providerId, path) [cloudMatch] still
      // holds - doing it the other way round trips that very constraint
      // against a row not yet gone.
      await (_db.delete(_db.galleryItems)
            ..where((t) => t.id.equals(cloudMatch.id)))
          .go();
      await (_db.update(_db.galleryItems)..where((t) => t.id.equals(row.id)))
          .write(GalleryItemsCompanion(
        origin: const Value(_originBoth),
        providerId: Value(cloudMatch.providerId),
        path: Value(cloudMatch.path),
        seq: Value(cloudMatch.seq),
        capturedAtSource: Value(cloudMatch.capturedAtSource),
        width: Value(cloudMatch.width),
        height: Value(cloudMatch.height),
        orientation: Value(cloudMatch.orientation),
        size: Value(cloudMatch.size),
        mime: Value(cloudMatch.mime),
        unsupported: Value(cloudMatch.unsupported),
        metadataPending: Value(cloudMatch.metadataPending),
        // capturedAt deliberately NOT rewritten - the device row (which
        // already existed) keeps its timeline position.
      ));
    }
  }

  /// How many gallery items - Device only or Synced alike - currently sit
  /// under [localFolderPath], for [SyncPair.photoCount]. Computed the same
  /// way [_unselectedFolders] computes its own prefix-matched set: distinct
  /// local folder paths already in the mirror, filtered in Dart by prefix,
  /// then counted with [_countMatching] - bounded by how many distinct
  /// folders actually exist on the device, not by total photo count.
  Future<int> _countCoveredByLocalFolder(String localFolderPath) async {
    final pathColumn = _db.galleryItems.localRelativePath;
    final distinctQuery = _db.selectOnly(_db.galleryItems, distinct: true)
      ..addColumns([pathColumn])
      ..where(pathColumn.isNotNull());
    final rows = await distinctQuery.get();

    final covered = <String>{};
    for (final r in rows) {
      final path = r.read(pathColumn);
      if (path != null &&
          (path == localFolderPath || path.startsWith(localFolderPath))) {
        covered.add(path);
      }
    }
    if (covered.isEmpty) {
      return 0;
    }
    return _countMatching((t) => t.localRelativePath.isIn(covered));
  }

  /// One page of the mirror, Capture Date descending (newest first, matching
  /// the server listing's order), with a total row count. Works with no
  /// network - it is a plain local query.
  ///
  /// [filter] restricts which rows are included (ticket 15's Availability
  /// filter) without ever changing their relative order - Availability is
  /// shown, and now filterable, but it never fragments the ordering.
  ///
  /// Ticket 29's Local Folder selection is applied here too, folded into the
  /// same [filter] machinery rather than as a separate step - see
  /// [_visibilityPredicates].
  Future<GalleryMirrorPage> queryPage({
    int offset = 0,
    int limit = 100,
    GalleryAvailabilityFilter filter = GalleryAvailabilityFilter.all,
  }) async {
    final unselectedFolders = await _unselectedFolders();

    final query = _db.select(_db.galleryItems)
      ..orderBy([
        (t) => OrderingTerm(expression: t.capturedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit, offset: offset)
      ..where((t) =>
          _visibilityPredicates(t, unselectedFolders).forFilter(filter));

    final rows = await query.get();
    final items =
        rows.map((r) => _presentedItem(r, unselectedFolders)).toList();
    final totalCount = await this.totalCount(filter: filter);

    return GalleryMirrorPage(items: items, totalCount: totalCount);
  }

  /// One page of the mirror in the same Capture-Date-descending order as
  /// [queryPage], but WITHOUT the total count.
  ///
  /// The grid asks for the count once, when it opens, and then keeps it: the
  /// item count must not move under the user's thumb as pages load, so
  /// re-counting on every page fetch would be both wasted work and a way to
  /// make the list shift. [queryPage] stays as it is for callers that want
  /// both in one go.
  Future<List<GalleryItem>> queryItems({
    int offset = 0,
    int limit = 100,
    GalleryAvailabilityFilter filter = GalleryAvailabilityFilter.all,
  }) async {
    final unselectedFolders = await _unselectedFolders();

    final query = _db.select(_db.galleryItems)
      ..orderBy([
        (t) => OrderingTerm(expression: t.capturedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit, offset: offset)
      ..where((t) =>
          _visibilityPredicates(t, unselectedFolders).forFilter(filter));

    final rows = await query.get();
    return rows.map((r) => _presentedItem(r, unselectedFolders)).toList();
  }

  /// What a caller actually sees for [item]: unchanged, **except** a Synced
  /// row ([_originBoth]) whose device copy sits in a currently-unselected
  /// Local Folder is handed back as Cloud only - [GalleryItem.origin]
  /// rewritten to [_originCloud] and its `local*` columns cleared.
  ///
  /// This is never written back to [GalleryItems] - the full media-store
  /// scan and dedup (`applyLocalScan`/`applyLocalDelta`/`applyPage`) read and
  /// write the table directly, never through this method, so they keep
  /// seeing the row's real origin regardless of any folder selection (ticket
  /// 29's governing rule). It is applied here, in the one place every reader
  /// - the grid, the tile, the viewer, [GalleryItemDisplay.availability] and
  /// [GalleryItemDisplay.hasLocalCopy] in `gallery_item_display.dart`, all of
  /// which read straight off the returned [GalleryItem] - gets its rows from,
  /// which is what makes "one predicate, applied once" true: none of them
  /// need to know Local Folders exist.
  GalleryItem _presentedItem(GalleryItem item, Set<String> unselectedFolders) {
    if (item.origin != _originBoth) {
      return item;
    }
    if (!unselectedFolders.contains(item.localRelativePath)) {
      return item;
    }
    return item.copyWith(
      origin: _originCloud,
      localRelativePath: const Value(null),
      localDisplayName: const Value(null),
      localSize: const Value(null),
      localDateTaken: const Value(null),
    );
  }

  /// The three visibility predicates ticket 29's rule reduces to, built once
  /// per read and reused by [queryPage]/[queryItems] (as a WHERE clause) and
  /// [totalCount]/[availabilitySummary] (as a count) alike - so a row can
  /// never be counted into one bucket while the grid shows it in another.
  ///
  /// - [_Visibility.deviceOnly]: a `device` row whose folder IS selected.
  ///   A `device` row in an unselected folder matches none of the three -
  ///   its device copy is invisible, and the row behaves as though it did
  ///   not exist (ticket 29's rule, in full).
  /// - [_Visibility.synced]: a `both` row whose folder IS selected.
  /// - [_Visibility.cloudOnly]: every `cloud` row, plus a `both` row whose
  ///   folder is NOT selected - the "displays, badges and counts as Cloud
  ///   only" case.
  _Visibility _visibilityPredicates(
    $GalleryItemsTable t,
    Set<String> unselectedFolders,
  ) {
    final folderSelected = t.localRelativePath.isNotIn(unselectedFolders);
    final folderUnselected = t.localRelativePath.isIn(unselectedFolders);
    return _Visibility(
      deviceOnly: t.origin.equals(_originDevice) & folderSelected,
      synced: t.origin.equals(_originBoth) & folderSelected,
      cloudOnly:
          t.origin.equals(_originCloud) | (t.origin.equals(_originBoth) & folderUnselected),
    );
  }

  /// The Capture Date of the item at [offset] in the gallery's order, or null
  /// if the mirror has no item there.
  ///
  /// This is what the date scrubber needs: while the user drags it, the
  /// position under their thumb has to be turned into a point in time without
  /// first loading the page of items it lands on - the whole point of the
  /// scrubber is to move faster than pages can load.
  Future<DateTime?> capturedAtAtOffset(
    int offset, {
    GalleryAvailabilityFilter filter = GalleryAvailabilityFilter.all,
  }) async {
    if (offset < 0) {
      return null;
    }
    final rows = await queryItems(offset: offset, limit: 1, filter: filter);
    if (rows.isEmpty) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(rows.first.capturedAt * 1000);
  }

  /// The total number of items currently in the mirror, optionally
  /// restricted by Availability. Ticket 29's Local Folder selection is
  /// already folded into what "restricted by Availability" means - see
  /// [_visibilityPredicates].
  Future<int> totalCount({
    GalleryAvailabilityFilter filter = GalleryAvailabilityFilter.all,
  }) async {
    final unselectedFolders = await _unselectedFolders();
    return _countMatching((t) =>
        _visibilityPredicates(t, unselectedFolders).forFilter(filter));
  }

  /// How many items are Device only, Synced and Cloud only right now - the
  /// backed-up/not-backed-up summary ticket 15 asks for. Always over the
  /// WHOLE mirror, regardless of any Availability filter a caller has
  /// applied to what it is displaying - the summary is meant to answer "what
  /// would I lose", not "what am I currently looking at".
  ///
  /// Ticket 29: a Device only photo in an unselected folder is not counted
  /// here at all (its device copy is invisible, full stop) and a Synced
  /// photo whose device copy sits in an unselected folder counts as Cloud
  /// only - the exact same [_visibilityPredicates] the grid and the
  /// Availability filter use, so this summary can never disagree with them.
  Future<GalleryAvailabilitySummary> availabilitySummary() async {
    final unselectedFolders = await _unselectedFolders();
    final deviceOnly = await _countMatching(
        (t) => _visibilityPredicates(t, unselectedFolders).deviceOnly);
    final synced = await _countMatching(
        (t) => _visibilityPredicates(t, unselectedFolders).synced);
    final cloudOnly = await _countMatching(
        (t) => _visibilityPredicates(t, unselectedFolders).cloudOnly);
    return GalleryAvailabilitySummary(
      deviceOnly: deviceOnly,
      synced: synced,
      cloudOnly: cloudOnly,
    );
  }

  Future<int> _countMatching(
    Expression<bool> Function($GalleryItemsTable t) predicate,
  ) async {
    final countExp = _db.galleryItems.id.count();
    final query = _db.selectOnly(_db.galleryItems)..addColumns([countExp]);
    query.where(predicate(_db.galleryItems));
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  // --- Ticket 29: Local Folder selection ---

  /// The device's photo folders, enumerated from rows already in the mirror
  /// (D21/ticket 29: no second scan, no new platform call) - what the *On
  /// this device* section of the Gallery folders screen lists. Empty on a
  /// platform with no Local Source, since then no row ever carries
  /// [GalleryItems.localRelativePath].
  ///
  /// [LocalFolder.selected] is computed with exactly the same rule
  /// [queryPage]/[queryItems]/[totalCount]/[availabilitySummary] apply on the
  /// read path (an explicit [LocalFolderSelections] row if the user has ever
  /// toggled this folder, else [_defaultFolderSelected]), so a folder never
  /// reports a selection state the grid disagrees with.
  Future<List<LocalFolder>> listLocalFolders() async {
    final pathColumn = _db.galleryItems.localRelativePath;
    final countExp = _db.galleryItems.id.count();
    final query = _db.selectOnly(_db.galleryItems)
      ..addColumns([pathColumn, countExp])
      ..where(pathColumn.isNotNull())
      ..groupBy([pathColumn]);

    final rows = await query.get();
    final overrides = await _folderOverrides();

    final folders = rows.map((row) {
      final path = row.read(pathColumn)!;
      final count = row.read(countExp) ?? 0;
      return LocalFolder(
        path: path,
        photoCount: count,
        selected: overrides[path] ?? _defaultFolderSelected(path),
      );
    }).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return folders;
  }

  /// Records the user's explicit choice for [folderPath] - selected or not -
  /// so every subsequent read reflects it immediately: no rescan, no
  /// re-merge, exactly [_presentedItem]/[_visibilityPredicates] re-evaluated
  /// against the new choice. Only ever writes [LocalFolderSelections], never
  /// touches [GalleryItems] - the filter lives entirely on the read path.
  Future<void> setLocalFolderSelected(String folderPath, bool selected) async {
    await _db.into(_db.localFolderSelections).insertOnConflictUpdate(
          LocalFolderSelectionsCompanion(
            folderPath: Value(folderPath),
            selected: Value(selected),
          ),
        );
  }

  Future<Map<String, bool>> _folderOverrides() async {
    final rows = await _db.select(_db.localFolderSelections).get();
    return {for (final row in rows) row.folderPath: row.selected};
  }

  /// Every folder, among folders that currently have at least one device row
  /// in the mirror, that is NOT selected right now - what every read-path
  /// query above excludes ([_Visibility.deviceOnly]) or demotes to Cloud only
  /// ([_Visibility.cloudOnly]).
  ///
  /// Scoped to folders present in the mirror rather than every folder
  /// [LocalFolderSelections] has ever recorded a choice for: a folder with no
  /// device rows left cannot hide anything regardless of its stored choice,
  /// and this keeps the set - and the SQL `IN (...)` list built from it -
  /// bounded by how many folders actually exist on the device right now.
  Future<Set<String>> _unselectedFolders() async {
    final pathColumn = _db.galleryItems.localRelativePath;
    final query = _db.selectOnly(_db.galleryItems, distinct: true)
      ..addColumns([pathColumn])
      ..where(pathColumn.isNotNull());
    final rows = await query.get();
    final overrides = await _folderOverrides();

    final unselected = <String>{};
    for (final row in rows) {
      final path = row.read(pathColumn);
      if (path == null) {
        continue;
      }
      final selected = overrides[path] ?? _defaultFolderSelected(path);
      if (!selected) {
        unselected.add(path);
      }
    }
    return unselected;
  }
}

/// The three visibility predicates [GalleryMirror._visibilityPredicates]
/// builds for one read - see that method's doc for what each one means and
/// why there are exactly three.
class _Visibility {
  const _Visibility({
    required this.deviceOnly,
    required this.synced,
    required this.cloudOnly,
  });

  final Expression<bool> deviceOnly;
  final Expression<bool> synced;
  final Expression<bool> cloudOnly;

  /// Every row visible under [GalleryAvailabilityFilter.all]: the union of
  /// all three buckets - nothing else exists.
  Expression<bool> get all => deviceOnly | synced | cloudOnly;

  Expression<bool> forFilter(GalleryAvailabilityFilter filter) {
    switch (filter) {
      case GalleryAvailabilityFilter.all:
        return all;
      case GalleryAvailabilityFilter.notBackedUp:
        return deviceOnly;
      case GalleryAvailabilityFilter.cloudOnly:
        return cloudOnly;
    }
  }
}
