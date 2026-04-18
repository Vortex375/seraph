# Flutter Chat UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the Flutter app, add a native chat feature that matches the React chat UI, and expose it through the existing app navigation.

**Architecture:** Keep the feature local to `lib/src/chat/` with a small `ChatService` for REST and SSE, a `ChatController` for screen state, and a responsive `ChatView` plus small feature widgets. Reuse the app's current `Get`, `Dio`, auth-token, and route patterns instead of introducing a new state or navigation stack.

**Tech Stack:** Flutter, Dart, GetX, Dio, Material 3, flutter_test

---

## File Structure

- Create: `app/seraph_app/lib/src/chat/chat_models.dart`
  Purpose: session/message DTOs and stream event parsing helpers.
- Create: `app/seraph_app/lib/src/chat/chat_service.dart`
  Purpose: chat REST requests, auth headers, and SSE parsing.
- Create: `app/seraph_app/lib/src/chat/chat_controller.dart`
  Purpose: chat state, optimistic send flow, stream lifecycle, responsive selection state.
- Create: `app/seraph_app/lib/src/chat/chat_view.dart`
  Purpose: route entry widget and responsive screen shell.
- Create: `app/seraph_app/lib/src/chat/chat_widgets.dart`
  Purpose: focused widgets for conversation list, transcript, citations, and composer.
- Modify: `app/seraph_app/lib/src/app.dart`
  Purpose: register the chat route and controller binding.
- Modify: `app/seraph_app/lib/src/app_bar/app_bar.dart`
  Purpose: add `Chat` to the route picker.
- Modify: `app/seraph_app/lib/src/initial_binding.dart`
  Purpose: register `ChatService`.
- Modify: `app/seraph_app/pubspec.yaml`
  Purpose: raise SDK constraint if required by the upgraded Flutter release and add any minimal dependency only if needed.
- Create: `app/seraph_app/test/chat/chat_service_test.dart`
  Purpose: verify JSON decoding, auth headers, and SSE parsing behavior.
- Create: `app/seraph_app/test/chat/chat_controller_test.dart`
  Purpose: verify session loading, optimistic send, stream reconciliation, and error recovery.
- Create: `app/seraph_app/test/chat/chat_view_test.dart`
  Purpose: verify responsive layout, navigation entry, citations, and empty/error states.
- Modify or replace: `app/seraph_app/test/widget_test.dart`
  Purpose: remove placeholder coverage in favor of real chat UI coverage.

### Task 1: Upgrade Flutter SDK And Establish The Feature Skeleton

**Files:**
- Modify: `app/seraph_app/pubspec.yaml`
- Create if needed by upgrade: `app/seraph_app/l10n.yaml`
- Create: `app/seraph_app/lib/src/chat/chat_models.dart`

- [ ] **Step 1: Write the failing model test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/chat/chat_models.dart';

