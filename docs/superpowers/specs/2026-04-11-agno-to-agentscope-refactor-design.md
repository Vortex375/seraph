# Agno to AgentScope Refactor Design

**Date:** 2026-04-11

**Status:** Approved for spec review

## Goal

Replace the current Agno/AgentOS-based `agents` package with a FastAPI + AgentScope implementation that:

- ingests user documents from the existing Python file provider client via NATS events,
- stores searchable document chunks in Postgres with pgvector,
- provides a multi-user, Seraph-authenticated chat agent grounded in those documents,
- serves a small SPA from the same service with support for multiple parallel chat sessions.

## Non-Goals

- Rebuilding the chat UI as a production Angular feature in this iteration.
- Adopting an AgentScope-native vector store in place of pgvector.
- Preserving Agno compatibility layers, AgentOS entrypoints, or dual-runtime support.
- Building a general-purpose multi-agent platform beyond the document-grounded chat use case.

## Current State

The existing `agents` package is based on Agno and AgentOS.

- `app/main.py` creates an `AgentOS` app and wires in the ingestion lifecycle.
- `ingestion/file_changed_consumer.py` already consumes Seraph file-change events and reads files through the Python file provider client.
- `knowledge/user_documents.py` uses Agno's pgvector-backed knowledge abstraction.
- `agents/documents_agent.py` defines a document assistant agent tied to the Agno knowledge base.

The existing webapp does not contain a reusable token-based auth client. It assumes same-origin backend-managed authentication and calls backend endpoints with browser-managed credentials.

## Design Summary

The replacement keeps the existing strengths of the current implementation while removing Agno/AgentOS entirely.

- FastAPI becomes the only HTTP application surface.
- AgentScope is embedded as the agent runtime layer, not the web server.
- Postgres remains the durable store for chat session metadata, AgentScope working memory, ingest state, and pgvector-backed document chunks.
- The existing NATS + file provider integration is retained and refactored to target the new ingestion/indexing services.
- Authentication is request-scoped and tied to the authenticated Seraph user identity.
- Document indexing is canonical to the file provider and path, while document access is enforced at retrieval time through Seraph spaces.
- AgentScope should own as much of the multi-turn chat runtime as possible, especially working memory, knowledge injection, streaming, and turn execution.
- The UI is a small SPA served by FastAPI on the same origin, intentionally thin so it can later be replaced by a richer production UI.

## Architecture

The new `agents` service is split into four layers.

### 1. API Layer

The API layer exposes:

- REST endpoints for chat sessions and chat history,
- a streaming endpoint for assistant responses,
- document index status endpoints for debugging and observability,
- static asset serving for the small SPA.

This layer owns request validation, authentication handoff, response shaping, and transport concerns only.

### 2. Auth Layer

The auth layer resolves the current Seraph user from the incoming same-origin authenticated request. It provides a stable internal `AuthenticatedUser` object containing at least:

- `user_id`,
- any stable username or display metadata available from Seraph,
- authorization decisions for resource ownership checks.

Every API call and background operation that reads or writes user-scoped data must depend on this resolved identity.

### 3. Application Layer

The application layer owns business workflows:

- chat session lifecycle,
- turn handling,
- retrieval orchestration,
- prompt assembly,
- ingestion coordination,
- document indexing/upsert logic,
- source citation shaping,
- multi-user ownership enforcement.

This layer contains the AgentScope integration boundary so the rest of the service is not coupled directly to framework-specific types.

### 4. Infrastructure Layer

The infrastructure layer owns:

- SQLAlchemy sessions and migrations,
- pgvector queries and document index persistence,
- NATS connections and JetStream consumer lifecycle,
- file provider client integration,
- model and embedding client construction,
- tracing and structured logging setup,
- static asset build/serving glue.

## Module Boundaries

The refactor should replace the current layout with explicit responsibility-driven modules.

- `app/`: FastAPI application bootstrap, lifespan wiring, static SPA serving.
- `api/`: routers, request/response schemas, streaming transport.
- `auth/`: user resolution from Seraph-authenticated requests.
- `chat/`: session service, AgentScope agent factory, turn runner, prompt policy.
- `retrieval/`: canonical chunk search, source shaping, spaces-aware authorization filtering.
- `knowledge/`: custom AgentScope `KnowledgeBase` adapter backed by Seraph retrieval.
- `ingestion/`: event consumer, content extraction, chunking, idempotent upsert/remove.
- `documents/`: SQLAlchemy models and repository logic for documents and chunks.
- `spaces/`: client for resolving user-accessible spaces from Seraph.
- `db/`: engine/session setup and shared persistence helpers.
- `ui/`: source for the small SPA, built and served by FastAPI.

