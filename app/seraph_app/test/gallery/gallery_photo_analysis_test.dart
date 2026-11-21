import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_photo_analysis.dart';
import 'package:seraph_app/src/gallery/gallery_search_controller.dart';
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

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

Response<dynamic> _unavailable(RequestOptions o) => Response(
    requestOptions: o, statusCode: 503, data: {'error': 'ai-unavailable'});

GalleryMirror? _mirror;

void main() {
  tearDown(Get.reset);

  test('parses the analysis response', () {
    final a = GalleryPhotoAnalysis.fromJson({
      'analysed': true,
      'tags': [
        {'tag': 'beach', 'score': 0.9}
      ],
      'faces': [
        {
          'id': 'f1',
          'box': {'x1': 0.1, 'y1': 0.2, 'x2': 0.3, 'y2': 0.4},
          'personId': 'p1',
          'personName': 'Anna',
          'manual': true,
        },
        {'id': 'f2', 'box': {}, 'personId': null},
      ],
    });
    expect(a.analysed, true);
    expect(a.tags.single.tag, 'beach');
    expect(a.faces[0].box.x2, 0.3);
    expect((a.faces[0].personId, a.faces[0].personName, a.faces[0].manual),
        ('p1', 'Anna', true));
    expect(a.faces[1].personId, isNull);
    expect(GalleryPhotoAnalysis.fromJson({'analysed': false}).tags, isEmpty);
  });

  group('overlay rect math', () {
    test('contain layout: landscape photo in a portrait area', () {
      final r = containedImageRect(const Size(400, 200), const Size(100, 300));
      expect(r, const Rect.fromLTWH(0, 125, 100, 50));
    });

    test('contain layout: portrait photo in a landscape area', () {
      final r = containedImageRect(const Size(200, 400), const Size(300, 100));
      expect(r, const Rect.fromLTWH(125, 0, 50, 100));
    });

    test('boxes map into the displayed rect, edges included', () {
      final image =
          containedImageRect(const Size(400, 200), const Size(100, 300));
      expect(faceOverlayRect(const GalleryFaceBox(0, 0, 1, 1), image), image);
      expect(faceOverlayRect(const GalleryFaceBox(0.5, 0.5, 1, 1), image),
          const Rect.fromLTRB(50, 150, 100, 175));
    });
  });

  test('assign bodies: personId, newPersonName and explicit null', () async {
    final bodies = <String>[];
    final service = _service((o) {
      expect(o.method, 'PUT');
      expect(o.path, '/api/gallery/faces/f1/person');
      bodies.add(jsonEncode(o.data));
      return _ok(o, <String, dynamic>{});
    });
    await service.assignFace('f1', personId: 'p1');
    await service.assignFace('f1', newPersonName: 'Bo');
    await service.assignFace('f1');
    expect(bodies, [
      '{"personId":"p1"}',
      '{"newPersonName":"Bo"}',
      '{"personId":null}',
    ]);
  });

  test('assigning refreshes the shared people list', () async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    var named = false;
    final controller = GallerySearchController(_service((o) {
      if (o.method == 'PUT') {
        named = true;
        return _ok(o, <String, dynamic>{});
      }
      return _ok(o, {
        'people': [
          if (named) {'id': 'p9', 'name': 'Bo', 'photoCount': 1},
        ]
      });
    }), GalleryMirror(db));

    expect(await controller.assignFace('f1', newPersonName: 'Bo'), true);
    expect(controller.people.map((p) => p.name), ['Bo']);
  });

  test('assign with ai-unavailable sets available=false', () async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    final controller =
        GallerySearchController(_service(_unavailable), GalleryMirror(db));
    expect(await controller.assignFace('f1'), false);
    expect(controller.available.value, false);
  });

  group('details section', () {
    Future<GalleryItem> cloudItem(WidgetTester tester) async {
      final db = openTestMirrorDatabase();
      addTearDown(db.close);
      await populateMirror(db, count: 1);
      _mirror = GalleryMirror(db);
      return (await tester.runAsync(() =>
              _mirror!.itemsBySpaceKeys([('space-a', '/Photos/photo-0.jpg')])))!
          .single;
    }

    Future<void> pump(WidgetTester tester, GalleryItem item,
        Response<dynamic> Function(RequestOptions) answer) async {
      Get.put(GallerySearchController(_service(answer), _mirror!));
      await tester.pumpWidget(GetMaterialApp(
          home: Scaffold(body: GalleryPhotoAnalysisSection(item: item))));
      await tester.pumpAndSettle();
    }

    testWidgets('not yet analysed shows the pending note', (tester) async {
      final item = await cloudItem(tester);
      await pump(tester, item, (o) {
        if (o.path.endsWith('/photos/analysis')) {
          return _ok(o, {'analysed': false});
        }
        return _ok(o, {'people': <dynamic>[]});
      });
      expect(find.text('Analysis pending'), findsOneWidget);
    });

    testWidgets('analysed shows tag chips', (tester) async {
      final item = await cloudItem(tester);
      await pump(tester, item, (o) {
        if (o.path.endsWith('/photos/analysis')) {
          return _ok(o, {
            'analysed': true,
            'tags': [
              {'tag': 'beach', 'score': 1}
            ]
          });
        }
        return _ok(o, {'people': <dynamic>[]});
      });
      expect(find.text('beach'), findsOneWidget);
    });

    testWidgets('ai-unavailable shows nothing', (tester) async {
      final item = await cloudItem(tester);
      await pump(tester, item, _unavailable);
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(Chip), findsNothing);
      expect(Get.find<GallerySearchController>().available.value, false);
    });
  });
}
