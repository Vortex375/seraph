import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';

/// A [Response] light enough to construct in a unit test without a real
/// transport - [DioException] only needs [Response.statusCode] and
/// [Response.requestOptions] to exist.
Response<dynamic> _resp(int status) => Response<dynamic>(
      statusCode: status,
      requestOptions: RequestOptions(path: '/test'),
    );

DioException _dioErr(int status) =>
    DioException(response: _resp(status), requestOptions: RequestOptions(path: '/test'));

/// [withTokenRecovery] is the reactive refresh-and-retry layer that closes
/// the gap ticket 23's lock leaves open: the lock serializes concurrent
/// refreshes, but neither the lock NOR any other mechanism guarantees a
/// refresh happens BEFORE an access token's short (5-minute, for the test
/// realm) lifetime elapses. The headless sync isolate loads ONE token at
/// session start and never refreshes mid-run; the main app only refreshes on
/// cold start, resume, and a 30s audio timer (only while music plays). So
/// both paths can present an expired access token, which the gateway answers
/// with HTTP 403 - the SAME status a genuinely read-only Space produces - and
/// [translateWebDavError] then misclassifies as a permanent "read-only"
/// failure.
///
/// [withTokenRecovery] refreshes once on 401/403 and retries: if the retry
/// succeeds, it was an expired token; if it fails the same way, it was a real
/// permission failure and the existing permanent classification stands. This
/// file tests exactly that branching, against [translateWebDavError] so the
/// classifications the rest of the app branches on are the real ones.
void main() {
  group('withTokenRecovery', () {
    test(
        'a 403 on the first attempt that succeeds on retry after a refresh '
        'returns the retry result - the expired-token case', () async {
      var opCalls = 0;
      var refreshCalls = 0;

      final result = await withTokenRecovery<int>(
        op: () async {
          opCalls++;
          if (opCalls == 1) {
            throw _dioErr(403);
          }
          return 42;
        },
        refreshToken: () async => refreshCalls++,
        translate: translateWebDavError,
      );

      expect(result, 42, reason: 'the retry succeeded - expired token, now refreshed');
      expect(opCalls, 2, reason: 'exactly one failed attempt then one retry');
      expect(refreshCalls, 1, reason: 'exactly one refresh between the two attempts');
    });

    test(
        'a 401 on the first attempt that succeeds on retry after a refresh '
        'returns the retry result - some gateways answer 401 rather than 403 '
        'for an expired bearer', () async {
      var opCalls = 0;

      final result = await withTokenRecovery<String>(
        op: () async {
          opCalls++;
          if (opCalls == 1) {
            throw _dioErr(401);
          }
          return 'ok';
        },
        refreshToken: () async {},
        translate: translateWebDavError,
      );

      expect(result, 'ok');
      expect(opCalls, 2);
    });

    test(
        'a 403 on BOTH attempts still classifies as a permanent read-only '
        'Space failure - the refresh was not wasted on a real permission '
        'denial', () async {
      var refreshCalls = 0;

      await expectLater(
        withTokenRecovery<void>(
          op: () async => throw _dioErr(403),
          refreshToken: () async => refreshCalls++,
          translate: translateWebDavError,
        ),
        throwsA(
          isA<GalleryUploadException>()
              .having((e) => e.readOnly, 'readOnly', isTrue)
              .having((e) => e.bucket, 'bucket',
                  GalleryUploadFailureBucket.permanent)
              .having((e) => e.message, 'message',
                  contains('read-only')),
        ),
      );

      expect(refreshCalls, 1,
          reason: 'the refresh ran once - it had to, to discover the retry '
              'still 403s - but no more than once');
    });

    test(
        'a non-401/403 DioException is translated immediately without any '
        'refresh - a 500 or a timeout has nothing to do with the token', () async {
      var refreshCalls = 0;

      await expectLater(
        withTokenRecovery<void>(
          op: () async => throw _dioErr(500),
          refreshToken: () async => refreshCalls++,
          translate: translateWebDavError,
        ),
        throwsA(
          isA<GalleryUploadException>()
              .having((e) => e.bucket, 'bucket',
                  GalleryUploadFailureBucket.transient)
              .having((e) => e.readOnly, 'readOnly', isFalse),
        ),
      );

      expect(refreshCalls, 0,
          reason: 'a transient failure must not waste a refresh-grant round '
              'trip - and must not risk presenting a rotating refresh token '
              'the lock cannot see');
    });

    test(
        'a 507 (out of storage) does not refresh - it is permanent but not '
        'token-related', () async {
      var refreshCalls = 0;

      await expectLater(
        withTokenRecovery<void>(
          op: () async => throw _dioErr(507),
          refreshToken: () async => refreshCalls++,
          translate: translateWebDavError,
        ),
        throwsA(
          isA<GalleryUploadException>()
              .having((e) => e.bucket, 'bucket',
                  GalleryUploadFailureBucket.permanent)
              .having((e) => e.message, 'message', contains('storage')),
        ),
      );

      expect(refreshCalls, 0);
    });

    test(
        'a 404 returned to [statSize] is NOT a token failure and is NOT '
        'refreshed - it is the "path is free" signal [WebDavGalleryUploadBackend'
        '].statSize handles itself before reaching this helper', () async {
      var refreshCalls = 0;

      await expectLater(
        withTokenRecovery<int?>(
          op: () async => throw _dioErr(404),
          refreshToken: () async => refreshCalls++,
          translate: translateWebDavError,
        ),
        throwsA(isA<GalleryUploadException>()),
      );

      expect(refreshCalls, 0);
    });

    test(
        'a refresh that itself throws propagates rather than masking the '
        'original 403 - the caller sees the refresh failure, not a silent '
        'retry with no new token', () async {
      await expectLater(
        withTokenRecovery<void>(
          op: () async => throw _dioErr(403),
          refreshToken: () async => throw StateError('token endpoint down'),
          translate: translateWebDavError,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
        'the retry attempt that throws a DIFFERENT status than 401/403 '
        'translates the retry\'s status, not the first attempt\'s - the '
        'second response is what actually happened on the wire', () async {
      var opCalls = 0;
      await expectLater(
        withTokenRecovery<void>(
          op: () async {
            opCalls++;
            if (opCalls == 1) {
              throw _dioErr(403);
            }
            throw _dioErr(507);
          },
          refreshToken: () async {},
          translate: translateWebDavError,
        ),
        throwsA(
          isA<GalleryUploadException>()
              .having((e) => e.message, 'message', contains('storage'))
              .having((e) => e.bucket, 'bucket',
                  GalleryUploadFailureBucket.permanent)
              .having((e) => e.readOnly, 'readOnly', isFalse),
        ),
      );
      expect(opCalls, 2);
    });

    test('a first attempt that succeeds never refreshes', () async {
      var refreshCalls = 0;
      final result = await withTokenRecovery<int>(
        op: () async => 7,
        refreshToken: () async => refreshCalls++,
        translate: translateWebDavError,
      );
      expect(result, 7);
      expect(refreshCalls, 0);
    });

    test(
        'a DioException with a null statusCode (e.g. a connection drop with '
        'no response) is translated immediately and never refreshed - it is '
        'transient, not a token failure', () async {
      var refreshCalls = 0;
      await expectLater(
        withTokenRecovery<void>(
          op: () async => throw DioException(
            requestOptions: RequestOptions(path: '/test'),
            type: DioExceptionType.connectionTimeout,
          ),
          refreshToken: () async => refreshCalls++,
          translate: translateWebDavError,
        ),
        throwsA(
          isA<GalleryUploadException>()
              .having((e) => e.bucket, 'bucket',
                  GalleryUploadFailureBucket.transient),
        ),
      );
      expect(refreshCalls, 0);
    });
  });
}
