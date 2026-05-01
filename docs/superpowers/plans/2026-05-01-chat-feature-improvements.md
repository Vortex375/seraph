# Chat Feature Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix markdown rendering, enable text selection/copy, and fix streaming updates in the Flutter chat feature.

**Architecture:** Add `flutter_markdown` for assistant bubble markdown rendering, wrap message list with `SelectionArea` for native text selection, and fix reactive stream updates in the controller by explicitly refreshing the RxList and making metadata refresh fire-and-forget.

**Tech Stack:** Flutter, GetX, flutter_markdown

---

## File Map

| File | Responsibility |
|------|---------------|
| `app/seraph_app/pubspec.yaml` | Declare `flutter_markdown` dependency |
| `app/seraph_app/lib/src/chat/chat_widgets.dart` | `ChatMessageCard` renders markdown; `ChatConversationPane` wraps list in `SelectionArea` |
| `app/seraph_app/lib/src/chat/chat_controller.dart` | Fix reactive updates after stream chunk + fire-and-forget metadata refresh |
| `app/seraph_app/test/chat/chat_widgets_test.dart` | New test file for markdown rendering and selection behavior |
| `app/seraph_app/test/chat/chat_controller_test.dart` | Existing tests; add stream refresh test |

---

### Task 1: Add flutter_markdown dependency

**Files:**
- Modify: `app/seraph_app/pubspec.yaml`

- [ ] **Step 1: Add dependency**

Add `flutter_markdown: ^0.7.6+2` to the `dependencies` section. Keep alphabetical order within the block.

```yaml
dependencies:
  audio_service: ^0.18.17
  audio_service_mpris: ^0.2.0
  audio_session: ^0.1.25
  dio: ^5.7.0
  flutter:
    sdk: flutter
  flutter_breadcrumb: ^1.0.1
  flutter_localizations:
    sdk: flutter
  flutter_markdown: ^0.7.6+2
  flutter_secure_storage: ^9.2.4
  get: ^4.7.2
  get_storage: ^2.1.1
  google_fonts: ^6.2.1
  media_kit: ^1.1.11
  media_kit_libs_video: ^1.0.5
  media_kit_video: ^1.2.5
  oidc: ^0.9.0+1
  oidc_core: ^0.9.1
  oidc_default_store: ^0.2.0+12
  path_provider: ^2.1.5
  provider: ^6.1.2
  shared_preferences: ^2.3.2
  url_launcher: ^6.3.1
  webdav_client: ^1.2.2
```

- [ ] **Step 2: Verify pubspec is valid**

Run: `cd app/seraph_app && flutter pub get` (or `dart pub get` if flutter CLI unavailable)

Expected: Resolves without errors.

- [ ] **Step 3: Commit**

```bash
git add app/seraph_app/pubspec.yaml
if [ -f app/seraph_app/pubspec.lock ]; then git add app/seraph_app/pubspec.lock; fi
git commit -m "deps: add flutter_markdown for chat markdown rendering"
```

---

### Task 2: Render markdown in assistant message bubbles

**Files:**
- Modify: `app/seraph_app/lib/src/chat/chat_widgets.dart`

- [ ] **Step 1: Import flutter_markdown**

Add at the top of the file, after existing imports:

```dart
import 'package:flutter_markdown/flutter_markdown.dart';
```

- [ ] **Step 2: Replace Text with MarkdownBody in ChatMessageCard**

In `ChatMessageCard.build`, replace the `Text(message.content)` line with conditional rendering. User messages stay plain text; assistant messages use `MarkdownBody`.

Find this block in `ChatMessageCard.build`:
```dart
                Text(message.content),
```

Replace with:
```dart
                if (isAssistant)
                  MarkdownBody(
                    data: message.content,
                    styleSheet: MarkdownStyleSheet(
                      p: Theme.of(context).textTheme.bodyMedium,
                      code: TextStyle(
                        fontFamily: 'monospace',
                        backgroundColor: colorScheme.surfaceContainerHighest,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  )
                else
                  Text(message.content),
```

- [ ] **Step 3: Commit**

```bash
git add app/seraph_app/lib/src/chat/chat_widgets.dart
git commit -m "feat: render markdown in assistant chat bubbles"
```

---

### Task 3: Enable text selection in chat bubbles

**Files:**
- Modify: `app/seraph_app/lib/src/chat/chat_widgets.dart`

- [ ] **Step 1: Wrap message list with SelectionArea**

In `ChatConversationPane.build`, find the `ListView.builder` block inside the `Expanded` widget.

Current code:
```dart
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: widget.messages.length,
                      itemBuilder: (context, index) {
                        final message = widget.messages[index];
                        return ChatMessageCard(message: message);
                      },
                    ),
```

Replace with:
```dart
                  : SelectionArea(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: widget.messages.length,
                        itemBuilder: (context, index) {
                          final message = widget.messages[index];
                          return ChatMessageCard(message: message);
                        },
                      ),
                    ),
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/chat/chat_widgets.dart
git commit -m "feat: enable text selection in chat messages"
```

---

### Task 4: Fix reactive streaming updates in controller

**Files:**
- Modify: `app/seraph_app/lib/src/chat/chat_controller.dart`

- [ ] **Step 1: Add messages.refresh() after stream content update**

In `sendCurrentMessage`, locate the stream listener's `onData` callback where the assistant message is rebuilt and added back to the list.

Find this block:
```dart
          if (content is String) {
            final last = messages.removeLast();
            messages.add(ChatMessage(
              id: event['id'] as String? ?? last.id,
              role: last.role,
              content: type == 'delta' ? '${last.content}$content' : content,
              createdAt: last.createdAt,
              citations: _extractStreamCitations(event['citations'], last.citations),
            ));
            await _refreshSessionMetadata(sessionId);
          }
```

