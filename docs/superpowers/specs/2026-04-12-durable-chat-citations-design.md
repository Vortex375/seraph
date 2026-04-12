# Durable Chat Citations Design

## Goal

Add durable file-path citations for assistant chat turns and expose them in the debugging SPA together with full chat history when reopening a session.

## Scope

- Persist assistant-turn citations in `chat_turn_sources`
- Add a chat history API that returns the full ordered conversation for a session
- Include assistant citations in the history payload as a simple list of file paths
- Update the SPA to load and render full history on session selection
- Render assistant citations under assistant messages as a plain list of file paths

## Out Of Scope

- Rich citation cards or previews
- Click-to-open document actions
- Citation snippets beyond file paths
- Streaming structured citations live in the SSE payload

## Current Problem

The assistant can now mention file paths in response text, but citation metadata is not durable from the user’s point of view. The current SPA clears messages when selecting a session and has no history endpoint to reload the prior conversation. `chat_turn_sources` exists, but the UI does not read it and the chat API does not expose stored citations alongside prior messages.

## Design

### Persistence Model

Keep `chat_turn_sources` as the durable citation store keyed by:

- `session_id`
- `assistant_message_id`
- `provider_id`
- `path`

No schema change is required for the first version because a file-path list is sufficient.

### History API

Add `GET /api/v1/chat/sessions/{session_id}/messages`.

The endpoint returns the full ordered chat history for the session. Each item includes:

- `id`
- `role`
- `content`
- `created_at`
- `citations`

For user messages, `citations` is an empty list.

For assistant messages, `citations` is a deduplicated ordered list of stored file paths from `chat_turn_sources` for that assistant message.

This endpoint becomes the single read path for restoring the SPA conversation state.

### Message Reconstruction

Use the existing AgentScope working-memory tables (`message`, `message_mark`, `session`) as the source of persisted conversation text. Map stored messages into a compact API model rather than leaking raw AgentScope rows.

Only messages relevant to the visible conversation should be returned. Internal retrieval-memory helper entries such as the injected `<retrieved_knowledge>` user message should be filtered out so the restored history matches what the user saw during streaming.

### Citation Recording

Continue recording sources during `_stream_chat_events`. The new history endpoint reads from `chat_turn_sources`, so once a streamed assistant message has its sources persisted, those citations become durable and reloadable.

### SPA Behavior

When the user selects a session:

- fetch full history from the new messages endpoint
- replace the message panel with the restored ordered conversation

When rendering assistant messages:

- render the assistant text as today
- if `citations.length > 0`, render a plain list of file paths directly below the assistant message

This keeps the SPA debugging-oriented and simple.

## Data Flow

1. User sends a chat message.
2. The streamed assistant response is produced.
3. Source paths are persisted into `chat_turn_sources` for the assistant message id.
4. Later, session history is requested.
5. The API loads stored user/assistant messages and joins assistant-message citations from `chat_turn_sources`.
6. The SPA renders the restored conversation and citation path lists.

## Error Handling

- If history loading fails, the SPA shows an error and leaves the current panel unchanged.
- If a session has no stored citations for an assistant message, render the message without a citations list.
- If source persistence fails during streaming, the assistant message still streams normally; the only degradation is missing durable citations on reload.

## Testing

- API tests for the new history endpoint
- API tests proving assistant messages include stored citations and user messages do not
- Tests proving hidden retrieval helper messages are excluded from restored history
- SPA tests proving session selection loads history instead of clearing it
- SPA tests proving assistant citations render as file-path lists under messages

## Rationale

This is the smallest coherent feature that turns citations into durable user-visible behavior. It avoids over-design, keeps structured citation storage intact, and gives the debugging SPA the one thing it currently lacks: reloadable conversation state with explicit file-path provenance.
