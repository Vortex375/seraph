import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:oidc/oidc.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_sync_service.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GallerySyncService', () {
    late SettingsController settingsController;
    late LoginController loginController;
    late Dio dio;
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;
    late GallerySyncService service;

    setUp(() {
      Get.testMode = true;
      settingsController = _FakeSettingsController('https://seraph.test');
      loginController = _FakeLoginController.initialized('access-token');
      dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
      service = GallerySyncService(settingsController, loginController, mirror,
          dio: dio);
    });

    tearDown(() async {
      await db.close();
    });

    test(
        'cold start with no local data populates the mirror from the delta feed',
        () async {
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.path, '/api/gallery/delta');
        expect(options.queryParameters['since'], 0);
        expect(options.queryParameters.containsKey('cursor'), isFalse);
        expect(options.headers['Authorization'], 'Bearer access-token');

        handler.resolve(Response(
          requestOptions: options,
          data: {
            'items': [
              {
                'providerId': 'space-a',
                'path': '/Photos/a.jpg',
                'seq': 1,
                'tombstone': false,
                'capturedAt': 1000,
              },
              {
                'providerId': 'space-a',
                'path': '/Photos/b.jpg',
                'seq': 2,
                'tombstone': false,
                'capturedAt': 2000,
              },
            ],
            'nextCursor': '',
            'hasMore': false,
            'nextSince': 2,
          },
        ));
      }));

      await service.sync();

      final page = await mirror.queryPage();
      expect(page.totalCount, 2);
      expect(page.items.map((i) => i.path), ['/Photos/b.jpg', '/Photos/a.jpg']);
      expect(await mirror.since(), 2);
    });

    test(
        'a subsequent sync sends the stored since and applies only the new changes',
        () async {
      // Seed the mirror as if a previous sync already ran.
      await mirror.applyPage(_page(
        items: [_wireItem(path: '/Photos/a.jpg', seq: 1, capturedAt: 1000)],
        nextSince: 5,
      ));

      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.queryParameters['since'], 5);

        handler.resolve(Response(
          requestOptions: options,
          data: {
            'items': [
              {
                'providerId': 'space-a',
                'path': '/Photos/c.jpg',
                'seq': 6,
                'tombstone': false,
                'capturedAt': 3000,
              },
            ],
            'nextCursor': '',
            'hasMore': false,
            'nextSince': 6,
          },
        ));
      }));

      await service.sync();

      final page = await mirror.queryPage();
      expect(page.totalCount, 2);
      expect(await mirror.since(), 6);
    });

    test('a tombstone delivered by the feed removes the item from the mirror',
        () async {
      await mirror.applyPage(_page(
        items: [_wireItem(path: '/Photos/a.jpg', seq: 1, capturedAt: 1000)],
        nextSince: 1,
      ));

      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(Response(
          requestOptions: options,
          data: {
            'items': [
              {
                'providerId': 'space-a',
                'path': '/Photos/a.jpg',
                'seq': 2,
                'tombstone': true,
              },
            ],
            'nextCursor': '',
            'hasMore': false,
            'nextSince': 2,
          },
        ));
      }));

      await service.sync();

      final page = await mirror.queryPage();
      expect(page.totalCount, 0);
    });

    test(
        'the sync cursor survives a simulated app restart: a new sync does not re-fetch everything',
        () async {
      var requestCount = 0;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requestCount++;
        expect(options.queryParameters['since'], 3);
        handler.resolve(Response(
          requestOptions: options,
          data: {
            'items': [],
            'nextCursor': '',
            'hasMore': false,
            'nextSince': 3
          },
        ));
      }));

      // Persist sync progress the way a real sync would, then throw away the
      // service and mirror wrapper - only the underlying database survives,
      // exactly like a process restart with the same on-disk file.
      await mirror.applyPage(_page(
        items: [_wireItem(path: '/Photos/a.jpg', seq: 3, capturedAt: 1000)],
        nextSince: 3,
      ));

      final restartedMirror = GalleryMirror(db);
      final restartedService = GallerySyncService(
        settingsController,
        loginController,
        restartedMirror,
        dio: dio,
      );

      await restartedService.sync();

      expect(requestCount, 1);
      expect(await restartedMirror.since(), 3);
    });

    test(
        'a sync interrupted mid-page resumes from the persisted cursor without duplicating items',
        () async {
      final requestedCursors = <String?>[];
      var callCount = 0;

      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        callCount++;
        requestedCursors.add(options.queryParameters['cursor'] as String?);

        if (callCount == 1) {
          // First page of the poll: more to come.
          handler.resolve(Response(
            requestOptions: options,
            data: {
              'items': [
                {
                  'providerId': 'space-a',
                  'path': '/Photos/a.jpg',
                  'seq': 1,
                  'tombstone': false,
                  'capturedAt': 1000,
                },
              ],
              'nextCursor': 'page-2-cursor',
              'hasMore': true,
              'nextSince': 0,
            },
          ));
        } else {
          // Second page: finishes the poll.
          handler.resolve(Response(
            requestOptions: options,
            data: {
              'items': [
                {
                  'providerId': 'space-a',
                  'path': '/Photos/b.jpg',
                  'seq': 2,
                  'tombstone': false,
                  'capturedAt': 2000,
                },
              ],
              'nextCursor': '',
              'hasMore': false,
              'nextSince': 2,
            },
          ));
        }
      }));

      await service.sync();

      expect(requestedCursors, [null, 'page-2-cursor']);
      final page = await mirror.queryPage();
      expect(page.totalCount, 2,
          reason:
              'both pages of the resumed poll should be applied exactly once');
      expect(await mirror.since(), 2);
      expect(await mirror.pendingCursor(), isNull);
    });
  });
}

