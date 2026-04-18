import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/chat/chat_controller.dart';
import 'package:seraph_app/src/chat/chat_widgets.dart';

class ChatView extends StatefulWidget {
  const ChatView({super.key});

  static const routeName = '/chat';

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  late final ChatController controller;
  bool showCompactConversation = false;

  @override
  void initState() {
    super.initState();
    controller = Get.find<ChatController>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.loadSessions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLargeLayout = MediaQuery.sizeOf(context).width >= 800;
    return Obx(() {
      final sessions = controller.sessions.toList(growable: false);
      final messages = controller.messages.toList(growable: false);
      final activeSessionId = controller.activeSessionId.value;
      final activeSession = sessions.firstWhereOrNull(
        (session) => session.id == activeSessionId,
      );

      final sessionList = ChatSessionList(
        sessions: sessions,
        activeSessionId: activeSessionId,
        onSelectSession: (sessionId) async {
          await controller.selectSession(sessionId);
          if (!isLargeLayout && mounted) {
            setState(() {
              showCompactConversation = true;
            });
          }
        },
        onNewChat: () async {
          final previousSessionId = controller.activeSessionId.value;
          await controller.createSession('New chat');
          final createdSuccessfully = controller.activeSessionId.value != null &&
              controller.activeSessionId.value != previousSessionId &&
              controller.appError.value == null;
          if (!isLargeLayout && mounted && createdSuccessfully) {
            setState(() {
              showCompactConversation = true;
            });
          }
        },
        onDeleteSession: (sessionId) async {
          final shouldDelete = await Get.dialog<bool>(
            AlertDialog(
              title: const Text('Delete chat?'),
              content: const Text('This conversation will be removed.'),
              actions: [
                TextButton(
                  onPressed: () => Get.back(result: false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Get.back(result: true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (shouldDelete == true) {
            await controller.deleteSession(sessionId);
          }
        },
        loading: controller.sessionsLoading.value,
        errorText: controller.appError.value,
      );

      final conversationPane = ChatConversationPane(
        sessionTitle: activeSession?.headline,
        messages: messages,
        loading: controller.messagesLoading.value,
        errorText: controller.historyError.value,
        hasActiveSession: activeSessionId != null,
        draftController: controller.draftController,
        onSend: controller.sendCurrentMessage,
        onBack: isLargeLayout
            ? null
            : () {
                setState(() {
                  showCompactConversation = false;
                });
              },
      );

      return Scaffold(
        appBar: seraphAppBar(
          context,
          name: 'Chat',
          routeName: ChatView.routeName,
        ),
        body: isLargeLayout
            ? Row(
                children: [
                  SizedBox(
                    width: 360,
                    child: sessionList,
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: conversationPane),
                ],
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: showCompactConversation
                    ? conversationPane
                    : sessionList,
              ),
      );
    });
  }
}
