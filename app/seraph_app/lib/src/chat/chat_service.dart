import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:seraph_app/src/chat/chat_models.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/util.dart';

class ChatService {
  ChatService(this.settingsController, this.loginController, {Dio? dio})
      : dio = dio ?? Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));

  final SettingsController settingsController;
  final LoginController loginController;
  final Dio dio;

  Future<Map<String, String>> _getRequestHeaders() async {
    await until(loginController.isInitialized, identity);

    if (loginController.currentUser.value != null) {
      return {
        'Authorization': 'Bearer ${loginController.currentUser.value?.token.accessToken}'
      };
    }

    return {};
  }

  Future<List<ChatSession>> listSessions() async {
    final response = await dio.get<List<dynamic>>(
      '/api/v1/chat/sessions',
      options: Options(headers: await _getRequestHeaders()),
    );

    return (response.data ?? const [])
        .map((item) => ChatSession.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<ChatSession> createSession(String title) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/api/v1/chat/sessions',
      data: {'title': title},
      options: Options(headers: await _getRequestHeaders()),
    );

    return ChatSession.fromJson(response.data!);
  }

  Future<void> deleteSession(String sessionId) async {
    await dio.delete<void>(
      '/api/v1/chat/sessions/$sessionId',
      options: Options(headers: await _getRequestHeaders()),
    );
  }

  Future<List<ChatMessage>> listMessages(String sessionId) async {
    final response = await dio.get<List<dynamic>>(
      '/api/v1/chat/sessions/$sessionId/messages',
      options: Options(headers: await _getRequestHeaders()),
    );

    return (response.data ?? const [])
        .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> sendMessage(String sessionId, String message) async {
    await dio.post<void>(
      '/api/v1/chat/sessions/$sessionId/messages',
      data: {'message': message},
      options: Options(headers: await _getRequestHeaders()),
    );
  }

  Stream<Map<String, dynamic>> streamAssistantReply(String sessionId) async* {
    final response = await dio.get<ResponseBody>(
      '/api/v1/chat/sessions/$sessionId/stream',
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'Accept': 'text/event-stream',
          ...await _getRequestHeaders(),
        },
      ),
    );

    final stream = response.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    final dataLines = <String>[];
    await for (final line in stream) {
      if (line.isEmpty) {
        if (dataLines.isEmpty) {
          continue;
        }

        final payload = dataLines.join('\n');
        dataLines.clear();
        yield json.decode(payload) as Map<String, dynamic>;
        continue;
      }

      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
  }
}
