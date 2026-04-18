# Flutter Chat Streaming Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the Flutter chat screen so streamed assistant updates render immediately and Enter submits the current draft while Shift+Enter still allows multiline input.

**Architecture:** Keep the existing controller and service flow intact. Materialize reactive chat state into plain values inside `ChatView`, and add keyboard submit behavior locally in the composer widget so the fix stays contained to the chat UI.

**Tech Stack:** Flutter, Dart, GetX, flutter_test, Material 3

---

## File Structure

- Modify: `app/seraph_app/lib/src/chat/chat_view.dart`
  Purpose: materialize reactive session and message state inside `Obx` before passing it to child widgets.
- Modify: `app/seraph_app/lib/src/chat/chat_widgets.dart`
  Purpose: add Enter-to-send behavior in the composer while preserving multiline editing.
- Modify: `app/seraph_app/test/chat/chat_view_test.dart`
  Purpose: add widget regressions for transcript repaint and keyboard submission behavior.

### Task 1: Add Failing Widget Regressions

**Files:**
- Modify: `app/seraph_app/test/chat/chat_view_test.dart`

- [ ] **Step 1: Add the transcript repaint regression test**

```dart
testWidgets('visible transcript updates immediately when the active message list changes', (tester) async {
  controller.sessions.assignAll([
    _session(id: 'session-1', title: 'Design review'),
  ]);
  controller.messages.assignAll([
    _message(id: 'assistant-1', role: 'assistant', content: 'Initial draft'),
  ]);
  controller.activeSessionId.value = 'session-1';

  await tester.pumpWidget(_wrapApp(const ChatView(), size: const Size(1200, 900)));
  await tester.pump();

  expect(find.text('Initial draft'), findsOneWidget);

  controller.messages.assignAll([
    _message(id: 'assistant-1', role: 'assistant', content: 'Updated streamed reply'),
  ]);
  await tester.pump();

  expect(find.text('Updated streamed reply'), findsOneWidget);
  expect(find.text('Initial draft'), findsNothing);
});
```

- [ ] **Step 2: Add the Enter/Shift+Enter composer tests**

```dart
testWidgets('pressing Enter in the composer sends the current draft', (tester) async {
  controller.sessions.assignAll([
    _session(id: 'session-1', title: 'Design review'),
  ]);
  controller.activeSessionId.value = 'session-1';

  await tester.pumpWidget(_wrapApp(const ChatView(), size: const Size(1200, 900)));
  await tester.pump();

  await tester.tap(find.byType(TextField));
  await tester.pump();
  await tester.enterText(find.byType(TextField), 'Send this');
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();

  expect(controller.sentDrafts, ['Send this']);
});

testWidgets('pressing Shift+Enter does not submit the draft', (tester) async {
  controller.sessions.assignAll([
    _session(id: 'session-1', title: 'Design review'),
  ]);
  controller.activeSessionId.value = 'session-1';

  await tester.pumpWidget(_wrapApp(const ChatView(), size: const Size(1200, 900)));
  await tester.pump();

  await tester.tap(find.byType(TextField));
  await tester.pump();
  await tester.enterText(find.byType(TextField), 'Keep editing');
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();

  expect(controller.sentDrafts, isEmpty);
});
```

- [ ] **Step 3: Run the widget test file to verify the new tests fail**

Run: `flutter test test/chat/chat_view_test.dart`
Expected: FAIL because the current view does not refresh from live message mutations and the composer does not submit on Enter.

### Task 2: Implement The Minimal Chat UI Fix

**Files:**
- Modify: `app/seraph_app/lib/src/chat/chat_view.dart`
- Modify: `app/seraph_app/lib/src/chat/chat_widgets.dart`

- [ ] **Step 1: Materialize reactive values inside `ChatView`**

Update the `Obx` builder to read concrete values before building children:

```dart
return Obx(() {
  final sessionItems = controller.sessions.toList(growable: false);
  final messageItems = controller.messages.toList(growable: false);
  final activeSessionId = controller.activeSessionId.value;
  final activeSession = sessionItems.firstWhereOrNull(
    (session) => session.id == activeSessionId,
  );

  final sessionList = ChatSessionList(
    sessions: sessionItems,
    activeSessionId: activeSessionId,
    ...
  );

  final conversationPane = ChatConversationPane(
    sessionTitle: activeSession?.headline,
    messages: messageItems,
    hasActiveSession: activeSessionId != null,
    ...
  );
```

- [ ] **Step 2: Add Enter-to-send handling in the composer**

Wrap the composer `TextField` in shortcuts/actions that submit on plain Enter and fall back to `onSubmitted`:

```dart
Shortcuts(
  shortcuts: const {
    SingleActivator(LogicalKeyboardKey.enter): _SubmitMessageIntent(),
  },
  child: Actions(
    actions: {
      _SubmitMessageIntent: CallbackAction<_SubmitMessageIntent>(
        onInvoke: (_) {
          widget.onSend();
          return null;
        },
      ),
    },
    child: TextField(
      controller: widget.draftController,
      minLines: 1,
      maxLines: 4,
      onSubmitted: (_) => widget.onSend(),
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        hintText: 'Message',
      ),
    ),
  ),
)
```

Keep Shift+Enter unbound so multiline editing still works.

- [ ] **Step 3: Re-run the widget test file**

Run: `flutter test test/chat/chat_view_test.dart`
Expected: PASS.

### Task 3: Verify The Full Fix

**Files:**
- Verify: `app/seraph_app/test/chat/chat_view_test.dart`
- Verify: `app/seraph_app/test/chat/chat_controller_test.dart`

- [ ] **Step 1: Run the focused chat widget and controller tests**

Run:

```bash
flutter test test/chat/chat_view_test.dart
flutter test test/chat/chat_controller_test.dart
```

Expected: both PASS.

- [ ] **Step 2: Re-check the running chat page in the browser**

Manual verification on `http://localhost:8080/app/#/chat`:

```text
1. Type a draft into the composer.
2. Press Enter.
3. Confirm the user message appears immediately.
4. Confirm the assistant reply updates without re-opening the conversation.
5. Confirm Shift+Enter does not submit the draft.
```

- [ ] **Step 3: Document any remaining risks only if verification exposes them**

Do not expand scope unless a second root cause appears during the verification step.

## Self-Review

- Spec coverage: reactive repaint and Enter-submit behavior are both covered by Tasks 1-3.
- Placeholder scan: no `TBD`, `TODO`, or deferred instructions remain.
- Type consistency: `ChatView`, `ChatConversationPane`, `ChatController`, and the new test helper names stay consistent across tasks.
