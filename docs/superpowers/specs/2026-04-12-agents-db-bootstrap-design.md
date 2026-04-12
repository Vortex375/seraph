# Agents Database Bootstrap Design

## Goal

Ensure the agents service can start against a fresh Postgres database in the dev stack and create its required SQLAlchemy tables automatically, so the SPA can create chat sessions without manual database setup.

## Decisions

- Use startup-time SQLAlchemy schema creation inside the agents service.
- Create all tables from the existing declarative metadata before serving requests.
- Keep the fix localized to app bootstrap rather than adding a separate compose init container or migration framework in this pass.

## Scope

### In scope

- Add startup-time schema creation for the existing SQLAlchemy models.
- Add regression coverage proving app startup initializes the schema on the configured engine.
- Verify the live dev stack can create a chat session after restart.

### Out of scope

- Introducing Alembic or a broader migration system.
- Reworking compose topology to add a database init job.

## Current Problem

The agents service starts successfully, but its Postgres schema is never initialized. The SQLAlchemy models exist and tests create them manually with `Base.metadata.create_all`, but the running app does not. In a fresh stack, headerless session creation now gets past auth and then fails with:

- `psycopg.errors.UndefinedTable: relation "chat_sessions" does not exist`

This blocks the SPA even though auth-disabled anonymous fallback is already fixed.

## Proposed Design

### Startup Schema Initialization

During FastAPI lifespan startup, before serving requests, the app should open an engine transaction and run:

- `Base.metadata.create_all`

against the configured async engine.

This is sufficient for the current development/runtime shape because:

- the schema already exists in declarative models
- no migration tool is present today
- the immediate requirement is fresh-stack usability in dev compose

### Placement

The schema bootstrap belongs in `agents/app/main.py` startup flow, alongside existing runtime initialization such as ingestion startup.

That keeps the behavior inside the service boundary and guarantees a freshly started app can prepare its own database before handling traffic.

### Testing

Add regression coverage proving startup performs schema creation on the engine. The test should verify the app startup path invokes `Base.metadata.create_all` via the engine during lifespan startup, not merely that the app object can be instantiated.

### Live Verification

After updating the app startup path:

- rebuild/restart `agents-api`
- send `POST /api/v1/chat/sessions` without auth header in the auth-disabled dev stack
- confirm it returns `201` instead of failing on missing table

## Risks

### Repeated startup creation cost

`create_all` runs on every startup.

Mitigation:

- acceptable for the current dev-focused requirement
- SQLAlchemy only creates missing tables

### Future schema evolution

This does not replace real migrations.

Mitigation:

- keep the fix minimal for current needs
- migrations can be added later without changing the immediate user-facing behavior goal
