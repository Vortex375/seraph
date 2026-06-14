# Chat Single-Request Streaming Design

## Summary

Replace the current split chat turn protocol (`POST /messages` followed by `GET /stream`) with a single streaming request per user turn. The backend should persist conversation state and complete assistant generation independently of the client connection. The frontend should manage only UI state such as whether a stream is currently visible, whether a placeholder assistant bubble is shown, and when to refresh the conversation.

This design removes the `PendingChatTurn` claim/unclaim model entirely. That state is delivery coordination state, not domain state, and it is the source of the current stale-claim failure mode.

## Goals

- Eliminate backend claim/unclaim state for chat streaming.
- Make one HTTP request represent one logical chat turn.
- Ensure a turn continues to completion even if the client disconnects.
- Persist final successful assistant output for later reload.
- Persist failure state, including partial assistant output if generation fails mid-stream.
- Keep frontend and backend state ownership cleanly separated.

## Non-Goals

- No durable distributed job system in this change.
- No attempt to support reconnecting to a still-running stream in the middle of a turn.
- No redesign of citations/source recording beyond adapting it to the new turn lifecycle.

## Problems In The Current Design

The current flow is:

1. Frontend `POST /sessions/{id}/messages`
2. Backend inserts `PendingChatTurn`
3. Frontend `GET /sessions/{id}/stream`
4. Backend claims that row, streams, then consumes or unclaims it

This creates a database-backed coordination protocol between two separate HTTP requests. The backend must persist transient state such as:

- whether a turn exists but has not started
- whether a turn has been claimed by a stream
- whether a later request is allowed to start another stream
- whether a failed stream should unclaim or consume the row

That state is not conversation state. It exists only because a single logical turn is split across two transport operations. The stale claimed row that produced `409 no pending chat turn` is a direct consequence of this coupling.

## Design Overview

### API Contract

Replace the current two-step send-and-stream flow with a single endpoint:

- `POST /api/v1/chat/sessions/{session_id}/messages/stream`

Request body:

```json
{
  "message": "What did you find?"
}
```

Response:

- `text/event-stream`
- Emits events for exactly one assistant turn

The existing non-streaming `POST /sessions/{session_id}/messages` and `GET /sessions/{session_id}/stream` endpoints should be removed once the frontend is migrated, or temporarily retained only for controlled compatibility if needed during rollout.

### State Ownership

Backend owns persistent domain state:

- chat sessions
- persisted user messages
- persisted assistant messages
- assistant turn failure records
- source/citation records

Frontend owns ephemeral UI state:

- whether a send is currently in progress
- the optimistic local user message bubble
- the optimistic local assistant placeholder bubble
- whether the visible stream subscription is active
- whether to refresh history after completion

The backend does not persist "stream claimed", "waiting for frontend to connect", or similar transport coordination state.

## Turn Lifecycle

For one `POST /messages/stream` request:

1. Validate session ownership.
2. Persist the user message immediately.
3. Create a persisted assistant turn record in a running state.
4. Start assistant generation in backend-owned execution.
5. While generation proceeds:
   - emit SSE deltas to the connected client if it remains connected
   - accumulate assistant content server-side
   - record citations/sources as they become known
6. On successful completion:
   - persist the completed assistant message content
   - mark the assistant turn as finished
   - persist citations/sources
7. On generation failure:
   - persist the partial assistant content if any
   - persist failure details
   - mark the assistant turn as failed
8. If the client disconnects at any point after the turn starts:
   - continue generation in the backend
   - finish persistence exactly as if the client had remained connected

## Persistence Model

### Remove `PendingChatTurn`

Delete the `pending_chat_turns` table and all backend logic that exists only to manage claim/unclaim/consume state.

### Persist Assistant Turn State Explicitly

The system still needs persistent truth for in-progress, finished, and failed assistant turns, but this should be modeled as domain state attached to the assistant message itself, not as a transport queue.

Recommended direction:

- extend persisted chat message history to support assistant message status
- add optional failure metadata for assistant messages

A practical shape is:

- user message: persisted once, always complete
- assistant message:
  - `status`: `running | finished | failed`
  - `content`: accumulated partial or final content
  - `error`: nullable failure description

The exact schema can be implemented either by extending the existing chat message persistence model or by adding a closely related assistant-turn table, but the state must represent conversation truth, not stream-claim bookkeeping.

### History API

`GET /sessions/{id}/messages` must return enough information for the frontend to reconstruct the conversation on reload, including:

- completed assistant responses
- failed assistant responses
- partial assistant content from failed turns if present
- assistant status when relevant
- citations/sources already associated with the assistant message

This implies `ChatMessageResponse` likely needs to expand beyond `{id, role, content, created_at, citations}` to include at least message status and optional error information for assistant messages.

