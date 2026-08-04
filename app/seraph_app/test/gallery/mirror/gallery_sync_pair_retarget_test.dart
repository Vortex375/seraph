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

/// Ticket 21's mirror-seam coverage: a Sync Pair's HISTORICAL targets, not
/// just its current one - "current target for writes, all targets for
/// lookups" (`.scratch/gallery-mode/spec.md`, "Remote path is a pure
/// function"). [GalleryMirror.removeSyncPair] keeps the removed row rather
/// than deleting it (see the class doc on `SyncPairs` in
/// `gallery_mirror_database.dart`), which is what makes every test below
/// possible without a second table.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryMirror Sync Pair retargeting (ticket 21)', () {
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
        'retargeting (remove then create) leaves a photo already backed up '
        'to the old target Synced, and a new photo goes to the new target',
        () async {
      final oldPair = await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Old',
      );

      // A photo already merged (Synced) against the OLD target, before the
      // retarget - what "photos already backed up to the old target stay
      // there" is asserting about.
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'already_there.jpg',
          size: 1111,
          dateTakenMillis: 1000000,
        ),
      ]);
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/Old/already_there.jpg',
              seq: 1,
              capturedAt: 1000,
              size: 1111)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      expect((await mirror.queryItems()).single.availability,
          GalleryAvailability.synced);

      // Retarget: delete-pair-plus-create-pair (ticket 21's stated flow).
      await mirror.removeSyncPair(oldPair.id);
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-b',
        path: '/Photos/New',
      );

      // The already-backed-up photo is untouched by the retarget itself.
      final afterRetarget = await mirror.queryItems();
      expect(afterRetarget, hasLength(1));
      expect(afterRetarget.single.availability, GalleryAvailability.synced);
      expect(afterRetarget.single.path, '/Photos/Old/already_there.jpg',
          reason: 'retargeting must not move a photo already at the old '
              'target');

      // A brand new device photo, appearing after the retarget, computes
      // its expected upload target against the NEW pair - "writes go to the
      // current target".
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'already_there.jpg',
          size: 1111,
          dateTakenMillis: 1000000,
        ),
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'brand_new.jpg',
          size: 2222,
          dateTakenMillis: 4000000,
        ),
      ]);
      final newItem = (await mirror.queryItems())
          .firstWhere((i) => i.localDisplayName == 'brand_new.jpg');
      final target = await mirror.expectedUploadTarget(newItem);
      expect(target, ('space-b', '/Photos/New/brand_new.jpg'),
          reason: 'a new photo goes to the CURRENT (new) target only');
    });

    test(
        'reinstalling after a retarget re-uploads nothing: a wipe-and-'
        'reconcile pass (full local scan plus one bulk delta-feed page) '
        'matches every photo back to whichever target - old or new - it is '
        'actually sitting at, and Availability reads Synced across the '
        'retarget', () async {
      // --- Before "reinstall": configure, retarget, and simulate uploads
      // to BOTH the old and the new target (so the reinstall has to
      // reconcile against history, not just the current target). ---
      final oldPair = await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Old',
      );
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'old_target_1.jpg',
          size: 100,
          dateTakenMillis: 1000000,
        ),
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'old_target_2.jpg',
          size: 200,
          dateTakenMillis: 2000000,
        ),
      ]);
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/Old/old_target_1.jpg',
              seq: 1,
              capturedAt: 1,
              size: 100),
          _cloudItem(
              path: '/Photos/Old/old_target_2.jpg',
              seq: 2,
              capturedAt: 2,
              size: 200),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      await mirror.removeSyncPair(oldPair.id);
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-b',
        path: '/Photos/New',
      );
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'old_target_1.jpg',
          size: 100,
          dateTakenMillis: 1000000,
        ),
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'old_target_2.jpg',
          size: 200,
          dateTakenMillis: 2000000,
        ),
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'new_target_1.jpg',
          size: 300,
          dateTakenMillis: 3000000,
        ),
      ]);
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/New/new_target_1.jpg',
              providerId: 'space-b',
              seq: 3,
              capturedAt: 3,
              size: 300),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 3,
      ));

      final beforeWipe = await mirror.queryItems();
      expect(beforeWipe, hasLength(3),
          reason: 'three distinct photos, all Synced, before the wipe');
      expect(beforeWipe.every((i) => i.availability == GalleryAvailability.synced),
          isTrue);

      // --- Simulate a reinstall: the local mirror's item cache (device
      // scan results and cloud rows alike) is wiped and rebuilt from
      // scratch, exactly what happens with a fresh GalleryItems table. Sync
      // Pair CONFIGURATION survives (it is local-only, ticket 18 - a real
      // uninstall costs a reconfiguration, but does not, by itself, lose
      // Seraph's own record of the two pairs the user already set up), so
      // both the current pair (space-b) and the retargeting's historical
      // one (space-a) are exactly what [GalleryMirror] still has. ---
      await db.delete(db.galleryItems).go();
      expect(await mirror.queryItems(), isEmpty);

      // The delta feed backfill: ONE bulk page carrying every cloud item
      // this user has, across BOTH the old and the new Gallery Source
      // Folder (both remain registered - ticket 18/21's "the cloud folder
      // remains a Gallery Source Folder" - so a cold backfill still walks
      // them). This is the "bulk query rather than one request per photo"
      // the acceptance criteria ask for: the whole reconcile below issues
      // exactly one simulated network page and one local full scan, no
      // matter how many photos are involved.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/Old/old_target_1.jpg',
              seq: 1,
              capturedAt: 1,
              size: 100),
          _cloudItem(
              path: '/Photos/Old/old_target_2.jpg',
              seq: 2,
              capturedAt: 2,
              size: 200),
          _cloudItem(
              path: '/Photos/New/new_target_1.jpg',
              providerId: 'space-b',
              seq: 3,
              capturedAt: 3,
              size: 300),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 3,
      ));
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'old_target_1.jpg',
          size: 100,
          dateTakenMillis: 1000000,
        ),
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'old_target_2.jpg',
          size: 200,
          dateTakenMillis: 2000000,
        ),
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'new_target_1.jpg',
          size: 300,
          dateTakenMillis: 3000000,
        ),
      ]);

      final afterReconcile = await mirror.queryItems();
      expect(afterReconcile, hasLength(3),
          reason: 'reconcile must not duplicate a single photo, at the old '
              'target or the new one');
      final byAvailability = <GalleryAvailability, int>{};
      for (final item in afterReconcile) {
        byAvailability[item.availability] =
            (byAvailability[item.availability] ?? 0) + 1;
      }
      expect(byAvailability[GalleryAvailability.synced], 3,
          reason: 'every photo - old-target and new-target alike - reads '
              'Synced again, not Device only, across the retarget');
    });

    test(
        'the same wipe-and-reconcile matches correctly when the local scan '
        'runs BEFORE the delta-feed backfill page arrives', () async {
      final oldPair = await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Old',
      );
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'old.jpg',
          size: 100,
          dateTakenMillis: 1000000,
        ),
      ]);
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/Old/old.jpg', seq: 1, capturedAt: 1, size: 100)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      await mirror.removeSyncPair(oldPair.id);
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-b',
        path: '/Photos/New',
      );

      await db.delete(db.galleryItems).go();

      // Local scan arrives FIRST this time - the opposite order from the
      // test above - to prove the historical-target match does not depend
      // on which side of the reconcile runs first (the same guarantee every
      // other dedup rule in this file already gives, per-direction tested).
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'old.jpg',
          size: 100,
          dateTakenMillis: 1000000,
        ),
      ]);
      expect((await mirror.queryItems()).single.availability,
          GalleryAvailability.deviceOnly,
          reason: 'not merged yet - the cloud side has not arrived');

      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/Old/old.jpg', seq: 1, capturedAt: 1, size: 100)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final items = await mirror.queryItems();
      expect(items, hasLength(1));
      expect(items.single.availability, GalleryAvailability.synced);
    });
  });
}
