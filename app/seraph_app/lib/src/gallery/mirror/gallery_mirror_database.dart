import 'package:drift/drift.dart';
import 'package:seraph_app/src/gallery/mirror/connection/connection.dart';

part 'gallery_mirror_database.g.dart';

/// The app's local mirror of the user's gallery: one row per gallery item,
/// merging the cloud delta feed today and, later (ticket 15), device items
/// imported from the media store into the SAME table.
///
/// This is a deliberate architectural constraint (see ticket 12 rationale,
/// `.scratch/gallery-mode/issues/12-app-local-database-and-mirror.md`, and
/// design decision D6 in `docs/gallery-mode-design-notes.md`): sync state,
/// the mirror and the UI list are one table, not three, so the merged view
/// browsing the gallery needs is a single indexed query ordered by Capture
/// Date with an honest total count. A lazy two-cursor merge over device and
/// server data was considered and rejected for exactly the properties this
/// table exists to provide - see the class doc on [GalleryItems].
///
/// [SyncCursors] is a second, tiny table holding delta-feed sync progress
/// (the last-applied sequence and, mid-poll, the page cursor) so a restart
/// resumes instead of re-fetching the whole gallery. [CachedThumbnails] is a
/// third: bytes already fetched from the preview endpoint, so that a gallery
/// opened with no network still shows the thumbnails it has already seen.
/// Neither is a second source of gallery items - the one-table constraint is
/// about what the UI list is built from, and that is [GalleryItems] alone.
@DriftDatabase(tables: [
  GalleryItems,
  SyncCursors,
  CachedThumbnails,
  LocalFolderSelections,
  SyncPairs,
  SyncRunState,
  TokenRefreshLock,
])
class GalleryMirrorDatabase extends _$GalleryMirrorDatabase {
  GalleryMirrorDatabase(super.e);

  /// Opens the mirror database for the current platform - a file in the app
  /// support directory on mobile/desktop, sqlite3-over-WebAssembly in the
  /// browser. See `connection/connection.dart` for why that choice is made
  /// behind a conditional import rather than an `if (kIsWeb)` here.
  factory GalleryMirrorDatabase.open() {
    return GalleryMirrorDatabase(openMirrorConnection());
  }

