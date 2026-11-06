// StreamAudioSource is just_audio's only hook for per-request auth; it has
// been marked experimental since its introduction.
// ignore_for_file: experimental_member_use

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart' show Get, Inst;
import 'package:just_audio/just_audio.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/login/login_controller.dart';

/// A queue item that authenticates each byte-range request at the moment the
/// player makes it. Access tokens live ~5 minutes, so a bearer baked into a
/// queue item when the queue is built has expired by the time playback (or a
/// seek) reaches it; here every request reads the current token through
/// [fetch], and a 401/403 refreshes once and retries ([retryOnTokenFailure]).
class AuthenticatedAudioSource extends StreamAudioSource {
  AuthenticatedAudioSource({
    required this.fetch,
    required this.refreshToken,
    super.tag,
  });

  /// Streamed GET of the file; `range` is a `Range` header value or null.
  final Future<Response<ResponseBody>> Function(String? range) fetch;
  final Future<void> Function() refreshToken;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // just_audio's [end] is exclusive, HTTP's is inclusive.
    final range = (start == null && end == null)
        ? null
        : 'bytes=${start ?? 0}-${end == null ? '' : end - 1}';
    final response = await retryOnTokenFailure(() => fetch(range), refreshToken);

    final contentType = response.headers.value(Headers.contentTypeHeader) ?? 'audio/mpeg';
    final stream = response.data!.stream;
    final contentRange = response.statusCode == 206
        ? RegExp(r'bytes (\d+)-(\d+)/(\d+|\*)')
            .firstMatch(response.headers.value('content-range') ?? '')
        : null;
    if (contentRange != null) {
      final first = int.parse(contentRange[1]!);
      return StreamAudioResponse(
        sourceLength: int.tryParse(contentRange[3]!),
        contentLength: int.parse(contentRange[2]!) - first + 1,
        offset: first,
        stream: stream,
        contentType: contentType,
      );
    }

    // Full body: either no range was asked for, or the server ignored it.
    final length = int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '');
    return StreamAudioResponse(
      rangeRequestsSupported: range == null,
      sourceLength: range == null ? null : length,
      contentLength: length,
      offset: range == null ? null : 0,
      stream: stream,
      contentType: contentType,
    );
  }
}

/// The player source for queue item [item] (id = file URL). On web the
/// browser authenticates with the gateway session cookie, so a plain URL
/// works - and [StreamAudioSource] must NOT be used there: just_audio's web
/// implementation reads the whole stream into a data URL before playing.
AudioSource audioSourceFor(MediaItem item) {
  if (kIsWeb) {
    return AudioSource.uri(Uri.parse(item.id), tag: item);
  }
  return AuthenticatedAudioSource(
    fetch: (range) => Get.find<FileService>().fetchFileStream(item.id, range),
    refreshToken: () => Get.find<LoginController>().refreshTokenIfNeeded(force: true),
    tag: item,
  );
}
