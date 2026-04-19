import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oidc/oidc.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/chat/chat_controller.dart';
import 'package:seraph_app/src/chat/chat_models.dart';
import 'package:seraph_app/src/chat/chat_service.dart';
import 'package:seraph_app/src/chat/chat_view.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_view.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_view.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatView', () {
    late _FakeChatController controller;

    setUp(() {
      Get.testMode = true;
      Get.reset();
      controller = _FakeChatController();
      Get.put<ShareController>(_FakeShareController());
      Get.put<ChatController>(controller);
    });

    tearDown(() {
      Get.reset();
    });

    testWidgets('app bar navigation includes Chat', (tester) async {
      await tester.pumpWidget(_wrapApp(const _AppBarHost()));
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Chat'), findsAtLeastNWidgets(1));
    });

    testWidgets('compact app bar keeps Chat route reachable without overflow', (tester) async {
      await tester.pumpWidget(
        _wrapApp(const _CompactAppBarHost(routeName: SettingsView.routeName), size: const Size(220, 800)),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Chat'), findsAtLeastNWidgets(1));
    });

    testWidgets('large layout shows conversations and transcript side by side', (tester) async {
      controller.sessions.assignAll([
        _session(
          id: 'session-1',
          title: 'Design review',
          preview: 'Latest answer',
          status: ChatSessionStatus.running,
        ),
      ]);
      controller.messages.assignAll([
        _message(id: 'message-1', role: 'assistant', content: 'Latest answer'),
      ]);
      controller.activeSessionId.value = 'session-1';

      await tester.pumpWidget(_wrapApp(const ChatView(), size: const Size(1200, 900)));
      await tester.pump();

      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('Design review'), findsAtLeastNWidgets(1));
      expect(find.text('Latest answer'), findsWidgets);
      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(find.byTooltip('Send message'), findsOneWidget);
    });

    testWidgets('small layout opens conversation thread after tapping a session', (tester) async {
      controller.sessions.assignAll([
        _session(
          id: 'session-1',
          title: 'Design review',
          preview: 'Latest answer',
        ),
      ]);
      controller.messagesBySession['session-1'] = [
        _message(id: 'message-1', role: 'assistant', content: 'Latest answer'),
      ];

      await tester.pumpWidget(_wrapApp(const ChatView(), size: const Size(420, 900)));
      await tester.pumpAndSettle();

      expect(find.text('Select a conversation'), findsNothing);
      await tester.tap(find.text('Design review'));
      await tester.pumpAndSettle();

      expect(controller.activeSessionId.value, 'session-1');
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.text('Latest answer'), findsWidgets);
      expect(find.byTooltip('Send message'), findsOneWidget);
    });

    testWidgets('small layout opens conversation pane after tapping New chat', (tester) async {
      await tester.pumpWidget(_wrapApp(const ChatView(), size: const Size(420, 900)));
      await tester.pumpAndSettle();

      expect(find.text('New chat'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsNothing);

      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();

      expect(controller.activeSessionId.value, 'new-session-1');
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.byTooltip('Send message'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('small layout stays on session list when New chat creation fails', (tester) async {
      controller.failCreate = true;

      await tester.pumpWidget(_wrapApp(const ChatView(), size: const Size(420, 900)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.text('Failed to create chat session'), findsOneWidget);
      expect(controller.activeSessionId.value, isNull);
    });

    testWidgets('session rows show delete action and confirm before deleting', (tester) async {
      controller.sessions.assignAll([
        _session(id: 'session-1', title: 'Design review', preview: 'Latest answer'),
      ]);

      await tester.pumpWidget(_wrapApp(const ChatView(), size: const Size(1200, 900)));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.text('Delete chat?'), findsOneWidget);
      expect(controller.deletedSessionIds, isEmpty);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(controller.deletedSessionIds, ['session-1']);
    });

    testWidgets('assistant citations render inside an expandable Sources section', (tester) async {
      controller.sessions.assignAll([
        _session(id: 'session-1', title: 'Design review'),
      ]);
      controller.messages.assignAll([
        ChatMessage(
          id: 'message-1',
          role: 'assistant',
          content: 'See the referenced notes.',
          createdAt: DateTime.parse('2026-04-12T00:00:03Z'),
          citations: const [
            ChatCitation(path: 'RFC-101', label: 'RFC-101'),
            ChatCitation(path: 'Meeting notes', label: 'Meeting notes'),
          ],
        ),
      ]);
      controller.activeSessionId.value = 'session-1';

      await tester.pumpWidget(_wrapApp(const ChatView(), size: const Size(1200, 900)));
      await tester.pumpAndSettle();

      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('RFC-101'), findsNothing);

      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();

      expect(find.text('RFC-101'), findsOneWidget);
      expect(find.text('Meeting notes'), findsOneWidget);
    });

    testWidgets('assistant citations open the file viewer route when tapped', (tester) async {
      final observer = _TestNavigatorObserver();
      controller.sessions.assignAll([
        _session(id: 'session-1', title: 'Design review'),
      ]);
      controller.messages.assignAll([
        ChatMessage(
          id: 'message-1',
          role: 'assistant',
          content: 'See the referenced notes.',
          createdAt: DateTime.parse('2026-04-12T00:00:03Z'),
          citations: const [
            ChatCitation(
              providerId: 'space-a',
              path: '/team/spec.md',
              label: '/team/spec.md',
            ),
          ],
        ),
      ]);
      controller.activeSessionId.value = 'session-1';

      await tester.pumpWidget(
        _wrapApp(
          const ChatView(),
          size: const Size(1200, 900),
          navigatorObservers: [observer],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/team/spec.md'));
      await tester.pumpAndSettle();

      expect(observer.pushedRoutes, contains('/view?path=space-a%2Fteam%2Fspec.md'));
      expect(Get.currentRoute, FileViewerView.routeName);
      expect(Get.parameters['path'], 'space-a/team/spec.md');
    });

    testWidgets('legacy citations render but do not navigate when tapped', (tester) async {
      final observer = _TestNavigatorObserver();
      controller.sessions.assignAll([
        _session(id: 'session-1', title: 'Design review'),
      ]);
      controller.messages.assignAll([
        ChatMessage(
          id: 'message-1',
          role: 'assistant',
          content: 'See the referenced notes.',
          createdAt: DateTime.parse('2026-04-12T00:00:03Z'),
          citations: const [
            ChatCitation(
              path: '/legacy/path.txt',
              label: '/legacy/path.txt',
            ),
          ],
        ),
      ]);
      controller.activeSessionId.value = 'session-1';

      await tester.pumpWidget(
        _wrapApp(
          const ChatView(),
          size: const Size(1200, 900),
          navigatorObservers: [observer],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/legacy/path.txt'));
      await tester.pumpAndSettle();

      expect(observer.pushedRoutes, isEmpty);
      expect(Get.currentRoute, ChatView.routeName);
    });

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
  });
}

Widget _wrapApp(
  Widget child, {
  Size size = const Size(1200, 900),
  List<NavigatorObserver> navigatorObservers = const [],
}) {
  return MediaQuery(
    data: MediaQueryData(size: size, textScaler: const TextScaler.linear(1.3)),
    child: GetMaterialApp(
      home: child,
      getPages: [
        GetPage(name: FileViewerView.routeName, page: () => const Scaffold(body: SizedBox.shrink())),
      ],
      navigatorObservers: navigatorObservers,
    ),
  );
}

class _TestNavigatorObserver extends NavigatorObserver {
  final List<String?> pushedRoutes = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    pushedRoutes.add(route.settings.name);
  }
}

class _AppBarHost extends StatelessWidget {
  const _AppBarHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: seraphAppBar(
        context,
        routeName: ChatView.routeName,
      ),
    );
  }
}

class _CompactAppBarHost extends StatelessWidget {
  const _CompactAppBarHost({required this.routeName});

  final String routeName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 220,
          child: Scaffold(
            appBar: seraphAppBar(
              context,
              routeName: routeName,
            ),
          ),
        ),
      ),
    );
  }
}

