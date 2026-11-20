import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

import '../gallery_test_support.dart';

/// Ticket 26 at the mirror seam, against a fake Local Source.
void main() {
  late GalleryMirrorDatabase db;
  late GalleryMirror mirror;
  late FakeLocalSource source;
  late LocalScanService service;

  final synced = localMediaItem(
      relativePath: 'DCIM/Camera/',
      displayName: 'a.jpg',
      size: 4096,
      dateTakenMillis: 1700000000000);
  final deviceOnly = localMediaItem(
      relativePath: 'DCIM/Camera/',
      displayName: 'b.jpg',
      size: 2048,
      dateTakenMillis: 1700000100000);

  setUp(() async {
    db = GalleryMirrorDatabase(NativeDatabase.memory());
    mirror = GalleryMirror(db);
    source = FakeLocalSource([synced, deviceOnly]);
    service = LocalScanService(mirror, localSource: source);
    // a.jpg is also in Seraph at the same size and capture second -> Synced.
    await mirror.applyPage(GalleryDeltaResponse(
      items: [
        GalleryDeltaItem(
            providerId: 'p',
            path: '/a.jpg',
            seq: 1,
            tombstone: false,
            capturedAt: 1700000000,
            size: 4096),
      ],
      nextCursor: '',
      hasMore: false,
      nextSince: 1,
    ));
    await service.scan();
  });

  tearDown(() async => db.close());

  Future<int> idOf(String name) async =>
      (await db.select(db.galleryItems).get())
          .firstWhere((r) => r.localDisplayName == name || r.path == '/$name')
          .id;

  test('only Synced items are freeable, and a non-Verified id is refused',
      () async {
    final syncedId = await idOf('a.jpg');
    final deviceId = await (db.select(db.galleryItems).get())
        .then((rows) => rows.firstWhere((r) => r.localDisplayName == 'b.jpg').id);

    expect((await mirror.freeableItems()).map((r) => r.id), [syncedId]);

    final result = await service.freeUpSpace([syncedId, deviceId]);
    expect(result.freed, 1);
    expect(result.skipped, 1);
    expect(result.bytes, 4096);
    expect(source.trashCalls.single.map((i) => i.displayName), ['a.jpg']);
  });

  test('freeing makes the item Cloud only; restoring returns it to Synced',
      () async {
    final id = await idOf('a.jpg');
    await service.freeUpSpace([id]);

    var row = (await db.select(db.galleryItems).get())
        .firstWhere((r) => r.id == id);
    expect(row.origin, 'cloud');
    expect(row.localRelativePath, isNull);

    source.setItems([synced, deviceOnly]); // restored from the trash
    await service.scan();
    final rows = await db.select(db.galleryItems).get();
    row = rows.firstWhere((r) => r.id == id);
    expect(row.origin, 'both');
    expect(rows.length, 2); // no duplicate
  });

  test('cancelling the dialog leaves everything unchanged', () async {
    source.confirmTrash = false;
    final id = await idOf('a.jpg');
    final result = await service.freeUpSpace([id]);
    expect(result.cancelled, isTrue);
    expect(result.freed, 0);
    expect((await mirror.freeableItems()).map((r) => r.id), [id]);
  });

  test('a freed item no longer reaches the platform a second time', () async {
    final id = await idOf('a.jpg');
    await service.freeUpSpace([id]);
    final again = await service.freeUpSpace([id]);
    expect(again.freed, 0);
    expect(source.trashCalls.length, 1);
  });

  test('a selection narrows what is freeable to the picked Synced items',
      () async {
    final id = await idOf('a.jpg');
    expect((await mirror.freeableItems(ids: [id + 100])), isEmpty);
    expect((await mirror.freeableItems(ids: [id])).single.id, id);
  });
}
