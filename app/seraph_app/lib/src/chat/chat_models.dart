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
