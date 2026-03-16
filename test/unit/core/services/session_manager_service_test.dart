import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/features/auth/domain/models/identity.dart';
import 'package:iris_chat/features/auth/domain/repositories/auth_repository.dart';

class _FakeAuthRepository implements AuthRepository {
  @override
  Future<Identity> createIdentity() {
    throw UnimplementedError();
  }

  @override
  Future<String?> getDevicePubkeyHex() {
    throw UnimplementedError();
  }

  @override
  Future<Identity?> getCurrentIdentity() {
    throw UnimplementedError();
  }

  @override
  Future<String?> getPrivateKey() {
    throw UnimplementedError();
  }

  @override
  Future<String?> getOwnerPrivateKey() async => null;

  @override
  Future<bool> hasIdentity() {
    throw UnimplementedError();
  }

  @override
  Future<Identity> login(String privateKeyNsec, {String? devicePrivkeyHex}) {
    throw UnimplementedError();
  }

  @override
  Future<Identity> loginLinkedDevice({
    required String ownerPubkeyHex,
    required String devicePrivkeyHex,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> logout() {
    throw UnimplementedError();
  }
}

void main() {
  const peerPubkey =
      '1111111111111111111111111111111111111111111111111111111111111111';
  const messageId =
      '2222222222222222222222222222222222222222222222222222222222222222';

  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionManagerService', () {
    late NostrService nostrService;
    late SessionManagerService sessionManager;

    setUp(() {
      nostrService = NostrService(relayUrls: const ['ws://127.0.0.1:65534']);
      sessionManager = SessionManagerService(
        nostrService,
        _FakeAuthRepository(),
      );
    });

    tearDown(() async {
      await sessionManager.dispose();
      await nostrService.dispose();
    });

    test('void operations become no-ops once dispose starts', () async {
      final disposeFuture = sessionManager.dispose();

      await expectLater(sessionManager.refreshSubscription(), completes);
      await expectLater(sessionManager.setupUser(peerPubkey), completes);
      await expectLater(sessionManager.setupUsers([peerPubkey]), completes);
      await expectLater(
        sessionManager.sendReceipt(
          recipientPubkeyHex: peerPubkey,
          receiptType: 'read',
          messageIds: const [messageId],
        ),
        completes,
      );
      await expectLater(
        sessionManager.sendTyping(recipientPubkeyHex: peerPubkey),
        completes,
      );
      await expectLater(
        sessionManager.sendReaction(
          recipientPubkeyHex: peerPubkey,
          messageId: messageId,
          emoji: '+',
        ),
        completes,
      );
      await expectLater(
        sessionManager.importSessionState(
          peerPubkeyHex: peerPubkey,
          stateJson: '{}',
        ),
        completes,
      );
      await expectLater(sessionManager.processEventJson('{}'), completes);

      await disposeFuture;
    });
  });