  @override
  int get schemaVersion => 11;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // Real, incremental migrations - not a drop-and-recreate - because
          // the mirror and the sync cursor both live here: losing the cursor
          // on an app upgrade would force a full re-fetch of the gallery for
          // every user on every version bump.
          if (from < 2) {
            // v2 added GalleryItems.orientation. Existing rows default to 0
            // (the EXIF "no rotation" value) until the next delta sync
            // refreshes them.
            await m.addColumn(galleryItems, galleryItems.orientation);
          }
          if (from < 3) {
            // v3 added the thumbnail byte cache. It is pure cache: creating
            // it empty costs one cold fetch per thumbnail and nothing else.
            await m.createTable(cachedThumbnails);
          }
          if (from < 4) {
            // v4 (ticket 30) added the three indexes documented on
            // [GalleryItems] itself - the mirror had grown large enough that
            // every write and every grid page were full table scans. Adding
            // an index to an existing table is exactly what `createIndex`
            // is for: unlike `createTable`/`addColumn` above, there is no
            // data to backfill, so this is the whole migration step.
            await m.createIndex(idxGalleryItemsLocalIdentity);
            await m.createIndex(idxGalleryItemsOriginSizeCapturedAt);
            await m.createIndex(idxGalleryItemsCapturedAtId);
          }
          if (from < 5) {
            // v5 added ticket 29's Local Folder selection. A fresh, empty
            // table - never a drop-and-recreate of anything existing, and
            // no existing row is touched. Empty is the correct starting
            // state: it means "no explicit choice yet" for every folder,
            // which is exactly what makes [GalleryMirror]'s DCIM default
            // take over until a user actually toggles something (see the
            // class doc on [LocalFolderSelections]).
            //
            // This step was written as v4 on its own branch and renumbered
            // when it landed after ticket 30's indexes, which had already
            // taken v4. The renumber is the whole point of the `from <`
            // ladder: a device that already migrated to v4 for the indexes
            // still gets this table, which a second, competing v4 would
            // have silently denied it.
            await m.createTable(localFolderSelections);
          }
          if (from < 6) {
            // v6 (ticket 18) added Sync Pairs. A fresh, empty table - a
            // device that already has Device only or Cloud only rows keeps
            // them exactly as they are; only a subsequent
            // [GalleryMirror.createSyncPair] call (never this migration
            // itself) ever merges or re-labels anything. See the class doc
            // on [SyncPairs] for why the table is the local-only half of
            // Sync Pair configuration.
            await m.createTable(syncPairs);
          }
          if (from < 7) {
            // v7 (ticket 20) added verification-through-the-delta-feed
            // tracking: which (providerId, path) an upload actually targeted,
            // pending independent confirmation from the feed. Three nullable
            // columns on an existing table, plus their index - no data to
            // backfill, since a pre-upgrade device has no upload in flight
            // that this table did not already know about some other way (a
            // row either never attempted an upload, in which case these stay
            // null forever until one does, or ticket 19's old behaviour had
            // already flipped it to `both` - which this migration leaves
            // alone; only NEW uploads after the upgrade go through the
            // verification-gated path).
            await m.addColumn(galleryItems, galleryItems.uploadState);
            await m.addColumn(
                galleryItems, galleryItems.uploadTargetProviderId);
            await m.addColumn(galleryItems, galleryItems.uploadTargetPath);
            await m.createIndex(idxGalleryItemsUploadTarget);
          }
          if (from < 8) {
            // v8 (ticket 21) added [SyncPairs.removedAt] and dropped the
            // table's UNIQUE(local_folder_path) constraint - a retargeted
            // Local Source now has more than one row (an old, removed one
            // and a new, active one) sharing the same [SyncPairs.
            // localFolderPath], which the old column-level UNIQUE constraint
            // would have rejected outright. SQLite cannot alter or drop a
            // table-level constraint in place, so this is a full rebuild via
            // [alterTable]'s 12-step procedure rather than a plain
            // `addColumn` - it recreates the table from the CURRENT (already
            // constraint-free) Dart definition and copies every existing row
            // across untouched, [removedAt] defaulting to null (still
            // active) for all of them. See the class doc on [SyncPairs] for
            // why keeping every past target, not just the current one, is
            // what makes reconcile survive a retarget.
            await m.alterTable(TableMigration(
              syncPairs,
              newColumns: [syncPairs.removedAt],
            ));
          }
          if (from < 9) {
            // v9 (ticket 22) added [SyncRunState] - the headless sync
            // engine's one channel to the UI (spec: "the local database is
            // the interface between the engine and the UI"). A fresh, empty
            // table; [GalleryMirror.syncRunState] already reports an idle,
            // all-zero snapshot when no row exists yet, so an upgraded
            // device with no run in progress reads exactly as a fresh
            // install would.
            await m.createTable(syncRunState);
          }
          if (from < 10) {
            // v10 (ticket 23) added [TokenRefreshLock] - the cross-isolate
            // guard around the UI isolate's and the headless engine's own
            // non-interactive OIDC refresh (see that table's class doc). A
            // fresh, empty table - there is nothing to backfill, since a
            // pre-upgrade device has never had a lock row to begin with, and
            // an absent row already reads as "free" everywhere this table is
            // consulted.
            await m.createTable(tokenRefreshLock);
          }
          if (from < 11) {
            // v11 (ticket 24) added [SyncRunState.lastSuccessAt] - "the time
            // of the last successful pass is visible in the app, so silence
            // is distinguishable from success" (this ticket's own
            // criterion). [GalleryMirror.writeSyncRunState] backfills it
            // itself the next time a run actually completes, so an upgraded
            // device with a pre-existing `completed` row simply reads "no
            // successful pass known yet" (null) until its next run, rather
            // than needing a data migration to infer a historical value that
            // was never recorded.
            //
            // A table rebuild ([alterTable]), not a plain [addColumn]:
            // [syncRunState] is itself created mid-ladder (`if (from < 9)`
            // above, not part of the v1 baseline `onCreate` creates), and
            // [createTable] always builds a table from the CURRENT Dart
            // definition - which, from this version on, already includes
            // [SyncRunState.lastSuccessAt]. A device upgrading from below v9
            // straight to v11+ therefore runs BOTH steps in the same
            // `onUpgrade` call; a plain `addColumn` here would then try to
            // add a column the v9 step's `createTable` already created,
            // failing with "duplicate column name" - exactly the failure a
            // multi-version jump (installing after months away, not every
            // intermediate release) makes routine, not exotic. [alterTable]
            // recreates the table from the current schema and copies
            // whatever rows existed under the old name regardless of
            // whether they already happened to have this column, so it is
            // correct on every upgrade path: a single-version v10->v11
            // step, and a multi-version jump that never had a "before this
            // column existed" moment to begin with.
            await m.alterTable(TableMigration(
              syncRunState,
              newColumns: [syncRunState.lastSuccessAt],
            ));
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          // Ticket 22: the sync engine runs in its own headless isolate -
          // its own OS process, for all SQLite's locking cares, given how
          // `flutter_foreground_task` spins up a second `FlutterEngine` for
          // it - with its own [GalleryMirrorDatabase] connection to this
          // SAME file the UI isolate has open. WAL lets one writer and any
          // number of readers proceed concurrently instead of a writer
          // blocking every reader for the duration of its transaction, and
          // the busy timeout makes a writer-vs-writer collision (both
          // isolates committing at once) wait and retry instead of failing
          // outright with SQLITE_BUSY - together, "the engine and the UI can
          // both touch the database without corrupting it" (this ticket's
          // own acceptance criterion) rather than merely "without crashing
          // most of the time".
          //
          // Both are wrapped: an in-memory database (every test in this
          // suite) silently keeps its "memory" journal mode rather than
          // erroring on the WAL request, but the web build's sqlite3-over-
          // WebAssembly executor is a different SQLite VFS entirely and
          // nothing here should risk the gallery failing to open on a
          // platform this pair of pragmas was never meant to change
          // behaviour on in the first place - Sync Pairs, and therefore a
          // second isolate ever touching this database at all, are Android-
          // only (D7).
          try {
            await customStatement('PRAGMA journal_mode = WAL');
          } catch (_) {}
          try {
            await customStatement('PRAGMA busy_timeout = 5000');
          } catch (_) {}
        },
      );
}

