import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Ticket 25's queue policy: which of the spec's two THROWN failure buckets
/// a [GalleryUploadException] belongs to. The third bucket, "moved target" -
/// a local file changed mid-upload - never throws at all; see
/// [GalleryUploadResult.deviceFileChanged] in `gallery_upload_service.dart`
/// instead. [GalleryUploadResult.deviceFileUnavailable] (an unreadable local
/// file) also never throws, but is NOT "moved target" - [GallerySyncEngine]
/// (`../sync/gallery_sync_engine.dart`) routes it to [permanent] by hand,
/// since the ticket names "unreadable local file" as its own PERMANENT
/// example and nothing would otherwise ever re-offer it usefully.
/// [GallerySyncEngine] branches on THIS enum to decide per-item exponential
/// backoff versus parking a row in the visible failure list - see that
/// class's own doc for the schedule.
enum GalleryUploadFailureBucket {
  /// Network gone, a 5xx, a timeout, "not connected" - anything that says
  /// nothing about THIS upload in particular and may well succeed on retry
  /// once whatever is wrong resolves itself. The default for every
  /// [GalleryUploadException] that does not explicitly say otherwise, since
  /// treating an unrecognised failure as worth retrying is the safe
  /// direction - a permanent failure wrongly treated as transient still
  /// eventually reaches the user (retried, still failing, forever - not
  /// ideal, but not silent either); a transient one wrongly treated as
  /// permanent stops retrying something that would have recovered on its
  /// own.
  transient,

  /// Read-only Space (403), out of storage (507) - retrying will not help
  /// until the user (or someone with access to the server) does something
  /// about it, so [GallerySyncEngine] stops retrying immediately and moves
  /// the row to [GalleryMirror.failedUploadItems] instead of backing off
  /// forever.
  permanent,
}

/// Thrown by a [GalleryUploadBackend] when a remote operation fails for a
/// reason [GalleryUploadService](gallery_upload_service.dart) cannot itself
/// recover from - a read-only Space (ticket 19's "fails with a comprehensible
/// reason rather than silently" criterion) chief among them.
///
/// Deliberately not a [DioException] subclass or wrapper: the whole point of
/// [GalleryUploadBackend] is that nothing above it needs to know the remote
/// side is WebDAV at all, HTTP-flavoured errors included - a test's fake
/// backend throws this directly, with no HTTP response to fabricate.
class GalleryUploadException implements Exception {
  const GalleryUploadException(
    this.message, {
    this.readOnly = false,
    this.bucket = GalleryUploadFailureBucket.transient,
  });

  /// A message fit to show the user directly - see [translateWebDavError]
  /// for the wording used for each server response the WebDAV backend
  /// recognises.
  final String message;

  /// True when the failure was specifically "this Space will not accept a
  /// write" (WebDAV 403) - kept alongside [bucket] (which already implies
  /// `permanent` for this case) purely as a finer-grained diagnostic; no
  /// caller needs to branch on [readOnly] itself.
  final bool readOnly;

  /// Ticket 25's queue-policy classification - see [GalleryUploadFailureBucket]
  /// for what each value means. Defaults to [GalleryUploadFailureBucket.
  /// transient], the safe-to-retry direction, for every call site that does
  /// not explicitly classify its own failure (see [translateWebDavError] for
  /// the one place that does, from the server's actual HTTP status).
  final GalleryUploadFailureBucket bucket;

  @override
  String toString() => message;
}

/// What ticket 19's upload needs from the remote filesystem: whether
/// something already occupies a target path, and how to publish new content
/// there. Narrow on purpose - see the class doc on
/// [GalleryUploadService](gallery_upload_service.dart) for why upload logic
/// (the never-overwrite rule, disambiguation, marking an item Synced) is kept
/// entirely out of this interface and lives one layer up instead: this seam
/// exists solely so that logic can be tested with an in-memory fake, per the
/// ticket's "covered at the app's mirror seam with a stubbed backend"
/// criterion, without standing up a real WebDAV server or fighting
/// `webdav_client`'s own Dio adapter plumbing.
abstract class GalleryUploadBackend {
  /// The size in bytes of whatever currently occupies ([spaceProviderId],
  /// [path]), or null if nothing is there yet.
  ///
  /// Throws [GalleryUploadException] for anything other than "found" or "not
  /// found" - a read-only Space in particular, which a stat can already
  /// reveal without ever attempting the PUT.
  Future<int?> statSize(String spaceProviderId, String path);

  /// Publishes [bytes] at ([spaceProviderId], [path]), creating any missing
  /// intermediate folders. Callers only ever call this once [statSize] has
  /// reported the target empty - see [GalleryUploadService.upload] - so an
  /// implementation is never asked to overwrite anything itself; the
  /// never-overwrite rule lives one layer up, not here.
  ///
  /// Throws [GalleryUploadException] on failure - a read-only Space, the
  /// server out of storage, or a dropped connection alike. An upload that
  /// throws must leave nothing at [path]: server-side atomic PUT (ADR 0002's
  /// amendment) is what makes that true for the WebDAV backend
  /// (`webdav_gallery_upload_backend.dart`) without any client-side staging
  /// of its own.
  Future<void> put(String spaceProviderId, String path, Uint8List bytes);

