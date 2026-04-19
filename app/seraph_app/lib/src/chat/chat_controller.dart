import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/chat/chat_models.dart';
import 'package:seraph_app/src/chat/chat_service.dart';

class ChatController extends GetxController {
  ChatController(this.chatService);

  final ChatService chatService;

  final TextEditingController draftController = TextEditingController();
  final RxList<ChatSession> sessions = RxList<ChatSession>([]);
  final RxList<ChatMessage> messages = RxList<ChatMessage>([]);
  final RxnString activeSessionId = RxnString();
  final RxnString appError = RxnString();
  final RxnString historyError = RxnString();
  final RxBool sessionsLoading = false.obs;
  final RxBool messagesLoading = false.obs;
  final RxBool sending = false.obs;

  StreamSubscription<Map<String, dynamic>>? _replySubscription;
  Completer<void>? _replyCompleter;
  int _selectionRequestId = 0;
  int _replyGeneration = 0;

  @override
  void onClose() {
    draftController.dispose();
    _cancelReplySubscription(resetSending: true);
    super.onClose();
  }

  Future<void> loadSessions() async {
    sessionsLoading.value = true;
    appError.value = null;
    try {
      sessions.assignAll(await chatService.listSessions());
    } catch (_) {
      appError.value = 'Failed to load chat sessions';
    } finally {
      sessionsLoading.value = false;
    }
  }

  Future<void> selectSession(String sessionId) async {
    final requestId = ++_selectionRequestId;
    _cancelReplySubscription(resetSending: true);
    activeSessionId.value = sessionId;
    messagesLoading.value = true;
    historyError.value = null;
    try {
      final sessionMessages = await chatService.listMessages(sessionId);
      if (requestId != _selectionRequestId || activeSessionId.value != sessionId) {
        return;
      }
      messages.assignAll(sessionMessages);
    } catch (_) {
      if (requestId != _selectionRequestId || activeSessionId.value != sessionId) {
        return;
      }
      messages.clear();
      historyError.value = 'Failed to load chat history';
    } finally {
      if (requestId == _selectionRequestId && activeSessionId.value == sessionId) {
        messagesLoading.value = false;
      }
    }
  }

  Future<void> createSession(String title) async {
    appError.value = null;
    try {
      final session = await chatService.createSession(title);
      sessions.insert(0, session);
      await selectSession(session.id);
    } catch (_) {
      appError.value = 'Failed to create chat session';
    }
  }

  Future<void> deleteSession(String sessionId) async {
    appError.value = null;
    try {
      final wasActive = activeSessionId.value == sessionId;
      if (wasActive) {
        _cancelReplySubscription(resetSending: true);
      }
      await chatService.deleteSession(sessionId);
      sessions.removeWhere((session) => session.id == sessionId);
      if (wasActive) {
        clearActiveSession();
      }
    } catch (_) {
      appError.value = 'Failed to delete chat session';
    }
  }

  Future<void> sendCurrentMessage() async {
    final sessionId = activeSessionId.value;
    final draft = draftController.text.trim();
    if (sessionId == null || draft.isEmpty || sending.value) {
      return;
    }

    final userMessage = ChatMessage(
      id: 'local-user-${DateTime.now().microsecondsSinceEpoch}',
      role: 'user',
      content: draft,
      createdAt: DateTime.now().toUtc(),
      citations: const [],
    );
    final assistantMessage = ChatMessage(
      id: 'local-assistant-${DateTime.now().microsecondsSinceEpoch}',
      role: 'assistant',
      content: '',
      createdAt: DateTime.now().toUtc(),
      citations: const [],
    );

    messages.add(userMessage);
    messages.add(assistantMessage);
    draftController.clear();
    sending.value = true;
    appError.value = null;
    historyError.value = null;

    try {
      await chatService.sendMessage(sessionId, draft);
      _cancelReplySubscription();
      final replyGeneration = ++_replyGeneration;
      _replyCompleter = Completer<void>();
      _replySubscription = chatService.streamAssistantReply(sessionId).listen(
        (event) async {
          if (replyGeneration != _replyGeneration || activeSessionId.value != sessionId || messages.isEmpty) {
            return;
          }
          final content = _extractStreamContent(event['content']);
          final type = event['type'];
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
        },
        onError: (_) {
          if (replyGeneration != _replyGeneration || activeSessionId.value != sessionId) {
            return;
          }
          historyError.value = 'Failed to stream assistant reply';
          sending.value = false;
          _completeReply();
        },
        onDone: () {
          if (replyGeneration != _replyGeneration || activeSessionId.value != sessionId) {
            return;
          }
          sending.value = false;
          _completeReply();
        },
      );
      await _replyCompleter?.future;
      await _refreshSessionMetadata(sessionId);
    } catch (_) {
      messages.remove(userMessage);
      messages.remove(assistantMessage);
      draftController.text = draft;
      appError.value = 'Failed to send message';
      sending.value = false;
    }
  }

  String? _extractStreamContent(dynamic rawContent) {
    if (rawContent is String) {
      return rawContent;
    }

    if (rawContent is List<dynamic>) {
      final text = rawContent
          .whereType<Map<dynamic, dynamic>>()
          .map((block) {
            final type = block['type'];
            final text = block['text'];
            return type == 'text' && text is String ? text : null;
          })
          .whereType<String>()
          .join();
      return text.isEmpty ? null : text;
    }

    return null;
  }

  void clearActiveSession() {
    _cancelReplySubscription(resetSending: true);
    activeSessionId.value = null;
    messages.clear();
    messagesLoading.value = false;
    sending.value = false;
    historyError.value = null;
  }

  void _cancelReplySubscription({bool resetSending = false}) {
    _replyGeneration++;
    _replySubscription?.cancel();
    _replySubscription = null;
    if (resetSending) {
      sending.value = false;
    }
    _completeReply();
  }

  void _completeReply() {
    final completer = _replyCompleter;
    _replyCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  List<ChatCitation> _extractStreamCitations(dynamic rawCitations, List<ChatCitation> fallback) {
    if (rawCitations is! List<dynamic>) {
      return fallback;
    }

    return rawCitations
        .map(_extractCitation)
        .whereType<ChatCitation>()
        .toList();
  }

  ChatCitation? _extractCitation(dynamic citation) {
    if (citation is String && citation.isNotEmpty) {
      return ChatCitation.fromJson(citation);
    }

    if (citation is Map<dynamic, dynamic>) {
      final normalized = citation.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      try {
        return ChatCitation.fromJson(normalized);
      } on FormatException {
        return null;
      }
    }

    return null;
  }

  Future<void> _refreshSessionMetadata(String sessionId) async {
    try {
      final latestSessions = await chatService.listSessions();
      final latestSession = latestSessions.firstWhereOrNull((session) => session.id == sessionId);
      if (latestSession == null) {
        return;
      }

      final index = sessions.indexWhere((session) => session.id == sessionId);
      if (index >= 0) {
        sessions[index] = latestSession;
      } else {
        sessions.insert(0, latestSession);
      }
    } catch (_) {
      // Keep the current sidebar state when refresh fails.
    }
  }
}
