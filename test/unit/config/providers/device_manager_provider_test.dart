import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/auth_provider.dart';
import 'package:iris_chat/config/providers/device_manager_provider.dart';
import 'package:iris_chat/core/ffi/ndr_ffi.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/features/auth/domain/repositories/auth_repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../../test_helpers.dart';

class MockRef extends Mock implements Ref {}

class MockNostrService extends Mock implements NostrService {}

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const NostrFilter());
  });

  late MockRef mockRef;
  late MockNostrService mockNostrService;
  late MockAuthRepository mockAuthRepository;
  late DeviceManagerNotifier notifier;

  setUp(() {
    mockRef = MockRef();
    mockNostrService = MockNostrService();
    mockAuthRepository = MockAuthRepository();

    when(() => mockRef.read(authStateProvider)).thenReturn(
      const AuthState(
        isAuthenticated: true,
        isInitialized: true,
        pubkeyHex: testPubkeyHex,
        devicePubkeyHex: 'linked-device',
      ),
    );
    when(
      () => mockNostrService.events,
    ).thenAnswer((_) => const Stream<NostrEvent>.empty());
    when(
      () => mockNostrService.subscribeWithId(any(), any()),
    ).thenReturn('subid');
    when(() => mockNostrService.closeSubscription(any())).thenReturn(null);

    notifier = DeviceManagerNotifier(
      mockRef,
      mockNostrService,
      mockAuthRepository,
      autoLoad: false,
    );
  });

  test(
    'mergeKnownDevices keeps a newly linked device visible when relay fetch is still empty',
    () async {
      const linkedDevice = 'linked-device';

      notifier.mergeKnownDevices(const <FfiDeviceEntry>[
        FfiDeviceEntry(identityPubkeyHex: linkedDevice, createdAt: 1700002000),
      ], currentDevicePubkeyHex: linkedDevice);

      await notifier.loadDevices();

      expect(notifier.state.isLoading, false);
      expect(notifier.state.currentDevicePubkeyHex, linkedDevice);
      expect(
        notifier.state.devices.map((device) => device.identityPubkeyHex),
        <String>[linkedDevice],
      );
      expect(notifier.state.devices.single.createdAt, 1700002000);
    },
  );
}
