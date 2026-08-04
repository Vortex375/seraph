import 'dart:async';

import 'package:oidc/oidc.dart';
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
/// again" - [readPersisted] must be a store-only read that never itself
/// calls the token endpoint (see [LockedOidcUserManager]'s class doc for why
/// that guarantee has to be enforced at the manager level, not just by
/// caller discipline here).
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

/// Forces [settings] to never let a plain [OidcUserManager.init] call the
/// token endpoint on its own: `isLoadedTokenAcceptable: (_, __) => true`
/// makes the package's own `loadCachedTokens()` (run both by
/// `OidcInitMode.cacheFirst`'s background revalidation - the default mode,
/// scheduled `unawaited` from inside `init()` itself - and by
/// `OidcInitMode.blockingValidate`) accept whatever cached token is on disk
/// AS-IS and return, skipping its own "refresh if expired" branch entirely,
/// rather than silently presenting a (possibly already-rotated) refresh
/// token outside [refreshTokenWithLock]. This is safe here specifically
/// because every call site that uses [lockedOidcSettings] always follows
/// `.init()` with an explicit, lock-guarded `refreshToken()` immediately
/// after (see `LoginController.init`/`refreshTokenIfNeeded` and
/// `_loadHeadlessSession`) - accepting a stale cached token for the instant
/// between the two is exactly what those call sites already did before
/// ticket 23 (the old code always called `refreshToken()` unconditionally
/// right after `init()`, too), so this changes nothing about what the app
/// ends up showing, only WHERE the actual refresh happens.
///
/// Combine with [LockedOidcUserManager] (which closes the other internal
/// path, the expiry-timer-driven auto-refresh) to make [refreshTokenWithLock]
/// the sole path to the token endpoint - see that class's own doc.
OidcUserManagerSettings lockedOidcSettings({
  required Uri redirectUri,
  required List<String> scope,
}) {
  return OidcUserManagerSettings(
    redirectUri: redirectUri,
    scope: scope,
    isLoadedTokenAcceptable: (_, __) => true,
  );
}

/// An [OidcUserManager] whose own internal, expiry-timer-driven auto-refresh
/// is disabled.
///
/// **Why this exists (ticket 23, second review round):** the foreman's rule
/// is that no call to the token endpoint may happen outside
/// [refreshTokenWithLock], from ANY code path, including ones inside the
/// `oidc` package itself - not just this app's own explicit calls.
/// `OidcUserManagerBase.attachLifecycleListeners()` unconditionally wires
/// `tokenEvents.expiring`/`tokenEvents.expired` to `handleTokenExpiring`/
/// `handleTokenExpired`, and `handleTokenExpired` in particular calls the
/// token endpoint UNCONDITIONALLY once the current token's real expiry
/// passes - this is NOT gated by `OidcUserManagerSettings.refreshBefore`
/// (that setting only controls the EARLIER `expiring` notification/timer;
/// `null` there disables `handleTokenExpiring`'s own early refresh but
/// leaves `handleTokenExpired`'s unconditional one armed). So a manager left
/// running for any length of time - exactly what [LoginController]'s
/// long-lived `_manager` is - will eventually refresh itself with no lock
/// involved at all, presenting whatever refresh token it currently holds
/// even if the OTHER isolate already rotated it away.
///
/// Both handlers are overridden to no-ops here instead: every refresh this
/// app performs goes through an explicit `manager.refreshToken()` call
/// inside [refreshTokenWithLock], never through the timers. See
/// [lockedOidcSettings] for the OTHER internal path (`init()`'s own cached-
/// token revalidation) this alone does not close.
class LockedOidcUserManager extends OidcUserManager {
  LockedOidcUserManager.lazy({
    required Uri discoveryDocumentUri,
    required OidcClientAuthentication clientCredentials,
    required OidcStore store,
    required OidcUserManagerSettings settings,
  }) : super.lazy(
          discoveryDocumentUri: discoveryDocumentUri,
          clientCredentials: clientCredentials,
          store: store,
          settings: settings,
        );

  @override
  Future<void> handleTokenExpiring(OidcToken event) async {
    // Deliberately does nothing - see the class doc. The early "about to
    // expire" notification would otherwise call the token endpoint outside
    // the lock.
  }

  @override
  void handleTokenExpired(OidcToken event) {
    // Deliberately does nothing - see the class doc. This is the
    // unconditional one `refreshBefore: null` cannot reach.
  }

  /// Adopts [user] as this manager's live current user WITHOUT presenting
  /// any token to the token endpoint: persists it exactly like a real
  /// refresh would (the same `saveUser` a successful `refreshToken()` call
  /// uses internally) and pushes it through the same `userSubject` a real
  /// refresh updates, so `currentUser`/`userChanges()` reflect [user]
  /// immediately and every existing listener (e.g. [LoginController]'s own
  /// `userChanges()` subscription) observes the update the normal way.
  ///
  /// This is what makes [refreshTokenWithLock]'s LOSER side safe on a
  /// long-lived manager: without it, the loser's `_manager` keeps holding
  /// the PRE-refresh `currentUser` in memory even though the winner already
  /// rotated that refresh token away on the server - so a LATER
  /// `manager.refreshToken()` call (from this same loser, next time it
  /// thinks a refresh is due) would present that already-invalidated token.
  /// Calling this right after reading the fresh, persisted [user] closes
  /// that gap: the next `refreshToken()` on this manager presents [user]'s
  /// CURRENT refresh token instead.
  Future<void> adoptPersistedUser(OidcUser? user) async {
    if (user != null) {
      await saveUser(user);
    }
    userSubject.add(user);
  }
}
