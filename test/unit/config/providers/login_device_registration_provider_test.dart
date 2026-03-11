import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/login_device_registration_provider.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nostr/nostr.dart' as nostr;

class MockNostrService extends Mock implements NostrService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockNostrService mockNostrService;
  late LoginDeviceRegistrationServiceImpl service;
  late String ownerPrivkeyNsec;

  const ownerPrivkeyHex =
      'f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2';
  const ownerPubkeyHex =
      'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
  const generatedDevicePrivkeyHex =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const generatedDevicePubkeyHex =
      'b1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
  setUpAll(() {
    registerFallbackValue(const NostrFilter());
  });

  setUp(() {
    ownerPrivkeyNsec = nostr.Nip19.encodePrivkey(ownerPrivkeyHex) as String;
    mockNostrService = MockNostrService();
    service = LoginDeviceRegistrationServiceImpl(mockNostrService);

    when(
      () => mockNostrService.events,
    ).thenAnswer((_) => const Stream<NostrEvent>.empty());
    when(
      () => mockNostrService.subscribeWithId(any(), any()),
    ).thenThrow(Exception('relay unavailable'));
    when(() => mockNostrService.closeSubscription(any())).thenReturn(null);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('to.iris.chat/ndr_ffi'), (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'derivePublicKey') {
            final args = methodCall.arguments as Map<dynamic, dynamic>;
            final privkeyHex = args['privkeyHex'] as String;
            if (privkeyHex == ownerPrivkeyHex) {
              return ownerPubkeyHex;
            }
            if (privkeyHex == generatedDevicePrivkeyHex) {
              return generatedDevicePubkeyHex;
            }
          }

          if (methodCall.method == 'generateKeypair') {
            return {
              'privateKeyHex': generatedDevicePrivkeyHex,
              'publicKeyHex': generatedDevicePubkeyHex,
            };
          }

          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('to.iris.chat/ndr_ffi'),
          null,
        );
  });

  test('preview marks generated device key as current device', () async {
    final preview = await service.buildPreviewFromPrivateKeyNsec(
      ownerPrivkeyNsec,
    );

    expect(preview.ownerPubkeyHex, ownerPubkeyHex);
    expect(preview.currentDevicePrivkeyHex, generatedDevicePrivkeyHex);
    expect(preview.currentDevicePubkeyHex, generatedDevicePubkeyHex);
    expect(preview.currentDevicePubkeyHex, isNot(preview.ownerPubkeyHex));
    expect(
      preview.devicesIfRegistered.map((d) => d.identityPubkeyHex),
      contains(generatedDevicePubkeyHex),
    );
  });
}
