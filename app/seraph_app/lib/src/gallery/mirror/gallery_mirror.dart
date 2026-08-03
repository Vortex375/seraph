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

/// [SyncCursors.source] value for ticket 17's device-side incremental-scan
/// watermark - the highest MediaStore generation already applied. Reuses the
/// same tiny table the delta feed's [GalleryMirror.since]/[pendingCursor]
/// live in: both are exactly "how far has this device gotten through a
/// change feed", just two different feeds, so a second table would only
/// duplicate [SyncCursors]' shape for no reason.
const String localMediaSource = 'local-media';

/// [SyncCursors.source] value for ticket 29's full-scan cadence: epoch
/// milliseconds at which [GalleryMirror.recordFullScanAt] last recorded a
/// completed full Local Source scan. A third borrower of [SyncCursors]'
/// shape, for the same reason [localMediaSource] is - this is "how far has
/// this device gotten", just measured in wall-clock time rather than a feed
/// position, so a purpose-built table would only duplicate what this one
/// already provides.
const String localFullScanSource = 'local-full-scan';

/// [SyncCursors.source] value for ticket 29's sync throttle: epoch
/// milliseconds at which the last (non-throttled) [GalleryGridController.
/// syncNow] completed. Persisted rather than held in memory because the
/// throttle must survive [GalleryGridController] itself being torn down and
/// recreated - GetX's `fenix: true` rebuilds it on every navigation back to
/// the gallery (see the class doc on [GalleryGridController] for why that
/// registration exists) - and an in-memory-only throttle would reset itself
/// on exactly the navigation pattern it exists to guard against.
const String syncThrottleSource = 'sync-throttle';

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
  Future<void> applyPage(
    GalleryDeltaResponse page, {
    String source = gallerySyncSource,
  }) async {
    await _db.transaction(() async {
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

        // No row for this (providerId, path) yet. A Device only row matching
        // by (size, capturedAt) is plausibly the same photo (see the class
        // doc on [applyLocalScan] for why this heuristic and not something
        // stronger) - merge onto it instead of inserting a second row, so a
        // photo already on the device that the delta feed reports for the
        // first time appears exactly once, at the position it already had.
        final deviceMatch = await (_db.select(_db.galleryItems)
              ..where((t) =>
                  t.origin.equals(_originDevice) &
                  t.size.equals(item.size) &
                  t.capturedAt.equals(item.capturedAt))
              ..limit(1))
            .getSingleOrNull();

        if (deviceMatch != null) {
          await (_db.update(_db.galleryItems)
                ..where((t) => t.id.equals(deviceMatch.id)))
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
  /// **Matching, in order:**
  /// 1. A row already carrying this exact local identity - `(relativePath,
  ///    displayName, size, dateTaken)` - is left alone. This is what makes a
  ///    changed (non-durable) media-store id a no-op: identity, not id,
  ///    decides "have we seen this file before".
  /// 2. Otherwise, a Cloud only row matching by `(size, capturedAt)` is
  ///    plausibly the same photo arriving from the other side - e.g. a photo
  ///    already in Seraph (copied over SMB, uploaded from the web UI, from
  ///    another phone) that also happens to sit on this device, with no Sync
  ///    Pair ever having linked the two. Merging onto that row is what makes
  ///    "a photo present both on the device and in Seraph appears exactly
  ///    once" true even before Sync Pairs and Upload exist (phase 3) to
  ///    record the link explicitly. `(size, capturedAt)` rather than a
  ///    content hash: D19/the spec's "no content hashing anywhere" rule
  ///    applies here too, and this ticket has even less to go on than the
  ///    upload path's path+size reconcile, since a device item's path is
  ///    never a Seraph path. The false-negative failure mode (two distinct
  ///    photos of identical size taken in the same second) produces a
  ///    harmless duplicate row, not a wrong merge.
  /// 3. Otherwise, a new Device only row.
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
      final seenIdentities = <String>{};

      for (final item in items) {
        seenIdentities.add(_localIdentityKey(
          relativePath: item.relativePath,
          displayName: item.displayName,
          size: item.size,
          dateTakenMillis: item.dateTakenMillis,
        ));
        await _upsertLocalItem(item);
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
      for (final item in items) {
        await _upsertLocalItem(item);
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
  /// `0` if one never has - ticket 29's "nothing has ever scanned" and "the
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
  /// a row already carrying [item]'s exact local identity is left alone: a
  /// Cloud only row matching by `(size, capturedAt)` is merged onto
  /// (Device+Cloud dedup, see [applyLocalScan]'s class doc for why this
  /// heuristic); otherwise a new Device only row is inserted. Never deletes
  /// or demotes anything - that determination needs the whole scan's result
  /// set, which only [applyLocalScan] has.
  Future<void> _upsertLocalItem(LocalMediaItem item) async {
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

  /// One page of the mirror, Capture Date descending (newest first, matching
  /// the server listing's order), with a total row count. Works with no
  /// network - it is a plain local query.
  ///
  /// [filter] restricts which rows are included (ticket 15's Availability
  /// filter) without ever changing their relative order - Availability is
  /// shown, and now filterable, but it never fragments the ordering.
  Future<GalleryMirrorPage> queryPage({
    int offset = 0,
    int limit = 100,
    GalleryAvailabilityFilter filter = GalleryAvailabilityFilter.all,
  }) async {
    final query = _db.select(_db.galleryItems)
      ..orderBy([
        (t) => OrderingTerm(expression: t.capturedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit, offset: offset);
    _applyFilter(query, filter);

    final items = await query.get();
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
  }) {
    final query = _db.select(_db.galleryItems)
      ..orderBy([
        (t) => OrderingTerm(expression: t.capturedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit, offset: offset);
    _applyFilter(query, filter);

    return query.get();
  }

  void _applyFilter(
    SimpleSelectStatement<$GalleryItemsTable, GalleryItem> query,
    GalleryAvailabilityFilter filter,
  ) {
    switch (filter) {
      case GalleryAvailabilityFilter.all:
        break;
      case GalleryAvailabilityFilter.notBackedUp:
        query.where((t) => t.origin.equals(_originDevice));
        break;
      case GalleryAvailabilityFilter.cloudOnly:
        query.where((t) => t.origin.equals(_originCloud));
        break;
    }
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
  /// restricted by Availability.
  Future<int> totalCount({
    GalleryAvailabilityFilter filter = GalleryAvailabilityFilter.all,
  }) {
    switch (filter) {
      case GalleryAvailabilityFilter.all:
        return _countWhere(null);
      case GalleryAvailabilityFilter.notBackedUp:
        return _countWhere(_originDevice);
      case GalleryAvailabilityFilter.cloudOnly:
        return _countWhere(_originCloud);
    }
  }

  /// How many items are Device only, Synced and Cloud only right now - the
  /// backed-up/not-backed-up summary ticket 15 asks for. Always over the
  /// WHOLE mirror, regardless of any Availability filter a caller has
  /// applied to what it is displaying - the summary is meant to answer "what
  /// would I lose", not "what am I currently looking at".
  Future<GalleryAvailabilitySummary> availabilitySummary() async {
    final deviceOnly = await _countWhere(_originDevice);
    final synced = await _countWhere(_originBoth);
    final cloudOnly = await _countWhere(_originCloud);
    return GalleryAvailabilitySummary(
      deviceOnly: deviceOnly,
      synced: synced,
      cloudOnly: cloudOnly,
    );
  }

  Future<int> _countWhere(String? origin) async {
    final countExp = _db.galleryItems.id.count();
    final query = _db.selectOnly(_db.galleryItems)..addColumns([countExp]);
    if (origin != null) {
      query.where(_db.galleryItems.origin.equals(origin));
    }
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }
}
