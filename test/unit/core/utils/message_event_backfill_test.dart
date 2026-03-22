import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/ffi/models/pubsub_event.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/utils/message_event_backfill.dart';
import 'package:mocktail/mocktail.dart';

class MockNostrService extends Mock implements NostrService {}

void main() {
  late MockNostrService mockNostrService;
  late StreamController<NostrEvent> controller;
  late StreamController<RelayConnectionEvent> connectionController;
  late int connectedCount;

  setUpAll(() {
    registerFallbackValue(const NostrFilter());
  });

  setUp(() {
    mockNostrService = MockNostrService();
    controller = StreamController<NostrEvent>.broadcast();
    connectionController = StreamController<RelayConnectionEvent>.broadcast();
    connectedCount = 1;

    when(() => mockNostrService.events).thenAnswer((_) => controller.stream);
    when(
      () => mockNostrService.connectionEvents,
    ).thenAnswer((_) => connectionController.stream);
    when(
      () => mockNostrService.connectedCount,
    ).thenAnswer((_) => connectedCount);
    when(() => mockNostrService.closeSubscription(any())).thenAnswer((_) {});
  });

  tearDown(() async {
    await controller.close();
    await connectionController.close();
  });

  test(
    'fetchRecentMessageEvents keeps only matching authors and sorts oldest first',
    () async {
      const wantedAuthor =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const otherAuthor =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

      when(() => mockNostrService.subscribeWithId(any(), any())).thenAnswer((
        invocation,
      ) {
        final subid = invocation.positionalArguments[0] as String;

        Future<void>.microtask(() {
          controller.add(
            _messageEvent(
              id: 'newer-message',
              pubkey: wantedAuthor,
              createdAt: 1700000002,
              subscriptionId: subid,
            ),
          );
          controller.add(
            _messageEvent(
              id: 'wrong-author',
              pubkey: otherAuthor,
              createdAt: 1700000001,
              subscriptionId: subid,
            ),
          );
          controller.add(
            _messageEvent(
              id: 'older-message',
              pubkey: wantedAuthor,
              createdAt: 1700000000,
              subscriptionId: subid,
            ),
          );
        });

        return subid;
      });

      final events = await fetchRecentMessageEvents(
        mockNostrService,
        senderPubkeysHex: const [wantedAuthor],
        sinceSeconds: 1699999990,
        timeout: const Duration(milliseconds: 20),
        subscriptionLabel: 'test-message-bootstrap',
      );

      expect(events.map((event) => event.id), [
        'older-message',
        'newer-message',
      ]);
    },
  );

  test(
    'fetchRecentMessageEvents de-duplicates event ids across relays',
    () async {
      const wantedAuthor =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

      when(() => mockNostrService.subscribeWithId(any(), any())).thenAnswer((
        invocation,
      ) {
        final subid = invocation.positionalArguments[0] as String;

        Future<void>.microtask(() {
          controller.add(
            _messageEvent(
              id: 'duplicate-message',
              pubkey: wantedAuthor,
              createdAt: 1700000001,
              subscriptionId: subid,
            ),
          );
          controller.add(
            _messageEvent(
              id: 'duplicate-message',
              pubkey: wantedAuthor,
              createdAt: 1700000001,
              subscriptionId: subid,
            ),
          );
        });

        return subid;
      });

      final events = await fetchRecentMessageEvents(
        mockNostrService,
        senderPubkeysHex: const [wantedAuthor],
        sinceSeconds: 1699999990,
        timeout: const Duration(milliseconds: 20),
        subscriptionLabel: 'test-message-bootstrap',
      );

      expect(events, hasLength(1));
      expect(events.single.id, 'duplicate-message');
    },
  );

  test(
    'waits for first relay connection before starting response timeout',
    () async {
      const wantedAuthor =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

      when(() => mockNostrService.subscribeWithId(any(), any())).thenAnswer((
        invocation,
      ) {
        final subid = invocation.positionalArguments[0] as String;

        Future<void>.delayed(const Duration(milliseconds: 30), () {
          connectedCount = 1;
          connectionController.add(
            const RelayConnectionEvent(
              url: 'wss://relay.example',
              status: RelayStatus.connected,
            ),
          );
        });
        Future<void>.delayed(const Duration(milliseconds: 50), () {
          controller.add(
            _messageEvent(
              id: 'post-connect-message',
              pubkey: wantedAuthor,
              createdAt: 1700000001,
              subscriptionId: subid,
            ),
          );
        });

        return subid;
      });

      connectedCount = 0;
      final events = await fetchRecentMessageEvents(
        mockNostrService,
        senderPubkeysHex: const [wantedAuthor],
        sinceSeconds: 1699999990,
        timeout: const Duration(milliseconds: 40),
        subscriptionLabel: 'test-message-bootstrap',
      );

      expect(events.map((event) => event.id), ['post-connect-message']);
    },
  );

  test(
    'directMessageSubscriptionBackfillAuthors returns only newly added session authors',
    () {
      const existingAuthor =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const addedAuthor =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

      final authors = directMessageSubscriptionBackfillAuthors(
        event: const PubSubEvent(
          kind: 'subscribe',
          subid: 'session-next-123',
          filterJson:
              '{"kinds":[1060],"authors":["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]}',
        ),
        existingAuthorRefCounts: const <String, int>{existingAuthor: 1},
      );

      expect(authors, [addedAuthor]);
    },
  );

  test(
    'directMessageSubscriptionBackfillAuthors ignores non-session and invalid filters',
    () {
      expect(
        directMessageSubscriptionBackfillAuthors(
          event: const PubSubEvent(
            kind: 'subscribe',
            subid: 'group-subscription',
            filterJson:
                '{"kinds":[1060],"authors":["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]}',
          ),
          existingAuthorRefCounts: const <String, int>{},
        ),
        isEmpty,
      );

      expect(
        directMessageSubscriptionBackfillAuthors(
          event: const PubSubEvent(
            kind: 'subscribe',
            subid: 'session-current-123',
            filterJson: '{"kinds":[1],"authors":["bbbb"]}',
          ),
          existingAuthorRefCounts: const <String, int>{},
        ),
        isEmpty,
      );
    },
  );
}

NostrEvent _messageEvent({
  required String id,
  required String pubkey,
  required int createdAt,
  required String subscriptionId,
}) {
  return NostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: messageEventKind,
    tags: const [
      ['header', 'encrypted-header'],
    ],
    content: 'ciphertext',
    sig: 'sig',
    subscriptionId: subscriptionId,
  );
}
