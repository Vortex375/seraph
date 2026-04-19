import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oidc/oidc.dart';
import 'package:seraph_app/src/chat/chat_controller.dart';
import 'package:seraph_app/src/chat/chat_models.dart';
import 'package:seraph_app/src/chat/chat_service.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatController', () {
    late _FakeChatService chatService;
    late ChatController controller;

    setUp(() {
      chatService = _FakeChatService(
        sessions: [
          _session(id: 'session-1', title: 'Inbox'),
        ],
        messagesBySession: {
          'session-1': [],
        },
      );
      controller = ChatController(chatService);
    });

    tearDown(() {
      controller.onClose();
    });

    test('sendCurrentMessage adds optimistic user message and streams assistant updates', () async {
      final streamController = StreamController<Map<String, dynamic>>();
      chatService.replyStreams['session-1'] = streamController.stream;

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final sendFuture = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      expect(chatService.sentMessages, [
        const _SentMessage('session-1', 'Hello there'),
      ]);
      expect(controller.messages, hasLength(2));
      expect(controller.messages[0].role, 'user');
      expect(controller.messages[0].content, 'Hello there');
      expect(controller.messages[1].role, 'assistant');
      expect(controller.messages[1].content, '');
      expect(controller.sending.value, isTrue);
      expect(controller.draftController.text, isEmpty);

      streamController.add({'type': 'delta', 'content': 'Hello'});
      await Future<void>.microtask(() {});
      expect(controller.messages[1].content, 'Hello');

      streamController.add({'type': 'delta', 'content': ' world'});
      await Future<void>.microtask(() {});
      expect(controller.messages[1].content, 'Hello world');

      await streamController.close();
      await sendFuture;

      expect(controller.sending.value, isFalse);
      expect(controller.historyError.value, isNull);
    });

    test('sendCurrentMessage updates assistant content from plain snapshot and explicit delta payloads', () async {
      final streamController = StreamController<Map<String, dynamic>>();
      chatService.replyStreams['session-1'] = streamController.stream;

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final sendFuture = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      streamController.add({'content': 'Hello'});
      await Future<void>.microtask(() {});
      expect(controller.messages[1].content, 'Hello');

      streamController.add({
        'type': 'delta',
        'id': 'assistant-remote-1',
        'content': ' world',
        'citations': ['RFC-101'],
      });
      await Future<void>.microtask(() {});

      expect(controller.messages[1].id, 'assistant-remote-1');
      expect(controller.messages[1].content, 'Hello world');
      expect(controller.messages[1].citations, hasLength(1));
      expect(controller.messages[1].citations.single.providerId, isNull);
      expect(controller.messages[1].citations.single.path, 'RFC-101');

      await streamController.close();
      await sendFuture;
    });

    test('sendCurrentMessage preserves structured streamed citations', () async {
      final streamController = StreamController<Map<String, dynamic>>();
      chatService.replyStreams['session-1'] = streamController.stream;

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final sendFuture = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      streamController.add({
        'id': 'assistant-remote-1',
        'content': 'Hello',
        'citations': [
          {'provider_id': 'provider-a', 'path': '/team/spec.md'},
          {'provider_id': 'provider-b', 'path': '/team/notes.md'},
        ],
      });
      await Future<void>.microtask(() {});

      expect(controller.messages[1].citations, hasLength(2));
      expect(controller.messages[1].citations[0].providerId, 'provider-a');
      expect(controller.messages[1].citations[0].path, '/team/spec.md');
      expect(controller.messages[1].citations[1].providerId, 'provider-b');
      expect(controller.messages[1].citations[1].path, '/team/notes.md');

      await streamController.close();
      await sendFuture;
    });

    test('sendCurrentMessage preserves legacy string citations from streamed events', () async {
      final streamController = StreamController<Map<String, dynamic>>();
      chatService.replyStreams['session-1'] = streamController.stream;

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final sendFuture = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      streamController.add({
        'id': 'assistant-remote-1',
        'content': 'Hello',
        'citations': ['/team/spec.md'],
      });
      await Future<void>.microtask(() {});

      expect(controller.messages[1].citations, hasLength(1));
      expect(controller.messages[1].citations.single.providerId, isNull);
      expect(controller.messages[1].citations.single.path, '/team/spec.md');

      await streamController.close();
      await sendFuture;
    });

    test('sendCurrentMessage updates assistant content from typed content block payloads', () async {
      final streamController = StreamController<Map<String, dynamic>>();
      chatService.replyStreams['session-1'] = streamController.stream;

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final sendFuture = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      streamController.add({
        'id': 'assistant-remote-1',
        'content': [
          {'type': 'text', 'text': 'Hello'},
        ],
      });
      await Future<void>.microtask(() {});
      expect(controller.messages[1].content, 'Hello');

      streamController.add({
        'id': 'assistant-remote-1',
        'content': [
          {'type': 'text', 'text': 'Hello world'},
        ],
      });
      await Future<void>.microtask(() {});
      expect(controller.messages[1].content, 'Hello world');

      await streamController.close();
      await sendFuture;
    });

    test('snapshot stream payloads replace assistant content and refresh session metadata', () async {
      final streamController = StreamController<Map<String, dynamic>>();
      chatService.replyStreams['session-1'] = streamController.stream;
      chatService.sessions[0] = _session(
        id: 'session-1',
        title: 'Inbox',
        headline: 'Original headline',
        preview: 'Original preview',
        status: ChatSessionStatus.running,
        updatedAt: DateTime.parse('2026-04-12T00:00:01Z'),
        lastMessageAt: DateTime.parse('2026-04-12T00:00:02Z'),
      );

      await controller.loadSessions();
      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final sendFuture = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      streamController.add({'content': 'Hello'});
      await Future<void>.microtask(() {});
      expect(controller.messages[1].content, 'Hello');

      chatService.sessions[0] = _session(
        id: 'session-1',
        title: 'Inbox',
        headline: 'Updated headline',
        preview: 'Updated preview',
        status: ChatSessionStatus.finished,
        updatedAt: DateTime.parse('2026-04-12T00:00:10Z'),
        lastMessageAt: DateTime.parse('2026-04-12T00:00:11Z'),
      );
      streamController.add({'content': 'Hello world'});
      await Future<void>.microtask(() {});

      await streamController.close();
      await sendFuture;

      expect(controller.messages[1].content, 'Hello world');
      expect(controller.sessions.single.headline, 'Updated headline');
      expect(controller.sessions.single.preview, 'Updated preview');
      expect(controller.sessions.single.status, ChatSessionStatus.finished);
      expect(controller.sessions.single.updatedAt, DateTime.parse('2026-04-12T00:00:10Z'));
      expect(controller.sessions.single.lastMessageAt, DateTime.parse('2026-04-12T00:00:11Z'));
    });

    test('selectSession ignores stale response from slower earlier request', () async {
      final firstMessages = Completer<List<ChatMessage>>();
      final secondMessages = Completer<List<ChatMessage>>();
      chatService.sessions.add(_session(id: 'session-2', title: 'Archive'));
      chatService.messageFutures['session-1'] = firstMessages.future;
      chatService.messageFutures['session-2'] = secondMessages.future;

      final firstSelect = controller.selectSession('session-1');
      await Future<void>.microtask(() {});
      final secondSelect = controller.selectSession('session-2');
      await Future<void>.microtask(() {});

      secondMessages.complete([
        _message(id: 'assistant-2', role: 'assistant', content: 'Latest session'),
      ]);
      await secondSelect;

      firstMessages.complete([
        _message(id: 'assistant-1', role: 'assistant', content: 'Stale session'),
      ]);
      await firstSelect;

      expect(controller.activeSessionId.value, 'session-2');
      expect(controller.messages.single.content, 'Latest session');
    });

    test('stream failure exposes recoverable history error', () async {
      chatService.replyStreams['session-1'] = Stream<Map<String, dynamic>>.error(StateError('stream failed'));

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      await controller.sendCurrentMessage();

      expect(controller.messages, hasLength(2));
      expect(controller.messages[0].role, 'user');
      expect(controller.messages[0].content, 'Hello there');
      expect(controller.messages[1].role, 'assistant');
      expect(controller.messages[1].content, '');
      expect(controller.historyError.value, 'Failed to stream assistant reply');
      expect(controller.appError.value, isNull);
      expect(controller.sending.value, isFalse);
    });

    test('delete failure preserves active session and local messages', () async {
      chatService.deleteError = StateError('delete failed');
      chatService.messagesBySession['session-1'] = [
        _message(id: 'assistant-1', role: 'assistant', content: 'Existing reply'),
      ];

      await controller.loadSessions();
      await controller.selectSession('session-1');
      await controller.deleteSession('session-1');

      expect(controller.activeSessionId.value, 'session-1');
      expect(controller.messages, hasLength(1));
      expect(controller.messages.single.content, 'Existing reply');
      expect(controller.sessions, hasLength(1));
      expect(controller.appError.value, 'Failed to delete chat session');
    });

    test('send failure restores draft and removes optimistic placeholders', () async {
      chatService.sendError = StateError('send failed');

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      await controller.sendCurrentMessage();

      expect(controller.messages, isEmpty);
      expect(controller.draftController.text, 'Hello there');
      expect(controller.appError.value, 'Failed to send message');
      expect(controller.historyError.value, isNull);
      expect(controller.sending.value, isFalse);
    });

    test('switching sessions cancels active stream and resets sending', () async {
      final firstStream = StreamController<Map<String, dynamic>>();
      chatService.sessions.add(_session(id: 'session-2', title: 'Archive'));
      chatService.messagesBySession['session-2'] = [];
      chatService.replyStreams['session-1'] = firstStream.stream;
      chatService.replyStreams['session-2'] = const Stream<Map<String, dynamic>>.empty();

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final firstSend = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      expect(controller.sending.value, isTrue);

      await controller.selectSession('session-2');
      await firstSend;

      expect(controller.activeSessionId.value, 'session-2');
      expect(controller.sending.value, isFalse);

      controller.draftController.text = 'Follow up';
      await controller.sendCurrentMessage();

      expect(chatService.sentMessages, [
        const _SentMessage('session-1', 'Hello there'),
        const _SentMessage('session-2', 'Follow up'),
      ]);

      await firstStream.close();
    });

    test('late events from a cancelled stream do not mutate the newly selected session', () async {
      final firstStream = StreamController<Map<String, dynamic>>.broadcast();
      final secondStream = StreamController<Map<String, dynamic>>();
      chatService.sessions.add(_session(id: 'session-2', title: 'Archive'));
      chatService.messagesBySession['session-2'] = [
        _message(id: 'assistant-2', role: 'assistant', content: 'Existing session-2 reply'),
      ];
      chatService.replyStreams['session-1'] = firstStream.stream;
      chatService.replyStreams['session-2'] = secondStream.stream;

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final firstSend = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      await controller.selectSession('session-2');
      expect(controller.activeSessionId.value, 'session-2');
      expect(controller.messages.single.content, 'Existing session-2 reply');

      firstStream.add({
        'id': 'assistant-remote-1',
        'type': 'delta',
        'content': 'late reply',
        'citations': [
          {'provider_id': 'provider-a', 'path': '/team/spec.md'},
        ],
      });
      await Future<void>.microtask(() {});
      await firstSend;

      expect(controller.activeSessionId.value, 'session-2');
      expect(controller.messages, hasLength(1));
      expect(controller.messages.single.content, 'Existing session-2 reply');
      expect(controller.messages.single.citations, isEmpty);

      await firstStream.close();
      await secondStream.close();
    });

    test('late stream completion from a cancelled session does not finish the active send', () async {
      final firstStream = _ManualReplyStream();
      final secondStream = StreamController<Map<String, dynamic>>();
      chatService.sessions.add(_session(id: 'session-2', title: 'Archive'));
      chatService.messagesBySession['session-2'] = [];
      chatService.replyStreams['session-1'] = firstStream;
      chatService.replyStreams['session-2'] = secondStream.stream;

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final firstSend = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      await controller.selectSession('session-2');
      controller.draftController.text = 'Follow up';

      final secondSend = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});
      expect(controller.sending.value, isTrue);

      firstStream.emitDone();
      await Future<void>.microtask(() {});

      expect(controller.sending.value, isTrue);
      expect(controller.historyError.value, isNull);

      await firstSend;
      await secondStream.close();
      await secondSend;
    });

    test('late stream errors from a cancelled session do not fail the active send', () async {
      final firstStream = _ManualReplyStream();
      final secondStream = StreamController<Map<String, dynamic>>();
      chatService.sessions.add(_session(id: 'session-2', title: 'Archive'));
      chatService.messagesBySession['session-2'] = [];
      chatService.replyStreams['session-1'] = firstStream;
      chatService.replyStreams['session-2'] = secondStream.stream;

      await controller.selectSession('session-1');
      controller.draftController.text = 'Hello there';

      final firstSend = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});

      await controller.selectSession('session-2');
      controller.draftController.text = 'Follow up';

      final secondSend = controller.sendCurrentMessage();
      await Future<void>.microtask(() {});
      expect(controller.sending.value, isTrue);

      firstStream.emitError(StateError('stale error'));
      await Future<void>.microtask(() {});

      expect(controller.sending.value, isTrue);
      expect(controller.historyError.value, isNull);

      await firstSend;
      await secondStream.close();
      await secondSend;
    });
  });
}

