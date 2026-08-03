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
@DriftDatabase(
    tables: [GalleryItems, SyncCursors, CachedThumbnails, LocalFolderSelections])
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
  int get schemaVersion => 5;

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
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
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
