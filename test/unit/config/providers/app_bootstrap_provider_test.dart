import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/app_bootstrap_provider.dart';

void main() {
  group('sessionBootstrapTargets', () {
    test('includes owner pubkey even when not present in sessions', () {
      final targets = sessionBootstrapTargets(
        sessionRecipientPubkeysHex: const ['abcdef'],
        ownerPubkeyHex: '123456',
      );

      expect(targets, ['abcdef', '123456']);
    });

    test('normalizes and de-duplicates recipients and owner', () {
      final targets = sessionBootstrapTargets(
        sessionRecipientPubkeysHex: const [' AbCdEf ', 'abcdef', ''],
        ownerPubkeyHex: ' ABCDEF ',
      );

      expect(targets, ['abcdef']);
    });
  });

  group('sessionRelayBootstrapTargets', () {
    test('includes only peers missing active session state', () async {
      final targets = await sessionRelayBootstrapTargets(
        bootstrapTargets: const ['alice', 'bob', 'carol'],
        getActiveSessionState: (peerPubkeyHex) async {
          switch (peerPubkeyHex) {
            case 'alice':
              return '{"session":"ready"}';
            case 'bob':
              return '';
            case 'carol':
              return null;
          }
          return null;
        },
      );

      expect(targets, ['bob', 'carol']);
    });
  });
}
