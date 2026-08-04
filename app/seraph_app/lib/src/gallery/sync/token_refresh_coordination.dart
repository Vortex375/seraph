import 'dart:async';

import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';

/// The default lease [refreshTokenWithLock] asks for - long enough to cover
/// a slow OIDC token refresh over a bad mobile connection, short enough that
/// an isolate killed mid-refresh does not block the other one for long. A
/// real refresh is a single HTTP round trip; this is generous headroom
/// around that, not a measured worst case.
const Duration tokenRefreshLockLease = Duration(seconds: 30);

/// How long a caller that lost the lock race waits, in total, for the
/// winner to finish before giving up and reading whatever is on disk
/// anyway. Kept comfortably above [tokenRefreshLockLease] itself: the lease
/// is what guarantees the wait terminates even if the winner never releases
/// explicitly (see [TokenRefreshLock]'s class doc), and this timeout is only
/// a second, independent backstop against that guarantee somehow not
/// holding - it should essentially never be the thing that ends the wait.
const Duration tokenRefreshLockWaitTimeout = Duration(seconds: 40);

/// How often a caller that lost the race polls [GalleryMirror.
/// tokenRefreshLockHeld] while waiting for the winner.
const Duration tokenRefreshLockPollInterval = Duration(milliseconds: 200);

/// [TokenRefreshLock.holder] for the app's own UI isolate - used by
/// `LoginController` (`../../login/login_controller.dart`).
const String uiTokenRefreshLockHolder = 'ui';

/// [TokenRefreshLock.holder] for the headless data-sync isolate - used by
/// `_loadHeadlessSession` in `gallery_sync_task_handler.dart`.
const String headlessTokenRefreshLockHolder = 'headless';

/// Runs [refresh] behind ticket 23's cross-isolate token-refresh lock
/// ([mirror]'s [TokenRefreshLock] row), so the real OIDC refresh-grant
/// request [refresh] makes happens on at most one isolate at a time -
/// necessary because the app's refresh token rotates on every use, so a
/// genuinely concurrent second refresh would present a token the first
/// refresh already invalidated and silently end the session.
///
/// The isolate that loses the race never calls [refresh] itself - once the
/// winner's lease has cleared (by release, or by simply expiring - see
/// [GalleryMirror.tryAcquireTokenRefreshLock]'s doc for why the two are
/// indistinguishable here, and deliberately so), it calls [readPersisted]
/// exactly once and returns whatever that reports. This is what ticket 23
/// means by "the loser re-reads the persisted token rather than refreshing
/// again" - [readPersisted] is expected to be a store-only read (e.g.
/// `OidcUserManager.loadCachedTokens()` plus `currentUser`), never a call
/// that itself hits the token endpoint.
///
/// [holder] only needs to be unique to the CALLING ISOLATE, not to this
/// call - see [uiTokenRefreshLockHolder] / [headlessTokenRefreshLockHolder]
/// and [TokenRefreshLock]'s class doc for why identity plays no part in the
/// acquisition decision itself.
Future<T> refreshTokenWithLock<T>({
  required GalleryMirror mirror,
  required String holder,
  required Future<T> Function() refresh,
  required Future<T> Function() readPersisted,
  Duration lease = tokenRefreshLockLease,
  Duration pollInterval = tokenRefreshLockPollInterval,
  Duration waitTimeout = tokenRefreshLockWaitTimeout,
}) async {
  final nowMillis = DateTime.now().millisecondsSinceEpoch;
  final acquired = await mirror.tryAcquireTokenRefreshLock(
    holder: holder,
    nowMillis: nowMillis,
    leaseMillis: lease.inMilliseconds,
  );
  if (acquired) {
    try {
      return await refresh();
    } finally {
      // Runs on success AND failure - see this function's own doc and
      // ticket 23's "a refresh that fails releases the lock" criterion.
      await mirror.releaseTokenRefreshLock(holder: holder);
    }
  }

  // Lost the race. Wait for the current holder's lease to clear - by
  // release or by expiry, whichever comes first - bounded by [waitTimeout]
  // as a second, independent backstop (see that constant's own doc).
  final deadline = DateTime.now().add(waitTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final stillHeld = await mirror.tokenRefreshLockHeld(
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
    if (!stillHeld) {
      break;
    }
    await Future<void>.delayed(pollInterval);
  }
  return readPersisted();
}