Agno-specific modules and AgentOS bootstrap files should be removed rather than retained behind compatibility wrappers.

## Data Model

The persistent model should make user isolation explicit.

### Chat Tables

`chat_sessions`

- `id`
- `user_id`
- `title`
- `created_at`
- `updated_at`
- `last_message_at`

Multi-turn message history should use AgentScope's `AsyncSQLAlchemyMemory` tables rather than a parallel custom transcript store. The service should treat the AgentScope memory backend as the source of truth for chat messages within a session.

`chat_turn_sources`

- `id`
- `session_id`
- `assistant_message_id`
- `user_id`
- `document_id`
- `chunk_id`
- `score`
- `path`
- `provider_id`
- `snippet`

`chat_turn_failures`

- `id`
- `session_id`
- `assistant_message_id` nullable
- `user_id`
- `error_code`
- `error_message`
- `created_at`

### Document Index Tables

`documents`

- `id`
- `provider_id`
- `file_id`
- `path`
- `mime`
- `size`
- `mod_time`
- `content_hash`
- `ingest_status`
- `last_ingested_at`
- `last_error` nullable

`document_chunks`

- `id`
- `document_id`
- `chunk_index`
- `content`
- `token_count` or character-count metadata
- `embedding` (`vector` via pgvector)
- `metadata` JSONB

Uniqueness constraints should prevent duplicate active records for the same canonical file identity. The primary identity should be canonical provider metadata such as `(provider_id, path)` with `file_id` retained when present from file-index events.

## Authentication and Access Control

The service must support multiple authenticated Seraph users from day one.

- The backend is authoritative for user identity.
- The SPA must not manage bearer tokens or implement a parallel auth system.
- Chat session ownership is filtered by `user_id`.
- Document retrieval is filtered by the spaces that the current user is allowed to access.
- Access to another user's session or to documents outside the caller's visible spaces must return `404`, not `403`, to avoid leaking resource existence.

The concrete mechanism for resolving the user should reuse the same backend-managed session/cookie model used by the existing webapp. If Seraph already exposes identity information through trusted headers or a same-origin session endpoint, the agents service should reuse that path rather than inventing a new login scheme.

### Spaces Model

Seraph authorization is space-based, not user-owned-file based.

- A space contains a list of users.
- A space also contains one or more `SpaceFileProvider` mappings.
- Each mapping links a `spaceProviderId` to a canonical `providerId` and a root `path`.
- A user can access a file when they belong to a space whose `providerId` matches the file's canonical provider and whose configured root path is a prefix of the file path.

Because of this, indexed documents must not be scoped to a single user. Access is determined dynamically from the current user's visible spaces.

## Ingestion Pipeline

The existing event-driven ingestion model remains, but the Agno knowledge dependency is removed.

### Flow

1. A JetStream consumer receives `FileChangedEvent` messages.
2. The event is decoded and validated.
3. Directory events, unsupported MIME types, and oversized files are skipped with structured logs.
4. For create/update events, the service reads the file through the existing Python file provider client.
5. The file is converted into normalized text content.
6. The text is chunked into retrieval-friendly segments.
7. Embeddings are generated for each chunk.
8. Existing rows for that canonical file identity are replaced idempotently.
9. For delete events, document and chunk rows are removed.

### Supported Formats

The first iteration should support the same practical set already implied by the current consumer:

- plain text and common `text/*` types,
- PDF,
- JSON,
- XML,
- CSV,
- JavaScript/SQL-like text payloads that can be decoded as UTF-8 replacement text.

Binary formats outside those readers are ignored for now.

### Canonical Index Identity

The existing event payload provides canonical file metadata such as `provider_id`, `path`, and `file_id`. This is sufficient for indexing because access control is not determined during ingestion.

Documents and chunks should be indexed canonically by provider and path rather than by user or by space alias. The same canonical file may later be visible through multiple spaces or become visible to different users as membership changes.

## Retrieval Design

Retrieval stays custom and pgvector-backed instead of adopting an AgentScope-native vector store.

### Why

- pgvector is already an accepted dependency in this repo.
- spaces-based filtering must be explicit and easy to audit,
- the ingestion schema needs Seraph-specific metadata and idempotency semantics,
- the retrieval layer should stay stable even if the agent runtime changes later.

