# Repository Overview

Seraph is a WebDAV/CardDAV/CalDAV/Subsonic server with a distributed microservice architecture.
Backend services are Go microservices; the mobile app is Flutter/Dart; the web UI is Angular/TypeScript;
the document-chat agent (`agents/`) is a Python/FastAPI service.

Most top-level folders are Go modules (a microservice or a shared library), all listed in `go.work`.
The exceptions are `agents/`, `app/`, `webapp/`, `docs/`, `openspec/`, `scripts/`, `test/` and `vendor-forks/`.
Services communicate over NATS (JetStream) and use `fx` for dependency injection.

# Tech Stack

- Backend microservices: Go `1.26.5` with multi-module workspace via `go.work`
- Backend architecture: distributed microservices with Uber `fx` dependency injection
- Messaging/eventing: NATS with JetStream
- Backend data storage: MongoDB; `gallery-ai` stores embeddings in PostgreSQL with `pgvector`
- Gallery ML inference: Immich's `immich-machine-learning` container (CLIP embeddings, faces), called by `gallery-ai`
- Observability: `slog`-based logging and OpenTelemetry tracing
- Schema/code generation: Avro schemas with generated Go sources (`avrogen`/`fastavro` related workflow)
- Web app: Angular `18`, TypeScript `5.5`, RxJS, Jasmine/Karma
- Mobile app: Flutter with Dart `>=3.4.3 <4.0.0`
- Mobile libraries in use: Dio, Get/GetX, Provider, OIDC, WebDAV client, media_kit/audio packages
- Agents app: Python `3.12` with FastAPI and Pydantic AI (`pydantic-ai-slim[openai]`), any OpenAI-compatible
  chat/embedding endpoint (`OPENAI_BASE_URL`; the dev stack uses OpenRouter); React/Vite chat UI in `agents/ui/`
- Agents data/storage: PostgreSQL with `pgvector` (SQLAlchemy async + psycopg)
- Agents tooling/integration: NATS (`nats-py`), Avro (`fastavro`), OpenTelemetry, `uv`, `mypy`, `ruff`, `pytest`
- Native/media integration: TagLib via SWIG wrapper

# Repository Layout

- Go microservices (each has its own `go.mod`): `api-gateway/`, `spaces/`, `shares/`, `file-indexer/`, `jobs/`,
  `thumbnailer/`, `audio-metadata/`, `gallery/`, `gallery-ai/`, `file-provider-dir/`, `file-provider-smb/`,
  `log-viewer/`.
- Shared Go libraries: `entities/`, `events/`, `messaging/`, `logging/`, `tracing/`, `config/`, `mongodb/`,
  `service-discovery/`, `file-provider/` (file-provider protocol, plus `cmd/fileprovider-testserver` used by
  agents integration tests), `util/`, `taglib/`.
- `vendor-forks/go-smb2/`: patched fork wired in via a `replace` in `go.work`.
- `webapp/seraph-web-app/`: Angular web app (Angular CLI 18.x).
- `app/seraph_app/`: Flutter mobile app.
- `agents/`: Pydantic AI document-chat service (Python/FastAPI + Postgres/pgvector, React/Vite UI).
- `events/`, `service-discovery/`, `thumbnailer/thumbnailer/`, `audio-metadata/audiometadata/`: codegen Makefiles
  (avrogen for NATS schemas); see Code Generation.
- `taglib/`: SWIG wrapper for TagLib; see `taglib/README.md` for build notes.
- `docs/` (ADRs, agent docs, research), `openspec/` (OpenSpec changes and specs), `CONTEXT.md` (domain context).
- `docker-compose.yml` / `docker-compose.dev.yml`: full stack (NATS, MongoDB, `agents-db`, all services).

# Build, Lint, Test Commands

## Go microservices (per module)

Go modules live in many directories. Run commands from the module directory.

- Build: `go build ./...`
- Run tests: `go test ./...`
- Run a single test: `go test ./... -run TestSpaceCrud`
- Run a single package test: `go test ./spaces -run TestSpaceCrud`

Notes:
- Integration tests in `spaces/` use Docker + Testcontainers + embedded NATS.
- Set up Docker before running those tests.

## Angular web app

Location: `webapp/seraph-web-app/`

- Install: `npm install`
- Dev server: `npm run start`
- Build: `npm run build`
- Test: `npm run test`
- Run a single test spec: `npx ng test --include=src/app/path/to/file.spec.ts`

