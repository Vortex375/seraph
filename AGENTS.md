# Repository Overview

Seraph is a WebDAV/CardDAV/CalDAV/Subsonic server with a distributed microservice architecture.
Backend services are Go microservices; the mobile app is Flutter/Dart; the web UI is Angular/TypeScript.

Each folder (except `app` and `webapp`) is a Go module hosting a microservice.
Services communicate over NATS (JetStream) and use `fx` for dependency injection.

# Tech Stack

- Backend microservices: Go `1.25.4` with multi-module workspace via `go.work`
- Backend architecture: distributed microservices with Uber `fx` dependency injection
- Messaging/eventing: NATS with JetStream
- Backend data storage: MongoDB
- Observability: `slog`-based logging and OpenTelemetry tracing
- Schema/code generation: Avro schemas with generated Go sources (`avrogen`/`fastavro` related workflow)
- Web app: Angular `18`, TypeScript `5.5`, RxJS, Jasmine/Karma
- Mobile app: Flutter with Dart `>=3.4.3 <4.0.0`
- Mobile libraries in use: Dio, Get/GetX, Provider, OIDC, WebDAV client, media_kit/audio packages
- Agents app: Python `3.12` with FastAPI and Agno/AgentOS
- Agents data/storage: PostgreSQL with `pgvector`, DuckDB
- Agents tooling/integration: NATS (`nats-py`), OpenTelemetry, `mypy`, `ruff`, `pytest`
- Native/media integration: TagLib via SWIG wrapper

# Repository Layout

- `api-gateway/`, `spaces/`, `shares/`, `file-indexer/`, `jobs/`, etc.: Go microservices (each has its own `go.mod`).
- `entities/`, `messaging/`, `logging/`, `tracing/`, `config/`, `mongodb/`: shared Go libraries.
- `webapp/seraph-web-app/`: Angular web app (Angular CLI 18.x).
- `app/seraph_app/`: Flutter mobile app.
- `agents/`: Agno/AgentOS multi-agent app (Python/FastAPI + Postgres + DuckDB).
- `events/`, `service-discovery/`, `thumbnailer/thumbnailer/`: codegen Makefiles (avrogen for NATS schemas).
- `taglib/`: SWIG wrapper for TagLib; see `taglib/README.md` for build notes.

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

## Agents app (Agno/AgentOS)

Location: `agents/`

- Docker dev: `docker compose up -d --build`
- Run API locally: `python -m app.main`
- Setup venv (uv): `./scripts/venv_setup.sh`
- Generate requirements: `./scripts/generate_requirements.sh`
- Lint: `ruff check .`
- Type check: `mypy .`

Agents structure:
- `agents/agents/`: individual agent definitions (Pal, knowledge, MCP).
- `agents/app/main.py`: AgentOS entry point.
- `agents/app/config.yaml`: agent prompt/config file.
- `agents/db/`: database session and URL helpers.

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
- The DB credentials above match the defaults defined in
  `docker-compose.dev.yml` under the `agents-db` service.

# Code Generation

These are file-specific Makefile rules for generating Go sources from Avro schemas.
Run them in the listed directories when changing the schema files.

- `events/`: `make` (generates `events.go` from `schema.avsc`)
- `service-discovery/`: `make` (generates `messages.go` from `messages_schema.avsc`)
- `thumbnailer/thumbnailer/`: `make` (generates `messages.go` from `messages_schema.avsc`)

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
- Prefer running `flutter analyze` after changes.

Formatting:
- Use `dart format` or `flutter format` for Dart files.

Testing:
- `flutter test` for all tests; pass a specific file for single tests.

## Python / Agno

Formatting and linting:
- Use Ruff (line length 120) and keep configs in `agents/pyproject.toml`.
- `ruff` and `mypy` are the expected lint/type tools.

Typing:
- Prefer type hints on public functions.
- `mypy` uses strict-ish settings (`check_untyped_defs`, `no_implicit_optional`).

# Agent Notes

- A repo-wide `go.work` exists at `go.work` listing the Go modules; use it for multi-module work.
- Avoid changing generated files unless updating the source schema/inputs.
- Follow existing patterns around NATS topics, tracing, and Mongo DB access.
- Keep changes localized to the service/module you are working on.