  /// Deletes whatever currently occupies ([spaceProviderId], [path]) - ticket
  /// 20's one case the app deletes something remotely on its own: a file the
  /// delta feed reports at a length that contradicts what this device
  /// believes it uploaded there. See [GalleryUploadService.
  /// retryMismatchedUpload].
  ///
  /// A no-op, not an error, if nothing is there - the remote side may have
  /// already been cleaned up by a previous, interrupted retry attempt.
  Future<void> remove(String spaceProviderId, String path);
}

/// The production [GalleryUploadBackend] lives in
/// `webdav_gallery_upload_backend.dart` - split out so the engine's import
/// graph (which imports THIS file for the interface, the exception and the
/// status-code translator) never reaches [FileService] and the GetX
/// controllers it transitively pulls in. See that file's doc for the
/// headlessness constraint this split upholds.
GalleryUploadException translateWebDavError(DioException e, int? status) {
  if (status == 403) {
    // Ticket 25: PERMANENT - a read-only Space does not become writable by
    // retrying, so this stops the per-item backoff loop and moves the row
    // straight to the failure list instead.
    return const GalleryUploadException(
      'This Space is read-only - uploading is not allowed here.',
      readOnly: true,
      bucket: GalleryUploadFailureBucket.permanent,
    );
  }
  if (status == 507) {
    // Ticket 25: PERMANENT for the same reason - out of storage will not
    // resolve itself on the next attempt.
    return const GalleryUploadException(
      'Seraph is out of storage space.',
      bucket: GalleryUploadFailureBucket.permanent,
    );
  }
  // Ticket 25: everything else - connection lost, a timeout, any other HTTP
  // status - is TRANSIENT (the enum's own default), the spec's "network
  // gone, 5xx, timeout" bucket: worth retrying with backoff rather than
  // giving up on.
  return GalleryUploadException(
      'Could not reach Seraph (${status ?? e.message}).');
}

/// The HTTP statuses the gateway returns for an access token that has
/// expired (or was otherwise invalidated). The auth middleware answers a
/// Bearer request whose token fails introspection with **403 Forbidden** -
/// NOT 401 - (see `auth/authenticationFailed`'s `bearerAuth` branch), the
/// SAME status a genuinely read-only Space's `fs.ErrPermission` surfaces as
/// via the webdav handler, which is exactly why [translateWebDavError] alone
/// cannot tell the two apart and [withTokenRecovery] has to retry to
/// disambiguate. 401 is included too: some gateways answer 401 for an
/// expired bearer, and accepting either keeps the recovery from depending
/// on one specific auth-server policy.
const Set<int> tokenRecoveryStatuses = {401, 403};

/// Runs [op], and if it throws a [DioException] whose HTTP status is in
/// [tokenRecoveryStatuses] - the gateway's "your access token is no good"
/// response, indistinguishable at the status-code level from a genuinely
/// read-only Space - calls [refreshToken] ONCE, then retries [op] a single
/// time. If the retry succeeds, the failure was an expired access token and
/// the upload proceeds as if nothing happened; if the retry throws the SAME
/// status, it was a real permission denial and [translate] classifies it the
/// usual way (a permanent, read-only-Space [GalleryUploadException]). A
/// non-recovery [DioException] (500, timeout, 507, 404, ...) is translated
/// immediately, without wasting a refresh-grant round trip on something that
/// has nothing to do with the token.
///
/// **Why this exists (the gap ticket 23's lock leaves open):** the
/// cross-isolate lock serializes concurrent refreshes so two isolates never
/// present a rotating refresh token at once, but NEITHER the lock nor any
/// other mechanism guarantees a refresh happens BEFORE an access token's
/// (short - 5 minutes, for the test realm) lifetime elapses. The headless
/// sync isolate loads ONE token at session start and never refreshes
/// mid-run; the main app only refreshes on cold start, resume, and a 30s
/// audio timer (only while music plays). So both paths can - and do -
/// present an expired access token, the gateway answers 403, and
/// [translateWebDavError] silently misclassifies a recoverable token
/// failure as a permanent "read-only Space" failure. This helper is the
/// reactive safety net that catches that: refresh, retry, and let the
/// classification reflect what the SECOND attempt actually returned.
///
/// The refresh runs even when the 403 turns out to be a real read-only
/// Space - one extra token-endpoint round trip per permanent failure is
/// cheap (the lock serializes it, and a refresh that did not need to happen
/// does not invalidate anything the other isolate still holds), and the
/// alternative - trying to predict whether a 403 is a token failure or a
/// permission failure WITHOUT retrying - is exactly the impossible call
/// [translateWebDavError] was already getting wrong.
Future<T> withTokenRecovery<T>({
  required Future<T> Function() op,
  required Future<void> Function() refreshToken,
  required GalleryUploadException Function(DioException e, int? status)
      translate,
}) async {
  try {
    return await op();
  } on DioException catch (e) {
    final status = e.response?.statusCode;
    if (!tokenRecoveryStatuses.contains(status)) {
      throw translate(e, status);
    }
    // An expired/invalid access token and a genuinely read-only Space both
    // surface as 403 (see [tokenRecoveryStatuses]'s own doc) - refresh the
    // token and retry once. If the retry succeeds, it was an expired token;
    // if it fails the same way, [translate] classifies it as permanent.
    await refreshToken();
    try {
      return await op();
    } on DioException catch (e2) {
      throw translate(e2, e2.response?.statusCode);
    }
  }
}