Lint:
- No lint script is defined in `package.json`.
- `.editorconfig` is enforced (2-space indent, single quotes in TS).

## Flutter app

Location: `app/seraph_app/`

- Pub get: `flutter pub get`
- Build (debug): `flutter run`
- Build (release APK): `flutter build apk`
- Test: `flutter test`
- Run a single test: `flutter test test/widget_test.dart`
- Analyze (lint): `flutter analyze` (uses `flutter_lints` via `analysis_options.yaml`)
- Build (web, the real gate): `flutter build web --release --base-href=/app/`
- Build (release APK): `flutter build apk` — **mandatory when the change touches
  anything under `android/`** (native code, manifests, gradle, plugins, or the
  Flutter-to-native channel/plugin wiring). The web build does not exercise any
  Android build target, so an Android-only break (a malformed plugin manifest, a
  Kotlin compile error, a missing gradle module) goes undetected by `flutter
  build web` and `flutter analyze` alike. Do not accept a change that touches
  `android/` on the web build alone; gate it on the APK build as well.

**`flutter analyze` clean does not mean the code builds.** Analyze has passed on code
that broke the web build. Do not accept a Dart change — and do not resolve a Dart
ticket — on `flutter analyze` alone; gate it on the web release build above.

**`flutter analyze` must report zero issues, not merely zero errors — this is now a
required gate.** The baseline is clean, so any info or warning `flutter analyze`
reports is a regression introduced by the change under review. This gate is
necessary but not sufficient: a zero-issue `flutter analyze` still does not mean the
code builds (see above) — separately run the web release build, and the APK build
when `android/` is touched, before accepting the change.

## Agents app (Pydantic AI)

Location: `agents/`

- Docker dev: `docker compose up -d --build`
- Run API locally: `uv run python -m app.main`
- Setup venv (uv): `./scripts/venv_setup.sh` (or `uv sync`)
- Add/change a dependency: edit `pyproject.toml`, run `uv lock`, then `./scripts/generate_requirements.sh`
  (the Docker image installs from `requirements.txt`, so both lockfiles must be updated)
- Lint: `uv run ruff check .`
- Type check: `uv run mypy .`
- Both at once: `uv run ./scripts/validate.sh`; format: `uv run ./scripts/format.sh`

Agents structure:
- `app/main.py`: FastAPI entry point (`create_app()`); the lifespan connects NATS once and builds the
  `AgentFactory` (model, retrieval, spaces, file access) into `app.state`; UI mounting.
- `app/settings.py`: settings from env (`OPENAI_API_KEY`, `OPENAI_BASE_URL`, `CHAT_MODEL_NAME`, `NATS_URL`, ...).
- `api/`: HTTP routes with typed `Depends` (`get_db_session`, `get_session_factory`, `get_agent_factory`,
  `get_spaces_client`). `api/chat.py` starts each turn as a background task and relays its events as SSE.
- `chat/`: the agent. `agent_factory.py` builds the Pydantic AI `Agent` per turn (`ChatAgent` = agent + deps +
  message history, `ChatAgent.stream()` yields text deltas) plus history (de)serialization; `turns.py` runs one
  turn on one DB session, yielding typed `TurnEvent`s and persisting turn state, citations, failures and
  history; `tools.py` holds the tools and `ChatDeps`; `prompts.py` the system prompt; `session_service.py`
  reads sessions and history for the API.
- `knowledge/`, `retrieval/`: spaces-aware semantic search over pgvector chunks.
- `ingestion/`, `documents/`: consume `SERAPH_FILE_CHANGED` events and index documents/chunks.
- `fileprovider/`, `spaces/`: NATS clients for file providers and space scopes.
- `auth/`: current-user resolution. `db/`: async engine/session, URL helpers, additive migrations.
- `ui/`: React/Vite chat UI, built to `ui/dist` and served by FastAPI.

### Test infrastructure (agents)

Most agents tests need PostgreSQL, NATS, and MongoDB. Start the minimal services:
```bash
docker compose -f docker-compose.dev.yml up -d nats mongodb agents-db
```

Then run tests with the required environment variables:
```bash
RUNTIME_ENV=dev \
DB_HOST=localhost DB_PORT=5432 DB_USER=ai DB_PASS=ai DB_DATABASE=ai \
NATS_URL=nats://localhost:4222 \
uv run pytest tests/ -v
```

Run a single test file:
```bash
uv run pytest tests/test_chat_api.py -v
```

Run a test by name:
```bash
uv run pytest tests/test_chat_api.py -k test_create_message -v
```

