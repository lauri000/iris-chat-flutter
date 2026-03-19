import 'package:flutter/material.dart';

import '../utils/chats_layout.dart';
import 'chat_list_screen.dart';

class ChatsShellScreen extends StatelessWidget {
  const ChatsShellScreen({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!useChatsWideLayout(context)) {
      return child;
    }

    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                right: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: const SizedBox(
              width: 360,
              child: ChatListPane(
                key: ValueKey('embedded-chat-list-pane'),
                embedded: true,
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
