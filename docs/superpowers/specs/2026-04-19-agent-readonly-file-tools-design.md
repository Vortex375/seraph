# Agent Read-Only File Tools Design

## Goal

Make the agents chat more useful for real file-based work by adding read-only tools that let the agent search for files by name, browse directories, inspect file metadata, and read file contents when the backing provider supports it. Agent replies should also carry direct file links so the Flutter chat UI can open the existing file viewer when a user taps a cited file.

## Current Context

- The agents service currently creates a `ReActAgent` with an empty `Toolkit()` and a single `SeraphKnowledgeBase` source in `agents/chat/agent_factory.py`.
- The knowledge path only covers indexed textual content, so non-ingested files and binary assets are invisible to the agent today.
- The repository already has two access paths we can reuse instead of inventing a new storage API:
  - name-based file search via the NATS-backed search pipeline (`api-gateway/search/search.go`, `file-indexer/fileindexer/search.go`)
  - read-oriented file operations via the Python NATS file-provider client in `agents/fileprovider/client.py`
- The Flutter app already has path-based navigation into `FileViewerView` using `?path=...`, and the chat UI already renders assistant citations as a list in `app/seraph_app/lib/src/chat/chat_widgets.dart`.

## User Experience

The agent keeps its current document-assistant behavior, but it gains explicit read-only file awareness:

- If a user asks for a file by name, the agent can search accessible files even if they were never ingested into the knowledge store.
- If a user asks what is in a folder, the agent can list directory entries within the user’s allowed scopes.
- If a user asks about file size, modification time, or whether something is a directory, the agent can inspect metadata directly.
- If a user asks to inspect a readable file, the agent can read a bounded portion of the file and summarize it.
- When the agent references a concrete file, the response includes a structured citation that the Flutter client can open in the existing file viewer.

The agent remains strictly read-only. No tool may create, rename, move, or delete files.

## Design Options

### Option 1: Agent-Local Read-Only Tools Over Existing NATS Services

Add a small read-only tool layer inside `agents` that uses the existing spaces client, search flow, and file-provider client.

Pros:
- Reuses existing permissions and storage boundaries
- Keeps the agent’s read capabilities close to the agent runtime
- Avoids expanding the public API surface just to serve the model
- Works for both indexed and non-indexed files

Cons:
- Requires some tool wiring in the Python agent layer
- Needs a new structured citation shape shared with Flutter

### Option 2: New Agents API Endpoints For File Search/Browse/Read

Expose explicit FastAPI endpoints for file search, stat, list, and read, then let the agent call them indirectly.

Pros:
- Clean HTTP contracts
- Easier to inspect manually

Cons:
- Adds public API surface not needed by the mobile app today
- Duplicates permission and orchestration work between HTTP and agent layers
- Still needs the same NATS/file-provider integrations underneath

### Option 3: Expand Knowledge Ingestion Only

Try to ingest more file types and avoid direct file tools.

Pros:
- Keeps the agent on a pure RAG model

Cons:
- Does not solve directory browsing, metadata lookup, or live inspection of non-indexed files
- Still weak for binary files and operational questions like “what files are in this folder?”

## Recommended Approach

Use Option 1.

It is the smallest architecture change that solves the actual user need: give the agent read-only access to the same file universe the user can browse, while preserving space-based permissions and avoiding write capabilities entirely.

## Architecture

### 1. Read-Only File Access Service In `agents`

Add a focused service layer in `agents` that exposes four high-level operations:

- `search_files(query)`
- `list_directory(provider_id, path)`
- `stat_file(provider_id, path)`
- `read_file(provider_id, path)`

Internally this service will:

- fetch the user’s allowed scopes from `SpacesClient`
- validate that every requested `provider_id` + `path` pair remains inside those scopes
- use the existing NATS file search behavior for `search_files`
- use the existing Python `FileProviderClient` for `stat`, `readdir`, and bounded file reads

This service should present normalized, agent-friendly results and hide transport details like NATS subjects, provider remapping, and Avro payloads.

### 2. Tool Surface For The Agent

Register a narrow set of tools on the agent `Toolkit()` in `agents/chat/agent_factory.py`.

Tool responsibilities:

- `find_files_by_name(query: str)`
  - returns a short list of matching files with provider, path, and a deep-link target
- `list_files(provider_id: str, path: str)`
  - returns directory entries with type, size, and modified time when available
- `get_file_metadata(provider_id: str, path: str)`
  - returns metadata for a single path
- `read_file_excerpt(provider_id: str, path: str)`
  - returns a bounded textual excerpt or a clear unsupported/binary message

The tools will not expose any mutating operations. The prompt should explicitly tell the agent to use them when knowledge retrieval is insufficient or when the user is asking about concrete files/folders.

### 3. Scope Enforcement

Scope enforcement must happen in the agent-side file access service, not just in the prompt.

Rules:

- `provider_id` must belong to one of the user’s space scopes
- requested path must normalize to a canonical POSIX path
- normalized path must stay within the allowed path prefix for that provider
- `..` path escapes are rejected
- reads are bounded by size and optionally by file extension / decode success