Notes:
- The ingestion integration tests (`test_ingestion_integration.py`) additionally
  require `OPENAI_API_KEY` to be set; they are skipped otherwise.
- `test_ingestion_integration.py` and `test_fileprovider_client_integration.py` start the Go
  `file-provider/cmd/fileprovider-testserver` via `go run`, so a Go toolchain must be on `PATH`.
- `test_retrieval_repository.py` skips itself when Postgres is unreachable.
- The DB credentials above match the defaults defined in
  `docker-compose.dev.yml` under the `agents-db` service.

### Database migrations

The agents service runs additive migrations automatically during startup
(`app/main.py` -> `db/migrations.py`). These migrations run after
`Base.metadata.create_all` and only add missing schema elements to existing
tables (for example, the `agent_state` column on `chat_sessions`).

If you change a model in a way that cannot be expressed as an additive
column addition (rename, drop, type change), you must extend
`db/migrations.py` or introduce a full migration framework such as Alembic.

### Docker dev integration tests

`tests/test_chat_docker_integration.py` exercises the real API deployed via
`docker-compose.dev.yml`. It covers the full chat workflow:

1. Health check
2. Create a chat session
3. List sessions
4. Stream a message response
5. List persisted messages
6. Delete the session

Start the dev services first:

```bash
docker compose -f docker-compose.dev.yml up -d --build
```

Run the integration tests:

```bash
uv run pytest tests/test_chat_docker_integration.py -v
```

To run the end-to-end agent response test, `OPENAI_API_KEY` must be available
in the test process environment (the dev container already requires it):

```bash
OPENAI_API_KEY=<your-key> uv run pytest tests/test_chat_docker_integration.py -v
```

A custom API base URL can be targeted with `AGENTS_API_URL` (default is
`http://localhost:8000`).

# Code Generation

These are file-specific Makefile rules for generating Go sources from Avro schemas.
Run them in the listed directories when changing the schema files.

- `events/`: `make` (generates `events.go` from `schema.avsc`)
- `service-discovery/`: `make` (generates `messages.go` from `messages_schema.avsc`)
- `thumbnailer/thumbnailer/`: `make` (generates `messages.go` from `messages_schema.avsc`)
- `audio-metadata/audiometadata/`: `make` (generates `messages.go` from `messages_schema.avsc`)

`gallery/geo/`: `make generate` downloads GeoNames/Natural Earth data and regenerates the committed
`data/geodata.bin.gz`. Run it only when refreshing the dataset, never as part of a build.

# Code Style Guidelines

## Go

Formatting and imports:
- Use `gofmt` for formatting; files appear gofmt-aligned.
- Imports are grouped with standard library first, then a blank line, then third-party/internal.
- Keep import paths consistent with module names, e.g. `umbasa.net/seraph/...`.

Naming:
- Exported types and functions use `UpperCamelCase`.
- Internal variables are `lowerCamelCase` or short names when scoped (`err`, `res`, `nc`).
- Topics/constants use `UpperCamelCase` constants, e.g. `SpaceResolveTopic`.

Dependency injection:
- `fx.In`/`fx.Out` structs named `Params`/`Result` are common.
- Modules are passed to `fx.New` in `main.go`; startup hooks use `fx.Lifecycle`.

Error handling:
- Check and return errors immediately.
- Wrap errors with `fmt.Errorf("...: %w", err)` when adding context.
- Use `errors.New` for validation errors and `errors.Is` for sentinel checks.
- In request/response handlers, return error strings on the response instead of panicking.

Logging/tracing:
- Use `logging.Logger` with `slog` under the hood.
- Tracing uses `umbasa.net/seraph/tracing` with OpenTelemetry; propagate context.

MongoDB usage:
- Use `context.Context` for DB operations.
- `FindOne`, `Find`, `FindOneAndUpdate` patterns are used with error checks.

Testing:
- Tests use `testing`, `testify/assert`, and sometimes `testcontainers-go`.
- Integration tests often set up NATS and Mongo; isolate resources per test run.

Files:
- Go files include a copyright/license header at the top.

## TypeScript / Angular

Formatting:
- `.editorconfig` enforces 2-space indent and single quotes in `.ts`.
- Keep trailing whitespace trimmed and final newline present.

Testing:
- Tests are run via Angular CLI (`ng test`).
- Single-test runs use `--include` to target a spec file.

## Flutter / Dart

