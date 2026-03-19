import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/features/chat/domain/models/message.dart';
import 'package:iris_chat/features/chat/presentation/utils/message_grouping.dart';

void main() {
  ChatMessage buildMessage({
    required String id,
    required DateTime timestamp,
    required MessageDirection direction,
    String? senderPubkeyHex,
    String? replyToId,
    Map<String, List<String>> reactions = const {},
  }) {
    return ChatMessage(
      id: id,
      sessionId: 's1',
      text: 'hello',
      timestamp: timestamp,
      direction: direction,
      status: MessageStatus.delivered,
      senderPubkeyHex: senderPubkeyHex,
      replyToId: replyToId,
      reactions: reactions,
    );
  }

  group('canGroupChatMessages', () {
    test('groups DM bubbles across consecutive minutes when same author', () {
      final first = buildMessage(
        id: 'm1',
        timestamp: DateTime(2026, 1, 1, 12, 1, 5),
        direction: MessageDirection.incoming,
      );
      final second = buildMessage(
        id: 'm2',
        timestamp: DateTime(2026, 1, 1, 12, 2, 50),
        direction: MessageDirection.incoming,
      );

      expect(
        canGroupChatMessages(first, second, isDirectMessage: true),
        isTrue,
      );
    });

    test(
      'does not group DM bubbles when minute buckets differ by more than one',
      () {
        final first = buildMessage(
          id: 'm1',
          timestamp: DateTime(2026, 1, 1, 12, 1, 5),
          direction: MessageDirection.incoming,
        );
        final second = buildMessage(
          id: 'm2',
          timestamp: DateTime(2026, 1, 1, 12, 3, 4),
          direction: MessageDirection.incoming,
        );

        expect(
          canGroupChatMessages(first, second, isDirectMessage: true),
          isFalse,
        );
      },
    );

    test('keeps the strict one-minute threshold for non-DM chats', () {
      final first = buildMessage(
        id: 'm1',
        timestamp: DateTime(2026, 1, 1, 12, 1, 5),
        direction: MessageDirection.incoming,
        senderPubkeyHex: 'alice',
      );
      final second = buildMessage(
        id: 'm2',
        timestamp: DateTime(2026, 1, 1, 12, 2, 50),
        direction: MessageDirection.incoming,
        senderPubkeyHex: 'alice',
      );

      expect(
        canGroupChatMessages(first, second, isDirectMessage: false),
        isFalse,
      );
    });

    test('does not group reply or reaction bubbles', () {
      final first = buildMessage(
        id: 'm1',
        timestamp: DateTime(2026, 1, 1, 12, 1, 5),
        direction: MessageDirection.outgoing,
      );
      final second = buildMessage(
        id: 'm2',
        timestamp: DateTime(2026, 1, 1, 12, 1, 40),
        direction: MessageDirection.outgoing,
        replyToId: 'm0',
      );
      final third = buildMessage(
        id: 'm3',
        timestamp: DateTime(2026, 1, 1, 12, 1, 50),
        direction: MessageDirection.outgoing,
        reactions: const {
          '❤️': ['me'],
        },
      );

      expect(
        canGroupChatMessages(first, second, isDirectMessage: true),
        isFalse,
      );
      expect(
        canGroupChatMessages(second, third, isDirectMessage: true),
        isFalse,
      );
    });
  });
}
