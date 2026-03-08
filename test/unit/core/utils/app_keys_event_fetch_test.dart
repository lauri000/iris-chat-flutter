import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/utils/app_keys_event_fetch.dart';
import 'package:mocktail/mocktail.dart';

class MockNostrService extends Mock implements NostrService {}

void main() {
  late MockNostrService mockNostrService;
  late StreamController<NostrEvent> controller;

  setUpAll(() {
    registerFallbackValue(const NostrFilter());
  });

  setUp(() {
    mockNostrService = MockNostrService();
    controller = StreamController<NostrEvent>.broadcast();

    when(() => mockNostrService.events).thenAnswer((_) => controller.stream);
    when(() => mockNostrService.closeSubscription(any())).thenAnswer((_) {});
  });

  tearDown(() async {
    await controller.close();
  });

  test('prefers the later-delivered AppKeys event when created_at ties', () async {
    when(() => mockNostrService.subscribeWithId(any(), any())).thenAnswer((
      invocation,
    ) {
      final subid = invocation.positionalArguments[0] as String;

      Future<void>.microtask(() {
        controller.add(
          _appKeysEvent(
            id: 'first-event',
            pubkey:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            createdAt: 1700000000,
            subscriptionId: subid,
          ),
        );
        controller.add(
          _appKeysEvent(
            id: 'second-event',
            pubkey:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            createdAt: 1700000000,
            subscriptionId: subid,
            devicePubkeys: const [
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ],
          ),
        );
      });

      return subid;
    });

    final latest = await fetchLatestAppKeysEvent(
      mockNostrService,
      ownerPubkeyHex:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      timeout: const Duration(milliseconds: 20),
      subscriptionLabel: 'test-appkeys',
    );

    expect(latest, isNotNull);
    expect(latest!.id, 'second-event');
    expect(
      latest.tags.where((tag) => tag.isNotEmpty && tag.first == 'device'),
      hasLength(2),
    );
  });

  test('ignores non-AppKeys and non-owner events', () async {
    when(() => mockNostrService.subscribeWithId(any(), any())).thenAnswer((
      invocation,
    ) {
      final subid = invocation.positionalArguments[0] as String;

      Future<void>.microtask(() {
        controller.add(
          _appKeysEvent(
            id: 'wrong-owner',
            pubkey:
                'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
            createdAt: 1700000001,
            subscriptionId: subid,
          ),
        );
        controller.add(
          _plainEvent(
            id: 'wrong-kind',
            pubkey:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            createdAt: 1700000002,
            kind: 1,
            subscriptionId: subid,
          ),
        );
        controller.add(
          _appKeysEvent(
            id: 'correct-owner',
            pubkey:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            createdAt: 1700000003,
            subscriptionId: subid,
          ),
        );
      });

      return subid;
    });

    final latest = await fetchLatestAppKeysEvent(
      mockNostrService,
      ownerPubkeyHex:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      timeout: const Duration(milliseconds: 20),
      subscriptionLabel: 'test-appkeys',
    );

    expect(latest, isNotNull);
    expect(latest!.id, 'correct-owner');
  });
}

NostrEvent _appKeysEvent({
  required String id,
  required String pubkey,
  required int createdAt,
  required String subscriptionId,
  List<String> devicePubkeys = const [
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ],
}) {
  return _plainEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: 30078,
    tags: [
      const ['d', 'double-ratchet/app-keys'],
      const ['version', '1'],
      ...devicePubkeys.map((pubkey) => ['device', pubkey, '$createdAt']),
    ],
    subscriptionId: subscriptionId,
  );
}

NostrEvent _plainEvent({
  required String id,
  required String pubkey,
  required int createdAt,
  required int kind,
  required String subscriptionId,
  List<List<String>> tags = const [],
}) {
  return NostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: kind,
    tags: tags,
    content: '',
    sig: 'sig',
    subscriptionId: subscriptionId,
  );
}
