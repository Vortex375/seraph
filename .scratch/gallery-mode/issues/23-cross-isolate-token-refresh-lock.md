# 23 — Cross-isolate token refresh lock

**What to build:** A long overnight backup does not end with the user silently
logged out.

With two isolates and rotating OIDC refresh tokens, concurrent refreshes mean
the second one presents a token the first has already invalidated, and the
session dies — during an unattended backup, the worst possible moment and the
hardest to diagnose, because the user only finds out hours later.

Guard refresh with a **database-backed cross-isolate lock**. Only one refresh is
ever in flight; **the loser re-reads the persisted token rather than refreshing
again.** The lock must live in shared persistent storage, since isolates share
no memory.

This gates unattended background scheduling: running two isolates unattended
without it is a known logout bug.

**Blocked by:** 22

**Status:** resolved

- [ ] Two isolates hitting an expired token concurrently produce exactly one refresh
- [ ] The isolate that does not win the lock uses the refreshed token rather than refreshing again
- [ ] A refreshed token is persisted so both isolates see it
- [ ] A refresh that fails releases the lock, and the next attempt is not blocked forever
- [ ] An isolate killed while holding the lock does not deadlock the other — the lock expires or is reclaimed
- [ ] A long-running backup spanning several token lifetimes completes without the user being logged out
- [ ] Covered by a test that drives concurrent refresh attempts from separate isolates and asserts a single refresh, plus a test for the holder-dies case

## Comments

### Implementer report

Guards the non-interactive OIDC refresh so the UI isolate and the headless sync isolate never present
the same rotating refresh token at once.

Files:

- `lib/src/gallery/mirror/gallery_mirror_database.dart` — new `TokenRefreshLock` table, schema v9→v10.
- `lib/src/gallery/mirror/gallery_mirror.dart` — `tryAcquireTokenRefreshLock`,
  `releaseTokenRefreshLock`, `tokenRefreshLockHeld`.
- `lib/src/gallery/sync/token_refresh_coordination.dart` (new) — `refreshTokenWithLock<T>`, the
  reusable winner/loser coordinator.
- `lib/src/login/login_controller.dart`, `lib/src/gallery/sync/gallery_sync_task_handler.dart` — wired
  into every refresh call site.
- `lib/main.dart`, `lib/src/initial_binding.dart` — `GalleryMirrorDatabase`/`GalleryMirror` now open in
  `main.dart` ahead of `LoginController`, which needs one; `InitialBinding` reuses them via `Get.find`.
- `test/gallery/sync/token_refresh_lock_test.dart` (new), plus a migration test.

**Locking primitive:** a single-row, lease-based lock acquired by one atomic SQLite UPSERT
(`INSERT ... ON CONFLICT DO UPDATE ... WHERE expires_at <= ?`), so acquire-if-free-or-expired is one
indivisible statement even across two connections to the same file — no read-then-write window. Plain
drift SQL, so it compiles identically on web, where it is simply uncontested.

**Holder dies mid-refresh:** the lock is a 30-second lease, not held-until-released. The next
acquirer's own WHERE clause treats an expired row as free — no liveness check, since neither isolate
can observe the other's process state anyway.

**Decision the ticket did not settle:** the loser's "read the persisted token" side uses a throwaway
manager built fresh, `init()`'d and disposed, rather than the package's `@protected`
`loadCachedTokens()`/`createUserFromToken()`, keeping the read on the public API.

### Verifier verdict (round 1)

REWORK — the lock itself verified sound (atomicity confirmed with real cross-connection tests, every
explicit call site guarded, additive migration, the `main.dart`/`InitialBinding` move safe including
web, no scope creep), but one root cause failed two criteria:

`OidcUserManagerBase` unconditionally arms its own expiry-driven auto-refresh — `handleTokenExpiring`
and `handleTokenExpired`, the latter *not* gated by `refreshBefore` — and `init()` performs its own
cached-token revalidation. Either can hit the token endpoint outside the lock. Meanwhile the loser path
read the fresh token through a throwaway probe but never fed it back into the long-lived `_manager`,
which kept a stale `currentUser`. When the package's internal timer then fired against it, the
already-rotated token produced a terminal `invalid_grant`, and `oidc_core` responded with
`forgetUser()` — the exact silent logout during an unattended overnight backup that this ticket exists
to prevent.

### Foreman's rule for the rework

No call to the token endpoint may happen outside `refreshTokenWithLock`, from any code path, including
ones inside the `oidc` package itself; and the loser path must leave the live manager holding the
current token, never a rotated-away one.

*(The first implementer was interrupted mid-edit by a session limit and left the rework uncommitted; a
second implementer finished it, completing the headless side and the tests.)*

### Rework as landed

- `LockedOidcUserManager` overrides both expiry handlers to no-ops, closing the timer path, and adds
  `adoptPersistedUser`, which persists through `saveUser` and pushes through `userSubject` so
  `currentUser` and `userChanges()` reflect the winner's token immediately.
- `lockedOidcSettings` sets `isLoadedTokenAcceptable: (_, __) => true`, so `init()`'s own revalidation
  accepts the cached token as-is instead of refreshing outside the lock. Safe because every call site
  already followed `init()` with an explicit guarded `refreshToken()`.
- Both `LoginController` and the headless isolate's `_buildHeadlessManager` now use them, and both
  loser paths adopt the persisted user into the manager they actually go on to use.
- Two new tests cover the loser-adopts-current-token contract. The implementer confirmed they are real
  by reverting `adoptPersistedUser` to a no-op and watching them fail (`stale-refresh-token` never
  became `fresh-refresh-token`), then restoring it.

### Verifier verdict (round 2, after rework)

APPROVED — the rule is met. The verifier read the `oidc`/`oidc_core` source in the pub cache and
enumerated every path to the token endpoint in `user_manager_base.dart`:
`handleTokenExpiring`/`handleTokenExpired` (now no-op'd, confirmed virtually dispatched through
`attachLifecycleListeners`'s tear-offs), `loadCachedTokens`'s refresh branch — both
`blockingValidate`'s direct call and `cacheFirst`'s unawaited background revalidation, both gated by
the same `isLoadedTokenAcceptable` check, confirmed to return before reaching `_performAutoRefresh` —
and `getAccessToken()`/`signInSilent()`, which the app never calls (every API call site reads
`.token.accessToken` directly). The public `refreshToken()` is called only inside
`refreshTokenWithLock`, and no raw `OidcUserManager.lazy` construction remains anywhere in `lib/`.

`saveUser` and `userSubject` are both `@protected` and legitimately reachable from the subclass;
`saveUser` is a store-only write, and `adoptPersistedUser` mirrors what a real refresh does internally,
so there is no double-persist or state corruption. No app code subscribes to the token
expiring/expired/refresh-failure events, so no-opping the handlers drops nothing live.

`flutter test` 295/295 (293 before the rework, +2 for the new tests, no skips or deletions),
`flutter build web --release --base-href=/app/` and `flutter build apk --debug` both succeed. The
rework touched only the four intended files. Verified against base `03780d2`.
