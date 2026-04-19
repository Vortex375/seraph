enum ChatSessionStatus { running, finished }

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

    if (json is! Map<String, dynamic>) {
      throw FormatException('Unknown chat citation payload: $json');
    }

    final path = json['path'] as String?;
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

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String,
      title: json['title'] as String,
      headline: json['headline'] as String,
      preview: (json['preview'] as String?) ?? '',
      status: _parseStatus(json['status'] as String),
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
  final List<ChatCitation> citations;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      citations: ((json['citations'] as List<dynamic>?) ?? const [])
          .map(ChatCitation.fromJson)
          .toList(),
    );
  }
}
