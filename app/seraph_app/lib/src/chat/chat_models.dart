enum ChatSessionStatus { running, finished }

enum ChatMessageStatus { pending, failed, finished }

class ChatCitation {
  const ChatCitation({
    this.providerId,
    required this.path,
    required this.label,
  });

  final String? providerId;
  final String path;
  final String label;

  bool get isNavigable => providerId != null && providerId!.isNotEmpty;

  factory ChatCitation.fromJson(dynamic json) {
    if (json is String) {
      return ChatCitation(providerId: null, path: json, label: json);
    }

    if (json is! Map) {
      throw FormatException('Unknown chat citation payload: $json');
    }

    final parsed = json.cast();
    final path = parsed['path'] as String?;
    if (path == null || path.isEmpty) {
      throw const FormatException('Chat citation path is required');
    }

    final providerId = json['provider_id'] as String?;
    return ChatCitation(
      providerId: providerId == null || providerId.isEmpty ? null : providerId,
      path: path,
      label: (json['label'] as String?) ?? path,
    );
  }

  String get viewerPath {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final providerId = this.providerId;
    if (providerId == null || providerId.isEmpty) {
      return normalizedPath;
    }
    return '$providerId$normalizedPath';
  }
}

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

  static ChatSessionStatus _parseStatus(String value) {
    switch (value) {
      case 'running':
        return ChatSessionStatus.running;
      case 'finished':
        return ChatSessionStatus.finished;
    }

    throw FormatException('Unknown chat session status: $value');
  }

  factory ChatSession.fromJson(Map json) {
    final parsed = json.cast();
    return ChatSession(
      id: parsed['id'] as String,
      title: parsed['title'] as String,
      headline: parsed['headline'] as String,
      preview: (parsed['preview'] as String?) ?? '',
      status: _parseStatus(parsed['status'] as String),
      userId: parsed['user_id'] as String,
      createdAt: DateTime.parse(parsed['created_at'] as String),
      updatedAt: DateTime.parse(parsed['updated_at'] as String),
      lastMessageAt: DateTime.parse(parsed['last_message_at'] as String),
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
    this.status = ChatMessageStatus.finished,
    this.error,
  });

  final String id;
  final String role;
  final String content;
  final DateTime createdAt;
  final List<ChatCitation> citations;
  final ChatMessageStatus status;
  final String? error;

  static ChatMessageStatus _parseStatus(String? value) {
    switch (value) {
      case 'pending':
        return ChatMessageStatus.pending;
      case 'failed':
        return ChatMessageStatus.failed;
      case 'finished':
      case null:
        return ChatMessageStatus.finished;
    }

    throw FormatException('Unknown chat message status: $value');
  }

  factory ChatMessage.fromJson(Map json) {
    final parsed = json.cast();
    return ChatMessage(
      id: parsed['id'] as String,
      role: parsed['role'] as String,
      content: parsed['content'] as String,
      createdAt: DateTime.parse(parsed['created_at'] as String),
      citations: ((parsed['citations'] as List?) ?? const [])
          .map(ChatCitation.fromJson)
          .toList(),
      status: _parseStatus(parsed['status'] as String?),
      error: parsed['error'] as String?,
    );
  }
}
