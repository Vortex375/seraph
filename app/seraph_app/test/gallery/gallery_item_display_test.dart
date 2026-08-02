import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

import 'gallery_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryItemDisplay', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = openTestMirrorDatabase();
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<GalleryItem> single() async {
      final rows = await mirror.queryItems(limit: 1);
      return rows.single;
    }

    test('a quarter-turned photo displays with its dimensions swapped',
        () async {
      // The read model stores the RAW decoded dimensions plus the EXIF
      // orientation tag, so a portrait photo from a phone is stored 4000x3000
      // with orientation 6. Reserving 4000x3000 of screen for it would show
      // every portrait shot in a landscape box.
      await insertMirrorItem(db,
          path: '/Photos/portrait.jpg',
          capturedAt: 1000,
          width: 4000,
          height: 3000,
          orientation: 6);

      final item = await single();
      expect(item.isQuarterTurned, isTrue);
      expect(item.displayWidth, 3000);
      expect(item.displayHeight, 4000);
      expect(item.displayAspectRatio, closeTo(3000 / 4000, 0.0001));
    });

    test('a 180-degree or unset orientation leaves the dimensions alone',
        () async {
      await insertMirrorItem(db,
          path: '/Photos/a.jpg',
          capturedAt: 1000,
          width: 4000,
          height: 3000,
          orientation: 3);

      final item = await single();
      expect(item.isQuarterTurned, isFalse);
      expect(item.displayWidth, 4000);
      expect(item.displayHeight, 3000);
    });

    test('an item with unknown dimensions reports no aspect ratio', () async {
      await insertMirrorItem(db,
          path: '/Photos/pending.jpg',
          capturedAt: 1000,
          width: 0,
          height: 0,
          metadataPending: true);

      expect((await single()).displayAspectRatio, isNull);
    });

    test('Capture Date is read as epoch seconds, the unit the feed carries',
        () async {
      // 2021-06-01T12:00:00Z
      await insertMirrorItem(db, path: '/Photos/a.jpg', capturedAt: 1622548800);

      final item = await single();
      expect(item.capturedAtDateTime.toUtc(),
          DateTime.utc(2021, 6, 1, 12, 0, 0));
    });

    test('an unsupported item explains itself rather than being hidden',
        () async {
      await insertMirrorItem(db,
          path: '/Photos/raw.dng', capturedAt: 1000, unsupported: 'format');
      await insertMirrorItem(db,
          path: '/Photos/broken.jpg',
          capturedAt: 900,
          unsupported: 'corrupt');
      await insertMirrorItem(db,
          path: '/Photos/future.xyz',
          capturedAt: 800,
          unsupported: 'somethingNew');

      final items = await mirror.queryItems();
      expect(items, hasLength(3));
      expect(items.every((i) => i.isUnsupported), isTrue);

      expect(items[0].unsupportedReasonLabel,
          'This file format cannot be displayed');
      expect(items[1].unsupportedReasonLabel, contains('truncated or corrupt'));
      // A reason code this build does not know about is still shown, not
      // swallowed.
      expect(items[2].unsupportedReasonLabel, contains('somethingNew'));
    });

    test('a displayable item is not marked unsupported', () async {
      await insertMirrorItem(db, path: '/Photos/a.jpg', capturedAt: 1000);
      expect((await single()).isUnsupported, isFalse);
      expect((await single()).unsupportedReasonLabel, '');
    });

    test('an item names the Seraph folder it lives in', () async {
      await insertMirrorItem(db,
          providerId: 'family-space',
          path: '/Holidays/2019/Crete/beach.jpg',
          capturedAt: 1000);

      final item = await single();
      expect(item.fileName, 'beach.jpg');
      expect(item.folderPath, '/Holidays/2019/Crete');
      expect(item.folderDisplayPath, '/family-space/Holidays/2019/Crete');
      expect(item.spaceDisplayPath, '/family-space/Holidays/2019/Crete/beach.jpg');
    });

    test('an item at the root of its space still names a folder', () async {
      await insertMirrorItem(
          db, providerId: 'space-a', path: '/top.jpg', capturedAt: 1000);

      final item = await single();
      expect(item.folderPath, '/');
      expect(item.folderDisplayPath, '/space-a');
    });

    test('the Capture Date source is spelled out, so a fallback is visible',
        () async {
      await insertMirrorItem(db,
          path: '/Photos/exif.jpg', capturedAt: 3000, capturedAtSource: 'exif');
      await insertMirrorItem(db,
          path: '/Photos/mod.jpg',
          capturedAt: 2000,
          capturedAtSource: 'modTime');
      await insertMirrorItem(db,
          path: '/Photos/idx.jpg',
          capturedAt: 1000,
          capturedAtSource: 'indexed');

      final items = await mirror.queryItems();
      expect(items[0].hasExifCaptureDate, isTrue);
      expect(items[0].captureDateSourceLabel, contains('Taken'));
      expect(items[1].hasExifCaptureDate, isFalse);
      expect(items[1].captureDateSourceLabel, contains('File modified'));
      expect(items[2].captureDateSourceLabel, contains('First seen'));
    });
  });

  group('date labels', () {
    test('month labels are what the heading and the scrubber show', () {
      expect(galleryMonthLabel(DateTime(2026, 8, 2)), 'August 2026');
      expect(galleryMonthLabel(DateTime(2019, 1, 31)), 'January 2019');
    });

    test('day labels are what one photo shows', () {
      expect(galleryDayLabel(DateTime(2026, 8, 2)), '2 August 2026');
    });
  });
}