### AgentScope Integration

Retrieval should be exposed to AgentScope through a custom `KnowledgeBase` implementation, for example `SeraphKnowledgeBase`, rather than by manually stitching retrieved text into prompts.

This knowledge adapter should:

- accept the current `user_id` and session context,
- embed the query,
- fetch the current user's visible spaces,
- translate those spaces into allowed canonical `(provider_id, path-prefix)` scopes,
- query pgvector-backed chunks using those scopes,
- return AgentScope `Document` objects with provenance metadata for citation.

This keeps AgentScope's built-in knowledge retrieval flow active while preserving Seraph-specific authorization and storage rules.

### Behavior

For each user chat turn:

1. Generate an embedding for the query.
2. Resolve the current user's visible spaces from Seraph.
3. Convert those spaces into allowed canonical provider/path scopes.
4. Query `document_chunks` constrained to those scopes.
5. Rank by vector similarity, with room for later lexical/hybrid improvements.
6. Return the top chunks with source metadata.
7. Optionally collapse duplicate neighboring chunks from the same document to improve context quality.

The retrieval layer's external contract should be AgentScope `Document` objects returned by the custom knowledge base. Internal helpers may still use a narrower `RetrievedContext` structure.

## Chat Runtime Design

The chat runtime should use AgentScope for as much of the conversational state and execution path as practical.

### AgentScope-First Responsibilities

The default session runtime should use:

- `ReActAgent` for turn execution,
- `AsyncSQLAlchemyMemory` for multi-turn working memory,
- the custom `SeraphKnowledgeBase` for retrieval-aware context injection,
- `stream_printing_messages(...)` as the bridge to SSE streaming,
- `Toolkit` and hook/middleware surfaces for any Seraph-specific tools or tracing.

The service should not reimplement chat-history accumulation, knowledge injection, or token/message streaming when AgentScope already provides those capabilities.

### Turn Flow

1. Resolve authenticated user.
2. Load or create the requested chat session for that user.
3. Create or reuse an AgentScope agent configured with `AsyncSQLAlchemyMemory(session_id, user_id)` and `SeraphKnowledgeBase(user_id, session_id)`.
4. Submit the user message to the agent.
5. Let AgentScope load prior conversation state from its memory backend.
6. Let AgentScope invoke the custom knowledge base as part of the turn.
7. Stream the assistant response through the SSE adapter.
8. Persist source citations and any failure metadata alongside the completed turn.
9. Return or stream the completed turn payload to the client.

### AgentScope Responsibilities

AgentScope should handle:

- model abstraction,
- turn execution,
- short-term working memory for a turn/session,
- knowledge retrieval injection through the knowledge base abstraction,
- tracing hooks,
- streaming message emission.

### Application Responsibilities

The surrounding service should handle:

- chat session metadata,
- user ownership,
- spaces resolution and access-control filtering,
- citation persistence,
- message acceptance and failure semantics,
- HTTP and streaming contracts.

### Session Persistence

The first iteration should rely on `AsyncSQLAlchemyMemory` for durable multi-turn chat history.

If later testing shows the application needs to persist more AgentScope module state than working memory alone, the service should add a Postgres-backed `SessionBase` implementation rather than inventing a separate session serialization model.

### Prompt Policy

The system prompt must instruct the agent to:

- answer from retrieved document context first,
- cite sources using file path or document metadata,
- say clearly when relevant information was not found,
- avoid inventing facts not supported by retrieved context.

## Multi-Session UI

The UI is a small SPA served by FastAPI on the same origin.

### Required Features

- show the current user's chat sessions,
- create a new session,
- open an existing session,
- rename or delete a session,
- send messages and receive streamed replies,
- render source citations attached to assistant replies,
- support multiple parallel chat sessions by persisting each thread independently.

### Intentional Constraints

- Keep styling and architecture minimal.
- Put business rules in backend APIs, not the SPA.
- Use stable JSON contracts so a future Angular or richer client can replace the SPA without changing core backend logic.

## API Shape

The exact endpoint names can be finalized in implementation, but the service should expose a stable versioned surface similar to:

- `GET /api/v1/chat/sessions`
- `POST /api/v1/chat/sessions`
- `PATCH /api/v1/chat/sessions/{session_id}`
- `DELETE /api/v1/chat/sessions/{session_id}`
- `GET /api/v1/chat/sessions/{session_id}/messages`
- `POST /api/v1/chat/sessions/{session_id}/messages`
- `GET /api/v1/documents/status`

