import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Value;
import 'package:seraph_app/src/gallery/gallery_photo_viewer.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

import 'gallery_test_support.dart';

/// The viewer's details sheet, at the seam the gallery-metadata tickets care
/// about: the Place line appears - "locality, admin1, country", skipping
/// empty parts - exactly when the item carries a Place, and is absent
/// otherwise. No coordinates, no map.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GalleryMirrorDatabase db;

  setUp(() {
    Get.testMode = true;
    db = openTestMirrorDatabase();
  });

  tearDown(() async {
    await db.close();
    Get.reset();
  });

  Future<GalleryItem> insertAndRead({
    String countryCode = '',
    String country = '',
    String admin1Code = '',
    String admin1 = '',
    int localityId = 0,
    String locality = '',
  }) async {
    await insertMirrorItem(
      db,
      path: '/Photos/a.jpg',
      capturedAt: 1700000000,
      placeCountryCode: countryCode,
      placeCountry: country,
      placeAdmin1Code: admin1Code,
      placeAdmin1: admin1,
      placeLocalityId: localityId,
      placeLocality: locality,
    );
    final rows = await db.select(db.galleryItems).get();
    return rows.last;
  }

  Future<void> pumpDetails(WidgetTester tester, GalleryItem item) async {
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: GalleryPhotoDetails(item: item),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a photo with a full Place shows "locality, admin1, country"',
      (tester) async {
    final item = await insertAndRead(
      countryCode: 'PT',
      country: 'Portugal',
      admin1Code: 'PT.11',
      admin1: 'Lisbon',
      localityId: 2267057,
      locality: 'Lisbon',
    );
    await pumpDetails(tester, item);

    expect(find.text('Lisbon, Lisbon, Portugal'), findsOneWidget);
    expect(find.text('Place'), findsOneWidget);
  });

  testWidgets('empty Place parts are skipped, not shown as blanks',
      (tester) async {
    final item = await insertAndRead(
      countryCode: 'GL',
      country: 'Greenland',
    );
    await pumpDetails(tester, item);

    expect(find.text('Greenland'), findsOneWidget);
    expect(find.text('Lisbon'), findsNothing);
  });

  testWidgets('a photo without a Place has no Place row at all',
      (tester) async {
    final item = await insertAndRead();
    await pumpDetails(tester, item);

    expect(find.text('Place'), findsNothing);
  });
}
