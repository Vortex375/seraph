import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/chat/chat_models.dart';
import 'package:seraph_app/src/chat/chat_widgets.dart';

void main() {
  testWidgets('assistant message card renders markdown body', (tester) async {
    final message = ChatMessage(
      id: 'msg-1',
      role: 'assistant',
      content: '## Hello\n\nThis is **bold**.',
      createdAt: DateTime.parse('2026-04-12T00:00:00Z'),
      citations: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageCard(message: message),
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
  });

  testWidgets('user message card renders plain text', (tester) async {
    final message = ChatMessage(
      id: 'msg-2',
      role: 'user',
      content: 'Plain text',
      createdAt: DateTime.parse('2026-04-12T00:00:00Z'),
      citations: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageCard(message: message),
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('Plain text'), findsOneWidget);
  });

  testWidgets('conversation pane wraps messages in SelectionArea', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatConversationPane(
            sessionTitle: 'Test',
            messages: [
              ChatMessage(
                id: 'msg-1',
                role: 'assistant',
                content: 'Selectable text',
                createdAt: DateTime.parse('2026-04-12T00:00:00Z'),
                citations: const [],
              ),
            ],
            loading: false,
            errorText: null,
            hasActiveSession: true,
            draftController: TextEditingController(),
            onSend: () {},
          ),
        ),
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('Selectable text'), findsOneWidget);
  });
}
