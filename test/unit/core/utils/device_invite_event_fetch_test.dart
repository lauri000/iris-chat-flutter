import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/utils/device_invite_event_fetch.dart';
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
    when(() => mockNostrService.connectedCount).thenAnswer((_) => connectedCount);
    when(() => mockNostrService.closeSubscription(any())).thenAnswer((_) {});
  });

  tearDown(() async {
    await controller.close();
    await connectionController.close();
  });

  test('prefers the later-delivered invite when created_at ties', () async {
    const devicePubkey =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    when(() => mockNostrService.subscribeWithId(any(), any())).thenAnswer((
      invocation,
    ) {
      final subid = invocation.positionalArguments[0] as String;

      Future<void>.microtask(() {
        controller.add(
          _inviteEvent(
            id: 'first-invite',
            pubkey: devicePubkey,
            createdAt: 1700000000,
            subscriptionId: subid,
            sharedSecret: 'one',
          ),
        );
        controller.add(
          _inviteEvent(
            id: 'second-invite',
            pubkey: devicePubkey,
            createdAt: 1700000000,
            subscriptionId: subid,
            sharedSecret: 'two',
          ),
        );
      });

      return subid;
    });

    final invites = await fetchLatestDeviceInviteEvents(
      mockNostrService,
      devicePubkeysHex: const [devicePubkey],
      timeout: const Duration(milliseconds: 20),
      subscriptionLabel: 'test-invite',
    );

    expect(invites, hasLength(1));
    expect(invites.single.id, 'second-invite');
    expect(invites.single.getTagValue('sharedSecret'), 'two');
  });

  test('ignores non-invite replaceable events and wrong authors', () async {
    const wantedDevice =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const otherDevice =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

    when(() => mockNostrService.subscribeWithId(any(), any())).thenAnswer((
      invocation,
    ) {
      final subid = invocation.positionalArguments[0] as String;

      Future<void>.microtask(() {
        controller.add(
          _plainEvent(
            id: 'wrong-author',
            pubkey: otherDevice,
            createdAt: 1700000001,
            subscriptionId: subid,
          ),
        );
        controller.add(
          _plainEvent(
            id: 'wrong-tags',
            pubkey: wantedDevice,
            createdAt: 1700000002,
            subscriptionId: subid,
            tags: const [
              ['d', 'double-ratchet/app-keys'],
            ],
          ),
        );
        controller.add(
          _inviteEvent(
            id: 'correct-invite',
            pubkey: wantedDevice,
            createdAt: 1700000003,
            subscriptionId: subid,
          ),
        );
      });

      return subid;
    });

    final invites = await fetchLatestDeviceInviteEvents(
      mockNostrService,
      devicePubkeysHex: const [wantedDevice],
      timeout: const Duration(milliseconds: 20),
      subscriptionLabel: 'test-invite',
    );

    expect(invites, hasLength(1));
    expect(invites.single.id, 'correct-invite');
  });

  test('waits for first relay connection before timing out invite fetch', () async {
    const wantedDevice =
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
          _inviteEvent(
            id: 'delayed-invite',
            pubkey: wantedDevice,
            createdAt: 1700000003,
            subscriptionId: subid,
          ),
        );
      });

      return subid;
    });

    connectedCount = 0;
    final invites = await fetchLatestDeviceInviteEvents(
      mockNostrService,
      devicePubkeysHex: const [wantedDevice],
      timeout: const Duration(milliseconds: 40),
      subscriptionLabel: 'test-invite',
    );

    expect(invites, hasLength(1));
    expect(invites.single.id, 'delayed-invite');
  });
}

NostrEvent _inviteEvent({
  required String id,
  required String pubkey,
  required int createdAt,
  required String subscriptionId,
  String sharedSecret = 'shared',
}) {
  return _plainEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    subscriptionId: subscriptionId,
    tags: [
      const ['l', 'double-ratchet/invites'],
      ['d', 'double-ratchet/invites/$pubkey'],
      const ['ephemeralKey', 'ephemeral'],
      ['sharedSecret', sharedSecret],
    ],
  );
}

NostrEvent _plainEvent({
  required String id,
  required String pubkey,
  required int createdAt,
  required String subscriptionId,
  List<List<String>> tags = const [],
}) {
  return NostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: 30078,
    tags: tags,
    content: '',
    sig: 'sig',
    subscriptionId: subscriptionId,
  );
}
