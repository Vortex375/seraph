import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_people_view.dart';
import 'package:seraph_app/src/gallery/gallery_search_controller.dart';
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';

import 'gallery_test_support.dart';

GalleryService _service(Response<dynamic> Function(RequestOptions) answer) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    final res = answer(options);
    if ((res.statusCode ?? 200) >= 400) {
      handler.reject(DioException(
          requestOptions: options,
          response: res,
          type: DioExceptionType.badResponse));
    } else {
      handler.resolve(res);
    }
  }));
  return GalleryService(FakeSettingsController(), FakeLoginController(),
      dio: dio);
}

Response<dynamic> _ok(RequestOptions o, Object data) =>
    Response(requestOptions: o, statusCode: 200, data: data);

void main() {
  test('parses search, status and people responses', () {
    final hits = GallerySearchHit.listFromJson({
      'items': [
        {'providerId': 'p', 'path': '/a.jpg', 'score': 0.9},
        {'providerId': 'p', 'path': '/b.jpg', 'score': 1},
      ]
    });
    expect(hits.map((h) => h.path), ['/a.jpg', '/b.jpg']);
    expect(hits[1].score, 1.0);
    expect(GallerySearchHit.listFromJson({'items': null}), isEmpty);

    final status = GalleryAnalysisStatus.fromJson(
        {'analysed': 3, 'pending': 2, 'failed': 1});
    expect((status.analysed, status.pending, status.failed), (3, 2, 1));

    final people = GalleryPerson.listFromJson({
      'people': [
        {'id': '1', 'name': '', 'photoCount': 9, 'cover': <String, dynamic>{}},
        {'id': '2', 'name': 'Zoe', 'photoCount': 2},
        {'id': '3', 'name': 'Anna', 'photoCount': 1},
      ]
    });
    expect(people.map((p) => p.id), ['3', '2', '1']);
  });

  test('mirror join keeps server order and skips unknown rows', () async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    final mirror = GalleryMirror(db);
    await populateMirror(db, count: 3); // space-a /Photos/photo-{0,1,2}.jpg

    final items = await mirror.itemsBySpaceKeys([
      ('space-a', '/Photos/photo-2.jpg'),
      ('space-a', '/Photos/not-synced.jpg'),
      ('other', '/Photos/photo-1.jpg'),
      ('space-a', '/Photos/photo-0.jpg'),
    ]);
    expect(items.map((i) => i.path), [
      '/Photos/photo-2.jpg',
      '/Photos/photo-0.jpg',
    ]);
  });

  test('controller search joins hits to the mirror', () async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    final mirror = GalleryMirror(db);
    await populateMirror(db, count: 2);
    Map<String, dynamic>? seen;
    final controller = GallerySearchController(_service((o) {
      seen = o.queryParameters;
      return _ok(o, {
        'items': [
          {'providerId': 'space-a', 'path': '/Photos/photo-1.jpg', 'score': 1},
          {'providerId': 'space-a', 'path': '/gone.jpg', 'score': 0.5},
        ]
      });
    }), mirror);

    controller.text.value = 'dog';
    controller.setTag('pet');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(seen, {'q': 'dog', 'tag': 'pet'});
    expect(controller.results.map((i) => i.path), ['/Photos/photo-1.jpg']);
  });

  test('ai-unavailable hides the entry', () async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    final controller = GallerySearchController(
        _service((o) => Response(
            requestOptions: o,
            statusCode: 503,
            data: {'error': 'ai-unavailable'})),
        GalleryMirror(db));

    await controller.probe();
    expect(controller.available.value, false);
  });

  test('available status shows the entry', () async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    final controller = GallerySearchController(
        _service((o) => _ok(o, {'analysed': 1, 'pending': 4, 'failed': 0})),
        GalleryMirror(db));

    await controller.probe();
    expect(controller.available.value, true);
    expect(controller.status.value.pending, 4);
  });

  group('faceCropRect', () {
    test('centres a square on the face with margin', () {
      // 100x100 px face box centred in a 1000x500 photo, 0.4 margin.
      final r =
          faceCropRect(const GalleryFaceBox(0.45, 0.4, 0.55, 0.6), 1000, 500);
      expect(r.width, closeTo(r.height, 1e-6));
      expect(r.width, closeTo(100 * 1.8, 1e-6)); // longer side is 100 (h=100)
      expect(r.center.dx, closeTo(500, 1e-6));
      expect(r.center.dy, closeTo(250, 1e-6));
    });

    test('shifts at the photo edge instead of leaving it', () {
      final r = faceCropRect(const GalleryFaceBox(0, 0, 0.1, 0.1), 1000, 1000);
      expect(r.left, 0);
      expect(r.top, 0);
      final br = faceCropRect(const GalleryFaceBox(0.9, 0.9, 1, 1), 1000, 1000);
      expect(br.right, 1000);
      expect(br.bottom, 1000);
      expect(br.width, closeTo(180, 1e-6));
    });

    test('a whole-photo box clamps to the shorter side', () {
      final r = faceCropRect(const GalleryFaceBox(0, 0, 1, 1), 800, 600);
      expect(r, const Rect.fromLTWH(100, 0, 600, 600));
    });
  });

  test('rename updates the shared people list', () async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    String? sentName;
    final controller = GallerySearchController(_service((o) {
      if (o.method == 'PATCH') {
        sentName = (o.data as Map)['name'] as String;
        return _ok(o, {
          'person': {'id': '1', 'name': sentName, 'photoCount': 3}
        });
      }
      return _ok(o, {
        'people': [
          {'id': '1', 'name': '', 'photoCount': 3},
          {'id': '2', 'name': 'Zoe', 'photoCount': 1},
        ]
      });
    }), GalleryMirror(db));
    await controller.loadChips();

    expect(await controller.renamePerson('1', ' Anna '), true);
    expect(sentName, 'Anna');
    expect(controller.people.map((p) => p.name), ['Zoe', 'Anna']);
  });

  test('person tap searches with the person filter only', () async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    Map<String, dynamic>? seen;
    final controller = GallerySearchController(_service((o) {
      seen = o.queryParameters;
      return _ok(o, {'items': <dynamic>[]});
    }), GalleryMirror(db));
    controller.text.value = 'dog';
    controller.tag.value = 'pet';

    controller.showPerson('p1');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(seen, {'person': 'p1'});
    expect(controller.personId.value, 'p1');
  });

  test('ai-unavailable on rename hides the entry', () async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    final controller = GallerySearchController(
        _service((o) => Response(
            requestOptions: o,
            statusCode: 503,
            data: {'error': 'ai-unavailable'})),
        GalleryMirror(db));
    controller.available.value = true;

    expect(await controller.renamePerson('1', 'x'), false);
    expect(controller.available.value, false);
  });
}