void main() {
  test('chat session and message decode backend payloads', () {
    final session = ChatSession.fromJson({
      'id': 'session-1',
      'title': 'Inbox',
      'headline': 'Inbox',
      'preview': 'Last preview line',
      'status': 'finished',
      'user_id': 'alice',
      'created_at': '2026-04-12T00:00:00Z',
      'updated_at': '2026-04-12T00:00:01Z',
      'last_message_at': '2026-04-12T00:00:02Z',
    });

    final message = ChatMessage.fromJson({
      'id': 'assistant-1',
      'role': 'assistant',
      'content': 'I found these documents.',
      'created_at': '2026-04-12T00:00:03Z',
      'citations': ['/Music/example.url'],
    });

    expect(session.headline, 'Inbox');
    expect(session.status, ChatSessionStatus.finished);
    expect(message.citations, ['/Music/example.url']);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_service_test.dart`
Expected: FAIL because `chat_models.dart` and model types do not exist yet.

- [ ] **Step 3: Upgrade Flutter and refresh generated state**

Run these commands in `app/seraph_app`:

```bash
"/home/vortex/Development/flutter/flutter/bin/flutter" upgrade
"/home/vortex/Development/flutter/flutter/bin/flutter" pub get
```

If the upgrade complains about deprecated generated l10n packaging, add `l10n.yaml` with:

```yaml
synthetic-package: true
```

If the upgraded toolchain requires a newer Dart lower-bound, update `pubspec.yaml` from:

```yaml
environment:
  sdk: '>=3.4.3 <4.0.0'
```

to the lowest bound accepted by the upgraded stable SDK while keeping the upper bound open enough for that toolchain.

- [ ] **Step 4: Write the minimal model implementation**

```dart
enum ChatSessionStatus { running, finished }

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.headline,
    required this.preview,
    required this.status,
    required this.userId,
    required this.createdAt,
    required this.updatedAt,
    required this.lastMessageAt,
  });

  final String id;
  final String title;
  final String headline;
  final String preview;
  final ChatSessionStatus status;
  final String userId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastMessageAt;

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String,
      title: json['title'] as String,
      headline: json['headline'] as String,
      preview: (json['preview'] as String?) ?? '',
      status: (json['status'] as String) == 'running'
          ? ChatSessionStatus.running
          : ChatSessionStatus.finished,
      userId: json['user_id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      lastMessageAt: DateTime.parse(json['last_message_at'] as String),
    );
  }
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    required this.citations,
  });

  final String id;
  final String role;
  final String content;
  final DateTime createdAt;
  final List<String> citations;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      citations: ((json['citations'] as List<dynamic>?) ?? const [])
          .map((item) => item as String)
          .toList(),
    );
  }
}
```

- [ ] **Step 5: Re-run the model test**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_service_test.dart`
Expected: PASS for the decode test.

- [ ] **Step 6: Run analyzer to surface upgrade issues early**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" analyze`
Expected: It may fail. Capture the concrete issues and resolve them before moving to Task 2.

### Task 2: Build And Verify The Chat Service And Controller With TDD

**Files:**
- Create: `app/seraph_app/lib/src/chat/chat_service.dart`
- Create: `app/seraph_app/lib/src/chat/chat_controller.dart`
- Create: `app/seraph_app/test/chat/chat_service_test.dart`
- Create: `app/seraph_app/test/chat/chat_controller_test.dart`
- Modify: `app/seraph_app/lib/src/initial_binding.dart`

- [ ] **Step 1: Write the failing service tests**

```dart
test('listSessions decodes session metadata from the backend', () async {
  final service = makeChatService(responseMap: {
    '/api/v1/chat/sessions': [
      {
        'id': 'session-1',
        'title': 'Inbox',
        'headline': 'Inbox',
        'preview': 'Last preview line',
        'status': 'finished',
        'user_id': 'alice',
        'created_at': '2026-04-12T00:00:00Z',
        'updated_at': '2026-04-12T00:00:00Z',
        'last_message_at': '2026-04-12T00:00:00Z',
      }
    ]
  });

  final sessions = await service.listSessions();

  expect(sessions.single.preview, 'Last preview line');
});

test('streamAssistantReply emits parsed text/event-stream payloads', () async {
  final service = makeChatService(streamBody: 'data: {"content":"Hello"}\n\n');

  expect(
    service.streamAssistantReply('session-1'),
    emitsInOrder([
      predicate<Map<String, dynamic>>((event) => event['content'] == 'Hello'),
      emitsDone,
    ]),
  );
});
```

- [ ] **Step 2: Run the service tests to verify they fail**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_service_test.dart`
Expected: FAIL because `ChatService` and test helpers do not exist.

- [ ] **Step 3: Write the minimal service implementation**

Implement `ChatService` with this public surface:

```dart
class ChatService {
  ChatService(this.settingsController, this.loginController, {Dio? dio})
      : dio = dio ?? Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));

  final SettingsController settingsController;
  final LoginController loginController;
  final Dio dio;

  Future<List<ChatSession>> listSessions();
  Future<ChatSession> createSession(String title);
  Future<void> deleteSession(String sessionId);
  Future<List<ChatMessage>> listMessages(String sessionId);
  Future<void> sendMessage(String sessionId, String message);
  Stream<Map<String, dynamic>> streamAssistantReply(String sessionId);
}
```

Reuse the auth waiting/header logic from `FileService` and the SSE parsing structure from `SearchService`.

- [ ] **Step 4: Re-run the service tests**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Write the failing controller tests**

```dart
test('sendMessage adds an optimistic user message and updates the streaming assistant reply', () async {
  final fakeService = FakeChatService(
    sessions: [makeSession(id: 'session-1')],
    messages: {'session-1': []},
    streamEvents: [
      {'content': 'Hello'},
      {'content': 'Hello again'},
    ],
  );
  final controller = ChatController(fakeService);

  await controller.loadSessions();
  await controller.selectSession('session-1');
  controller.draftController.text = 'Hi';

  await controller.sendCurrentMessage();

  expect(controller.messages[0].role, 'user');
  expect(controller.messages[0].content, 'Hi');
  expect(controller.messages[1].content, 'Hello again');
});

