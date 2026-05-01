import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:http/http.dart' as http;
import 'package:oidc/oidc.dart';
import 'package:seraph_app/src/chat/chat_models.dart';
import 'package:seraph_app/src/chat/chat_service.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      'status': 'failed',
      'error': 'upstream provider error',
      'citations': [
        {
          'provider_id': 'space-a',
          'path': '/Music/example.url',
          'label': 'Example URL',
        },
        '/legacy/path.txt',
      ],
    });

    expect(session.headline, 'Inbox');
    expect(session.status, ChatSessionStatus.finished);
    expect(message.citations, hasLength(2));
    expect(message.citations[0].providerId, 'space-a');
    expect(message.citations[0].path, '/Music/example.url');
    expect(message.citations[0].label, 'Example URL');
    expect(message.citations[0].viewerPath, 'space-a/Music/example.url');
    expect(message.citations[0].isNavigable, isTrue);
    expect(message.citations[1].providerId, isNull);
    expect(message.citations[1].path, '/legacy/path.txt');
    expect(message.citations[1].label, '/legacy/path.txt');
    expect(message.citations[1].viewerPath, '/legacy/path.txt');
    expect(message.citations[1].isNavigable, isFalse);
    expect(message.status, ChatMessageStatus.failed);
    expect(message.error, 'upstream provider error');
  });

  test('chat session decode rejects unknown backend status', () {
    expect(
      () => ChatSession.fromJson({
        'id': 'session-1',
        'title': 'Inbox',
        'headline': 'Inbox',
        'preview': 'Last preview line',
        'status': 'queued',
        'user_id': 'alice',
        'created_at': '2026-04-12T00:00:00Z',
        'updated_at': '2026-04-12T00:00:01Z',
        'last_message_at': '2026-04-12T00:00:02Z',
      }),
      throwsA(isA<FormatException>()),
    );
  });

  group('ChatService', () {
    late SettingsController settingsController;
    late LoginController loginController;
    late Dio dio;
    late _FakeStreamHttpClient httpClient;
    late ChatService service;

    setUp(() {
      Get.testMode = true;
      settingsController = _FakeSettingsController('https://seraph.test');
      loginController = _FakeLoginController.initialized('access-token');
      dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));
      httpClient = _FakeStreamHttpClient();
      service = ChatService(settingsController, loginController, dio: dio, httpClient: httpClient);
    });

    test('listSessions decodes backend session metadata', () async {
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/api/v1/chat/sessions');
            expect(options.headers['Authorization'], 'Bearer access-token');

            handler.resolve(
              Response<List<dynamic>>(
                requestOptions: options,
                data: [
                  {
                    'id': 'session-1',
                    'title': 'Inbox summary',
                    'headline': 'Inbox summary',
                    'preview': 'Latest assistant response',
                    'status': 'running',
                    'user_id': 'alice',
                    'created_at': '2026-04-12T00:00:00Z',
                    'updated_at': '2026-04-12T00:00:10Z',
                    'last_message_at': '2026-04-12T00:00:20Z',
                  }
                ],
              ),
            );
          },
        ),
      );

      final sessions = await service.listSessions();

      expect(sessions, hasLength(1));
      expect(sessions.single.id, 'session-1');
      expect(sessions.single.preview, 'Latest assistant response');
      expect(sessions.single.status, ChatSessionStatus.running);
      expect(sessions.single.lastMessageAt.toUtc(), DateTime.parse('2026-04-12T00:00:20Z'));
    });

    test('sendMessageAndStreamReply posts a streamed backend request', () async {
      httpClient.handler = (request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), 'https://seraph.test/api/v1/chat/sessions/session-1/messages/stream');
        expect(request.headers['Accept'], 'text/event-stream');
        expect(request.headers['Content-Type'], startsWith('application/json'));
        expect(request.headers['Authorization'], 'Bearer access-token');
        expect(await request.finalize().bytesToString(), '{"message":"Hello there"}');

        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            utf8.encode('event: reply\n'),
            utf8.encode('data: {"type":"delta",'),
            utf8.encode('"content":"Hello"}\n\n'),
            utf8.encode('data: {"type":"done"}\n\n'),
          ]),
          200,
          headers: const {
            'content-type': 'text/event-stream',
          },
        );
      };

      final events = await service.sendMessageAndStreamReply('session-1', 'Hello there').toList();

      expect(events, [
        {'type': 'delta', 'content': 'Hello'},
        {'type': 'done'},
      ]);
    });
  });
}

typedef _StreamedHandler = Future<http.StreamedResponse> Function(http.BaseRequest request);

class _FakeStreamHttpClient extends http.BaseClient {
  _StreamedHandler? handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final handler = this.handler;
    if (handler == null) {
      throw StateError('No HTTP stream handler configured');
    }

    return handler(request);
  }
}

class _FakeSettingsController extends GetxController implements SettingsController {
  _FakeSettingsController(String serverUrl)
      : _serverUrl = serverUrl.obs,
        _serverUrlConfirmed = true.obs,
        _oidcIssuer = Rx<String?>(null),
        _oidcClientId = Rx<String?>(null),
        _themeMode = Rx<ThemeMode>(ThemeMode.system),
        _fileBrowserViewMode = 'list'.obs;

  final Rx<String> _serverUrl;
  final Rx<bool> _serverUrlConfirmed;
  final Rx<String?> _oidcIssuer;
  final Rx<String?> _oidcClientId;
  final Rx<ThemeMode> _themeMode;
  final Rx<String> _fileBrowserViewMode;

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
  _FakeLoginController._(this._isInitialized, this._currentUser, this._isNoAuth);

  factory _FakeLoginController.initialized(String token) {
    return _FakeLoginController._(
      true.obs,
      Rx<OidcUser?>(_FakeOidcUser(token)),
      false.obs,
    );
  }

  final Rx<bool> _isInitialized;
  final Rx<OidcUser?> _currentUser;
  final Rx<bool> _isNoAuth;

  @override
  Rx<bool> get isInitialized => _isInitialized;

  @override
  Rx<OidcUser?> get currentUser => _currentUser;

  @override
  Rx<bool> get isNoAuth => _isNoAuth;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOidcUser implements OidcUser {
  _FakeOidcUser(String accessToken) : _token = _FakeOidcToken(accessToken);

  final OidcToken _token;

  @override
  OidcToken get token => _token;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOidcToken implements OidcToken {
  _FakeOidcToken(this.accessToken);

  @override
  final String accessToken;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
