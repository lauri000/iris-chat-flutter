import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/ffi/models/ffi_device_entry.dart';
import 'package:iris_chat/core/utils/device_labels.dart';

void main() {
  group('device_labels', () {
    test(
      'mergeDeviceEntries preserves known labels while filling missing ensured labels',
      () {
        final merged = mergeDeviceEntries(
          existingDevices: const [
            FfiDeviceEntry(
              identityPubkeyHex: 'aaaa',
              createdAt: 100,
              deviceLabel: 'Sirius MacBook',
            ),
          ],
          ensuredDevices: const [
            FfiDeviceEntry(
              identityPubkeyHex: 'aaaa',
              createdAt: 200,
              clientLabel: 'Iris Chat Desktop',
            ),
            FfiDeviceEntry(
              identityPubkeyHex: 'bbbb',
              createdAt: 300,
              deviceLabel: 'Linked device',
              clientLabel: 'Iris Chat Mobile',
            ),
          ],
        );

        expect(
          merged,
          contains(
            const FfiDeviceEntry(
              identityPubkeyHex: 'aaaa',
              createdAt: 100,
              deviceLabel: 'Sirius MacBook',
              clientLabel: 'Iris Chat Desktop',
            ),
          ),
        );
        expect(
          merged,
          contains(
            const FfiDeviceEntry(
              identityPubkeyHex: 'bbbb',
              createdAt: 300,
              deviceLabel: 'Linked device',
              clientLabel: 'Iris Chat Mobile',
            ),
          ),
        );
      },
    );

    test(
      'device display prefers encrypted labels before falling back to pubkey',
      () {
        const labeled = FfiDeviceEntry(
          identityPubkeyHex:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          createdAt: 100,
          deviceLabel: 'Sirius MacBook',
          clientLabel: 'Iris Chat Desktop',
        );

        expect(deviceDisplayTitle(labeled), 'Sirius MacBook');
        expect(deviceDisplaySubtitle(labeled), contains('Iris Chat Desktop'));
      },
    );

    test('buildLinkedDeviceEntry uses a generic linked-device label', () {
      final device = buildLinkedDeviceEntry(
        identityPubkeyHex: 'bbbb',
        createdAt: 300,
      );

      expect(device.deviceLabel, 'Linked device');
      expect(device.clientLabel, 'Iris Chat');
    });
  });
}