/// One row per gallery item, cloud or (later) device.
///
/// Identity and dedup: a cloud item's identity is (`providerId`, `path`) -
/// the SPACE coordinates the gallery delta feed and listing API both use
/// (see `gallery/gallery/messages.go` `GalleryDeltaItem` doc). A future
/// device item's identity will be its local identity from design decision D9
/// (`docs/gallery-mode-design-notes.md`) - relative path, display name, size,
/// date taken - populated in the `local*` columns below, which exist now
/// (nullable) so that ticket 15 does not need to alter this table's shape,
/// only start populating and reading columns already present. Dedup between
/// a cloud item and its matching device item happens at write time by
/// resolving to the same row rather than inserting a second one; the exact
/// matching rule is ticket 15's decision, not this one's.
///
/// [origin] records which side(s) currently vouch for a row's existence -
/// `cloud`, `device`, or (once ticket 15 dedups a pair onto one row) `both` -
/// so the future "Cloud only" / "Device only" / "Synced" availability states
/// (D6/D17 in the design notes) can be read directly off this table without
/// a join.
///
/// **Three indexes (ticket 30), added in schema v4 - see
/// `GalleryMirrorDatabase.migration`'s `from < 4` step for why an existing
/// mirror gets them via `createIndex` rather than a table rebuild:**
///
/// - [idxGalleryItemsLocalIdentity] on `(localRelativePath, localDisplayName,
///   localSize, localDateTaken)` - the local-identity probe
///   `GalleryMirror._upsertLocalItem` runs once per device photo on every
///   scan. Without it, importing N device photos against an M-row mirror is
///   an O(N x M) table scan; a device with tens of thousands of photos made
///   this the dominant cost of opening the gallery.
/// - [idxGalleryItemsOriginSizeCapturedAt] on `(origin, size, capturedAt)` -
///   the dedup probe run from both directions (`applyPage`'s device match,
///   `_upsertLocalItem`'s cloud match). `origin` is deliberately the
///   leftmost column: SQLite can use a prefix of a multi-column index for a
///   query that only constrains that prefix, so `availabilitySummary()`'s
///   three `COUNT ... WHERE origin = ?` queries - run on every [reload] -
///   use this same index too. A fourth, single-column index on `origin`
///   alone would only duplicate that prefix for no benefit.
/// - [idxGalleryItemsCapturedAtId] on `(capturedAt, id)`, ascending - the
///   grid's own ordering (`queryItems`/`queryPage` sort by `capturedAt DESC,
///   id DESC`). Declared ascending rather than descending because SQLite can
///   walk an ascending index backwards to satisfy a `DESC` query directly;
///   a second, descending-only index here would exist purely to save SQLite
///   a reverse traversal it already knows how to do for free.
/// - [idxGalleryItemsUploadTarget] (ticket 20) on `(uploadTargetProviderId,
///   uploadTargetPath)` - the probe [GalleryMirror.applyPage] runs for every
///   non-tombstone feed item to recognise "this is the exact file I uploaded,
///   pending verification" before falling back to the ordinary dedup rules.
///   Without it, every delta page item costs a full table scan looking for a
///   row awaiting verification, on top of the dedup work the page already
///   does.
@TableIndex(
  name: 'idx_gallery_items_local_identity',
  columns: {
    #localRelativePath,
    #localDisplayName,
    #localSize,
    #localDateTaken,
  },
)
@TableIndex(
  name: 'idx_gallery_items_origin_size_captured_at',
  columns: {#origin, #size, #capturedAt},
)
@TableIndex(
  name: 'idx_gallery_items_captured_at_id',
  columns: {#capturedAt, #id},
)
@TableIndex(
  name: 'idx_gallery_items_upload_target',
  columns: {#uploadTargetProviderId, #uploadTargetPath},
)
class GalleryItems extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 'cloud', or (from ticket 15 on) 'device' / 'both'. Plain text rather
  /// than a Dart enum mapped column, so a future value does not require a
  /// migration by itself - only new columns do.
  TextColumn get origin => text().withDefault(const Constant('cloud'))();

  // --- Cloud identity (SPACE coordinates) and delta-feed bookkeeping ---

  /// SPACE provider id. Null for a device-only item (none exists yet, but
  /// the column is nullable from the start for that reason).
  TextColumn get providerId => text().nullable()();

  /// SPACE path. Null for a device-only item.
  TextColumn get path => text().nullable()();

  /// The delta feed sequence this row was last written at. Used only to
  /// decide idempotency of a re-applied page (see
  /// `GallerySyncService.applyPage`); the authoritative "how far has this
  /// device synced" position lives in [SyncCursors], not here.
  IntColumn get seq => integer().nullable()();

  // --- Future device identity (design decision D9), unused until ticket 15 ---

  TextColumn get localRelativePath => text().nullable()();
  TextColumn get localDisplayName => text().nullable()();
  IntColumn get localSize => integer().nullable()();
  IntColumn get localDateTaken => integer().nullable()();

  // --- Display metadata, shared by cloud and (later) device items ---

  /// Capture Date in epoch SECONDS (UTC) - the sort key for the merged
  /// gallery view (design decision D5). Seconds, not milliseconds, because
  /// that is what the delta feed carries: the gallery service derives the
  /// value with Go's `time.Time.Unix()` (`gallery/gallery/ingest.go`,
  /// `resolveCaptureDate`) and the mirror stores the wire value unconverted.
  IntColumn get capturedAt => integer()();
  TextColumn get capturedAtSource => text().withDefault(const Constant(''))();

  IntColumn get width => integer().withDefault(const Constant(0))();
  IntColumn get height => integer().withDefault(const Constant(0))();

  /// Added in schema v2, exercising the migration mechanism: EXIF
  /// orientation (1-8), defaulting to 0 ("unknown/not set") for rows written
  /// before this column existed.
  IntColumn get orientation => integer().withDefault(const Constant(0))();

  IntColumn get size => integer().withDefault(const Constant(0))();
  TextColumn get mime => text().withDefault(const Constant(''))();

  TextColumn get unsupported => text().withDefault(const Constant(''))();
  BoolColumn get metadataPending =>
      boolean().withDefault(const Constant(false))();

  // --- Ticket 20: verification through the delta feed ---

  /// Null when no upload is currently pending verification for this row -
  /// which is every row except a `device` one [GalleryMirror.recordUploaded]
  /// has written to. Four non-null values, one of two pairs depending on
  /// HOW the row got here (ticket 20's rework - the distinction matters
  /// because only one of the two may ever have its remote file deleted):
  ///
  /// - `'uploaded'` - a real PUT succeeded; [GalleryMirror.applyPage] is
  ///   watching the feed for confirmation at ([uploadTargetProviderId],
  ///   [uploadTargetPath]).
  /// - `'assumed'` - the ticket-19 "same size, assume it's ours" shortcut
  ///   fired instead: nothing was PUT, this device merely believes a
  ///   pre-existing file at the target path is its own content.
  /// - `'mismatch'` - a row that was `'uploaded'`, but the feed reported a
  ///   length that contradicts what this device sent. The remote file IS
  ///   this device's own upload, so it cannot be trusted and
  ///   [GalleryUploadService.retryMismatchedUpload] deletes it and retries.
  /// - `'assumedMismatch'` - a row that was `'assumed'`, but the feed
  ///   contradicted it. This device never wrote that file, so the mismatch
  ///   only disproves the assumption - it is never permission to delete
  ///   someone else's content. [GalleryUploadService.retryMismatchedUpload]
  ///   falls back to ticket 19's different-size collision rule instead:
  ///   disambiguate to a new name, leaving the file exactly as it was.
  ///
  /// Cleared back to null the moment verification actually succeeds - at
  /// that point [origin] has already flipped to `both`, which is what makes
  /// "Synced" true; this column exists only to gate that flip on the feed
  /// rather than on the upload response (CONTEXT.md's **Verified**, D10 in
  /// `docs/gallery-mode-design-notes.md`). Plain text, not a Dart enum
  /// column, for the same reason [origin] is.
  TextColumn get uploadState => text().nullable()();

  /// The exact (providerId, path) [GalleryUploadService.upload] PUT to, or
  /// found already occupied by this device's own content - **the path the
  /// photo actually went to, not a recipe for deriving it** (ticket 19),
  /// which matters here specifically because a disambiguated upload's real
  /// path cannot be recomputed from the Sync Pair alone. Set together with
  /// [uploadState] by [GalleryMirror.recordUploaded]; read back by
  /// [GalleryMirror.applyPage] to recognise the delta feed independently
  /// reporting this exact file. Both null whenever [uploadState] is.
  TextColumn get uploadTargetProviderId => text().nullable()();
  TextColumn get uploadTargetPath => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {providerId, path},
      ];
}

/// Delta-feed sync progress, one row per feed source (currently always
/// `'server'` - a single row today, but keyed so a second source is not a
/// schema change).
///
/// [since] is the last sequence value the client has fully applied - the
/// `NextSince` the server returned once a poll's `HasMore` became false. It
/// is what survives an app restart so a restart resumes rather than
/// re-fetching the whole gallery.
///
/// [pendingCursor] is the opaque page cursor for a poll still in progress
/// (`NextCursor` from the last page applied, while `HasMore` was still
/// true). It is persisted after every page is applied, and cleared once the
/// poll finishes - so a sync interrupted mid-page resumes exactly where it
/// left off on the next app start rather than restarting the poll from
/// [since] and re-applying already-applied pages. Re-applying is harmless
/// either way (upserts and tombstone-deletes are idempotent), but resuming
/// from [pendingCursor] avoids redoing the work.
class SyncCursors extends Table {
  TextColumn get source => text()();
  IntColumn get since => integer().withDefault(const Constant(0))();
  TextColumn get pendingCursor => text().nullable()();

  @override
  Set<Column> get primaryKey => {source};
}

/// Thumbnail bytes already fetched from the existing preview endpoint, kept
/// so that "with no network, the gallery still opens and shows already-cached
/// Thumbnails" is a property the app actually has rather than one it inherits
/// from whatever HTTP cache happens to be underneath it.
///
/// It lives in the mirror database rather than in files on disk for one
/// reason: drift already runs on every platform this app ships to, including
/// the web build (sqlite3-over-WebAssembly), so there is a single code path
/// instead of a `dart:io` cache plus a browser-cache assumption. Nothing here
/// is a source of gallery items - see [GalleryMirrorDatabase]'s doc.
///
/// Keyed on the same ([providerId], [path]) identity as [GalleryItems] plus
/// the requested [size], because the grid and the viewer ask for different
/// sizes of the same photo. [fetchedAt] exists so the cache can be pruned
/// oldest-first once it exceeds its entry budget.
class CachedThumbnails extends Table {
  TextColumn get providerId => text()();
  TextColumn get path => text()();

  /// The `w`/`h` value the preview endpoint was asked for. The endpoint snaps
  /// to its own size ladder, so this is the requested size, not necessarily
  /// the returned pixel size.
  IntColumn get size => integer()();

  BlobColumn get bytes => blob()();

  /// Epoch milliseconds this entry was written, used for oldest-first
  /// eviction.
  IntColumn get fetchedAt => integer()();

  @override
  Set<Column> get primaryKey => {providerId, path, size};
}

/// Ticket 29's Local Folder selection: which folders on this device feed the
/// merged gallery, as an explicit override a user has made by toggling one in
/// the *On this device* section of the Gallery folders screen.
///
/// A folder never explicitly toggled has **no row here at all** - its
/// selection is the DCIM default [GalleryMirror] computes instead (see the
/// class doc on `GalleryMirror.listLocalFolders` in `gallery_mirror.dart`).
/// That is what makes "the seed happens once and a user's choice is never
/// re-derived afterwards" true without a separate seed-marker row: a row
/// exists only once a user has made a choice, and once it does it wins over
/// the default forever, restart after restart.
///
/// **Never sent to the server** (design record D21, `docs/gallery-mode-
/// design-notes.md`, and D4's own reasoning): a Local Folder names a path
/// that exists on exactly one phone, so a second device has nothing useful
/// to read here.
class LocalFolderSelections extends Table {
  /// The device's own folder identifier - on Android, MediaStore's
  /// `RELATIVE_PATH` value (e.g. `DCIM/Camera/`), exactly the string
  /// [GalleryItems.localRelativePath] stores - so folder enumeration and
  /// selection lookup are a plain equality match, no normalisation needed.
  TextColumn get folderPath => text()();

  BoolColumn get selected => boolean()();

  @override
  Set<Column> get primaryKey => {folderPath};
}

/// Ticket 18's Sync Pairs: one row per configured mapping from a Local
/// Source on this device to a folder in Seraph. Everything under the local
/// folder is meant to be uploaded there, relative path preserved (ticket 19,
/// not this one - see [GalleryMirror.createSyncPair]'s "no network" note).
///
/// **Local, not server-side** (CONTEXT.md's Sync Pair entry, D4/D18 in
/// `docs/gallery-mode-design-notes.md`): a Sync Pair references a Local
/// Source that exists on exactly one device, so losing this table to a data
/// wipe costs a reconfiguration, never data - unlike Gallery Source Folders,
/// which live server-side because the thumbnail pre-generator needs to read
/// them and cannot reach into a phone's local database.
///
/// **Ticket 21 revised what "one row per Local Source" means.** A Sync Pair
/// is no longer deleted on removal - [GalleryMirror.removeSyncPair] sets
/// [removedAt] instead - and [localFolderPath] is consequently no longer a
/// unique column: a retargeted Local Source (delete-pair-plus-create-pair)
/// leaves an old, removed row and a new, active one both carrying the same
/// [localFolderPath]. **A Local Source may still appear in at most one
/// ACTIVE Sync Pair** ([removedAt] null), enforced the same way ticket 18's
/// overlap rule always was - [GalleryMirror.createSyncPair] checking before
/// insert, scoped to active rows only - so retargeting the same folder is
/// exactly the "delete then create" the spec calls for, not blocked by a
/// leftover historical row.
///
/// **Why keep the old rows at all, rather than truly deleting them:** the
/// spec's rule for the remote path function surviving a retarget is *current
/// target for writes, all targets for lookups*. [GalleryMirror.
/// expectedUploadTarget] (a write) reads only the active row for a Local
/// Source. Dedup and reconcile ([GalleryMirror._upsertLocalItem],
/// [GalleryMirror.applyPage]) are lookups - they consult every row a Local
/// Source has EVER had, active or not, because a photo already sitting at an
/// old target does not stop being backed up just because the pair that put
/// it there was replaced. Without this, a reinstall (or any reconcile pass)
/// after a retarget would only know about the new target, find nothing at
/// the old one, and duplicate every photo already there - the exact failure
/// `.scratch/gallery-mode/spec.md`'s "Remote path is a pure function"
/// section warns about.
///
/// Named `SyncPairRow` rather than drift's default `SyncPair` (see
/// [DataClassName] below) because `SyncPair` is already
/// [GalleryMirror]'s own public, richer model - id plus both sides plus
/// [SyncPair.photoCount] - which callers outside the mirror actually use.
@DataClassName('SyncPairRow')
class SyncPairs extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The device-side Local Source - on Android, MediaStore's `RELATIVE_PATH`
  /// for the folder (e.g. `DCIM/Camera/`), exactly the string
  /// [GalleryItems.localRelativePath] and [LocalFolderSelections.folderPath]
  /// use, so "which folder" means the same thing everywhere in the mirror.
  /// Coverage of a subfolder is a plain string-prefix test against this
  /// value (both always trailing-slash-terminated, so `DCIM/Camera/` can
  /// never falsely prefix-match `DCIM/Camera2/`).
  TextColumn get localFolderPath => text()();

  /// The Seraph folder side, in Space terms - the same
  /// (spaceProviderId, path) pair [GallerySourceFolder] uses, since this
  /// folder IS one (ticket 18's rule: a Sync Pair's Seraph folder
  /// automatically becomes a Gallery Source Folder). This is THIS row's
  /// target - current if [removedAt] is null, historical otherwise; see the
  /// class doc for how the two are used differently.
  TextColumn get spaceProviderId => text()();
  TextColumn get path => text()();

  /// Epoch milliseconds this pair was created - used only to order
  /// [GalleryMirror.listSyncPairs] (oldest first, so the list does not
  /// reorder itself as photo counts change).
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  /// Null while this pair is active (the normal state for every row before
  /// ticket 21). Set to the epoch milliseconds [GalleryMirror.removeSyncPair]
  /// ran at otherwise - the row is kept, never deleted, purely as a
  /// historical target for dedup/reconcile lookups (see the class doc).
  /// [GalleryMirror.listSyncPairs] (the UI's list) and every "current
  /// target" computation filter this to null; dedup/reconcile lookups do
  /// not filter on it at all.
  IntColumn get removedAt => integer().nullable()();
}