class _FakeChatService extends ChatService {
  _FakeChatService({
    required this.sessions,
    required this.messagesBySession,
  }) : super(_FakeSettingsController(), _FakeLoginController());

  final List<ChatSession> sessions;
  final Map<String, List<ChatMessage>> messagesBySession;
  final Map<String, Future<List<ChatMessage>>> messageFutures = {};
  final Map<String, Stream<Map<String, dynamic>>> replyStreams = {};
  final List<_SentMessage> sentMessages = [];
  Object? deleteError;
  Object? sendError;

  @override
  Future<List<ChatSession>> listSessions() async => List<ChatSession>.from(sessions);

  @override
  Future<ChatSession> createSession(String title) async {
    final session = _session(id: 'session-${sessions.length + 1}', title: title);
    sessions.add(session);
    messagesBySession[session.id] = [];
    return session;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    if (deleteError != null) {
      throw deleteError!;
    }
    sessions.removeWhere((session) => session.id == sessionId);
    messagesBySession.remove(sessionId);
  }

  @override
  Future<List<ChatMessage>> listMessages(String sessionId) async {
    final future = messageFutures[sessionId];
    if (future != null) {
      return List<ChatMessage>.from(await future);
    }
    return List<ChatMessage>.from(messagesBySession[sessionId] ?? const []);
  }