  group('linked-device state repair helpers', () {
    test(
      'sessionStateTracksSenderPubkeyJson matches current and next sender keys',
      () {
        expect(
          sessionStateTracksSenderPubkeyJson(
            '{"their_current_nostr_public_key":"aaaa","their_next_nostr_public_key":"bbbb"}',
            'aaaa',
          ),
          isTrue,
        );
        expect(
          sessionStateTracksSenderPubkeyJson(
            '{"their_current_nostr_public_key":"aaaa","their_next_nostr_public_key":"bbbb"}',
            'bbbb',
          ),
          isTrue,
        );
        expect(
          sessionStateTracksSenderPubkeyJson(
            '{"their_current_nostr_public_key":"aaaa","their_next_nostr_public_key":"bbbb"}',
            'cccc',
          ),
          isFalse,
        );
      },
    );

    test(
      'storedDeviceIdsMissingReceivingStateForSender finds sender-matched devices missing receive state',
      () {
        const userRecordJson = '''
{
  "devices": [
    {
      "device_id": "owner-device",
      "active_session": {
        "their_current_nostr_public_key": "sender-a",
        "receiving_chain_key": "receive"
      },
      "inactive_sessions": []
    },
    {
      "device_id": "linked-device",
      "active_session": {
        "their_next_nostr_public_key": "sender-a",
        "sending_chain_key": "send-only"
      },
      "inactive_sessions": []
    },
    {
      "device_id": "other-device",
      "active_session": {
        "their_next_nostr_public_key": "sender-b",
        "sending_chain_key": "send-only"
      },
      "inactive_sessions": []
    }
  ]
}
''';

        expect(
          storedDeviceIdsMissingReceivingStateForSender(
            userRecordJson: userRecordJson,
            senderPubkeyHex: 'sender-a',
          ),
          ['linked-device'],
        );
      },
    );

    test(
      'storedKnownDeviceIdsMissingRecords finds known devices missing from records',
      () {
        const userRecordJson = '''
{
  "devices": [
    {
      "device_id": "owner-device",
      "active_session": {
        "their_current_nostr_public_key": "sender-a",
        "receiving_chain_key": "receive"
      },
      "inactive_sessions": []
    }
  ],
  "known_device_identities": [
    "owner-device",
    "linked-device"
  ]
}
''';

        expect(storedKnownDeviceIdsMissingRecords(userRecordJson), [
          'linked-device',
        ]);
      },
    );

    test(
      'storedReceivingSessionStateForDevice restores sender-matched receive session from snapshot',
      () {
        const userRecordJson = '''
{
  "devices": [
    {
      "device_id": "linked-device",
      "active_session": {
        "their_next_nostr_public_key": "sender-old",
        "sending_chain_key": "send-only"
      },
      "inactive_sessions": [
        {
          "their_next_nostr_public_key": "sender-target",
          "receiving_chain_key": "receive-target"
        }
      ]
    }
  ]
}
''';

        final restored = storedReceivingSessionStateForDevice(
          userRecordJson: userRecordJson,
          deviceId: 'linked-device',
          senderPubkeyHex: 'sender-target',
        );

        expect(restored, isNotNull);
        expect(
          sessionStateTracksSenderPubkeyJson(restored!, 'sender-target'),
          isTrue,
        );
        expect(sessionStateHasReceivingCapabilityJson(restored), isTrue);
      },
    );

    test(
      'storedReceivingSessionStateForDevice falls back to first receive-capable session for device',
      () {
        const userRecordJson = '''
{
  "devices": [
    {
      "device_id": "linked-device",
      "active_session": {
        "their_next_nostr_public_key": "sender-old",
        "receiving_chain_key": "receive-active"
      },
      "inactive_sessions": [
        {
          "their_next_nostr_public_key": "sender-target",
          "sending_chain_key": "send-only"
        }
      ]
    }
  ]
}
''';

        final restored = storedReceivingSessionStateForDevice(
          userRecordJson: userRecordJson,
          deviceId: 'linked-device',
          senderPubkeyHex: 'missing-sender',
        );

        expect(restored, isNotNull);
        expect(sessionStateHasReceivingCapabilityJson(restored!), isTrue);
      },
    );

    test(
      'storedDeviceIdsMissingReceiveStateComparedToSnapshot finds devices that lost receive capability after restart',
      () {
        const currentUserRecordJson = '''
{
  "devices": [
    {
      "device_id": "owner-device",
      "active_session": {
        "their_current_nostr_public_key": "sender-owner",
        "receiving_chain_key": "receive-owner"
      },
      "inactive_sessions": []
    },
    {
      "device_id": "linked-device",
      "active_session": {
        "their_next_nostr_public_key": "sender-linked",
        "sending_chain_key": "send-only"
      },
      "inactive_sessions": []
    }
  ]
}
''';
        const snapshotUserRecordJson = '''
{
  "devices": [
    {
      "device_id": "owner-device",
      "active_session": {
        "their_current_nostr_public_key": "sender-owner",
        "receiving_chain_key": "receive-owner"
      },
      "inactive_sessions": []
    },
    {
      "device_id": "linked-device",
      "active_session": {
        "their_current_nostr_public_key": "sender-linked",
        "receiving_chain_key": "receive-linked"
      },
      "inactive_sessions": []
    }
  ]
}
''';

        expect(
          storedDeviceIdsMissingReceiveStateComparedToSnapshot(
            currentUserRecordJson: currentUserRecordJson,
            snapshotUserRecordJson: snapshotUserRecordJson,
          ),
          ['linked-device'],
        );
      },
    );
  });
}