Linting:
- Uses `flutter_lints` via `analysis_options.yaml`.
- `flutter analyze` must come back with zero issues (the baseline is clean; any
  finding is a regression) — but treat a clean run as a lint gate, not a build check.
  It is known to pass on code that fails `flutter build web --release`. Verify Dart
  changes with the web release build (see the Flutter app commands above).

Formatting:
- Use `dart format` or `flutter format` for Dart files.

Testing:
- `flutter test` for all tests; pass a specific file for single tests.

## Python / Pydantic AI

Formatting and linting:
- Use Ruff (line length 120) and keep configs in `agents/pyproject.toml`.
- `ruff` and `mypy` are the expected lint/type tools.

Typing:
- Prefer type hints on public functions.
- `mypy` uses strict-ish settings (`check_untyped_defs`, `no_implicit_optional`) with the pydantic plugin.

Pydantic AI patterns:
- Tools are plain async functions taking `RunContext[ChatDeps]`, registered in `BASE_TOOLS` / `FILE_TOOLS`
  in `chat/tools.py`. The docstring (with an `Args:` section) becomes the tool and parameter descriptions.
- Tools that surface files append them to `ctx.deps.citations`; `chat/turns.py` de-duplicates and persists
  those. Never trust citations from the model's text.
- Tools are wrapped with `_errors_to_model`, which turns any exception into `ToolFailed(str(exc))`: the model
  gets a failed tool result (`outcome='failed'`) it can explain, instead of the user's turn aborting (Pydantic AI
  aborts the run on any other exception raised inside a tool). Raise `ToolFailed` yourself for expected
  terminal failures, and `ModelRetry` only when the model should retry with different arguments.
- The per-session system prompt is persisted in `chat_sessions.system_prompt` and passed as `instructions`.
- Message history is stored in `chat_sessions.agent_state` as `ModelMessagesTypeAdapter` JSON. Each turn's
  assistant message id is the Pydantic AI `run_id`, which links history to `ChatTurnState` and
  `ChatTurnSource` rows. Unreadable (legacy) history loads as `None` instead of failing.
- Test agents with `pydantic_ai.models.function.FunctionModel` (or `agent.override(model=...)`), not by
  stubbing framework classes. `tests/conftest.py` provides a SQLite `session_factory`, `make_factory` and an
  `app`/`client` with dependencies overridden (no lifespan, so no Postgres/NATS); doubles live in
  `tests/support.py`. Do not monkeypatch private functions.

# Agent Notes

- A repo-wide `go.work` exists at `go.work` listing the Go modules; use it for multi-module work.
- Avoid changing generated files unless updating the source schema/inputs.
- Follow existing patterns around NATS topics, tracing, and Mongo DB access.
- Keep changes localized to the service/module you are working on.

## Production access (`.env.seraph-prod`)

If `.env.seraph-prod` exists in the repo root, it holds credentials for the production instance.
It is gitignored; never commit it, print its values, or copy it elsewhere. Keep it at mode `600`.

Format (plain `KEY=value` lines, no `export`):

- `SERAPH_URL`: base URL of the production API.
- `OIDC_TOKEN_URL`: the OIDC provider's token endpoint.
- `OIDC_CLIENT_ID`: the public client ID used for the refresh grant.
- `SERAPH_REFRESH_TOKEN`: an OIDC refresh token. There is no stored access token.

To get access, run a refresh-token grant:

1. `POST` to `OIDC_TOKEN_URL` with form fields `grant_type=refresh_token`, `refresh_token=$SERAPH_REFRESH_TOKEN`
   and `client_id=$OIDC_CLIENT_ID`.
2. The response contains an `access_token` that lives about 300 seconds. Send it as
   `Authorization: Bearer <token>` to `SERAPH_URL`. Refresh again when it expires.
3. **The provider rotates refresh tokens.** Each successful grant invalidates the old
   `SERAPH_REFRESH_TOKEN` and returns a new `refresh_token`. Write the new one back into
   `.env.seraph-prod` immediately, before doing anything else (write to a temp file with mode `600`, then
   rename over the original so a crash cannot truncate it). If the write is lost, access is lost
   and the user must issue a new token.

Rules:

- Use it only when the task needs production, and keep requests read-only unless the user says otherwise.
- Never log or echo tokens; report only status codes and non-secret facts.
- If the refresh fails with an `invalid_grant`-style error, stop and tell the user. Do not retry in a loop.
- Do not refresh just to check that the file is valid; every refresh rotates the token.

## Agent skills

### Issue tracker

Issues and specs live as local markdown files under `.scratch/<feature-slug>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
