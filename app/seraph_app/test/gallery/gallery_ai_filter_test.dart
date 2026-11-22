import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_search_controller.dart';
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_erase_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';

import 'gallery_test_support.dart';

/// A service whose `search` answers through [answer], which may be slow
/// (returns a Future) or throw.
GalleryService _service(
  Future<List<String>> Function(Map<String, dynamic> query) answer,
) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        try {
          final paths = await answer(options.queryParameters);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'items': [
                  for (final p in paths)
                    {'providerId': 'space-a', 'path': p, 'score': 1},
                ],
              },
            ),
          );
        } catch (_) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 500),
              type: DioExceptionType.badResponse,
            ),
          );
        }
      },
    ),
  );
  return GalleryService(
    FakeSettingsController(),
    FakeLoginController(),
    dio: dio,
  );
}

String _p(int i) => '/Photos/photo-$i.jpg';
(String, String) _k(int i) => ('space-a', _p(i));

void main() {
  late GalleryMirror mirror;

  setUp(() async {
    final db = openTestMirrorDatabase();
    addTearDown(db.close);
    mirror = GalleryMirror(db);
    await populateMirror(db, count: 5); // photo-0 newest, 1 day apart
  });

  Future<List<String>> paths(GalleryFilter f) async => [
        for (final i in await mirror.queryItems(filter: f)) i.path!,
      ];

  test('text search is membership in Capture Date order, intersected with '
      'other filters', () async {
    final ai = GalleryAiFilter(
      text: 'sunrise',
      keys: [_k(3), _k(0), _k(2), _k(4)],
    );
    expect(await paths(GalleryFilter(ai: ai)), [_p(0), _p(2), _p(3), _p(4)]);

    // Date range: photo-0 and photo-1 only.
    final newest = DateTime.fromMillisecondsSinceEpoch(
      1770000000 * 1000,
      isUtc: true,
    );
    final day = DateTime.utc(newest.year, newest.month, newest.day);
    expect(
      await paths(
        GalleryFilter(
          ai: GalleryAiFilter(text: 'x', keys: [_k(1), _k(0), _k(3)]),
          capturedFrom: day.subtract(const Duration(days: 1)),
          capturedTo: day,
        ),
      ),
      [_p(0), _p(1)],
    );
  });

  test('tag or person alone stays in Capture Date order', () async {
    final keys = [_k(3), _k(0), _k(2)];
    expect(
      await paths(
        GalleryFilter(
          ai: GalleryAiFilter(tag: 'pet', keys: keys),
        ),
      ),
      [_p(0), _p(2), _p(3)],
    );
    expect(
      await paths(
        GalleryFilter(
          ai: GalleryAiFilter(
            person: const GalleryPerson(id: 'p', name: 'P', photoCount: 3),
            keys: keys,
          ),
        ),
      ),
      [_p(0), _p(2), _p(3)],
    );
  });

  test('works with more than 999 keys', () async {
    final keys = [
      for (var i = 0; i < 1200; i++) ('space-a', '/missing/$i.jpg'),
      _k(2),
      _k(1),
    ];
    expect(
      await paths(
        GalleryFilter(
          ai: GalleryAiFilter(text: 't', keys: keys),
        ),
      ),
      [_p(1), _p(2)],
    );
  });

  test('sorted by relevance, text orders by key position', () async {
    final ai = GalleryAiFilter(
      text: 'sunrise',
      keys: [_k(3), _k(0), _k(2), _k(4)],
      byRelevance: true,
    );
    expect(GalleryFilter(ai: ai).ranked, true);
    expect(await paths(GalleryFilter(ai: ai)), [_p(3), _p(0), _p(2), _p(4)]);
    expect(
      (await mirror.queryPage(filter: GalleryFilter(ai: ai)))
          .items
          .map((i) => i.path),
      [_p(3), _p(0), _p(2), _p(4)],
    );
    // without text the flag means nothing: Capture Date order
    final tagOnly =
        GalleryAiFilter(tag: 'x', keys: [_k(3), _k(0)], byRelevance: true);
    expect(GalleryFilter(ai: tagOnly).ranked, false);
    expect(await paths(GalleryFilter(ai: tagOnly)), [_p(0), _p(3)]);
  });

  test('relevance order works with more than 999 keys', () async {
    final keys = [
      for (var i = 0; i < 1200; i++) ('space-a', '/missing/$i.jpg'),
      _k(2),
      _k(1),
    ];
    expect(
      await paths(
        GalleryFilter(
          ai: GalleryAiFilter(text: 't', keys: keys, byRelevance: true),
        ),
      ),
      [_p(2), _p(1)],
    );
  });

  test('activeCount counts text, tag and person separately', () {
    const anna = GalleryPerson(id: 'p', name: 'A', photoCount: 1);
    expect(
      const GalleryFilter(
        ai: GalleryAiFilter(text: 't', tag: 'x', person: anna),
      ).activeCount,
      3,
    );
    expect(const GalleryFilter(ai: GalleryAiFilter(tag: 'x')).activeCount, 1);
  });

  group('applyAi', () {
    late GalleryGridController grid;

    setUp(() async {
      grid = GalleryGridController(
        mirror: mirror,
        eraseService: GalleryEraseService(
          mirror,
          FakeGalleryUploadBackend(),
          null,
        ),
      );
      await grid.open();
    });

    test(
      'sends one request with every part and sets the filter',
      () async {
        final seen = <Map<String, dynamic>>[];
        final c = GallerySearchController(
          _service((q) async {
            seen.add(q);
            return [_p(2), _p(0)];
          }),
          mirror,
        );
        const anna = GalleryPerson(id: 'p1', name: 'Anna', photoCount: 2);

        expect(
          await c.applyAi(grid, text: 'sunrise', tag: 'beach', person: anna),
          true,
        );

        expect(seen, [
          {'q': 'sunrise', 'tag': 'beach', 'person': 'p1', 'limit': 1000},
        ]);
        expect(grid.filter.value.ai?.keys, [_k(2), _k(0)]);
        expect(grid.totalCount.value, 2);
      },
    );

    test('keeps the sort order while text stays, and drops it with the text',
        () async {
      final c = GallerySearchController(
        _service((q) async => [_p(2), _p(0)]),
        mirror,
      );
      await c.applyAi(grid, text: 'sunrise');
      expect(grid.filter.value.ai?.byRelevance, false, reason: 'date default');
      await grid.setFilter(grid.filter.value
          .copyWith(ai: grid.filter.value.ai!.withRelevance(true)));
      expect(grid.filter.value.ranked, true);

      await c.applyAi(grid, text: 'sunrise', tag: 'beach');
      expect(grid.filter.value.ranked, true);

      await c.applyAi(grid, tag: 'beach');
      expect(grid.filter.value.ai?.byRelevance, false);
      await c.applyAi(grid, text: 'dawn', tag: 'beach');
      expect(grid.filter.value.ranked, false);
    });

    test('leaves the filter unchanged on failure', () async {
      final c = GallerySearchController(
        _service((q) async => q['q'] == 'bad' ? throw Exception() : [_p(1)]),
        mirror,
      );
      await c.applyAi(grid, tag: 'ok');
      final before = grid.filter.value;

      expect(await c.applyAi(grid, text: 'bad'), false);

      expect(grid.filter.value, before);
    });

    test('the newest call wins over a slower older one', () async {
      final slow = Completer<List<String>>();
      final c = GallerySearchController(
        _service((q) => q['q'] == 'old' ? slow.future : Future.value([_p(4)])),
        mirror,
      );

      final older = c.applyAi(grid, text: 'old');
      await c.applyAi(grid, text: 'new');
      slow.complete([_p(0)]);
      await older;

      expect(grid.filter.value.ai?.text, 'new');
      expect(grid.filter.value.ai?.keys, [_k(4)]);
    });

    test('clearing every part removes the filter without a request', () async {
      var requests = 0;
      final c = GallerySearchController(
        _service((q) async {
          requests++;
          return [_p(1)];
        }),
        mirror,
      );
      await c.applyAi(grid, text: 't');
      await c.applyAi(grid);

      expect(requests, 1);
      expect(grid.filter.value.ai, isNull);
      expect(grid.totalCount.value, 5);
    });
  });
}