The first iteration should use SSE for assistant response streaming. The transport contract should be:

- `POST /api/v1/chat/sessions/{session_id}/messages` persists the user message and creates the assistant turn,
- `GET /api/v1/chat/sessions/{session_id}/stream` opens an SSE stream for the active turn in that session.

The streaming boundary should stay isolated so a future UI can switch to WebSockets without rewriting chat orchestration.

## Error Handling

### Ingestion

- Unsupported or oversized files are skipped and logged.
- File read and transient processing failures trigger retry via `nak`.
- Upserts must be idempotent so retries do not duplicate chunks.
- Permanent parse failures should set a document ingest status and preserve the last error for inspection.

### Chat

- Missing retrieval results should produce an explicit grounded fallback answer, not hallucinated content.
- Provider or model outages should surface as `503`-class errors.
- If a user message is accepted before generation fails, the failure must be visible in the session history rather than silently disappearing.
- Ownership failures return `404`.

## Observability

The service should preserve the repo's observability expectations.

- structured logs for ingestion, retrieval, and chat turn execution,
- OpenTelemetry setup for FastAPI and AgentScope,
- trace correlation across HTTP request, retrieval, model call, and NATS ingestion paths where available,
- metrics or structured counters for indexed files, skipped files, failed ingests, chat turns, and retrieval misses.

## Testing Strategy

Implementation must use TDD for new behavior.

### Unit Tests

- auth resolution and request user extraction,
- session ownership checks,
- spaces-to-provider/path authorization filtering,
- retrieval filtering and ranking behavior,
- AgentScope knowledge adapter behavior,
- ingestion chunking and upsert/remove logic,
- citation shaping.

### Integration Tests

- NATS-driven ingestion using the existing file provider test harness patterns,
- Postgres/pgvector-backed retrieval,
- API tests covering multi-user session isolation,
- retrieval tests covering space-based visibility,
- streaming chat endpoint behavior,
- parallel session behavior for the same user.

### End-to-End Verification

Use the local Docker compose setup once the major pieces are wired:

- start dependencies,
- ingest representative documents,
- open the SPA,
- create multiple sessions,
- verify grounded answers and citations,
- verify cross-user isolation.

## Migration Plan Shape

The eventual implementation plan should break the work into the following slices:

1. Replace application bootstrap and dependency graph with FastAPI.
2. Introduce persistent schemas for session metadata, AgentScope-backed memory persistence, and document chunks.
3. Refactor ingestion away from Agno knowledge into canonical indexing services.
4. Add space-aware retrieval through a custom AgentScope knowledge adapter.
5. Add authenticated multi-session APIs.
6. Add the small SPA and streaming UX.
7. Remove remaining Agno/AgentOS code and dependencies.
8. Run integration and Docker-based end-to-end verification.

## Open Risks

These are design risks to actively address in implementation, not unresolved spec placeholders.

### 1. Space resolution performance

Retrieval now depends on resolving visible spaces for each user and translating them into canonical provider/path scopes. The implementation should cache or batch that work carefully enough that it does not dominate retrieval latency.

### 2. Chunking quality

Poor chunking will degrade retrieval quality. Start with a simple deterministic chunker, but keep the implementation isolated so chunking policy can be improved without changing API or storage contracts.

### 3. Streaming semantics

SSE is preferred for simplicity, but the implementation should keep the transport boundary thin in case the future production UI prefers WebSockets.

### 4. AgentScope session abstractions

The service should avoid overcommitting to AgentScope persistence abstractions if they complicate the explicit Postgres data model required for Seraph. AgentScope should remain the runtime, not the source of truth for business entities.

## Acceptance Criteria

The refactor is complete when all of the following are true:

- No Agno or AgentOS runtime code remains in the `agents` package.
- The service runs as FastAPI and serves both APIs and the small SPA.
- Authenticated Seraph users can create multiple chat sessions and talk to the agent in parallel.
- Chat answers are grounded in canonically indexed documents that are filtered by the caller's accessible spaces and include citations.
- The ingestion pipeline uses the existing Python file provider client and indexes supported documents into pgvector-backed storage.
- Multi-user isolation is enforced for chat sessions, and document visibility is enforced through Seraph spaces during retrieval.
- Automated tests cover core units and integrations, and Docker-based end-to-end verification passes.
