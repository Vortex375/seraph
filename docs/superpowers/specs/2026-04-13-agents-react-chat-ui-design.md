# Agents React Chat UI Design

**Date:** 2026-04-13

**Status:** Approved by standing user approval

## Goal

Replace the current debug-only `agents/ui` SPA with a production-grade React/Vite chat application that keeps the existing FastAPI backend surface, adds richer session metadata for the sidebar, and supports deleting conversations.

## Scope

- Keep the agents service same-origin and backend-authenticated.
- Replace the current hand-built DOM UI with a React app built by Vite.
- Render a split-pane layout with a session list on the left and the active conversation on the right.
- Show session running state, auto-generated headline, preview text, and delete action in the session list.
- Show chat bubbles, streaming assistant output, and expandable citations in the conversation pane.
- Keep the existing streaming chat transport and extend the REST API only where the UI needs more metadata.

## Non-Goals

- Introducing client-side authentication.
- Adding markdown rendering, rich text editing, or attachments.
- Reworking the chat streaming protocol away from SSE.
- Adding a second frontend deployment target.

## Existing Constraints

- The FastAPI app already serves the UI on the same origin.
- Chat history lives in AgentScope SQLAlchemy memory tables, while citations and pending turns live in local SQLAlchemy models.
- The current UI is intentionally minimal and uses direct DOM manipulation plus an `esbuild` bundle.
- Session creation currently stores a title immediately, but the requested product behavior is an auto-generated summary headline.

## Design

### Backend

The backend remains the single source of truth for session state.

- `GET /api/v1/chat/sessions` will return enriched session summaries.
- Each session summary includes:
  - `id`
  - `user_id`
  - `title`
  - `headline`
  - `preview`
  - `status` with values `running` or `finished`
  - `created_at`
  - `updated_at`
  - `last_message_at`
- `DELETE /api/v1/chat/sessions/{session_id}` will delete the chat session and its associated AgentScope session/message rows.
- New sessions default to `New conversation`.
- When the first user turn is accepted for a default-titled session, the backend promotes the session title to a trimmed one-line headline derived from that first message.

Session summary computation uses existing persisted state instead of a new table:

- `status` is `running` when a session still has a pending turn.
- `preview` is the last non-empty line of the latest visible user or assistant message.
- `headline` is the stored session title, which becomes auto-generated after the first user message.

### Frontend

The frontend becomes a standard React/Vite app served from `agents/ui/dist`.

- Vite builds the static app with base path `/ui/`.
- FastAPI serves `dist/index.html` at `/` and static assets from `/ui`.
- React owns all UI state: session list, active session, message history, streaming state, errors, and delete confirmation.

Layout:

- Full-height split pane.
- Left sidebar contains branding, a `New chat` action, and the conversation list.
- Right pane contains the selected conversation transcript and composer.
- Empty state appears when no session is selected.

Conversation list item content:

- Running/finished indicator badge.
- Headline.
- Preview text.
- Relative ordering by `last_message_at` descending.
- Delete button with confirmation.

Conversation transcript:

- User and assistant messages render as distinct bubbles.
- Assistant bubbles with citations render a `<details>` section labelled `Sources`.
- Streaming messages append to the current conversation immediately, then the client refreshes server history at stream completion so persisted citations appear.

### Error Handling

- Sidebar fetch failures show an inline app error without breaking the layout.
- History fetch failures preserve the currently selected session while showing an error banner.
- Send failures preserve the typed draft.
- Stream termination triggers a history refresh first; if that fails, the UI shows a recoverable error.

## Testing

- Python API tests cover enriched session summaries, auto-headline behavior, and deletion.
- Python static UI tests verify the built Vite app is served from FastAPI.
- Frontend component tests cover session list rendering, delete flow, split-pane conversation behavior, streaming updates, and citations expansion.

## Implementation Notes

- Keep the API additive where possible by retaining `title` while adding `headline`, `preview`, and `status`.
- Keep session summary generation inside `chat/session_service.py` so the router stays thin.
- Prefer simple React state and effects over introducing a client-side state library.
- Use minimal CSS with strong spacing, readable contrast, and responsive behavior rather than introducing a component framework.
