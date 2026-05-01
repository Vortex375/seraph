# Chat Feature Improvements — Design Document

**Date:** 2026-05-01
**Scope:** Flutter chat UI (markdown rendering, streaming, text selection)

---

## Problems

1. **No markdown rendering**: Assistant message bubbles display raw markdown text (e.g. `**bold**`, `## heading`) as plain text.
2. **Streaming feels broken**: Assistant bubbles appear empty until the full response arrives, or updates are missed entirely.
3. **No text selection**: Users cannot select or copy text from chat bubbles.

---

## Root Causes (from code analysis)

- `ChatMessageCard` uses `Text(message.content)` — no markdown processing.
- `ChatMessageCard` content tree is outside any `SelectionArea` — Flutter disables text selection by default.
- The stream listener in `ChatController` does `messages.removeLast(); messages.add(newMsg);` on an `RxList`. GetX tracks list reactivity but `replace/add/remove` on a reactive list isn't guaranteed to emit without an explicit `.refresh()` call.
- After every stream chunk, the listener `await`s `_refreshSessionMetadata()` which makes an HTTP call. This serializes chunk processing: the listener can't handle the next chunk until the HTTP round-trip finishes, creating perceived "lag" in the stream.

---

## Changes

### 1. Add `flutter_markdown` dependency

Add `flutter_markdown: ^0.7.6+2` to `app/seraph_app/pubspec.yaml`.

### 2. Render markdown in assistant bubbles

Replace `Text(message.content)` in `ChatMessageCard` with `flutter_markdown`'s `MarkdownBody` for assistant messages. User messages stay plain `Text` (users don't type markdown in the composer).

Style: custom code-block styling with surface color, font-family `monospace`, and standard padding.

### 3. Enable text selection

Wrap the `ListView.builder` in `ChatConversationPane` with `SelectionArea` so all text inside message bubbles becomes selectable and copyable natively.

### 4. Fix reactive streaming updates

In `ChatController.sendCurrentMessage`, after each stream event handler processes the content delta:

- Call `messages.refresh()` to force a reactive update downstream.

### 5. Fix stream-blocking HTTP call

Change `_refreshSessionMetadata(sessionId)` in the stream listener to fire-and-forget (remove `await`). The sidebar refresh is best-effort; blocking the stream thread causes stuttering.

---

## Affected Files

| File | Change |
|------|--------|
| `app/seraph_app/pubspec.yaml` | Add `flutter_markdown` dependency |
| `app/seraph_app/lib/src/chat/chat_widgets.dart` | `MarkdownBody` + `SelectionArea` |
| `app/seraph_app/lib/src/chat/chat_controller.dart` | `.refresh()` after update; fire-and-forget metadata refresh |

---

## Not in Scope

- Backend SSE format changes (verified correct)
- Chat bubble design overhaul
- Code syntax highlighting in markdown

---

## Testing Strategy

- Existing unit tests in `test/chat/` continue to pass.
- Add a widget test verifying `MarkdownBody` renders inside assistant bubbles when content contains `**bold**`.
- Add a widget test verifying `SelectionArea` wraps the message list (detectable via widget type finder).
- Add a controller unit test verifying `messages.refresh()` is invoked after stream chunk.
- Run `flutter analyze` to verify no regressions.