/// Ticket 22's headless sync engine progress: the engine's ONLY channel to
/// the UI (spec/`docs/gallery-mode-design-notes.md` D11: "the local database
/// is the interface between the engine and the UI - the engine writes state,
/// the UI observes and renders"). [GallerySyncEngine]
/// (`../sync/gallery_sync_engine.dart`) writes this after every item it
/// processes; [GalleryDataSyncController] (`../sync/gallery_data_sync_controller.dart`)
/// polls it to drive the in-app progress UI, and the foreground service's own
/// notification text is updated from the very same row - so the notification
/// and the app can never disagree about how a run is going, because there is
/// only one row either of them could be reading.
///
/// **Always exactly one row** ([id] is always [GalleryMirror.syncRunStateId])
/// - there is only ever one backup run at a time (one foreground service, one
/// engine instance), so this is a snapshot, not a log.
///
/// **Why a row survives the app/engine that wrote it dying mid-run:** on
/// restart, nothing here is treated as proof a run is still active - see
/// [GalleryMirror.syncRunState]'s doc and [GalleryDataSyncController]'s
/// reconciliation - so a `running` row left behind by a killed process is
/// read as "was running, is not now" (correctable to `paused`) rather than as
/// a stuck state.
class SyncRunState extends Table {
  TextColumn get id => text()();

