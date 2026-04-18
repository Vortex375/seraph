import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
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
      'citations': ['/Music/example.url'],
    });

    expect(session.headline, 'Inbox');
    expect(session.status, ChatSessionStatus.finished);
    expect(message.citations, ['/Music/example.url']);
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
    late ChatService service;

    setUp(() {
      Get.testMode = true;
      settingsController = _FakeSettingsController('https://seraph.test');
      loginController = _FakeLoginController.initialized('access-token');
      dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));
      service = ChatService(settingsController, loginController, dio: dio);
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

    test('sendMessage posts approved backend payload', () async {
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/api/v1/chat/sessions/session-1/messages');
            expect(options.data, {'message': 'Hello there'});
            expect(options.data, isNot({'content': 'Hello there'}));
            expect(options.headers['Authorization'], 'Bearer access-token');

            handler.resolve(Response<void>(requestOptions: options));
          },
        ),
      );

      await service.sendMessage('session-1', 'Hello there');
    });

    test('streamAssistantReply parses text event stream payloads', () async {
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/api/v1/chat/sessions/session-1/stream');
            expect(options.responseType, ResponseType.stream);
            expect(options.headers['Accept'], 'text/event-stream');
            expect(options.headers['Authorization'], 'Bearer access-token');

            handler.resolve(
              Response<ResponseBody>(
                requestOptions: options,
                data: ResponseBody(
                  Stream<Uint8List>.fromIterable([
                    Uint8List.fromList(utf8.encode('event: reply\n')),
                    Uint8List.fromList(utf8.encode('data: {"type":"delta",')),
                    Uint8List.fromList(utf8.encode('"content":"Hello"}\n\n')),
                    Uint8List.fromList(utf8.encode('data: {"type":"done"}\n\n')),
                  ]),
                  200,
                  headers: {
                    Headers.contentTypeHeader: ['text/event-stream'],
                  },
                ),
              ),
            );
          },
        ),
      );

      final events = await service.streamAssistantReply('session-1').toList();

      expect(events, [
        {'type': 'delta', 'content': 'Hello'},
        {'type': 'done'},
      ]);
    });
  });
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
