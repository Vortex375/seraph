## Context

The chat feature in `app/seraph_app/` lets users converse with a Seraph agent. While a response is being generated, both the `ConversationList` and the `Conversation` view need to show the conversation as "running"; when generation ends (success, error, cancellation), it must flip to "finished". Currently the two views seem to disagree because the generation state is tracked in more than one place or updated at inconsistent moments.

The conversation list cell derives its status from the conversation model, while the active chat view derives it from the message stream / controller. During the thinking phase before the first token is emitted, the assistant message already exists in the list but has no visible indicator. The goal is to keep a single authoritative generation state tied to the request lifecycle and broadcast it to all observers.

## Goals / Non-Goals

**Goals:**
- Maintain one canonical `isGenerating` / generation state in the chat controller/state layer.
- Stream assistant responses and render each chunk in the active message bubble as soon as it is received.
- Show a loading indicator inside the assistant message bubble while no tokens have arrived yet.
- Flip the conversation list item and detail view status to `finished` only after the response stream completes.
- Refresh the conversation view and conversation list entry when streaming ends so the persisted final state is reflected in the UI.
- Keep the message input send button disabled while the assistant is generating.
- Add or update widget/controller tests to assert the correct state transitions.

**Non-Goals:**
- Changing the agent API response contract, backend event stream protocol, or data models.
- Implementing a fully new chat framework; reuse existing Flutter/controller patterns.
- Improving message persistence or handling offline queues beyond the current scope.

## Decisions

1. **Source of truth lives in the active chat controller.**  
   The `ChatController` (or equivalent GetX/Provider stores) already owns the response stream. Adding an `isGenerating` observable / value notifier there avoids a second state in the conversation repository.  
   *Rationale*: The stream starts/stops inside the controller; state transitions naturally belong there.  
   *Alternative considered*: Track state by inspecting the last message's content emptiness. Rejected because emptiness is not identical to generation state and causes the reported empty-bubble bug.

2. **Drive the conversation-list status from the same `isGenerating` value.**  
   When the chat controller enters generation, it emits the running state to the list item that represents the same conversation. When the stream ends it emits finished.  
   *Rationale*: Prevents the list and detail views from disagreeing.  
   *Alternative considered*: Let the list poll the conversation model's `updatedAt` or last message. Rejected because model-level timestamps cannot tell whether generation is still in progress.

3. **Show a loading indicator inside the active assistant bubble while generating.**  
   The assistant message bubble is inserted as soon as the request starts. It displays a spinner/typing indicator before the first token arrives, continues showing the spinner while streamed tokens are appended, and removes the indicator only when the stream completes, fails, or is cancelled.  
   *Rationale*: Gives immediate feedback before the first token, and keeps the user aware that more content may still arrive while tokens are streaming.  
   *Alternative considered*: Show a floating spinner outside the message list. Rejected because it breaks the visual conversation thread.

4. **Assistant responses are consumed and rendered as a stream.**  
   The chat controller subscribes to the response stream and appends each received chunk to the active assistant message immediately. This applies from the first token through the last.  
   *Rationale*: Keeps the UI responsive and gives users immediate feedback while the assistant is thinking.  
   *Alternative considered*: Wait for the complete response before rendering. Rejected because it would freeze the message area and hide the assistant's progress.

5. **State transitions are event-driven from the stream lifecycle, followed by a final refresh.**  
   - `request` → `isGenerating = true`, insert assistant placeholder with spinner.  
   - `chunk` → append chunk to the active message and keep the spinner visible.  
   - `stream end / error / cancel` → `isGenerating = false`, remove the spinner, then explicitly refresh the current conversation and list item so the UI reflects the persisted final state.  
   *Rationale*: Tying status to the exact stream lifecycle removes race windows; the refresh guarantees that any local per-chunk approximations are reconciled with the server source of truth.

6. **Testing focuses on state transitions, not the LLM surface.**  
   Unit/widget tests will inject a fake stream that emits no events, partial events, and completion events, then assert on `isGenerating`, the status displayed in widgets, and the refresh callback triggered at stream end.  
   *Rationale*: Keeps tests deterministic and fast.  
   *Alternative considered*: Record/replay against the actual agent API. Rejected because it is slower and requires API keys/infra.

## Risks / Trade-offs

- **Risk**: Existing `ChatController` is large; adding another observable may make it harder to reason about.  
  **Mitigation**: Encapsulate the generation state in a small immutable value object (e.g. `ChatGenerationStatus { bool isGenerating, String? currentResponseId, bool hasReceivedFirstToken }`) and update it through helper methods.

- **Risk**: Other parts of the app (search assistant, notifications) could also listen to chat state and react incorrectly.  
  **Mitigation**: Scope the new observable to the chat feature packages/screens; do not expose it globally if not already public.

- **Risk**: Conversation-list status may lag because it gets the done event from a controller that was garbage-collected or closed.  
  **Mitigation**: Ensure the controller calls a central service/callback that outlives the view; if using GetX, update the store object bound to the conversation ID.

- **Risk**: Cancelling generation does not immediately clear state, so input stays disabled.  
  **Mitigation**: Treat cancellation the same as stream completion in `finally`/dispose handlers.

- **Risk**: Refreshing the conversation at the end of streaming could redraw the message list and cause scroll-position jumps or flicker.  
  **Mitigation**: Refresh only the conversation metadata and the mutated message, or diff the message list so identical items do not rebuild. If a full refresh is required, preserve scroll offset.

## Migration Plan

No deployment or data migration is needed. This is a client-only Flutter change.

Rollout:
1. Inspect the chat controller and repository to understand the existing streaming API.
2. Update controller to consume the stream, append chunks, and trigger a final refresh.
3. Update message bubble widget and chat list item.
4. Run `flutter test` and `flutter analyze` in `app/seraph_app/`.
5. Merge behind the normal mobile CI pipeline.

Rollback: revert the pull request. No persisted state or schema changes are involved.

## Open Questions

- Does the current chat controller use GetX, Provider, Riverpod, or a custom stream? The exact reactive primitive will be confirmed by reading `app/seraph_app/` before implementation.
- Is there an existing "loading"/"typing" widget that should be reused for the placeholder, or should a new one be created?
