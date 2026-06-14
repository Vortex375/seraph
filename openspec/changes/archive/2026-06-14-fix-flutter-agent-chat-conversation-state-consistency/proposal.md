## Why

The chat UI in the Flutter agents app does not accurately reflect the assistant's streaming state. Conversation list items and individual message bubbles sometimes report `finished` while tokens are still arriving, and `running` after generation has completed. Users also see an empty assistant bubble during the pre-token thinking window, which makes it hard to know whether the assistant is working or the request failed. This change makes the conversation state consistent and visible across the list and detail views.

## What Changes

- Introduce a single source of truth in the chat state layer for whether an assistant response is currently in progress.
- Require assistant responses to be streamed; render each generated chunk in the message bubble as soon as it arrives so the UI feels responsive.
- Synchronize that state with the message list UI so the active assistant bubble shows a loading/generating indicator while no tokens have arrived and while tokens are streaming.
- Ensure the conversation list cell reflects the actual state (running vs finished) based on the active response completion, not on stale or optimistic flags.
- Change the running/finished status only when the underlying response stream terminates, is cancelled, or the first/last token events fire.
- Refresh the active conversation view and the conversation list entry when streaming ends so the final displayed state is consistent.
- Keep user input disabled/enable behavior tied to the same state flag so users cannot submit a new message while the assistant is still generating.
- Treat these as UI/implementation fixes only; no backend API or agent capability contract changes are required.

## Capabilities

### New Capabilities
- `agent-chat-conversation-state`: Unified tracking and visualization of assistant generation state across the Flutter chat conversation list and detail views, including live streaming of response chunks, loading indicators, accurate `running` / `finished` labels, and a final refresh when streaming ends.

### Modified Capabilities
<!-- No existing spec-level requirements change. -->

## Impact

- Affected code: Flutter chat screens, chat state/store/controller classes, message list widgets, conversation list item widgets, and chat tests under `app/seraph_app/`.
- No backend, API, or data-model changes are required.
- Dependencies: existing provider/GetX/chat controllers, the chat event stream, and message repository classes.