  /// One of [GalleryMirror.syncStatusIdle]/[syncStatusRunning]/
  /// [syncStatusPaused]/[syncStatusCompleted]/[syncStatusError] - plain text,
  /// not a Dart enum column, for the same forward-compatibility reason
  /// [GalleryItems.origin] is.
  TextColumn get status => text()();

  /// How many items [GallerySyncEngine.run] queued for this run in total -
  /// retries (ticket 20's mismatched uploads) and fresh backlog alike. Fixed
  /// for the run's lifetime; only [completedItems] and [failedItems] move.
  IntColumn get totalItems => integer().withDefault(const Constant(0))();

  /// How many of [totalItems] have been attempted (successfully or not) so
  /// far - what "photos remaining" (this ticket's own progress criterion) is
  /// `totalItems - completedItems - failedItems` from.
  IntColumn get completedItems => integer().withDefault(const Constant(0))();

  /// How many of [totalItems] threw rather than completing - counted
  /// separately from [completedItems] so a run that hit failures does not
  /// silently read as fully done. A visible, actionable failure list is
  /// ticket 25's job; this is only the count.
  IntColumn get failedItems => integer().withDefault(const Constant(0))();

  /// The approximate total byte volume [totalItems] represents - "roughly
  /// how much data" (this ticket's own progress criterion), summed from each
  /// item's local file size once, up front, not re-measured per item.
  IntColumn get totalBytes => integer().withDefault(const Constant(0))();

