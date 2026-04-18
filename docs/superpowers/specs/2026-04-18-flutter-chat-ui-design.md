# Flutter Chat UI Design

**Date:** 2026-04-18

**Status:** Approved in brainstorming session

## Goal

Add a production-quality chat feature to the Flutter app that matches the current React chat UI behavior, works across the app's currently supported platforms, and integrates into the existing navigation menu.

## Scope

- Upgrade the Flutter app's local SDK installation to the latest upstream stable Flutter release and resolve project issues exposed by that upgrade.
- Add a new `Chat` destination to the existing navigation menu alongside files, gallery, and settings.
- Implement conversation listing, conversation creation, deletion, message history, message sending, streamed assistant replies, and citations.
- Support responsive behavior across currently supported Flutter targets, with split-pane layout on larger screens and stacked navigation on smaller screens.
- Reuse the existing agents chat backend contract.

## Non-Goals

- Reworking the agents backend API or streaming protocol.
- Adding attachments, markdown rendering, rich text editing, or voice input.
- Creating a separate design language for chat that diverges from the existing Flutter app.
- Depending on a third-party chat UI package unless a concrete platform gap appears during implementation.

## Findings

- The React chat UI already defines the feature surface to match: session list metadata, delete flow, message history, streamed assistant output, and expandable citations.
- The agents backend already exposes the required endpoints:
  - `GET /api/v1/chat/sessions`
  - `POST /api/v1/chat/sessions`
  - `DELETE /api/v1/chat/sessions/{session_id}`
  - `GET /api/v1/chat/sessions/{session_id}/messages`
  - `POST /api/v1/chat/sessions/{session_id}/messages`
  - `GET /api/v1/chat/sessions/{session_id}/stream`
- The Flutter app already uses `Get`, `Dio`, and reactive controllers, and it already contains an SSE parsing pattern in `lib/src/search/search_service.dart`.
- The Flutter app currently has platform directories in-tree for Android, Linux, and web. The implementation should work on every platform target that remains enabled in the app after the SDK upgrade and dependency refresh.
- Current local Flutter SDK path is `/home/vortex/Development/flutter/flutter`. Flutter documentation indicates newer stable releases exist than the currently installed `3.29.2`.
- Flutter does not appear to provide a first-party built-in chat UI widget set that would replace the needed conversation/session UX, so a native feature implementation is the correct default.

## Design

### Architecture

The Flutter app will add a focused `chat` feature that follows existing app patterns instead of introducing a new architecture.

- Add a `ChatView` route and register it alongside existing app destinations.
- Extend the existing navigation menu to include a `Chat` entry.
- Add a `ChatController` that owns:
  - session list state
  - active session state
  - message history state
  - composer draft state
  - loading, sending, and streaming flags
  - active SSE stream lifecycle
- Add a `ChatService` that encapsulates REST and SSE calls to the agents backend.
- Keep view code split into small feature-local widgets only where it improves readability, such as session list items, message bubbles, citations, and composer.

The controller remains the feature coordinator, while the service stays responsible for backend transport and payload parsing.

### Data Flow

The Flutter chat feature will mirror the React app's behavior while reusing current auth and networking patterns.

- `ChatService` waits for login initialization before making requests.
- Authenticated requests attach the bearer token when a user session exists, matching existing app behavior.
- Session list loading uses `GET /api/v1/chat/sessions` and orders the UI using backend-provided timestamps.
- Selecting a session loads `GET /api/v1/chat/sessions/{session_id}/messages` and renders the full visible transcript.
- Creating a conversation uses `POST /api/v1/chat/sessions` and immediately inserts/selects the new session in the UI.
- Sending a message uses this sequence:
  - insert the user message optimistically
  - update the active session preview and running state immediately
  - `POST /api/v1/chat/sessions/{session_id}/messages`
  - open `GET /api/v1/chat/sessions/{session_id}/stream`
  - append or update an in-flight assistant message as SSE chunks arrive
- When streaming completes or fails, the controller closes the stream and reloads both the active message history and the session list so server state, final assistant text, citations, and status are reconciled.
- Switching sessions or deleting the active session always tears down the active stream first.

The SSE implementation should reuse the low-level parsing approach already present in the search feature rather than introducing a different streaming stack unless the SDK upgrade reveals a specific web compatibility issue.

### UI And Navigation

The chat feature should feel native to the current Flutter app while preserving the React UI's functionality.

- Add `Chat` to the existing navigation drop-down.
- Use responsive layouts:
  - large screens: two-pane layout with conversations on the left and the active thread on the right
  - small screens: conversation list first, then navigate into a dedicated thread view
- Large-screen conversation list includes:
  - `New chat` action
  - session headline
  - preview text
  - status indicator for running or finished sessions
  - delete action with confirmation
- Conversation thread view includes:
  - session title/header
  - scrollable message list
  - distinct user and assistant bubbles
  - expandable citations section for assistant messages with citations
  - composer anchored at the bottom with safe-area handling
- Empty states:
  - no conversations: `No conversations yet.`
  - no active conversation on large screens: `Select a conversation to start chatting.`

The visual styling should stay aligned with the Flutter app's existing Material language instead of trying to reproduce the React shell exactly.

### Error Handling

The feature should fail softly and remain navigable.

- Session list load failures show a recoverable error state without breaking the screen shell.
- Message history load failures keep the selected session and show an inline error.
- Send failures keep the draft text intact and surface an actionable error message.
- Stream connection failures or mid-stream disconnects trigger a refresh of the active session state and then show a recoverable error if reconciliation fails.
- A `409 no pending chat turn` stream response is treated as a recoverable sync condition rather than a fatal state.
- While a send request is in flight, the composer send action is disabled to avoid duplicate submissions.
- Navigation away from chat, session switches, and deletions always clean up stream subscriptions to avoid stale updates.

### Flutter SDK Upgrade

The feature work begins with bringing the Flutter app's local SDK installation up to the latest upstream stable release.

- Upgrade the SDK at `/home/vortex/Development/flutter/flutter` to the latest stable Flutter release.
- Refresh dependencies with `flutter pub get`.
- Run analysis and tests.
- Fix any breakages introduced by the SDK upgrade before landing chat feature changes.
- Only introduce an additional package if the upgrade exposes a concrete missing capability that is necessary for supported platforms.

## Testing

- Add service or controller tests for:
  - session loading
  - optimistic send flow
  - stream-driven assistant message updates
  - delete flow state updates
  - stream and request error recovery
- Add widget tests for:
  - large-screen split layout
  - small-screen stacked navigation flow
  - citation expansion rendering
  - empty states
  - representative error states
- Verify the upgraded app with at least:
  - `flutter analyze`
  - `flutter test`

## Implementation Notes

- Prefer minimal new abstractions and keep logic localized to the chat feature.
- Reuse app patterns for auth, dependency access, and reactive state rather than introducing a new state management library.
- Keep the backend contract unchanged unless implementation uncovers a real gap.
- Preserve behavior parity with the React UI as the source of truth for feature scope.
