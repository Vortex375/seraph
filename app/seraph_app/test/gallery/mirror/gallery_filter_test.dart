import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

import '../gallery_test_support.dart';

/// Epoch seconds of a WALL-CLOCK moment rendered as if it were UTC - the
/// "wall seconds" frame the date-range predicate and [galleryCaptureWallTime]
/// both speak (ADR 0003).
int wallSeconds(int year, int month, int day, [int hour = 0, int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).millisecondsSinceEpoch ~/ 1000;

/// Turns a row [insertMirrorItem] wrote (cloud by default) into a Device
/// only one - what a photo only this device holds looks like to the filter.
Future<void> _makeDeviceOnly(GalleryMirrorDatabase db, String path) async {
  await (db.update(db.galleryItems)..where((t) => t.path.equals(path)))
      .write(const GalleryItemsCompanion(
    origin: Value('device'),
  ));
}

GalleryDeltaItem _feedItem({
  String providerId = 'space-a',
  required String path,
  required int seq,
  int capturedAt = 1000,
  int? capturedAtOffset,
  double? lat,
  double? lon,
  String placeCountryCode = '',
  String placeCountry = '',
  String placeAdmin1Code = '',
  String placeAdmin1 = '',
  int placeLocalityId = 0,
  String placeLocality = '',
}) {
  return GalleryDeltaItem(
    providerId: providerId,
    path: path,
    seq: seq,
    tombstone: false,
    capturedAt: capturedAt,
    capturedAtSource: 'exif',
    capturedAtOffset: capturedAtOffset,
    lat: lat,
    lon: lon,
    placeCountryCode: placeCountryCode,
    placeCountry: placeCountry,
    placeAdmin1Code: placeAdmin1Code,
    placeAdmin1: placeAdmin1,
    placeLocalityId: placeLocalityId,
    placeLocality: placeLocality,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryFilter date range (capture wall time, ADR 0003)', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;
    var deviceOffset = 0;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db, deviceUtcOffsetSeconds: () => deviceOffset);
    });

    tearDown(() async {
      await db.close();
    });

    test(
        'a photo at 23:30 wall (+02:00) on the last day is included; '
        '00:30 the next wall day is not - independent of the device zone',
        () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          // Wall 2024-05-10 23:30 +02:00 -> true instant 2024-05-10 21:30 UTC.
          _feedItem(
              path: '/Photos/last-day.jpg',
              seq: 1,
              capturedAt: wallSeconds(2024, 5, 10, 21, 30),
              capturedAtOffset: 7200),
          // Wall 2024-05-11 00:30 +02:00 -> true instant 2024-05-10 22:30 UTC
          // - a LATER instant than the one above, sorting after it, yet the
          // next WALL day.
          _feedItem(
              path: '/Photos/next-day.jpg',
              seq: 2,
              capturedAt: wallSeconds(2024, 5, 10, 22, 30),
              capturedAtOffset: 7200),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      final filter = GalleryFilter(
        capturedFrom: DateTime.utc(2024, 5, 1),
        capturedTo: DateTime.utc(2024, 5, 10),
      );
      final items = await mirror.queryItems(filter: filter);
      expect(items.map((i) => i.path), ['/Photos/last-day.jpg']);
      expect(await mirror.totalCount(filter: filter), 1);
    });

    test('null-offset rows are filtered by device-local wall time', () async {
      // The device sits in UTC-05:00 - pinned through the seam, not the
      // test machine's zone.
      deviceOffset = -5 * 3600;
      // Device-local wall 2024-05-10 12:00 -> true instant 17:00 UTC.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _feedItem(
              path: '/Photos/local-in.jpg',
              seq: 1,
              capturedAt: wallSeconds(2024, 5, 10, 12) - deviceOffset),
          // Device-local wall 2024-05-11 00:30 -> outside the range.
          _feedItem(
              path: '/Photos/local-out.jpg',
              seq: 2,
              capturedAt: wallSeconds(2024, 5, 11, 0, 30) - deviceOffset),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      final filter = GalleryFilter(
        capturedFrom: DateTime.utc(2024, 5, 1),
        capturedTo: DateTime.utc(2024, 5, 10),
      );
      final items = await mirror.queryItems(filter: filter);
      expect(items.map((i) => i.path), ['/Photos/local-in.jpg']);
    });

    test('the date range combines with each Availability value', () async {
      deviceOffset = 0;
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _feedItem(
              path: '/Photos/cloud.jpg',
              seq: 1,
              capturedAt: wallSeconds(2024, 5, 5, 12)),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      // A device-only photo inside the range.
      await insertMirrorItem(db,
          path: 'DCIM/device.jpg', capturedAt: wallSeconds(2024, 5, 6, 12));
      await _makeDeviceOnly(db, 'DCIM/device.jpg');

      final range = GalleryFilter(
        capturedFrom: DateTime.utc(2024, 5, 1),
        capturedTo: DateTime.utc(2024, 5, 10),
      );
      expect(await mirror.totalCount(filter: range), 2);
      expect(
          await mirror.totalCount(
              filter: range.copyWith(
                  availability: GalleryAvailabilityFilter.notBackedUp)),
          1);
      expect(
          (await mirror.queryItems(
                  filter: range.copyWith(
                      availability: GalleryAvailabilityFilter.notBackedUp)))
              .single
              .path,
          'DCIM/device.jpg');
      expect(
          await mirror.totalCount(
              filter: range.copyWith(
                  availability: GalleryAvailabilityFilter.cloudOnly)),
          1);
    });

    test(
        'count and capturedAtColumn reflect the filtered set, and the '
        'column agrees with the wall-time display helper', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          // Wall 2024-04-30 23:30 +02:00 - APRIL on the wall, although its
          // true instant is 21:30 UTC that day.
          _feedItem(
              path: '/Photos/april.jpg',
              seq: 1,
              capturedAt: wallSeconds(2024, 4, 30, 21, 30),
              capturedAtOffset: 7200),
          // Wall 2024-05-01 00:30 +02:00 - MAY on the wall, although its
          // true instant is still 2024-04-30 22:30 UTC.
          _feedItem(
              path: '/Photos/may.jpg',
              seq: 2,
              capturedAt: wallSeconds(2024, 4, 30, 22, 30),
              capturedAtOffset: 7200),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      final april = GalleryFilter(
        capturedFrom: DateTime.utc(2024, 4, 1),
        capturedTo: DateTime.utc(2024, 4, 30),
      );
      final column = await mirror.capturedAtColumn(filter: april);
      expect(column, hasLength(1));
      // The one photo the filter keeps is April on the wall - by the SAME
      // conversion the displayed label uses.
      final wall = galleryCaptureWallTime(column.single.$1, column.single.$2);
      expect(wall.year, 2024);
      expect(wall.month, 4);
      expect(wall.day, 30);
      expect(wall.hour, 23);
      expect(await mirror.totalCount(filter: april), 1);

      final may = GalleryFilter(
        capturedFrom: DateTime.utc(2024, 5, 1),
        capturedTo: DateTime.utc(2024, 5, 31),
      );
      expect(await mirror.capturedAtColumn(filter: may), hasLength(1));
      expect(
          galleryCaptureWallTime(
                  (await mirror.capturedAtColumn(filter: may)).single.$1,
                  (await mirror.capturedAtColumn(filter: may)).single.$2)
              .month,
          5);
    });

    test('no range at all means no date predicate', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _feedItem(path: '/Photos/a.jpg', seq: 1, capturedAt: 100),
          _feedItem(path: '/Photos/b.jpg', seq: 2, capturedAt: 200),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));
      expect(await mirror.totalCount(filter: GalleryFilter()), 2);
    });
  });

  group('GalleryFilter place', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db, deviceUtcOffsetSeconds: () => 0);
    });

    tearDown(() async {
      await db.close();
    });

    test('country / region / city filters match exactly their level', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _feedItem(
              path: '/Photos/lisbon.jpg',
              seq: 1,
              placeCountryCode: 'PT',
              placeCountry: 'Portugal',
              placeAdmin1Code: 'PT.11',
              placeAdmin1: 'Lisbon',
              placeLocalityId: 2267057,
              placeLocality: 'Lisbon'),
          _feedItem(
              path: '/Photos/cascais.jpg',
              seq: 2,
              placeCountryCode: 'PT',
              placeCountry: 'Portugal',
              placeAdmin1Code: 'PT.11',
              placeAdmin1: 'Lisbon',
              placeLocalityId: 2269592,
              placeLocality: 'Cascais'),
          _feedItem(
              path: '/Photos/berlin.jpg',
              seq: 3,
              placeCountryCode: 'DE',
              placeCountry: 'Germany',
              placeAdmin1Code: 'DE.BE',
              placeAdmin1: 'Berlin',
              placeLocalityId: 2950159,
              placeLocality: 'Berlin'),
          // No Place at all.
          _feedItem(path: '/Photos/unknown.jpg', seq: 4),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 4,
      ));

      // Country: every Portuguese photo, both cities.
      final portugal = await mirror.queryItems(
          filter: GalleryFilter(
              place: GalleryPlaceFilter.country('PT', label: 'Portugal')));
      expect(portugal.map((i) => i.path).toSet(),
          {'/Photos/lisbon.jpg', '/Photos/cascais.jpg'});

      // Region: same set here - both photos sit in the same region.
      final lisbonRegion = await mirror.queryItems(
          filter: GalleryFilter(
              place: GalleryPlaceFilter.admin1('PT.11', label: 'Lisbon')));
      expect(lisbonRegion.map((i) => i.path).toSet(),
          {'/Photos/lisbon.jpg', '/Photos/cascais.jpg'});

      // City: exactly one.
      final lisbonCity = await mirror.queryItems(
          filter: GalleryFilter(
              place: GalleryPlaceFilter.locality(2267057, label: 'Lisbon')));
      expect(lisbonCity.single.path, '/Photos/lisbon.jpg');

      // A photo without a Place never matches any place filter.
      expect(
          await mirror.totalCount(
              filter: GalleryFilter(place: GalleryPlaceFilter.country('DE'))),
          1);
      expect(
          await mirror.totalCount(
              filter:
                  GalleryFilter(place: GalleryPlaceFilter.locality(999999))),
          0);
    });

    test('place combines with date range and Availability', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _feedItem(
              path: '/Photos/in.jpg',
              seq: 1,
              capturedAt: wallSeconds(2024, 5, 5, 12),
              placeCountryCode: 'PT',
              placeCountry: 'Portugal'),
          _feedItem(
              path: '/Photos/out-of-range.jpg',
              seq: 2,
              capturedAt: wallSeconds(2024, 6, 5, 12),
              placeCountryCode: 'PT',
              placeCountry: 'Portugal'),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));
      await insertMirrorItem(db,
          path: 'DCIM/device-in-portugal.jpg',
          capturedAt: wallSeconds(2024, 5, 6, 12),
          placeCountryCode: 'PT',
          placeCountry: 'Portugal');
      await _makeDeviceOnly(db, 'DCIM/device-in-portugal.jpg');

      final portugal = GalleryFilter(place: GalleryPlaceFilter.country('PT'));
      expect(await mirror.totalCount(filter: portugal), 3);

      final may = portugal.copyWith(
        capturedFrom: DateTime.utc(2024, 5, 1),
        capturedTo: DateTime.utc(2024, 5, 31),
      );
      expect(await mirror.totalCount(filter: may), 2);

      final deviceOnlyMay =
          may.copyWith(availability: GalleryAvailabilityFilter.notBackedUp);
      expect((await mirror.queryItems(filter: deviceOnlyMay)).single.path,
          'DCIM/device-in-portugal.jpg');
    });
  });

  group('placeSuggestions', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db, deviceUtcOffsetSeconds: () => 0);
    });

    tearDown(() async {
      await db.close();
    });

    test(
        'suggests the user\'s own places with counts, parents and '
        'case-insensitive substring match', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          for (var i = 0; i < 3; i++)
            _feedItem(
                path: '/Photos/lisbon-$i.jpg',
                seq: i + 1,
                placeCountryCode: 'PT',
                placeCountry: 'Portugal',
                placeAdmin1Code: 'PT.11',
                placeAdmin1: 'Lisbon',
                placeLocalityId: 2267057,
                placeLocality: 'Lisbon'),
          _feedItem(
              path: '/Photos/berlin.jpg',
              seq: 10,
              placeCountryCode: 'DE',
              placeCountry: 'Germany',
              placeAdmin1Code: 'DE.BE',
              placeAdmin1: 'Berlin',
              placeLocalityId: 2950159,
              placeLocality: 'Berlin'),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 10,
      ));

      // Countries: "por" matches Portugal with its 3 photos.
      final countries = await mirror.placeSuggestions(
          level: GalleryPlaceLevel.country, query: 'por');
      expect(countries, hasLength(1));
      expect(countries.single.name, 'Portugal');
      expect(countries.single.parentLabel, '');
      expect(countries.single.photoCount, 3);
      expect(countries.single.filter.countryCode, 'PT');

      // Regions carry their parent country; ordered by count, Lisbon (3)
      // before Berlin (1).
      final regions =
          await mirror.placeSuggestions(level: GalleryPlaceLevel.admin1);
      expect(regions.map((r) => r.name), ['Lisbon', 'Berlin']);
      expect(regions.first.parentLabel, 'Portugal');
      expect(regions.first.filter.admin1Code, 'PT.11');
      expect(regions.last.parentLabel, 'Germany');

      // Cities: ordered by count, Lisbon (3) before Berlin (1).
      final cities =
          await mirror.placeSuggestions(level: GalleryPlaceLevel.locality);
      expect(cities.map((c) => c.name), ['Lisbon', 'Berlin']);
      expect(cities.first.photoCount, 3);
      expect(cities.first.parentLabel, 'Portugal');
      expect(cities.first.filter.localityId, 2267057);

      // Empty query returns everything at the level.
      final allCountries =
          await mirror.placeSuggestions(level: GalleryPlaceLevel.country);
      expect(allCountries.map((c) => c.name), ['Portugal', 'Germany']);
    });

    test(
        'photos in an unselected Local Folder do not appear in '
        'suggestions or counts', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _feedItem(
              path: '/Photos/visible.jpg',
              seq: 1,
              placeCountryCode: 'PT',
              placeCountry: 'Portugal'),
          // A device photo in an unselected folder (anything outside DCIM)
          // is invisible, full stop - it feeds no suggestion, no count.
          _feedItem(
              path: '/Photos/visible-2.jpg',
              seq: 2,
              placeCountryCode: 'PT',
              placeCountry: 'Portugal'),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));
      await insertMirrorItem(db,
          path: 'Test/Hidden/hidden.jpg',
          capturedAt: 1000,
          placeCountryCode: 'DE',
          placeCountry: 'Germany');
      // Device rows are invisible unless their folder is selected; mark the
      // row as device-origin with an unselected local folder.
      await (db.update(db.galleryItems)
            ..where((t) => t.path.equals('Test/Hidden/hidden.jpg')))
          .write(const GalleryItemsCompanion(
        origin: Value('device'),
        localRelativePath: Value('Test/Hidden'),
      ));

      final countries =
          await mirror.placeSuggestions(level: GalleryPlaceLevel.country);
      expect(countries.map((c) => c.name), ['Portugal']);
    });
  });

  group('delta feed carries capture offset and Place', () {
    test('GalleryDeltaItem.fromJson parses the new fields', () {
      final item = GalleryDeltaItem.fromJson({
        'providerId': 'space-a',
        'path': '/Photos/a.jpg',
        'seq': 7,
        'capturedAt': 1715351400,
        'capturedAtSource': 'exif',
        'capturedAtOffset': 7200,
        'lat': 38.7223,
        'lon': -9.1393,
        'placeCountryCode': 'PT',
        'placeCountry': 'Portugal',
        'placeAdmin1Code': 'PT.11',
        'placeAdmin1': 'Lisbon',
        'placeLocalityId': 2267057,
        'placeLocality': 'Lisbon',
      });
      expect(item.capturedAtOffset, 7200);
      expect(item.lat, 38.7223);
      expect(item.lon, -9.1393);
      expect(item.placeCountryCode, 'PT');
      expect(item.placeCountry, 'Portugal');
      expect(item.placeAdmin1Code, 'PT.11');
      expect(item.placeAdmin1, 'Lisbon');
      expect(item.placeLocalityId, 2267057);
      expect(item.placeLocality, 'Lisbon');

      // A payload without them - an older server - parses to "unknown".
      final bare = GalleryDeltaItem.fromJson({
        'providerId': 'space-a',
        'path': '/Photos/b.jpg',
        'seq': 8,
      });
      expect(bare.capturedAtOffset, isNull);
      expect(bare.lat, isNull);
      expect(bare.lon, isNull);
      expect(bare.placeCountryCode, '');
      expect(bare.placeLocalityId, 0);
    });

    test(
        'applyPage writes the capture offset and the Place onto the row, '
        'and a later page updates them in place', () async {
      final db = GalleryMirrorDatabase(NativeDatabase.memory());
      final mirror = GalleryMirror(db, deviceUtcOffsetSeconds: () => 0);
      addTearDown(db.close);

      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _feedItem(
              path: '/Photos/a.jpg',
              seq: 1,
              capturedAt: wallSeconds(2024, 5, 10, 21, 30),
              capturedAtOffset: 7200,
              lat: 38.7223,
              lon: -9.1393,
              placeCountryCode: 'PT',
              placeCountry: 'Portugal',
              placeAdmin1Code: 'PT.11',
              placeAdmin1: 'Lisbon',
              placeLocalityId: 2267057,
              placeLocality: 'Lisbon'),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final first = await mirror.queryItems();
      expect(first.single.capturedAtOffset, 7200);
      expect(first.single.lat, closeTo(38.7223, 1e-9));
      expect(first.single.lon, closeTo(-9.1393, 1e-9));
      expect(first.single.placeCountryCode, 'PT');
      expect(first.single.placeLocalityId, 2267057);
      expect(first.single.placeLocality, 'Lisbon');

      // The server's geo re-resolve pass (ticket 03) can only ever sharpen
      // a Place; a later page carrying one replaces it.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _feedItem(
              path: '/Photos/a.jpg',
              seq: 2,
              capturedAt: wallSeconds(2024, 5, 10, 21, 30),
              capturedAtOffset: 7200,
              placeCountryCode: 'PT',
              placeCountry: 'Portugal',
              placeAdmin1Code: 'PT.11',
              placeAdmin1: 'Lisbon',
              placeLocalityId: 2269592,
              placeLocality: 'Cascais'),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      final second = await mirror.queryItems();
      expect(second.single.seq, 2);
      expect(second.single.placeLocalityId, 2269592);
      expect(second.single.placeLocality, 'Cascais');
      // The instant and its offset were re-stated identically, not shifted.
      expect(second.single.capturedAt, wallSeconds(2024, 5, 10, 21, 30));
      expect(second.single.capturedAtOffset, 7200);
    });
  });
}