  @override
  Future<void> sendMessage(String sessionId, String message) async {
    if (sendError != null) {
      throw sendError!;
    }
    sentMessages.add(_SentMessage(sessionId, message));
  }

  @override
  Stream<Map<String, dynamic>> streamAssistantReply(String sessionId) {
    return replyStreams[sessionId] ?? const Stream<Map<String, dynamic>>.empty();
  }
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

class _SentMessage {
  const _SentMessage(this.sessionId, this.message);

  final String sessionId;
  final String message;

  @override
  bool operator ==(Object other) {
    return other is _SentMessage &&
        other.sessionId == sessionId &&
        other.message == message;
  }

  @override
  int get hashCode => Object.hash(sessionId, message);
}

class _ManualReplyStream extends Stream<Map<String, dynamic>> {
  _ManualReplySubscription? _subscription;

  void emitDone() {
    _subscription?.emitDone();
  }

  void emitError(Object error) {
    _subscription?.emitError(error);
  }

  @override
  StreamSubscription<Map<String, dynamic>> listen(
    void Function(Map<String, dynamic> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = _ManualReplySubscription(
      onData: onData,
      onError: onError,
      onDone: onDone,
    );
    _subscription = subscription;
    return subscription;
  }
}

class _ManualReplySubscription implements StreamSubscription<Map<String, dynamic>> {
  _ManualReplySubscription({
    void Function(Map<String, dynamic> event)? onData,
    Function? onError,
    void Function()? onDone,
  })  : _onData = onData,
        _onError = onError,
        _onDone = onDone;