Map<String, dynamic> _wireItem({
  required String path,
  required int seq,
  required int capturedAt,
  String providerId = 'space-a',
}) {
  return {
    'providerId': providerId,
    'path': path,
    'seq': seq,
    'tombstone': false,
    'capturedAt': capturedAt,
  };
}

GalleryDeltaResponse _page({
  required List<Map<String, dynamic>> items,
  required int nextSince,
  String nextCursor = '',
  bool hasMore = false,
}) {
  return GalleryDeltaResponse.fromJson({
    'items': items,
    'nextCursor': nextCursor,
    'hasMore': hasMore,
    'nextSince': nextSince,
  });
}

class _FakeSettingsController extends GetxController
    implements SettingsController {
  _FakeSettingsController(String serverUrl)
      : _serverUrl = serverUrl.obs,
        _serverUrlConfirmed = true.obs,
        _oidcIssuer = Rx<String?>(null),
        _oidcClientId = Rx<String?>(null),
        _themeMode = Rx<ThemeMode>(ThemeMode.system),
        _fileBrowserViewMode = 'list'.obs;

  final Rx<String> _serverUrl;
  final Rx<bool> _serverUrlConfirmed;
  final Rx<String?> _oidcIssuer;
  final Rx<String?> _oidcClientId;
  final Rx<ThemeMode> _themeMode;
  final Rx<String> _fileBrowserViewMode;

  @override
  Rx<String> get serverUrl => _serverUrl;

  @override
  Rx<bool> get serverUrlConfirmed => _serverUrlConfirmed;

  @override
  Rx<String?> get oidcIssuer => _oidcIssuer;

  @override
  Rx<String?> get oidcClientId => _oidcClientId;

  @override
  Rx<ThemeMode> get themeMode => _themeMode;

  @override
  Rx<String> get fileBrowserViewMode => _fileBrowserViewMode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLoginController extends GetxController implements LoginController {
  _FakeLoginController._(
      this._isInitialized, this._currentUser, this._isNoAuth);

  factory _FakeLoginController.initialized(String token) {
    return _FakeLoginController._(
      true.obs,
      Rx<OidcUser?>(_FakeOidcUser(token)),
      false.obs,
    );
  }

  final Rx<bool> _isInitialized;
  final Rx<OidcUser?> _currentUser;
  final Rx<bool> _isNoAuth;

  @override
  Rx<bool> get isInitialized => _isInitialized;

  @override
  Rx<OidcUser?> get currentUser => _currentUser;

  @override
  Rx<bool> get isNoAuth => _isNoAuth;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOidcUser implements OidcUser {
  _FakeOidcUser(String accessToken) : _token = _FakeOidcToken(accessToken);

  final OidcToken _token;

  @override
  OidcToken get token => _token;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOidcToken implements OidcToken {
  _FakeOidcToken(this.accessToken);

  @override
  final String accessToken;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