## Backend Execution Model

### Recommended First Step: In-Process Turn Runner

The simplest implementation is an in-process turn runner created by the streaming request.

Responsibilities of the turn runner:

- own the assistant generation lifecycle
- own persistence of assistant message state
- own final completion/failure transitions
- publish stream events to zero or more subscribers

Responsibilities of the HTTP layer:

- start the runner for the new turn
- subscribe the current SSE response to runner events
- detach cleanly if the client disconnects

Important property:

- the runner continues even if the HTTP response is cancelled

This is the key behavioral change. Today the stream generator and the HTTP response lifetime are too tightly coupled. In the new design, the stream response is only a consumer of turn events, not the owner of turn completion.

### Why Not A Durable Job System Yet

A queue/worker architecture would also solve the problem, but it adds operational and architectural scope that is not necessary for this fix. This design should preserve a clean abstraction boundary so a future worker-based implementation is possible without another API change.

## SSE Event Model

The stream still carries assistant updates for one turn. The event payloads should remain incrementally useful to the frontend.

At minimum the stream should carry:

- assistant message id
- delta or snapshot content updates
- final completion event
- error event if generation fails while the client is still connected
- citations when available

The stream payload format may remain close to the current format to minimize frontend churn, but it should be documented as a one-turn stream rather than a session-level claimable stream.

## Frontend Behavior

The Flutter chat controller should change from:

1. optimistic local user message
2. optimistic local assistant placeholder
3. `sendMessage(sessionId, draft)`
4. `streamAssistantReply(sessionId)`

to:

1. optimistic local user message
2. optimistic local assistant placeholder
3. `sendMessageAndStreamReply(sessionId, draft)` via a single streamed POST

Frontend responsibilities after this change:

- do not model backend queue/claim state
- show stream updates as they arrive
- mark the local stream as done on completion or error
- refresh conversation history after stream completion when appropriate
- on page reload or session reopen, trust `listMessages()` as the source of truth

If the client disconnects, the frontend does nothing special beyond later reloading messages. The backend-completed turn should already be persisted.

## Failure Semantics

### Client Disconnect

Required behavior:

- assistant generation continues after disconnect
- final assistant message is persisted when generation succeeds
- next history load shows the completed response

### Mid-Generation Provider Failure

Required behavior:

- persist the failure state
- persist partial assistant content if any exists
- preserve any sources/citations already attached to the turn
- next history load shows the failed turn rather than silently hiding it

If the client is still connected when the failure happens, it should also receive a stream error event.

## Migration Plan

1. Introduce new single-request streaming endpoint.
2. Introduce assistant persisted status/error model in message history.
3. Move backend generation orchestration to a turn runner that is not owned by the HTTP response lifetime.
4. Update Flutter client to use single streamed POST.
5. Update history rendering to support assistant `running`/`failed` state as persisted history.
6. Remove `PendingChatTurn` model, cleanup code, and related tests.
7. Add migration to drop obsolete storage once rollout is complete.

## Testing Strategy

### Backend

Add coverage for:

- streamed POST persists user message immediately
- successful turn persists completed assistant output
- client disconnect does not stop backend completion
- provider failure persists failure state and partial output
- history endpoint returns failed/completed assistant messages with status
- no `PendingChatTurn` claim logic remains in the turn lifecycle

### Frontend

Add coverage for:

- single streamed POST is used for sending a turn
- assistant placeholder updates incrementally from the streamed POST response
- stream completion clears local sending state
- stream error surfaces correctly without requiring a second request
- history reload shows persisted failed/completed turns

### End-To-End

Verify:

- normal streaming conversation
- closing the browser mid-stream still results in a completed persisted assistant reply
- upstream failure yields persisted failed state visible after reload

## Risks And Mitigations

### Risk: In-process background runners are lost on process crash

Mitigation:

- acceptable for this scope as long as failures are explicit and recoverable
- preserve a clean abstraction so a future durable worker implementation can replace the runner internals without changing the API

### Risk: Partial persistence semantics become inconsistent

Mitigation:

- define assistant message status transitions explicitly: `running -> finished` or `running -> failed`
- keep final persistence in one owner component, the turn runner

### Risk: Frontend optimistic placeholder diverges from persisted history

Mitigation:

- refresh authoritative history after stream completion and on reopen
- use assistant message id from stream events so local placeholder can reconcile with persisted history

## Recommendation

Implement the single-request streamed POST design with an in-process backend turn runner and remove `PendingChatTurn` entirely. This directly addresses the current stale-claim failure mode and aligns state ownership with the actual domain boundaries:

- backend persists conversation truth
- frontend manages only ephemeral UI streaming state

That is a materially simpler and more robust design than repairing the existing claim/unclaim flow.
