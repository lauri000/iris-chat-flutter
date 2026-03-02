import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/utils/nostr_rumor.dart';
import 'package:iris_chat/core/utils/typing_rumor.dart';

void main() {
  NostrRumor rumor({
    required int createdAtSeconds,
    required String content,
    List<List<String>> tags = const [],
  }) {
    return NostrRumor(
      id: 'id',
      pubkey:
          '2222222222222222222222222222222222222222222222222222222222222222',
      createdAt: createdAtSeconds,
      kind: 25,
      content: content,
      tags: tags,
    );
  }

  group('isTypingStopRumor', () {
    test('treats explicit typing off content as stop', () {
      final value = isTypingStopRumor(
        rumor(createdAtSeconds: 1700000000, content: 'typing off'),
      );
      expect(value, isTrue);
    });

    test(
      'treats immediate future expiration as stop when created_at matches',
      () {
        const futureSeconds = 4102444800;
        final value = isTypingStopRumor(
          rumor(
            createdAtSeconds: futureSeconds,
            content: 'typing',
            tags: [
              ['expiration', '$futureSeconds'],
            ],
          ),
          now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );
        expect(value, isTrue);
      },
    );

    test('does not treat long-lived future expiration as stop', () {
      final value = isTypingStopRumor(
        rumor(
          createdAtSeconds: 1700000000,
          content: 'typing',
          tags: [
            ['expiration', '1700003600'],
          ],
        ),
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(value, isFalse);
    });
  });

  group('isTypingTimestampStale', () {
    test('returns false when no message baseline exists', () {
      expect(
        isTypingTimestampStale(
          typingTimestampMs: 1700000000000,
          lastMessageTimestampMs: null,
        ),
        isFalse,
      );
    });

    test('returns true when typing timestamp is older than last message', () {
      expect(
        isTypingTimestampStale(
          typingTimestampMs: 1700000000000,
          lastMessageTimestampMs: 1700000001000,
        ),
        isTrue,
      );
    });
  });
}