  /// Bytes actually moved so far - only items that resulted in a real PUT or
  /// the ticket-19 same-size short-circuit add to this; an item skipped for
  /// any other reason (no Sync Pair, device file gone) advances
  /// [completedItems] without moving this.
  IntColumn get completedBytes => integer().withDefault(const Constant(0))();

  /// The most recent per-item failure's message, or null - a single value,
  /// not a log, because a real failure list (ticket 25) is out of this
  /// ticket's scope; this exists only so the UI has something more useful to
  /// show than a bare failure count while that ticket is still ahead.
  TextColumn get lastError => text().nullable()();

  /// Epoch milliseconds this row was last written - what
  /// [GalleryDataSyncController] uses to notice a `running` row has gone
  /// stale (see its own reconciliation doc) if it is ever extended to time
  /// out a run whose process vanished without the courtesy of a final write.
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  /// Ticket 24: epoch milliseconds the most recent run that reached
  /// [GalleryMirror.syncStatusCompleted] finished at, or null if no run ever
  /// has. **Never regresses** - [GalleryMirror.writeSyncRunState] carries the
  /// previous value forward on every write that is not itself a completed
  /// run, so a `running`/`paused`/`error` write never clears it. This is
  /// what makes "silence distinguishable from success" (the ticket's own
  /// wording) possible: an unattended scheduled run that silently stops
  /// firing (a killed process, a revoked permission, a constraint that never
  /// clears) leaves this timestamp visibly going stale in the UI, rather
  /// than the UI having no way to tell "quietly up to date" from "quietly
  /// not running at all".
  IntColumn get lastSuccessAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Ticket 23's cross-isolate token-refresh lock: a DB-backed mutex so the UI
/// isolate ([LoginController], `../../login/login_controller.dart`) and the
/// headless sync engine's own isolate (`_loadHeadlessSession` in
/// `../sync/gallery_sync_task_handler.dart`) never both call the OIDC token
/// endpoint's refresh grant at the same time. This matters specifically
/// because the app's refresh token ROTATES on every use: a second, truly
/// concurrent refresh presents a refresh token the first refresh has already
/// invalidated server-side, and the whole session dies silently - during an
/// unattended overnight backup, the worst possible moment to find out (spec:
/// "Token refresh is guarded by a database-backed cross-isolate lock").
///
/// Read and written through [GalleryMirror.tryAcquireTokenRefreshLock] /
/// [GalleryMirror.releaseTokenRefreshLock] / [GalleryMirror.
/// tokenRefreshLockHeld] - never directly - and the actual refresh callers on
/// both isolates go through `refreshTokenWithLock` in
/// `../sync/token_refresh_coordination.dart`, which is what turns "one
/// isolate holds the lock" into "the loser reads the persisted token instead
/// of refreshing again" (ticket 23's own acceptance criterion).
///
/// Lives under `gallery/mirror/` alongside every other mirror table even
/// though [LoginController] is not gallery-specific, because
/// [GalleryMirrorDatabase] is the only storage this app has that is already
/// open, as the SAME on-disk file, from both isolates - exactly what "the
/// lock must live in shared persistent storage, since isolates share no
/// memory" (this ticket's own text) requires. A second, auth-specific
/// database would only duplicate that property for no benefit.
///
/// **Always at most one row** ([id] is always [tokenRefreshLockId]) - the
/// same single-well-known-row shape [SyncRunState] uses, for the same reason:
/// there is only ever one refresh worth serialising against.
///
/// **Lease-based, not held until explicitly released.** [expiresAt] is what
/// bounds how long a holder may keep the lock even if it is killed before it
/// ever calls [GalleryMirror.releaseTokenRefreshLock] - an isolate reaped by
/// the OS mid-refresh (the headless service's process, or the app itself)
/// leaves a row behind that [GalleryMirror.tryAcquireTokenRefreshLock]'s own
/// UPSERT `WHERE` clause treats as free again once [expiresAt] has passed,
/// rather than a lock nothing could ever clear - this is what makes "An
/// isolate killed while holding the lock does not deadlock the other" true
/// without any process-liveness check, which neither isolate has any way to
/// perform on the other. [holder] is diagnostic only - an isolate-identifying
/// string recorded at acquisition - and plays no part in the acquisition
/// decision itself: an unexpired lease is honoured regardless of who asks.
class TokenRefreshLock extends Table {
  TextColumn get id => text()();

  /// Which isolate currently holds (or most recently held) the lock -
  /// `'ui'` or `'headless'`, see the constants next to `refreshTokenWithLock`
  /// in `../sync/token_refresh_coordination.dart`. Diagnostic only, per the
  /// class doc.
  TextColumn get holder => text()();

  /// Epoch milliseconds the current holder acquired the lock at.
  IntColumn get acquiredAt => integer()();

  /// Epoch milliseconds the current lease expires at - past this point the
  /// lock is free for another acquire regardless of whether
  /// [GalleryMirror.releaseTokenRefreshLock] was ever called (see the class
  /// doc's "lease-based" note).
  IntColumn get expiresAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}