  void Function(Map<String, dynamic> event)? _onData;
  Function? _onError;
  void Function()? _onDone;
  bool _isPaused = false;

  void emitDone() {
    _onDone?.call();
  }

  void emitError(Object error) {
    final handler = _onError;
    if (handler is void Function(Object)) {
      handler(error);
      return;
    }
    if (handler is void Function(Object, StackTrace)) {
      handler(error, StackTrace.empty);
      return;
    }
    if (handler is void Function()) {
      handler();
    }
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue as E);

  @override
  Future<void> cancel() async {}

  @override
  bool get isPaused => _isPaused;

  @override
  void onData(void Function(Map<String, dynamic> data)? handleData) {
    _onData = handleData;
  }

  @override
  void onDone(void Function()? handleDone) {
    _onDone = handleDone;
  }

  @override
  void onError(Function? handleError) {
    _onError = handleError;
  }

  @override
  void pause([Future<void>? resumeSignal]) {
    _isPaused = true;
    resumeSignal?.whenComplete(resume);
  }

  @override
  void resume() {
    _isPaused = false;
  }
}

ChatSession _session({
  required String id,
  required String title,
  String? headline,
  String preview = '',
  ChatSessionStatus status = ChatSessionStatus.finished,
  DateTime? updatedAt,
  DateTime? lastMessageAt,
}) {
  return ChatSession(
    id: id,
    title: title,
    headline: headline ?? title,
    preview: preview,
    status: status,
    userId: 'alice',
    createdAt: DateTime.parse('2026-04-12T00:00:00Z'),
    updatedAt: updatedAt ?? DateTime.parse('2026-04-12T00:00:01Z'),
    lastMessageAt: lastMessageAt ?? DateTime.parse('2026-04-12T00:00:02Z'),
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
