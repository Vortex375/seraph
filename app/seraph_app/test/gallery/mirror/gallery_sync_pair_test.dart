import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

import '../gallery_test_support.dart';

GalleryDeltaItem _cloudItem({
  String providerId = 'space-a',
  required String path,
  required int seq,
  required int capturedAt,
  int size = 2048,
  bool tombstone = false,
}) {
  return GalleryDeltaItem(
    providerId: providerId,
    path: path,
    seq: seq,
    tombstone: tombstone,
    capturedAt: capturedAt,
    size: size,
  );
}

/// Ticket 18's mirror-seam coverage: Sync Pair configuration (create, list
/// with counts, conflict refusal, persistence, removal) and the dedup rule
/// order it introduces - a Sync Pair's deterministic path+size match always
/// outranking, and for a covered item completely replacing, ticket 15's
/// (size, capturedAt) heuristic. Driven directly against [GalleryMirror],
/// exactly the seam ticket 13 established, with a fake Local Source never
/// even needed since these are pure local-database operations - a "stubbed
/// backend" for the network half (adding a Gallery Source Folder) lives at
/// the view/service layer instead, since [GalleryMirror] itself does no
/// network access (see its class doc).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryMirror Sync Pair configuration', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('createSyncPair persists a pair mapping a device folder to a '
        'Seraph folder', () async {
      final pair = await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      expect(pair.localFolderPath, 'DCIM/Camera/');
      expect(pair.spaceProviderId, 'space-a');
      expect(pair.path, '/Photos/Phone');
      expect(pair.photoCount, 0);
      expect(pair.seraphDisplayPath, '/space-a/Photos/Phone');

      final pairs = await mirror.listSyncPairs();
      expect(pairs, hasLength(1));
      expect(pairs.single.id, pair.id);
    });

    test('multiple Sync Pairs can be configured, targeting different Seraph '
        'folders', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      await mirror.createSyncPair(
        localFolderPath: 'Pictures/Screenshots/',
        spaceProviderId: 'space-a',
        path: '/Photos/Screenshots',
      );

      final pairs = await mirror.listSyncPairs();
      expect(pairs, hasLength(2));
      expect(pairs.map((p) => p.path),
          containsAll(<String>['/Photos/Phone', '/Photos/Screenshots']));
    });

    test('adding a device folder already covered by another Sync Pair is '
        'refused', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      await expectLater(
        mirror.createSyncPair(
          localFolderPath: 'DCIM/Camera/',
          spaceProviderId: 'space-a',
          path: '/Photos/Other',
        ),
        throwsA(isA<SyncPairConflictException>()),
      );

      expect(await mirror.listSyncPairs(), hasLength(1),
          reason: 'the refused pair must not have been created');
    });

    test('the conflict check refuses a parent or child folder too, not just '
        'an exact match - a photo must never be covered by two pairs',
        () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      await expectLater(
        mirror.createSyncPair(
          localFolderPath: 'DCIM/',
          spaceProviderId: 'space-a',
          path: '/Photos/All',
        ),
        throwsA(isA<SyncPairConflictException>()),
        reason: 'a parent folder would let DCIM/Camera/ be covered twice',
      );

      await expectLater(
        mirror.createSyncPair(
          localFolderPath: 'DCIM/Camera/Edited/',
          spaceProviderId: 'space-a',
          path: '/Photos/Edited',
        ),
        throwsA(isA<SyncPairConflictException>()),
        reason: 'a child folder is covered by the existing pair already',
      );

      expect(await mirror.listSyncPairs(), hasLength(1));
    });

    test('listSyncPairs reports how many photos each pair currently covers, '
        'including subfolders', () async {
      await mirror.applyLocalScan([
        localMediaItem(
            relativePath: 'DCIM/Camera/', displayName: 'a.jpg', size: 1),
        localMediaItem(
            relativePath: 'DCIM/Camera/2026/', displayName: 'b.jpg', size: 2),
        localMediaItem(
            relativePath: 'Pictures/Screenshots/',
            displayName: 'c.jpg',
            size: 3),
      ]);

      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      final pairs = await mirror.listSyncPairs();
      expect(pairs.single.photoCount, 2,
          reason: 'a.jpg directly in the folder and b.jpg in a subfolder - '
              'not the unrelated Screenshots photo');
    });

    test('Sync Pairs persist across app restarts', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      // Simulate a restart: a fresh GalleryMirror over the SAME database.
      final restarted = GalleryMirror(db);
      final pairs = await restarted.listSyncPairs();
      expect(pairs, hasLength(1));
      expect(pairs.single.localFolderPath, 'DCIM/Camera/');
      expect(pairs.single.path, '/Photos/Phone');
    });

    test('removing a Sync Pair leaves the pairs list without it, and '
        'changes no gallery row', () async {
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'a.jpg',
          size: 1024,
          dateTakenMillis: 1000000,
        ),
      ]);
      final pair = await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      final beforeRows = await db.select(db.galleryItems).get();

      await mirror.removeSyncPair(pair.id);

      expect(await mirror.listSyncPairs(), isEmpty);
      final afterRows = await db.select(db.galleryItems).get();
      expect(afterRows, hasLength(beforeRows.length));
      expect(afterRows.single.id, beforeRows.single.id);
    });
  });

  group('GalleryMirror Sync Pair dedup (ticket 18 rule order)', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
    });

    test(
        'a device photo whose disagreeing Capture Date would have split the '
        'heuristic still merges into one item when the Sync Pair path '
        'matches - cloud item present first', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/Phone/IMG_0001.jpg',
              seq: 1,
              capturedAt: 500000,
              size: 4096)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      final beforeId = (await mirror.queryItems()).single.id;

      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_0001.jpg',
          size: 4096,
          // Deliberately disagrees with the server-extracted capturedAt
          // (500000) above - the case the (size, capturedAt) heuristic
          // would have split into two rows.
          dateTakenMillis: 999999 * 1000,
        ),
      ]);

      final items = await mirror.queryItems();
      expect(items, hasLength(1));
      expect(items.single.id, beforeId);
      expect(items.single.availability, GalleryAvailability.synced);
      expect(items.single.capturedAt, 500000,
          reason: 'the row must not move even though the device disagreed');
    });

    test(
        'the same disagreeing-date merge happens when the cloud item arrives '
        'AFTER the covered device photo', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_0002.jpg',
          size: 3000,
          dateTakenMillis: 111111 * 1000,
        ),
      ]);
      final beforeId = (await mirror.queryItems()).single.id;
      expect((await mirror.queryItems()).single.availability,
          GalleryAvailability.deviceOnly);

      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/Phone/IMG_0002.jpg',
              seq: 1,
              // Disagrees with the device's own dateTakenMillis (111111).
              capturedAt: 777777,
              size: 3000)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final items = await mirror.queryItems();
      expect(items, hasLength(1));
      expect(items.single.id, beforeId);
      expect(items.single.availability, GalleryAvailability.synced);
      expect(items.single.capturedAt, 111111,
          reason: 'the device row (which existed first) keeps its position');
    });

    test(
        'two distinct device photos of identical size and Capture Date, '
        'both covered by a Sync Pair, stay two items - the heuristic must '
        'not steal one onto an unrelated cloud row that happens to '
        'collide', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      // An unrelated cloud photo, uploaded independently of this pair, that
      // happens to collide on (size, capturedAt) with both burst shots
      // below - exactly the coincidence the ticket 15 heuristic alone could
      // not tell apart from a real match.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Elsewhere/unrelated.jpg',
              seq: 1,
              capturedAt: 42000,
              size: 9999)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'burst1.jpg',
          size: 9999,
          dateTakenMillis: 42000 * 1000,
        ),
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'burst2.jpg',
          size: 9999,
          dateTakenMillis: 42000 * 1000,
        ),
      ]);

      final items = await mirror.queryItems();
      expect(items, hasLength(3),
          reason: 'the two burst shots and the unrelated cloud photo, all '
              'distinct - neither burst shot may steal the unrelated match');
      final byAvailability = <GalleryAvailability, int>{};
      for (final item in items) {
        byAvailability[item.availability] =
            (byAvailability[item.availability] ?? 0) + 1;
      }
      expect(byAvailability[GalleryAvailability.deviceOnly], 2);
      expect(byAvailability[GalleryAvailability.cloudOnly], 1);
    });

    test(
        'the same protection holds when the unrelated cloud photo arrives '
        'AFTER the covered burst shots', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'burst1.jpg',
          size: 9999,
          dateTakenMillis: 42000 * 1000,
        ),
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'burst2.jpg',
          size: 9999,
          dateTakenMillis: 42000 * 1000,
        ),
      ]);

      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Elsewhere/unrelated.jpg',
              seq: 1,
              capturedAt: 42000,
              size: 9999)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final items = await mirror.queryItems();
      expect(items, hasLength(3));
      final byAvailability = <GalleryAvailability, int>{};
      for (final item in items) {
        byAvailability[item.availability] =
            (byAvailability[item.availability] ?? 0) + 1;
      }
      expect(byAvailability[GalleryAvailability.deviceOnly], 2);
      expect(byAvailability[GalleryAvailability.cloudOnly], 1);
    });

    test(
        'the heuristic still applies to device items no Sync Pair covers, '
        'even while other Sync Pairs exist', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(path: '/Photos/other.jpg', seq: 1, capturedAt: 5000, size: 777)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      await mirror.applyLocalScan([
        // Deliberately under DCIM but NOT under the pair's own
        // 'DCIM/Camera/' folder - covered by neither the pair nor (ticket
        // 29's) an unselected-folder default, so only the folder coverage
        // question is exercised, not Local Folder visibility.
        localMediaItem(
          relativePath: 'DCIM/Screenshots/',
          displayName: 'shot.jpg',
          size: 777,
          dateTakenMillis: 5000 * 1000,
        ),
      ]);

      final items = await mirror.queryItems();
      expect(items, hasLength(1),
          reason: 'an uncovered item still gets the ticket 15 heuristic');
      expect(items.single.availability, GalleryAvailability.synced);
    });

    test(
        'configuring a Sync Pair whose Seraph folder already holds a device '
        "photo's counterpart merges the two into one Synced item, without "
        'any upload having happened', () async {
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_9999.jpg',
          size: 12345,
          dateTakenMillis: 1000000,
        ),
      ]);
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/Phone/IMG_9999.jpg',
              seq: 1,
              // Disagrees with the device row's own capturedAt (1000) -
              // proof the merge is path-driven, not date-driven.
              capturedAt: 999999,
              size: 12345)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      expect(await mirror.totalCount(), 2,
          reason: 'two standalone items before the pair exists');

      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      final items = await mirror.queryItems();
      expect(items, hasLength(1),
          reason: 'merged the moment the pair was configured');
      expect(items.single.availability, GalleryAvailability.synced);
      expect(items.single.path, '/Photos/Phone/IMG_9999.jpg');
      expect(items.single.localDisplayName, 'IMG_9999.jpg');
      expect(items.single.capturedAt, 1000,
          reason: 'the device row existed first and keeps its position');
    });

    test(
        'ticket 21: removing a Sync Pair does NOT return its items to '
        'heuristic dedup - a folder it ever covered keeps its one '
        'deterministic path+size chance forever, never the fuzzy '
        '(size, capturedAt) fallback', () async {
      final pair = await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'kept.jpg',
          size: 500,
          dateTakenMillis: 2000000,
        ),
      ]);
      final beforeRemoval = await db.select(db.galleryItems).get();
      expect(beforeRemoval, hasLength(1));

      await mirror.removeSyncPair(pair.id);

      // The row itself is untouched by the removal.
      final afterRemoval = await db.select(db.galleryItems).get();
      expect(afterRemoval, hasLength(1));
      expect(afterRemoval.single.id, beforeRemoval.single.id);
      expect(afterRemoval.single.origin, 'device');

      // Before ticket 21, a folder losing its only pair fell back to the
      // ticket 15 heuristic - here, that would have wrongly merged this
      // unrelated cloud item onto 'kept.jpg' purely because they collide on
      // (size, capturedAt). Ticket 21: the removed pair is kept as a
      // historical target ([GalleryMirror._allSyncPairs]), so this folder
      // stays covered forever - the heuristic never gets a vote on it again,
      // removed pair or not.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Unrelated/whatever.jpg',
              seq: 1,
              capturedAt: 2000,
              size: 500)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final items = await mirror.queryItems();
      expect(items, hasLength(2),
          reason: 'the unrelated cloud item must NOT steal the device row - '
              'it becomes its own Cloud only item instead');
      final byAvailability = <GalleryAvailability, int>{};
      for (final item in items) {
        byAvailability[item.availability] =
            (byAvailability[item.availability] ?? 0) + 1;
      }
      expect(byAvailability[GalleryAvailability.deviceOnly], 1,
          reason: '\'kept.jpg\' stays exactly what it was - not backed up');
      expect(byAvailability[GalleryAvailability.cloudOnly], 1);
    });

    test(
        'ticket 21: a cloud item arriving at a removed pair\'s own '
        '(historical) target still merges deterministically, even with no '
        'active pair covering the folder any more', () async {
      final pair = await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'late.jpg',
          size: 777,
          dateTakenMillis: 3000000,
        ),
      ]);
      await mirror.removeSyncPair(pair.id);

      // The delta feed only now reports the file at the removed pair's own
      // target - e.g. an upload that was in flight, or a slow-arriving feed
      // page, at the moment the pair was removed.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/Phone/late.jpg',
              seq: 1,
              // Deliberately disagrees with the device's own Capture Date -
              // path+size, not (size, capturedAt), is what must decide this.
              capturedAt: 999,
              size: 777)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final items = await mirror.queryItems();
      expect(items, hasLength(1),
          reason: 'the device row and the historical-target cloud item '
              'merge onto one Synced row rather than staying two');
      expect(items.single.availability, GalleryAvailability.synced);
      expect(items.single.capturedAt, 3000000 ~/ 1000,
          reason: 'the device row (which existed first) keeps its position');
    });
  });
}