class _FakeChatController extends ChatController {
  _FakeChatController()
      : messagesBySession = <String, List<ChatMessage>>{},
        deletedSessionIds = <String>[],
        sentDrafts = <String>[],
        super(_NoopChatService());

  final Map<String, List<ChatMessage>> messagesBySession;
  final List<String> deletedSessionIds;
  final List<String> sentDrafts;
  int createdSessions = 0;
  bool failCreate = false;

  @override
  Future<void> loadSessions() async {}

  @override
  Future<void> selectSession(String sessionId) async {
    activeSessionId.value = sessionId;
    messages.assignAll(messagesBySession[sessionId] ?? messages);
  }

  @override
  Future<void> createSession(String title) async {
    if (failCreate) {
      appError.value = 'Failed to create chat session';
      return;
    }
    createdSessions += 1;
    final session = _session(
      id: 'new-session-$createdSessions',
      title: title,
      headline: title,
    );
    sessions.insert(0, session);
    messagesBySession[session.id] = [];
    activeSessionId.value = session.id;
    messages.clear();
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    deletedSessionIds.add(sessionId);
    sessions.removeWhere((session) => session.id == sessionId);
    if (activeSessionId.value == sessionId) {
      clearActiveSession();
    }
  }

  @override
  Future<void> sendCurrentMessage() async {
    final draft = draftController.text.trim();
    if (activeSessionId.value == null || draft.isEmpty) {
      return;
    }
    sentDrafts.add(draft);
    draftController.clear();
  }
}