This matches the existing security model already used by retrieval and document-status filtering.

### 4. Search Reuse

For file name search, reuse the existing search request/reply contract rather than duplicating file-indexer queries in Python.

Implementation shape:

- add a lightweight Python search client in `agents` that publishes `events.SearchRequest` over NATS
- collect `SearchAck` / `SearchReply` responses like the Go gateway does today
- normalize results into a list of file references

This keeps search semantics aligned with the existing product behavior and lets improvements in the search subsystem benefit both app search and agent search.

### 5. File Read Semantics

`read_file_excerpt` should be intentionally conservative.

Behavior:

- stat the file first
- reject directories
- reject files above a bounded size threshold for inline reading
- read only the first bounded chunk of bytes
- decode as UTF-8 with graceful failure
- if decoding fails, return a clear message that metadata is available but textual content is not directly readable

That gives the agent enough power to inspect many common files without turning the chat into an unrestricted file dump mechanism.

### 6. Structured File References And Citations

Plain citation strings are no longer enough for deep linking. Add a structured file reference shape to the agents chat payloads and Flutter chat models.

Recommended shape:

```json
{
  "provider_id": "provider-a",
  "path": "/team/spec.md",
  "label": "/team/spec.md",
  "route": "/view?path=provider-a/team/spec.md"
}
```

Notes:

- The persisted chat history can still keep a simple human-readable label if needed for backward compatibility, but the live and stored response model used by the app should carry structured file references.
- The UI should render the label while using the structured target for navigation.
- Existing document citations from knowledge retrieval should be upgraded into this same structured file-reference shape so live replies and loaded history behave consistently.

### 7. Flutter Navigation

The Flutter app already opens `FileViewerView` via `Get.toNamed('${FileViewerView.routeName}?path=...')`.

To make chat links work reliably:

- add a small chat file-link model and navigation helper
- render citations as tappable rows instead of plain text
- when tapped, navigate to `FileViewerView.routeName` with the resolved file path
- preserve existing display of path text while making it interactive

If the provider-prefixed path needs normalization before file viewing, centralize that conversion in one helper shared by chat and search flows.

## Data Model Changes

### Agents API

Extend chat streaming/history payloads so assistant citations can be structured objects instead of plain strings.

Suggested response model evolution:

- current: `citations: list[str]`
- target: `citations: list[FileCitationResponse]`

Where `FileCitationResponse` contains:

- `provider_id: str`
- `path: str`
- `label: str`

The streaming path should emit the same citation shape as the history path.

### Flutter Models

Replace `List<String>` assistant citations with a small typed object list in `chat_models.dart`, while keeping parsing tolerant of legacy string-only history.

That allows the mobile app to:

- render labels
- preserve deep-link targets
- stay compatible with older stored or partial payloads

## Error Handling

Agent tools should fail in user-comprehensible ways:

- out-of-scope path: “I can’t access that location.”
- missing file: “That file could not be found.”
- binary/unreadable file: “I can inspect metadata but can’t read that file as text.”
- large file: “That file is too large to read inline; here is the metadata and a direct link.”
- search transport failure: “I couldn’t search files right now.”

These messages should be tool outputs, so the model can incorporate them into a natural answer without hallucinating successful access.

## Testing Strategy

### Agents

Add tests for:

- scope filtering and path normalization for file-tool requests
- NATS-backed search client request/reply handling
- directory listing and metadata adaptation from `FileProviderClient`
- bounded text reads and unreadable/binary fallbacks
- agent factory wiring to ensure the new tools are registered
- chat API serialization of structured citations

### API Gateway

Minimal or no gateway changes are preferred. If proxy routing must expand for new agents endpoints, add focused proxy tests there.

### Flutter

Add tests for:

- parsing structured citations from chat history and SSE events
- rendering chat citations as tappable links
- navigating from a citation tap into `FileViewerView`
- preserving old string citations for backward compatibility if older history can still exist

## Non-Goals

- no write, rename, move, or delete tool support
- no general shell-like remote file manipulation
- no attempt to ingest every binary format into the knowledge store as part of this work
- no redesign of the existing global search UI beyond whatever is needed to share path/link helpers

## Implementation Notes

- Prefer a separate read-only service module in `agents` over embedding transport logic directly inside `agent_factory.py`.
- Reuse `SpacesClient` and `FileProviderClient` directly; do not add a parallel permission system.
- Keep tool outputs compact and deterministic so the model can reliably use them.
- Keep the first version bounded: name search, list, stat, and text excerpt are enough to materially improve usefulness.

## Success Criteria

- The agent can discover files by name even when they are not in the knowledge index.
- The agent can inspect folders and file metadata within the user’s permitted spaces.
- The agent can read bounded textual excerpts from accessible files.
- The agent cannot mutate files through any exposed tool.
- Chat replies include direct, tappable file links that open the Flutter file viewer.
- Knowledge-derived citations and file-tool-derived citations share one structured file reference model.
