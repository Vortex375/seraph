import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/media_player/authenticated_audio_source.dart';

Response<ResponseBody> _ok(int status, Map<String, String> headers, [String body = 'abc']) =>
    Response<ResponseBody>(
      statusCode: status,
      data: ResponseBody.fromString(body, status),
      headers: Headers.fromMap(headers.map((k, v) => MapEntry(k, [v]))),
      requestOptions: RequestOptions(path: '/song.mp3'),
    );

DioException _err(int status) => DioException(
      response: Response<dynamic>(statusCode: status, requestOptions: RequestOptions(path: '/song.mp3')),
      requestOptions: RequestOptions(path: '/song.mp3'),
    );

/// [AuthenticatedAudioSource.request] is the one seam the audio player's
/// token handling hangs on: just_audio's proxy calls it for every byte range
/// (start, seek, buffer refill), so it must translate ranges, map the
/// server's response onto [StreamAudioResponse], and survive an access token
/// that expired since the queue was built.
void main() {
  late List<String?> ranges;
  late int refreshes;

  AuthenticatedAudioSource source(List<Object> responses) {
    return AuthenticatedAudioSource(
      fetch: (range) async {
        ranges.add(range);
        final next = responses.removeAt(0);
        if (next is DioException) throw next;
        return next as Response<ResponseBody>;
      },
      refreshToken: () async => refreshes++,
    );
  }

  setUp(() {
    ranges = [];
    refreshes = 0;
  });

  test('no range asked: whole file, plain 200 response', () async {
    final res = await source([_ok(200, {'content-length': '3', 'content-type': 'audio/flac'})]).request();
    expect(ranges, [null]);
    expect(res.offset, isNull);
    expect(res.sourceLength, isNull);
    expect(res.contentLength, 3);
    expect(res.contentType, 'audio/flac');
    expect(utf8.decode(await res.stream.expand((b) => b).toList()), 'abc');
  });

  test('open-ended range maps Content-Range of the 206', () async {
    final res = await source([_ok(206, {'content-range': 'bytes 100-999/1000'})]).request(100);
    expect(ranges, ['bytes=100-']);
    expect(res.offset, 100);
    expect(res.contentLength, 900);
    expect(res.sourceLength, 1000);
    expect(res.contentType, 'audio/mpeg');
  });

  test('bounded range: just_audio end is exclusive, HTTP end inclusive', () async {
    final res = await source([_ok(206, {'content-range': 'bytes 0-49/1000'})]).request(0, 50);
    expect(ranges, ['bytes=0-49']);
    expect(res.offset, 0);
    expect(res.contentLength, 50);
  });

  test('server ignoring the range: full body at offset 0', () async {
    final res = await source([_ok(200, {'content-length': '1000'})]).request(100);
    expect(res.offset, 0);
    expect(res.contentLength, 1000);
    expect(res.sourceLength, 1000);
    expect(res.rangeRequestsSupported, isFalse);
  });

  for (final status in [401, 403]) {
    test('$status (expired token): refresh once, retry, return the retry', () async {
      final res = await source([_err(status), _ok(206, {'content-range': 'bytes 5-9/10'})]).request(5);
      expect(refreshes, 1);
      expect(ranges, ['bytes=5-', 'bytes=5-']);
      expect(res.offset, 5);
    });
  }

  test('403 again after refresh (real denial) propagates', () async {
    await expectLater(source([_err(403), _err(403)]).request(), throwsA(isA<DioException>()));
    expect(refreshes, 1);
    expect(ranges.length, 2);
  });

  for (final status in [404, 500]) {
    test('$status propagates without refresh', () async {
      await expectLater(source([_err(status)]).request(), throwsA(isA<DioException>()));
      expect(refreshes, 0);
      expect(ranges.length, 1);
    });
  }
}