test('stream failure restores draft-independent state and exposes an error', () async {
  final fakeService = FakeChatService(
    sessions: [makeSession(id: 'session-1')],
    messages: {'session-1': []},
    streamError: Exception('boom'),
  );
  final controller = ChatController(fakeService);

  await controller.loadSessions();
  await controller.selectSession('session-1');
  controller.draftController.text = 'Hi';

  await controller.sendCurrentMessage();

  expect(controller.historyError.value, isNotEmpty);
});
```

- [ ] **Step 6: Run the controller tests to verify they fail**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_controller_test.dart`
Expected: FAIL because `ChatController` does not exist.

- [ ] **Step 7: Write the minimal controller implementation**

Implement `ChatController` with these responsibilities:

```dart
class ChatController extends GetxController {
  ChatController(this.chatService);

  final ChatService chatService;
  final TextEditingController draftController = TextEditingController();

  final RxList<ChatSession> sessions = <ChatSession>[].obs;
  final RxList<ChatMessage> messages = <ChatMessage>[].obs;
  final RxnString activeSessionId = RxnString();
  final RxString appError = ''.obs;
  final RxString historyError = ''.obs;
  final RxBool isLoadingSessions = false.obs;
  final RxBool isLoadingMessages = false.obs;
  final RxBool isSending = false.obs;

  Future<void> loadSessions();
  Future<void> selectSession(String sessionId);
  Future<void> createSession();
  Future<void> deleteSession(ChatSession session);
  Future<void> sendCurrentMessage();
  void clearActiveSession();
}
```

Keep the stream subscription private and always cancel it before switching sessions or deleting the active conversation.

- [ ] **Step 8: Re-run the controller tests**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_controller_test.dart`
Expected: PASS.

- [ ] **Step 9: Register the service in the app binding**

Update `InitialBinding.dependencies()` to include:

```dart
Get.put(ChatService(Get.find(), Get.find()));
```

Place it next to the existing `SearchService` registration so feature services stay grouped.

### Task 3: Add Navigation And The Responsive Chat UI With TDD

**Files:**
- Create: `app/seraph_app/lib/src/chat/chat_view.dart`
- Create: `app/seraph_app/lib/src/chat/chat_widgets.dart`
- Modify: `app/seraph_app/lib/src/app.dart`
- Modify: `app/seraph_app/lib/src/app_bar/app_bar.dart`
- Create: `app/seraph_app/test/chat/chat_view_test.dart`

- [ ] **Step 1: Write the failing widget tests**

```dart
testWidgets('app bar navigation includes chat', (tester) async {
  await tester.pumpWidget(makeShell(routeName: FileBrowserView.routeName));

  await tester.tap(find.byType(DropdownButton<String>));
  await tester.pumpAndSettle();

  expect(find.text('Chat'), findsOneWidget);
});

testWidgets('large layout shows sessions and transcript side by side', (tester) async {
  await tester.pumpWidget(makeChatViewTestApp(width: 1200));

  expect(find.text('Conversations'), findsOneWidget);
  expect(find.text('Select a conversation to start chatting.'), findsOneWidget);
});

testWidgets('small layout opens conversation thread after tapping a session', (tester) async {
  await tester.pumpWidget(makeChatViewTestApp(width: 430));

  await tester.tap(find.text('Inbox'));
  await tester.pumpAndSettle();

  expect(find.text('Message Seraph'), findsOneWidget);
  expect(find.byTooltip('Back to conversations'), findsOneWidget);
});