Replace with:
```dart
          if (content is String) {
            final last = messages.removeLast();
            messages.add(ChatMessage(
              id: event['id'] as String? ?? last.id,
              role: last.role,
              content: type == 'delta' ? '${last.content}$content' : content,
              createdAt: last.createdAt,
              citations: _extractStreamCitations(event['citations'], last.citations),
            ));
            messages.refresh();
            unawaited(_refreshSessionMetadata(sessionId));
          }
```

- [ ] **Step 2: Import dart:async for unawaited**

Ensure `import 'dart:async';` is present at the top of the file. It already is, but verify.

- [ ] **Step 3: Commit**

```bash
git add app/seraph_app/lib/src/chat/chat_controller.dart
git commit -m "fix: refresh messages list and unblock stream listener on chunk"
```

---

### Task 5: Add widget tests for markdown rendering

**Files:**
- Create: `app/seraph_app/test/chat/chat_widgets_test.dart`

- [ ] **Step 1: Write markdown rendering test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/chat/chat_models.dart';
import 'package:seraph_app/src/chat/chat_widgets.dart';

void main() {
  testWidgets('assistant message card renders markdown body', (tester) async {
    final message = ChatMessage(
      id: 'msg-1',
      role: 'assistant',
      content: '## Hello\n\nThis is **bold**.',
      createdAt: DateTime.parse('2026-04-12T00:00:00Z'),
      citations: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageCard(message: message),
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
  });

  testWidgets('user message card renders plain text', (tester) async {
    final message = ChatMessage(
      id: 'msg-2',
      role: 'user',
      content: 'Plain text',
      createdAt: DateTime.parse('2026-04-12T00:00:00Z'),
      citations: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageCard(message: message),
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('Plain text'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run widget tests**

Run: `cd app/seraph_app && flutter test test/chat/chat_widgets_test.dart`

Expected: Both tests pass.

- [ ] **Step 3: Commit**

```bash
git add app/seraph_app/test/chat/chat_widgets_test.dart
git commit -m "test: verify markdown rendering in assistant bubbles"
```

---

### Task 6: Add controller test for stream refresh

**Files:**
- Modify: `app/seraph_app/test/chat/chat_controller_test.dart`

- [ ] **Step 1: Add refresh verification test**

Add the following test to the existing `group('ChatController', ...)` block in `chat_controller_test.dart`:

```dart
    test('stream chunk triggers reactive refresh so listeners see update', () async {
      final streamController = StreamController<Map<String, dynamic>>();
      chatService.replyStreams['session-1'] = streamController.stream;

      var refreshCount = 0;
      final disposer = ever(controller.messages, (_) {
        refreshCount++;
      });

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final sendFuture = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      // Initial add of user + assistant messages triggers ever once
      final countBeforeChunk = refreshCount;

      streamController.add({'type': 'delta', 'content': 'World'});
      await Future<void>.microtask(() {});

      // The stream chunk handler should have refreshed reactive listeners
      expect(refreshCount, greaterThan(countBeforeChunk));
      expect(controller.messages[1].content, 'World');

      await streamController.close();
      await sendFuture;
      disposer();
    });
```

- [ ] **Step 2: Run controller tests**

Run: `cd app/seraph_app && flutter test test/chat/chat_controller_test.dart`

Expected: All tests pass, including the new one.

- [ ] **Step 3: Commit**

```bash
git add app/seraph_app/test/chat/chat_controller_test.dart
git commit -m "test: verify reactive refresh on stream chunk"
```

---

### Task 7: Add widget test for selection area presence

**Files:**
- Modify: `app/seraph_app/test/chat/chat_widgets_test.dart`

- [ ] **Step 1: Add SelectionArea presence test**

Append to `chat_widgets_test.dart`:

```dart
  testWidgets('conversation pane wraps messages in SelectionArea', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatConversationPane(
            sessionTitle: 'Test',
            messages: [
              ChatMessage(
                id: 'msg-1',
                role: 'assistant',
                content: 'Selectable text',
                createdAt: DateTime.parse('2026-04-12T00:00:00Z'),
                citations: const [],
              ),
            ],
            loading: false,
            errorText: null,
            hasActiveSession: true,
            draftController: TextEditingController(),
            onSend: () {},
          ),
        ),
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('Selectable text'), findsOneWidget);
  });
```

- [ ] **Step 2: Run tests**

Run: `cd app/seraph_app && flutter test test/chat/chat_widgets_test.dart`

Expected: All 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add app/seraph_app/test/chat/chat_widgets_test.dart
git commit -m "test: verify SelectionArea wraps chat message list"
```

---

### Task 8: Final verification

**Files:**
- Modify: none (verification only)

- [ ] **Step 1: Run all chat tests**

Run: `cd app/seraph_app && flutter test test/chat/`

Expected: All tests pass.

- [ ] **Step 2: Run static analysis**

Run: `cd app/seraph_app && flutter analyze lib/src/chat/ test/chat/`

Expected: No issues found.

- [ ] **Step 3: Commit any fixes (if needed)**

If analysis finds issues, fix and commit. Otherwise skip.

---

## Spec Coverage Check

| Spec Requirement | Task |
|-----------------|------|
| Add `flutter_markdown` dependency | Task 1 |
| Render markdown in assistant bubbles | Task 2 |
| Enable text selection (`SelectionArea`) | Task 3 |
| Fix reactive streaming (`.refresh()`) | Task 4 |
| Fix stream-blocking HTTP call | Task 4 |
| Tests for markdown rendering | Task 5 |
| Tests for reactive refresh | Task 6 |
| Tests for selection area | Task 7 |

All requirements covered. No placeholders in plan.
