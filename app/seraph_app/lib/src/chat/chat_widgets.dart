import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:seraph_app/src/chat/chat_navigation.dart';
import 'package:seraph_app/src/chat/chat_models.dart';

class ChatSessionList extends StatelessWidget {
  const ChatSessionList({
    super.key,
    required this.sessions,
    required this.activeSessionId,
    required this.onSelectSession,
    required this.onNewChat,
    required this.onDeleteSession,
    required this.loading,
    required this.errorText,
  });

  final List<ChatSession> sessions;
  final String? activeSessionId;
  final ValueChanged<String> onSelectSession;
  final VoidCallback onNewChat;
  final ValueChanged<String> onDeleteSession;
  final bool loading;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: FilledButton.icon(
            onPressed: onNewChat,
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('New chat'),
          ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              errorText!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : sessions.isEmpty
                  ? const Center(child: Text('No conversations yet'))
                  : ListView.builder(
                      itemCount: sessions.length,
                      itemBuilder: (context, index) {
                        final session = sessions[index];
                        final selected = session.id == activeSessionId;
                        final isRunning = session.status == ChatSessionStatus.running;
                        return ListTile(
                          selected: selected,
                          leading: Icon(
                            isRunning ? Icons.sync : Icons.check_circle_outline,
                            color: isRunning ? Theme.of(context).colorScheme.primary : null,
                          ),
                          title: Text(session.headline),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (session.preview.isNotEmpty) Text(session.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
                              Text(isRunning ? 'Running' : 'Finished'),
                            ],
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete chat',
                            onPressed: () => onDeleteSession(session.id),
                          ),
                          onTap: () => onSelectSession(session.id),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class ChatConversationPane extends StatefulWidget {
  const ChatConversationPane({
    super.key,
    required this.sessionTitle,
    required this.messages,
    required this.loading,
    required this.errorText,
    required this.hasActiveSession,
    required this.draftController,
    required this.onSend,
    this.onBack,
  });

  final String? sessionTitle;
  final List<ChatMessage> messages;
  final bool loading;
  final String? errorText;
  final bool hasActiveSession;
  final TextEditingController draftController;
  final VoidCallback onSend;
  final VoidCallback? onBack;

  @override
  State<ChatConversationPane> createState() => _ChatConversationPaneState();
}

class _ChatConversationPaneState extends State<ChatConversationPane> {
  late final ScrollController _scrollController;
  late final FocusNode _composerFocusNode;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _composerFocusNode = FocusNode(onKeyEvent: _handleComposerKey);
  }

  @override
  void didUpdateWidget(covariant ChatConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hasActiveSession &&
        (!oldWidget.hasActiveSession ||
            oldWidget.messages.length != widget.messages.length ||
            _lastMessageChanged(oldWidget.messages, widget.messages))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) {
          return;
        }
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      });
    }
  }

  bool _lastMessageChanged(List<ChatMessage> previous, List<ChatMessage> next) {
    if (previous.isEmpty || next.isEmpty) {
      return false;
    }
    final oldLast = previous.last;
    final newLast = next.last;
    return oldLast.content != newLast.content || oldLast.citations != newLast.citations;
  }

  @override
  void dispose() {
    _composerFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }

    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }

    widget.onSend();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.hasActiveSession) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48),
            SizedBox(height: 12),
            Text('Select a conversation'),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
          child: Row(
            children: [
              if (widget.onBack != null)
                IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(
                  widget.sessionTitle ?? 'Conversation',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
        ),
        if (widget.errorText != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        Expanded(
          child: widget.loading
              ? const Center(child: CircularProgressIndicator())
              : widget.messages.isEmpty
                  ? const Center(child: Text('No messages yet'))
                  : SelectionArea(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: widget.messages.length,
                        itemBuilder: (context, index) {
                          final message = widget.messages[index];
                          return ChatMessageCard(message: message);
                        },
                      ),
                    ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    focusNode: _composerFocusNode,
                    controller: widget.draftController,
                    minLines: 1,
                    maxLines: 4,
                    onSubmitted: (_) => widget.onSend(),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Message',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filled(
                  onPressed: widget.onSend,
                  tooltip: 'Send message',
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ChatMessageCard extends StatelessWidget {
  const ChatMessageCard({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isAssistant = message.role == 'assistant';
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isAssistant ? Alignment.centerLeft : Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Card(
          color: isAssistant ? colorScheme.surfaceContainerHighest : colorScheme.primaryContainer,
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAssistant
                      ? (message.status == ChatMessageStatus.failed
                          ? 'Assistant failed'
                          : 'Assistant')
                      : 'You',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                if (isAssistant)
                  MarkdownBody(
                    data: message.content,
                    styleSheet: MarkdownStyleSheet(
                      p: Theme.of(context).textTheme.bodyMedium,
                      code: TextStyle(
                        fontFamily: 'monospace',
                        backgroundColor: colorScheme.surfaceContainerHighest,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  )
                else
                  Text(message.content),
                if (isAssistant && message.status == ChatMessageStatus.failed && message.error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    message.error!,
                    style: TextStyle(
                      color: colorScheme.error,
                      fontSize: Theme.of(context).textTheme.bodySmall?.fontSize,
                    ),
                  ),
                ],
                if (message.citations.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: const Text('Sources'),
                    children: message.citations
                        .map(
                          (citation) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(citation.label),
                            dense: true,
                            enabled: citation.isNavigable,
                            onTap: citation.isNavigable ? () => openChatCitation(citation) : null,
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
