# Flutter Chat Streaming Fix Design

**Date:** 2026-04-18

**Status:** Approved in brainstorming session

## Goal

Fix the Flutter chat screen so streamed assistant updates appear immediately in the open conversation, and allow users to submit a chat message by pressing Enter.

## Scope

- Fix the chat conversation pane so optimistic sends and streamed assistant updates repaint without needing to reopen the session.
- Add keyboard submission for the chat composer on Flutter web and other desktop-style targets.
- Cover the regression with focused widget tests.

## Non-Goals

- Changing the agents backend streaming protocol or endpoints.
- Redesigning the chat layout, message cards, or session list.
- Adding markdown, rich text, attachments, or new composer controls.

## Findings

- Browser reproduction on `http://localhost:8080/app/#/chat` shows the expected `POST /api/v1/chat/sessions/{id}/messages` request and a live `GET /api/v1/chat/sessions/{id}/stream` request, but the visible conversation does not refresh after send.
- The chat controller already appends an optimistic user message, inserts a placeholder assistant message, and updates that assistant message as stream events arrive.
- `ChatView` passes `controller.messages` directly into `ChatConversationPane` from inside `Obx`. That keeps a long-lived `RxList` instance flowing into the child instead of a concrete list snapshot for the current rebuild, which makes the UI vulnerable to missing stream-driven repaint updates.
- The composer `TextField` currently has no submit callback or keyboard handler, so Enter does not send a message.

## Design

### Architecture

Keep the existing feature structure intact.

- `ChatController` remains responsible for optimistic send state and stream updates.
- `ChatView` will materialize the current reactive values inside `Obx` and pass plain values into `ChatConversationPane`.
- `ChatConversationPane` will handle Enter-to-send locally in the composer without changing controller responsibilities.

This keeps the fix small and local to the existing Flutter chat feature.

### UI Update Flow

- In `ChatView`, read the current session list, active session id, and message list inside the reactive builder.
- Pass the message collection to `ChatConversationPane` as a plain snapshot instead of the mutable `RxList` object.
- Preserve the existing auto-scroll behavior in `ChatConversationPane` so new assistant chunks still scroll into view when the final visible message changes.

The goal is to make each streamed chunk participate in a normal Flutter rebuild instead of depending on implicit mutation of a shared reactive collection reference.

### Keyboard Submission

- Keep the composer as a multiline `TextField`.
- Submit on Enter when no Shift modifier is pressed.
- Leave Shift+Enter available for inserting a newline.
- Also wire `onSubmitted` to `onSend` as a fallback for platforms that surface submit through the text input action instead of the raw key event path.

This matches the expected chat behavior without adding extra UI affordances.

### Error Handling

- Ignore Enter submission when the existing controller guard would already reject the send: no active session, empty draft, or send already in progress.
- Do not change backend error behavior or stream error messaging as part of this fix.

### Testing

- Add a widget regression test showing that changing `controller.messages` while `ChatView` is visible updates the rendered transcript immediately.
- Add a widget test showing that pressing Enter in the focused composer sends the current draft.
- Add a widget test showing that Shift+Enter does not trigger send.

## Implementation Notes

- Prefer a minimal patch in `chat_view.dart` and `chat_widgets.dart`.
- Reuse the existing fake controller pattern in `test/chat/chat_view_test.dart` rather than adding a new test harness.
- Keep the controller and service logic unchanged unless the new tests reveal a second root cause.
