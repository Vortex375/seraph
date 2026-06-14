## 1. Investigate current chat state lifecycles

- [x] 1.1 Read the chat controller/store code in `app/seraph_app/` to identify the reactive framework in use (GetX, Provider, Riverpod, or custom) and how response streams are managed.
- [x] 1.2 Identify all places where `running` / `finished` labels are computed for both the conversation list item and the assistant message bubble.
- [x] 1.3 Confirm the stream emit order and response contract: request start, empty thinking chunk, first token, subsequent tokens, completion, cancellation, and error paths.

## 2. Unify generation state in the chat controller

- [x] 2.1 Add an observable/chat state value (e.g. `ChatGenerationStatus` or an `isGenerating` flag) that is set to `running` when a message is submitted and `finished` in all completion paths.
- [x] 2.2 Wire `running` and `finished` transitions to the stream lifecycle (on listen/done/error/cancel) using `try`/`finally` or equivalent so cancellations cannot leave the flag stuck.
- [x] 2.3 Expose the state so the conversation list item and the message input widget can observe it without accessing stream internals.

## 3. Stream and render assistant responses

- [x] 3.1 Ensure the chat controller requests the assistant response through a streaming endpoint.
- [x] 3.2 Insert the assistant message placeholder row when the request starts.
- [x] 3.3 Render a spinner/typing indicator while the response has not received any token.
- [x] 3.4 Switch from the indicator to streaming text as soon as the first token arrives, then append each subsequent chunk to the active message in real time.
- [x] 3.5 Keep the message list reactive so chunks are visible as they arrive rather than only after the stream closes.

## 4. Synchronize conversation-list status

- [x] 4.1 Make the conversation list item watch the same `isGenerating` value for the active conversation.
- [x] 4.2 Ensure the list cell label flips to `finished` only when the generation state transitions to `finished`.
- [x] 4.3 Verify that selecting or deselecting a conversation resets the status correctly.

## 5. Refresh conversation when streaming ends

- [x] 5.1 Implement a refresh hook in the controller that runs after the stream completes, errors, or is cancelled.
- [x] 5.2 Refresh the active conversation and its messages from the repository/API once the stream closes.
- [x] 5.3 Refresh the corresponding conversation list item so the final persisted state is shown.
- [x] 5.4 Avoid scroll-position jumps or flicker by refreshing only modified messages/conversation metadata, or by preserving scroll offset.

## 6. Tie user input enablement to generation state

- [x] 6.1 Disable the message input send button while the generation state is `running`.
- [x] 6.2 Re-enable the send button when the state becomes `finished`.
- [x] 6.3 Guard the send action in the controller so a second request cannot bypass the UI control.

## 7. Add unit/widget tests

- [x] 7.1 Add controller tests that verify `running` → `finished` transitions for success, error, and cancellation.
- [x] 7.2 Add widget tests that assert the pre-token indicator appears and disappears correctly.
- [x] 7.3 Add widget tests that verify incoming stream chunks are appended to the assistant message bubble in order.
- [x] 7.4 Add widget tests for the conversation list item that assert `running` and `finished` labels based on the shared state.
- [x] 7.5 Add tests verifying the refresh hook is called after the stream ends.

## 8. Verify and finalize

- [x] 8.1 Run `flutter test` in `app/seraph_app/` and fix any regressions.
- [x] 8.2 Run `flutter analyze` in `app/seraph_app/` and resolve all warnings.
- [x] 8.3 Manually smoke-test a multi-turn chat to confirm streaming chunks, final refresh, list/detail view sync, and input enablement all behave correctly.
