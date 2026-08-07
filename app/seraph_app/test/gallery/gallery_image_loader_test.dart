import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response, Value;
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

import 'gallery_test_support.dart';

/// Drives an [ImageProvider] all the way to decoded pixels, which is the only
/// level at which "does the decoder apply the EXIF orientation tag" can be
/// asked.
Future<ui.Image> _resolve(ImageProvider provider) {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) {
        completer.complete(info.image);
      }
    },
    onError: (error, stack) {
      stream.removeListener(listener);
      if (!completer.isCompleted) {
        completer.completeError(error, stack);
      }
    },
  );
  stream.addListener(listener);
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryImageLoader', () {
    late GalleryMirrorDatabase db;
    late Dio dio;
    late List<String> requested;

    setUp(() {
      Get.testMode = true;
      db = openTestMirrorDatabase();
      dio = Dio();
      requested = [];
      // GalleryImage keys on (providerId, path, size) only, so a decoded
      // image left in Flutter's global cache by another test would be
      // returned here instead of the bytes this test stubbed.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    tearDown(() async {
      await db.close();
    });

    GalleryImageLoader loaderWith({int maxCachedThumbnails = 2000}) =>
        GalleryImageLoader(
          FakeSettingsController(),
          FakeLoginController(),
          db,
          dio: dio,
          maxCachedThumbnails: maxCachedThumbnails,
        );

    void stubServing(List<int> bytes) {
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requested.add(options.path);
        handler.resolve(Response(requestOptions: options, data: bytes));
      }));
    }

    void stubOffline() {
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requested.add(options.path);
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'offline',
        ));
      }));
    }

    test('a thumbnail comes from the preview endpoint and is then cached',
        () async {
      stubServing(onePixelPng);
      final loader = loaderWith();

      final first = await loader.thumbnail('space-a', '/Photos/a.jpg', 512);
      expect(first, onePixelPng);
      expect(requested, hasLength(1));
      expect(requested.single, contains('/preview?p='));
      expect(requested.single, contains('w=512'));

      final second = await loader.thumbnail('space-a', '/Photos/a.jpg', 512);
      expect(second, onePixelPng);
      expect(requested, hasLength(1),
          reason: 'the second read must come from the cache');
    });

    test('a cached thumbnail still renders with no network at all', () async {
      stubServing(onePixelPng);
      await loaderWith().thumbnail('space-a', '/Photos/a.jpg', 512);

      // A new loader over the SAME database, as after an app restart, and a
      // network that is simply gone.
      dio = Dio();
      requested = [];
      stubOffline();
      final offlineLoader = loaderWith();

      final bytes =
          await offlineLoader.thumbnail('space-a', '/Photos/a.jpg', 512);
      expect(bytes, onePixelPng);
      expect(requested, isEmpty,
          reason: 'a cached thumbnail must not need the network');
    });

    test('a thumbnail never seen before fails honestly when offline',
        () async {
      stubOffline();
      final loader = loaderWith();

      await expectLater(
        loader.thumbnail('space-a', '/Photos/never-seen.jpg', 512),
        throwsA(isA<GalleryImageUnavailable>()),
      );
    });

    test('the authenticated client is the one used', () async {
      final login = FakeLoginController();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        // No signed-in user in this fake, so no Authorization header - the
        // point is that the header comes from the login controller rather
        // than from nowhere.
        expect(options.headers.containsKey('Authorization'), isFalse);
        handler.resolve(Response(requestOptions: options, data: onePixelPng));
      }));

      final loader = GalleryImageLoader(
          FakeSettingsController(), login, db, dio: dio);
      await loader.thumbnail('space-a', '/Photos/a.jpg', 512);
    });

    test('two requests for the same thumbnail issue one HTTP call', () async {
      stubServing(onePixelPng);
      final loader = loaderWith();

      final results = await Future.wait([
        loader.thumbnail('space-a', '/Photos/a.jpg', 512),
        loader.thumbnail('space-a', '/Photos/a.jpg', 512),
      ]);

      expect(results[0], onePixelPng);
      expect(results[1], onePixelPng);
      expect(requested, hasLength(1));
    });

    test('full resolution comes from the WebDAV path and is not cached',
        () async {
      stubServing(onePixelPng);
      final loader = loaderWith();

      await loader.fullResolution('space-a', '/Photos/a.jpg');
      await loader.fullResolution('space-a', '/Photos/a.jpg');

      expect(requested, hasLength(2));
      expect(requested.first, contains('/dav/p/space-a/Photos/a.jpg'));

      final cached = await db.select(db.cachedThumbnails).get();
      expect(cached, isEmpty,
          reason: 'full-resolution images would evict thousands of thumbnails');
    });

    test(
        'a photo with EXIF orientation arrives already rotated, so the app must not rotate it again',
        () async {
      // A 40x20 JPEG carrying EXIF Orientation 6 (rotate 90 CW): displayed,
      // it is 20x40. If the decoder did NOT apply the tag, the app would have
      // to rotate it - and every place that does rotate (the thumbnailer's
      // imaging.AutoOrientation, and this decoder) would then double up.
      // Locking the behaviour down here is what lets GalleryItemDisplay say
      // "nothing rotates pixels a second time" and mean it.
      stubServing(exifOrientation6Jpeg);
      final loader = loaderWith();

      final image = await _resolve(GalleryImage(
        loader: loader,
        providerId: 'space-a',
        path: '/Photos/portrait.jpg',
      ));

      expect(image.width, 20);
      expect(image.height, 40);
    });

    test('the cache is bounded, dropping the oldest entries first', () async {
      stubServing(onePixelPng);
      final loader = loaderWith(maxCachedThumbnails: 3);

      for (var i = 0; i < 5; i++) {
        await loader.thumbnail('space-a', '/Photos/$i.jpg', 512);
        // The cache orders eviction by write time; make the writes
        // distinguishable rather than relying on clock resolution.
        await (db.update(db.cachedThumbnails)
              ..where((t) => t.path.equals('/Photos/$i.jpg')))
            .write(CachedThumbnailsCompanion(fetchedAt: Value(1000 + i)));
      }

      await loader.evictOverflow();

      final remaining = await db.select(db.cachedThumbnails).get();
      expect(remaining.map((t) => t.path).toList()..sort(),
          ['/Photos/2.jpg', '/Photos/3.jpg', '/Photos/4.jpg']);
    });

    group('token recovery on 401/403', () {
      // The gateway answers an expired access token with HTTP 403 (the same
      // status a genuinely read-only Space produces). Without a reactive
      // refresh-and-retry in GalleryImageLoader, every non-cached thumbnail
      // fetched after the token's lifetime elapses 403s and the tile renders
      // its error placeholder until some other path refreshes the token -
      // this is the bug these tests lock down.
      late FakeLoginController login;

      setUp(() {
        login = FakeLoginController();
      });

      DioException reject403(RequestOptions options) => DioException(
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: 403),
            type: DioExceptionType.badResponse,
          );

      test(
          'a 403 from an expired token is recovered by a forced refresh and a single retry',
          () async {
        var attempts = 0;
        dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          requested.add(options.path);
          attempts++;
          if (attempts == 1) {
            handler.reject(reject403(options));
          } else {
            handler.resolve(
                Response(requestOptions: options, data: onePixelPng));
          }
        }));
        final loader =
            GalleryImageLoader(FakeSettingsController(), login, db, dio: dio);

        final bytes = await loader.thumbnail('space-a', '/Photos/a.jpg', 512);

        expect(bytes, onePixelPng);
        expect(attempts, 2, reason: 'the first 403 must trigger one retry');
        expect(login.refreshTokenIfNeededCalls, [true],
            reason: 'a 403 must force-refresh the token exactly once');
      });

      test('a 403 on full resolution is recovered the same way', () async {
        var attempts = 0;
        dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          requested.add(options.path);
          attempts++;
          if (attempts == 1) {
            handler.reject(reject403(options));
          } else {
            handler.resolve(
                Response(requestOptions: options, data: onePixelPng));
          }
        }));
        final loader =
            GalleryImageLoader(FakeSettingsController(), login, db, dio: dio);

        final bytes = await loader.fullResolution('space-a', '/Photos/a.jpg');

        expect(bytes, onePixelPng);
        expect(attempts, 2);
        expect(login.refreshTokenIfNeededCalls, [true]);
      });

      test('a 403 that persists after refresh surfaces as unavailable', () async {
        dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          requested.add(options.path);
          handler.reject(reject403(options));
        }));
        final loader =
            GalleryImageLoader(FakeSettingsController(), login, db, dio: dio);

        await expectLater(
          loader.thumbnail('space-a', '/Photos/readonly.jpg', 512),
          throwsA(isA<GalleryImageUnavailable>()),
        );
        expect(login.refreshTokenIfNeededCalls, [true],
            reason: 'refresh once, retry once, then give up - no refresh loop');
      });

      test('a non-auth failure is not treated as an expired token', () async {
        var attempts = 0;
        dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          requested.add(options.path);
          attempts++;
          handler.reject(DioException(
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: 500),
            type: DioExceptionType.badResponse,
          ));
        }));
        final loader =
            GalleryImageLoader(FakeSettingsController(), login, db, dio: dio);

        await expectLater(
          loader.thumbnail('space-a', '/Photos/oops.jpg', 512),
          throwsA(isA<GalleryImageUnavailable>()),
        );
        expect(attempts, 1, reason: 'a 500 must not trigger a retry');
        expect(login.refreshTokenIfNeededCalls, isEmpty,
            reason: 'no token refresh on a non-auth failure');
      });
    });
  });
}
