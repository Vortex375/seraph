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

**Status:** ready-for-agent

- [ ] Two isolates hitting an expired token concurrently produce exactly one refresh
- [ ] The isolate that does not win the lock uses the refreshed token rather than refreshing again
- [ ] A refreshed token is persisted so both isolates see it
- [ ] A refresh that fails releases the lock, and the next attempt is not blocked forever
- [ ] An isolate killed while holding the lock does not deadlock the other — the lock expires or is reclaimed
- [ ] A long-running backup spanning several token lifetimes completes without the user being logged out
- [ ] Covered by a test that drives concurrent refresh attempts from separate isolates and asserts a single refresh, plus a test for the holder-dies case
