# Seraph Agents

Seraph Agents is a FastAPI service built around a Pydantic AI agent. It indexes canonical Seraph documents into Postgres/pgvector and applies spaces-aware retrieval before documents reach the model. Clients (the Flutter app) reach its chat API through the api-gateway.

## Runtime Overview

- `app/main.py` exposes the FastAPI entrypoint via `create_app()` and the module-level `app`
- Pydantic AI powers the conversational runtime and tool calls; each session's message history is stored as JSON in `chat_sessions.agent_state`
- ingestion consumers persist canonical document records and chunks for retrieval
- retrieval filters results against Seraph spaces before grounding model responses

## Local Development

Run commands from `agents/`.

```sh
./scripts/venv_setup.sh
source .venv/bin/activate
# Start the local NATS dependency, or disable ingestion with KB_INGEST_ENABLED=false.
```

Run the API:

```sh
python -m app.main
```

Useful checks:

```sh
./scripts/validate.sh
./.venv/bin/pytest tests/ -v
```

The ingestion service starts with the FastAPI lifespan. For local runs without NATS, export `KB_INGEST_ENABLED=false`
before running `python -m app.main`.

## Docker

Build the image manually:

```sh
docker build -t seraph-agents .
```

Run the compose stack:

```sh
docker compose up -d --build
```

`compose.yaml` bind-mounts the repository into `/app` for local container development.

## Repair Existing Documents

If the canonical `documents` and `document_chunks` tables are empty because historical `SERAPH_FILE_CHANGED` messages were
already acknowledged before this storage path existed, run the one-shot repair command inside the agents container:

```sh
docker exec -w /app seraph-agents-api-1 uv run python -m app.repair backfill-documents
```

The command replays the current `SERAPH_FILE_CHANGED` JetStream history into canonical document storage and prints a short
`processed` / `failed` summary.

## Key Files

```text
app/main.py                  FastAPI entrypoint and runtime wiring (lifespan)
chat/agent_factory.py        Pydantic AI agent assembly (model, tools, deps)
chat/turns.py                One chat turn: streaming and persistence
documents/repository.py      Canonical document indexing persistence
retrieval/service.py         Spaces-aware retrieval orchestration
tests/                       Regression, API, and ingestion coverage
```