class _NoopChatService extends ChatService {
  _NoopChatService() : super(_FakeSettingsController(), _FakeLoginController());
}

class _FakeShareController extends GetxController implements ShareController {
  @override
  final RxBool shareMode = false.obs;

  @override
  final RxBool fail = false.obs;

  @override
  final RxBool ready = true.obs;

  @override
  final Rx<String?> title = Rx<String?>(null);

  @override
  final RxBool isDir = false.obs;

  @override
  final RxMap<String, String> sharedPaths = <String, String>{}.obs;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSettingsController extends GetxController implements SettingsController {
  final Rx<String> _serverUrl = 'https://seraph.test'.obs;
  final Rx<bool> _serverUrlConfirmed = true.obs;
  final Rx<String?> _oidcIssuer = Rx<String?>(null);
  final Rx<String?> _oidcClientId = Rx<String?>(null);
  final Rx<ThemeMode> _themeMode = Rx<ThemeMode>(ThemeMode.system);
  final Rx<String> _fileBrowserViewMode = 'list'.obs;

  @override
  Rx<String> get serverUrl => _serverUrl;

  @override
  Rx<bool> get serverUrlConfirmed => _serverUrlConfirmed;

  @override
  Rx<String?> get oidcIssuer => _oidcIssuer;

  @override
  Rx<String?> get oidcClientId => _oidcClientId;

  @override
  Rx<ThemeMode> get themeMode => _themeMode;

  @override
  Rx<String> get fileBrowserViewMode => _fileBrowserViewMode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLoginController extends GetxController implements LoginController {
  final Rx<bool> _isInitialized = true.obs;
  final Rx<bool> _isNoAuth = false.obs;
  final Rx<OidcUser?> _currentUser = Rx<OidcUser?>(null);

  @override
  Rx<bool> get isInitialized => _isInitialized;

  @override
  Rx<bool> get isNoAuth => _isNoAuth;

  @override
  Rx<OidcUser?> get currentUser => _currentUser;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatSession _session({
  required String id,
  required String title,
  String? headline,
  String preview = '',
  ChatSessionStatus status = ChatSessionStatus.finished,
}) {
  return ChatSession(
    id: id,
    title: title,
    headline: headline ?? title,
    preview: preview,
    status: status,
    userId: 'alice',
    createdAt: DateTime.parse('2026-04-12T00:00:00Z'),
    updatedAt: DateTime.parse('2026-04-12T00:00:01Z'),
    lastMessageAt: DateTime.parse('2026-04-12T00:00:02Z'),
  );
}

ChatMessage _message({required String id, required String role, required String content}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    createdAt: DateTime.parse('2026-04-12T00:00:03Z'),
    citations: const [],
  );
}