testWidgets('assistant citations render inside an expandable section', (tester) async {
  await tester.pumpWidget(makeChatViewTestApp(
    width: 1200,
    selectedSessionId: 'session-1',
    messages: [
      ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'I found these documents.',
        createdAt: DateTime.parse('2026-04-12T00:00:00Z'),
        citations: ['/Music/example.url'],
      ),
    ],
  ));

  expect(find.text('Sources'), findsOneWidget);
});
```

- [ ] **Step 2: Run the widget tests to verify they fail**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_view_test.dart`
Expected: FAIL because the chat route and widgets do not exist yet.

- [ ] **Step 3: Add the chat route and menu entry**

Update `app.dart` to register:

```dart
GetPage(
  name: ChatView.routeName,
  page: () => const ChatView(),
  binding: BindingsBuilder(() {
    Get.put(ChatController(Get.find()));
  }),
),
```

Update `app_bar.dart` dropdown items to include:

```dart
const DropdownMenuItem(
  value: ChatView.routeName,
  child: Text('Chat'),
),
```

Place `Chat` with the other main destinations rather than below the divider.

- [ ] **Step 4: Implement the minimal responsive chat view**

Use this screen split:

```dart
class ChatView extends StatelessWidget {
  static const routeName = '/chat';

  const ChatView({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ChatController>();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 800;
        return Obx(() => Scaffold(
          appBar: seraphAppBar(
            context,
            name: 'Chat',
            routeName: routeName,
            actions: const [],
          ),
          body: isWide
              ? Row(
                  children: [
                    SizedBox(width: 320, child: ChatSessionList(controller: controller)),
                    const VerticalDivider(width: 1),
                    Expanded(child: ChatConversationPane(controller: controller, isCompact: false)),
                  ],
                )
              : controller.activeSessionId.value == null
                  ? ChatSessionList(controller: controller)
                  : ChatConversationPane(controller: controller, isCompact: true),
        ));
      },
    );
  }
}
```

Inside `ChatConversationPane`, show a back affordance when `isCompact` is true.

- [ ] **Step 5: Re-run the widget tests**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_view_test.dart`
Expected: PASS.

### Task 4: Full Verification And Cleanup

**Files:**
- Modify as needed: any files touched in Tasks 1-3
- Verify: `app/seraph_app/test/chat/*.dart`

- [ ] **Step 1: Run the focused chat test suite**

Run:

```bash
"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_service_test.dart
"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_controller_test.dart
"/home/vortex/Development/flutter/flutter/bin/flutter" test test/chat/chat_view_test.dart
```

Expected: all PASS.

- [ ] **Step 2: Run the full app test suite**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" test`
Expected: PASS.

- [ ] **Step 3: Run analyzer and fix all reported issues**

Run: `"/home/vortex/Development/flutter/flutter/bin/flutter" analyze`
Expected: `No issues found!`

- [ ] **Step 4: Manually sanity-check navigation and responsive behavior**

Run one or more of:

```bash
"/home/vortex/Development/flutter/flutter/bin/flutter" run -d linux
"/home/vortex/Development/flutter/flutter/bin/flutter" run -d chrome
```

Verify:

```text
1. App bar menu includes Chat.
2. New chat creates and selects a conversation.
3. Sending a message shows an optimistic user bubble.
4. Streaming assistant text updates in place.
5. Citations appear under Sources after reconciliation.
6. Narrow layouts move between list and thread without broken state.
```

- [ ] **Step 5: Summarize any remaining risks without adding scope**

If any platform-specific limitation remains after verification, document it in the final handoff rather than expanding the implementation.

## Self-Review

- Spec coverage: SDK upgrade, chat navigation, full React feature parity, responsive layouts, citations, and verification are all covered by Tasks 1-4.
- Placeholder scan: no `TBD`, `TODO`, or deferred implementation markers remain in the plan body.
- Type consistency: `ChatService`, `ChatController`, `ChatView`, `ChatSession`, and `ChatMessage` use the same names across tasks.
