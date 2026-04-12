# Seraph Agents

Seraph Agents is a FastAPI service built around an AgentScope runtime. It indexes canonical Seraph documents into Postgres/pgvector, applies spaces-aware retrieval before documents reach the model, and serves a minimal chat SPA directly from the API process.

## Runtime Overview

- `app/main.py` exposes the FastAPI entrypoint via `create_app()` and the module-level `app`
- AgentScope powers the conversational runtime, memory, and tool orchestration used by the chat API
- ingestion consumers persist canonical document records and chunks for retrieval
- retrieval filters results against Seraph spaces before grounding model responses
- the FastAPI app also mounts the minimal SPA used for multi-session chat

## Local Development

Run commands from `agents/`.

```sh
./scripts/venv_setup.sh
source .venv/bin/activate
# Start the local NATS dependency, or disable ingestion with KB_INGEST_ENABLED=false.
python -m app.main
```

Useful checks:

```sh
uv run pytest tests/test_dependency_cleanup.py -v
uv run pytest tests/test_fileprovider_client_integration.py -v
uv run pytest tests/test_ingestion_integration.py tests/test_chat_api.py tests/test_chat_streaming.py -v
uv run ruff check .
uv run mypy .
```

The ingestion service starts with the FastAPI lifespan. For local runs without NATS, export `KB_INGEST_ENABLED=false`
before running `python -m app.main`.

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
app/main.py                  FastAPI entrypoint and SPA mounting
chat/agent_factory.py        AgentScope runtime assembly
documents/repository.py      Canonical document indexing persistence
retrieval/service.py         Spaces-aware retrieval orchestration
ui/                          Minimal SPA served by FastAPI
tests/                       Regression, API, and ingestion coverage
```
