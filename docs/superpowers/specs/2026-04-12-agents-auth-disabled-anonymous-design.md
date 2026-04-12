# Agents Auth-Disabled Anonymous Fallback Design

## Goal

Make the agents API behave like the rest of Seraph when authentication is disabled: requests without an auth header should resolve to the synthetic user `anonymous` instead of returning `401 Unauthorized`.

## Decisions

- Add an explicit `SERAPH_AUTH_ENABLED` setting to the agents service.
- Keep header-based identity resolution unchanged when auth is enabled.
- When auth is disabled and the incoming user header is missing or blank, resolve the current user as `anonymous`.
- Apply this behavior at the backend auth dependency layer, not in the SPA client.

## Scope

### In scope

- Update agents settings to include `SERAPH_AUTH_ENABLED`.
- Update the auth dependency used by the agents API.
- Add regression tests for both the auth helper and an API endpoint.
- Wire the setting through the compose files so the dev stack matches the existing Seraph auth-disabled behavior.

### Out of scope

- Reworking Seraph's broader auth model.
- Adding a gateway-mediated identity propagation layer for agents.
- Changing authenticated-mode behavior when `SERAPH_AUTH_ENABLED=true`.

## Current Problem

The agents API currently rejects requests unless `X-Seraph-User` is present. In the root dev stack, the SPA talks directly to the agents API, but the service does not yet mirror Seraph's auth-disabled behavior. As a result:

- `GET /api/v1/chat/sessions` returns `401`
- `POST /api/v1/chat/sessions` returns `401`
- the minimal SPA cannot create a session or proceed in auth-disabled dev mode

Meanwhile, the rest of Seraph treats requests as user `anonymous` when `SERAPH_AUTH_ENABLED=false`.

## Proposed Design

### Settings

Add a new settings field in `agents/app/settings.py`:

- `seraph_auth_enabled: bool = True`

This is sourced from:

- `SERAPH_AUTH_ENABLED`

That makes auth mode explicit and avoids inferring security behavior from `RUNTIME_ENV`.

### Auth Resolution

Update `agents/auth/current_user.py` so the dependency resolves user identity using this order:

1. If `X-Seraph-User` is present and non-blank, use it.
2. If the header is missing or blank and `SERAPH_AUTH_ENABLED=false`, return `AuthenticatedUser(user_id="anonymous")`.
3. Otherwise, return `401 Unauthorized` with the existing missing-user error.

This keeps authenticated mode strict while making auth-disabled mode match the rest of Seraph.

### Why Backend, Not SPA

The fallback belongs in the backend auth dependency, not the client:

- the server owns auth policy
- non-SPA callers should get the same auth-disabled behavior
- the SPA should not be responsible for asserting a privileged identity string

This also keeps the system consistent with how the existing gateway behaves when auth is disabled.

### Compose Integration

Expose `SERAPH_AUTH_ENABLED` in:

- `docker-compose.yml`
- `docker-compose.dev.yml`
- `agents/compose.yaml`

For the integrated dev stack, the agents service should honor the same env flag the rest of Seraph already uses.

That means a dev configuration with:

- `SERAPH_AUTH_ENABLED=false`

will make the agents API treat missing user headers as `anonymous`.

### Tests

Add regression coverage for:

- auth helper returns the header user when provided
- auth helper rejects missing user when auth is enabled
- auth helper resolves `anonymous` when auth is disabled and the header is missing
- an API-level chat/session request succeeds without `X-Seraph-User` when auth is disabled

These tests should prove the intended backend behavior directly rather than relying only on manual SPA interaction.

## Verification Plan

### Unit/API verification

- targeted auth tests
- targeted chat API tests

Expected:

- existing authenticated-header behavior still passes
- anonymous fallback passes only when `SERAPH_AUTH_ENABLED=false`

### Stack verification

After updating compose env wiring:

- restart `agents-api` in the dev stack
- verify the service starts cleanly
- verify the SPA can create a session without returning `401`

## Risks

### Behavior drift between agents and gateway

If the agents fallback behavior is implemented ad hoc instead of being explicitly tied to `SERAPH_AUTH_ENABLED`, it could drift from the rest of Seraph.

Mitigation:

- use the same explicit env flag name
- implement the fallback centrally in the auth dependency

### Over-broad anonymous behavior

If the fallback is applied when auth is enabled, it would weaken authentication.

Mitigation:

- only fall back to `anonymous` when `SERAPH_AUTH_ENABLED=false`
- preserve current `401` behavior otherwise
