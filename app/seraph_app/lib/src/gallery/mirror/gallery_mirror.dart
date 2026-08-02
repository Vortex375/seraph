import 'package:drift/drift.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

/// The name of the (currently only) delta-feed source, used as the key into
/// [SyncCursors]. Kept as a named constant rather than a literal scattered
/// across the sync service and its tests, and because a second source
/// (unrelated to device items, which live in [GalleryItems] itself) is not
/// unthinkable.
const String gallerySyncSource = 'server';

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
  Future<void> applyPage(
    GalleryDeltaResponse page, {
    String source = gallerySyncSource,
  }) async {
    await _db.transaction(() async {
      for (final item in page.items) {
        if (item.tombstone) {
          await (_db.delete(_db.galleryItems)
                ..where((t) =>
                    t.providerId.equals(item.providerId) &
                    t.path.equals(item.path)))
              .go();
          continue;
        }

        final companion = GalleryItemsCompanion.insert(
          origin: const Value('cloud'),
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
        );

        // The conflict target must be the (providerId, path) unique key,
        // not the default (the primary key, `id`): a fresh insert never
        // supplies `id`, so the default target would never match anything
        // and every re-delivered item would insert a duplicate row instead
        // of updating the existing one - defeating the write-time dedup
        // this table exists for (see GalleryMirrorDatabase's GalleryItems
        // doc).
        await _db.into(_db.galleryItems).insert(
              companion,
              onConflict: DoUpdate(
                (_) => companion,
                target: [_db.galleryItems.providerId, _db.galleryItems.path],
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

  /// One page of the mirror, Capture Date descending (newest first, matching
  /// the server listing's order), with a total row count. Works with no
  /// network - it is a plain local query.
  Future<GalleryMirrorPage> queryPage({int offset = 0, int limit = 100}) async {
    final query = _db.select(_db.galleryItems)
      ..orderBy([
        (t) => OrderingTerm(expression: t.capturedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit, offset: offset);

    final items = await query.get();
    final totalCount = await this.totalCount();

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
  Future<List<GalleryItem>> queryItems({int offset = 0, int limit = 100}) {
    final query = _db.select(_db.galleryItems)
      ..orderBy([
        (t) => OrderingTerm(expression: t.capturedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit, offset: offset);

    return query.get();
  }

  /// The Capture Date of the item at [offset] in the gallery's order, or null
  /// if the mirror has no item there.
  ///
  /// This is what the date scrubber needs: while the user drags it, the
  /// position under their thumb has to be turned into a point in time without
  /// first loading the page of items it lands on - the whole point of the
  /// scrubber is to move faster than pages can load.
  Future<DateTime?> capturedAtAtOffset(int offset) async {
    if (offset < 0) {
      return null;
    }
    final rows = await queryItems(offset: offset, limit: 1);
    if (rows.isEmpty) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(rows.first.capturedAt * 1000);
  }

  /// The total number of items currently in the mirror.
  Future<int> totalCount() async {
    final countExp = _db.galleryItems.id.count();
    final query = _db.selectOnly(_db.galleryItems)..addColumns([countExp]);
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }
}
