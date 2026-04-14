# Seraph Agents

Seraph Agents is a FastAPI service built around an AgentScope runtime. It indexes canonical Seraph documents into Postgres/pgvector, applies spaces-aware retrieval before documents reach the model, and serves a React/Vite chat UI directly from the API process.

## Runtime Overview

- `app/main.py` exposes the FastAPI entrypoint via `create_app()` and the module-level `app`
- AgentScope powers the conversational runtime, memory, and tool orchestration used by the chat API
- ingestion consumers persist canonical document records and chunks for retrieval
- retrieval filters results against Seraph spaces before grounding model responses
- the FastAPI app also mounts the production React/Vite UI used for multi-session chat

## Local Development

Run commands from `agents/`.

```sh
./scripts/venv_setup.sh
source .venv/bin/activate
# Start the local NATS dependency, or disable ingestion with KB_INGEST_ENABLED=false.
```

### Backend with built UI assets

Build the frontend once, then run FastAPI directly:

```sh
cd ui
npm install
npm run build
cd ..
python -m app.main
```

Open `http://localhost:8000/`.

### Backend with Vite dev mode

Run the React dev server in one shell:

```sh
cd ui
npm install
npm run dev
```

Run FastAPI in another shell with the UI dev server configured:

```sh
RUNTIME_ENV=dev UI_DEV_SERVER_URL=http://127.0.0.1:5173 python -m app.main
```

Open `http://localhost:8000/`.

In this mode the backend still serves the API, while `/` redirects to `/ui-dev/` and hands the browser off to the Vite dev server.

Useful checks:

```sh
./.venv/bin/pytest tests/test_dependency_cleanup.py -v
./.venv/bin/pytest tests/test_fileprovider_client_integration.py -v
./.venv/bin/pytest tests/test_ingestion_integration.py tests/test_chat_api.py tests/test_chat_streaming.py -v
./.venv/bin/pytest tests/test_ui_static.py tests/test_docker_assets.py -v
./.venv/bin/ruff check .
./.venv/bin/mypy .
cd ui && npm test
```

The ingestion service starts with the FastAPI lifespan. For local runs without NATS, export `KB_INGEST_ENABLED=false`
before running `python -m app.main`.

## Docker

The production image uses a multi-stage build:

- a Node stage runs `npm ci` and `npm run build` in `ui/`
- the final Python image copies `ui/dist` and serves it from FastAPI

Build the image manually:

```sh
docker build -t seraph-agents .
```

Run the compose stack:

```sh
docker compose up -d --build
```

`compose.yaml` still bind-mounts the repository into `/app` for local container development. If you set `UI_DEV_SERVER_URL`, the backend will redirect `/` to the external Vite dev server while continuing to serve API traffic from the container.

## Repair Existing Documents

If the canonical `documents` and `document_chunks` tables are empty because historical `SERAPH_FILE_CHANGED` messages were
already acknowledged before this storage path existed, run the one-shot repair command inside the agents container:

```sh
docker exec -w /app agentscope-refactor-agents-api-1 uv run python -m app.repair backfill-documents
```

The command replays the current `SERAPH_FILE_CHANGED` JetStream history into canonical document storage and prints a short
`processed` / `failed` summary.

## Key Files

```text
app/main.py                  FastAPI entrypoint and UI mounting/dev redirect
chat/agent_factory.py        AgentScope runtime assembly
documents/repository.py      Canonical document indexing persistence
retrieval/service.py         Spaces-aware retrieval orchestration
ui/                          React/Vite frontend served by FastAPI
tests/                       Regression, API, and ingestion coverage
```
