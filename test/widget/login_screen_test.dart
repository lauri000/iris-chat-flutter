import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:iris_chat/config/providers/auth_provider.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/config/providers/invite_provider.dart';
import 'package:iris_chat/config/providers/login_device_registration_provider.dart';
import 'package:iris_chat/core/ffi/models/ffi_device_entry.dart';
import 'package:iris_chat/core/services/database_service.dart';
import 'package:iris_chat/features/auth/domain/models/identity.dart';
import 'package:iris_chat/features/auth/domain/repositories/auth_repository.dart';
import 'package:iris_chat/features/auth/presentation/screens/login_screen.dart';
import 'package:iris_chat/features/invite/data/datasources/invite_local_datasource.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nostr/nostr.dart' as nostr;

import '../test_helpers.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

class MockDatabaseService extends Mock implements DatabaseService {}

class MockLoginDeviceRegistrationService extends Mock
    implements LoginDeviceRegistrationService {}

class MockInviteLocalDatasource extends Mock implements InviteLocalDatasource {}

class _TestLoginInviteNotifier extends InviteNotifier {
  // ignore: use_super_parameters
  _TestLoginInviteNotifier(InviteLocalDatasource datasource, Ref ref)
    : super(datasource, ref);

  int ensurePublishedPublicInviteCalls = 0;

  @override
  Future<void> ensurePublishedPublicInvite() async {
    ensurePublishedPublicInviteCalls += 1;
  }
}

const generatedDevicePubkeyHex =
    'b1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
const generatedDevicePrivkeyHex =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const existingDevicePubkeyHex =
    'c1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

LoginDeviceRegistrationPreview _buildPreview({
  List<FfiDeviceEntry>? existingDevices,
  bool deviceListLoaded = true,
  String? deviceListLoadError,
}) {
  final existing =
      existingDevices ??
      const [
        FfiDeviceEntry(
          identityPubkeyHex: existingDevicePubkeyHex,
          createdAt: 1700000000,
        ),
      ];

  return LoginDeviceRegistrationPreview(
    ownerPubkeyHex: testPubkeyHex,
    ownerPrivkeyHex: testPrivkeyHex,
    currentDevicePrivkeyHex: generatedDevicePrivkeyHex,
    currentDevicePubkeyHex: generatedDevicePubkeyHex,
    existingDevices: existing,
    devicesIfRegistered: [
      ...existing,
      const FfiDeviceEntry(
        identityPubkeyHex: generatedDevicePubkeyHex,
        createdAt: 1700000001,
      ),
    ],
    deviceListLoaded: deviceListLoaded,
    deviceListLoadError: deviceListLoadError,
  );
}

String _validNsec() => nostr.Nip19.encodePrivkey(testPrivkeyHex) as String;

void main() {
  late MockAuthRepository mockAuthRepo;
  late MockDatabaseService mockDatabaseService;
  late MockLoginDeviceRegistrationService mockLoginDeviceRegistrationService;
  late MockInviteLocalDatasource mockInviteDatasource;

  setUp(() {
    mockAuthRepo = MockAuthRepository();
    mockDatabaseService = MockDatabaseService();
    mockLoginDeviceRegistrationService = MockLoginDeviceRegistrationService();
    mockInviteDatasource = MockInviteLocalDatasource();
    when(() => mockDatabaseService.deleteDatabase()).thenAnswer((_) async {});
    when(
      () => mockAuthRepo.login(
        any(),
        devicePrivkeyHex: any(named: 'devicePrivkeyHex'),
      ),
    ).thenAnswer((_) async => const Identity(pubkeyHex: testPubkeyHex));
    when(
      () => mockAuthRepo.getDevicePubkeyHex(),
    ).thenAnswer((_) async => generatedDevicePubkeyHex);
    when(
      () => mockAuthRepo.getOwnerPrivateKey(),
    ).thenAnswer((_) async => testPrivkeyHex);
    when(
      () => mockLoginDeviceRegistrationService.publishDeviceList(
        ownerPubkeyHex: any(named: 'ownerPubkeyHex'),
        ownerPrivkeyHex: any(named: 'ownerPrivkeyHex'),
        devices: any(named: 'devices'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => mockLoginDeviceRegistrationService.publishSingleDevice(
        ownerPubkeyHex: any(named: 'ownerPubkeyHex'),
        ownerPrivkeyHex: any(named: 'ownerPrivkeyHex'),
        devicePubkeyHex: any(named: 'devicePubkeyHex'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => mockLoginDeviceRegistrationService.registerDevice(
        ownerPubkeyHex: any(named: 'ownerPubkeyHex'),
        ownerPrivkeyHex: any(named: 'ownerPrivkeyHex'),
        devicePubkeyHex: any(named: 'devicePubkeyHex'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => mockLoginDeviceRegistrationService.buildPreviewFromPrivateKeyNsec(
        any(),
      ),
    ).thenAnswer((_) async => _buildPreview());
  });

  Widget buildLoginScreen({
    AuthState? initialAuthState,
    void Function(_TestLoginInviteNotifier notifier)? onInviteNotifierCreated,
  }) {
    return createTestApp(
      const LoginScreen(),
      overrides: [
        authRepositoryProvider.overrideWithValue(mockAuthRepo),
        databaseServiceProvider.overrideWithValue(mockDatabaseService),
        inviteDatasourceProvider.overrideWithValue(mockInviteDatasource),
        inviteStateProvider.overrideWith((ref) {
          final notifier = _TestLoginInviteNotifier(mockInviteDatasource, ref);
          onInviteNotifierCreated?.call(notifier);
          return notifier;
        }),
        loginDeviceRegistrationServiceProvider.overrideWithValue(
          mockLoginDeviceRegistrationService,
        ),
        if (initialAuthState != null)
          authStateProvider.overrideWith((ref) {
            final notifier = AuthNotifier(mockAuthRepo);
            return notifier;
          }),
      ],
    );
  }

  Widget buildLoginScreenRouter({
    void Function(_TestLoginInviteNotifier notifier)? onInviteNotifierCreated,
  }) {
    final router = GoRouter(
      initialLocation: '/login',
      routes: [
        GoRoute(
          path: '/login',
          builder: (context, state) => const LoginScreen(),
        ),
        GoRoute(
          path: '/chats',
          builder: (context, state) =>
              const Scaffold(body: Text('Chats Screen')),
        ),
      ],
    );

    return createTestRouterApp(
      router,
      overrides: [
        authRepositoryProvider.overrideWithValue(mockAuthRepo),
        databaseServiceProvider.overrideWithValue(mockDatabaseService),
        inviteDatasourceProvider.overrideWithValue(mockInviteDatasource),
        inviteStateProvider.overrideWith((ref) {
          final notifier = _TestLoginInviteNotifier(mockInviteDatasource, ref);
          onInviteNotifierCreated?.call(notifier);
          return notifier;
        }),
        loginDeviceRegistrationServiceProvider.overrideWithValue(
          mockLoginDeviceRegistrationService,
        ),
      ],
    );
  }

  group('LoginScreen', () {
    group('initial rendering', () {
      testWidgets('shows app logo and title', (tester) async {
        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsOneWidget);
        // Title is a RichText with "iris" and "chat" spans
        expect(find.byType(RichText), findsWidgets);
      });

      testWidgets('shows create identity button', (tester) async {
        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        expect(find.text('Create New Identity'), findsOneWidget);
        expect(find.byIcon(Icons.add), findsOneWidget);
      });

      testWidgets('shows import existing key button', (tester) async {
        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        expect(find.text('Import Existing Key'), findsOneWidget);
        expect(find.byIcon(Icons.key), findsOneWidget);
      });

      testWidgets('does not show key input initially', (tester) async {
        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        expect(find.byType(TextField), findsNothing);
        expect(find.text('Login'), findsNothing);
      });
    });

    group('import existing key', () {
      testWidgets('shows key input when import button tapped', (tester) async {
        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        expect(find.byType(TextField), findsOneWidget);
        expect(find.text('Private Key (nsec)'), findsOneWidget);
        expect(find.text('Login'), findsOneWidget);
      });

      testWidgets('hides key input when close button tapped', (tester) async {
        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        expect(find.byType(TextField), findsOneWidget);

        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();

        expect(find.byType(TextField), findsNothing);
      });

      testWidgets('login button calls login with entered key', (tester) async {
        // Use a completer to control when the login completes
        when(
          () => mockAuthRepo.login(
            any(),
            devicePrivkeyHex: any(named: 'devicePrivkeyHex'),
          ),
        ).thenAnswer((_) async => const Identity(pubkeyHex: testPubkeyHex));

        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), testPrivkeyHex);
        await tester.pumpAndSettle();

        await tester.tap(find.text('Login'));
        // Only pump once to verify login was called, don't wait for navigation
        await tester.pump();

        verify(
          () => mockAuthRepo.login(testPrivkeyHex, devicePrivkeyHex: null),
        ).called(1);
      }, skip: true);

      testWidgets('does not call login with empty key', (tester) async {
        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        // Leave text field empty
        await tester.tap(find.text('Login'));
        await tester.pump();

        verifyNever(
          () => mockAuthRepo.login(
            any(),
            devicePrivkeyHex: any(named: 'devicePrivkeyHex'),
          ),
        );
      });

      testWidgets('obscures password input', (tester) async {
        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        final textField = tester.widget<TextField>(find.byType(TextField));
        expect(textField.obscureText, isTrue);
      });
    });

    group('create identity', () {
      testWidgets(
        'create identity clears local data then calls createIdentity',
        (tester) async {
          when(
            () => mockAuthRepo.createIdentity(),
          ).thenThrow(Exception('create failed'));

          await tester.pumpWidget(buildLoginScreen());
          await tester.pumpAndSettle();

          await tester.tap(find.text('Create New Identity'));
          await tester.pump();

          verifyInOrder([
            () => mockDatabaseService.deleteDatabase(),
            () => mockAuthRepo.createIdentity(),
          ]);
        },
      );

      testWidgets('create identity auto-registers current device', (
        tester,
      ) async {
        when(
          () => mockAuthRepo.createIdentity(),
        ).thenAnswer((_) async => const Identity(pubkeyHex: testPubkeyHex));
        when(
          () => mockAuthRepo.getOwnerPrivateKey(),
        ).thenAnswer((_) async => testPrivkeyHex);

        await tester.pumpWidget(buildLoginScreenRouter());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Create New Identity'));
        await tester.pumpAndSettle();

        verify(
          () => mockLoginDeviceRegistrationService.publishSingleDevice(
            ownerPubkeyHex: testPubkeyHex,
            ownerPrivkeyHex: testPrivkeyHex,
            devicePubkeyHex: testPubkeyHex,
          ),
        ).called(1);
      });

      testWidgets('create identity auto-generates signup invite link', (
        tester,
      ) async {
        _TestLoginInviteNotifier? inviteNotifier;

        when(
          () => mockAuthRepo.createIdentity(),
        ).thenAnswer((_) async => const Identity(pubkeyHex: testPubkeyHex));
        when(
          () => mockAuthRepo.getOwnerPrivateKey(),
        ).thenAnswer((_) async => testPrivkeyHex);

        await tester.pumpWidget(
          buildLoginScreenRouter(
            onInviteNotifierCreated: (notifier) => inviteNotifier = notifier,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Create New Identity'));
        await tester.pumpAndSettle();

        expect(inviteNotifier, isNotNull);
        expect(inviteNotifier!.ensurePublishedPublicInviteCalls, 1);
      });
    });

    group('loading state', () {
      testWidgets('shows loading indicator when creating identity', (
        tester,
      ) async {
        when(() => mockAuthRepo.createIdentity()).thenAnswer((_) async {
          await Future.delayed(const Duration(seconds: 1));
          return const Identity(pubkeyHex: testPubkeyHex);
        });

        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Create New Identity'));
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      }, skip: true);

      testWidgets('disables buttons when loading', (tester) async {
        when(() => mockAuthRepo.createIdentity()).thenAnswer((_) async {
          await Future.delayed(const Duration(seconds: 1));
          return const Identity(pubkeyHex: testPubkeyHex);
        });

        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Create New Identity'));
        await tester.pump();

        // Try to tap the button again - should be disabled
        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Create New Identity').first,
        );
        expect(button.onPressed, isNull);
      }, skip: true);
    });

    group('error handling', () {
      testWidgets('displays error message from state', (tester) async {
        when(
          () => mockAuthRepo.login(
            any(),
            devicePrivkeyHex: any(named: 'devicePrivkeyHex'),
          ),
        ).thenThrow(const InvalidKeyException('Invalid key format'));

        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'invalid-key');
        await tester.tap(find.text('Login'));
        await tester.pumpAndSettle();

        expect(find.text('Invalid key format'), findsOneWidget);
      });

      testWidgets('error container has correct styling', (tester) async {
        when(
          () => mockAuthRepo.login(
            any(),
            devicePrivkeyHex: any(named: 'devicePrivkeyHex'),
          ),
        ).thenThrow(const InvalidKeyException('Test error'));

        await tester.pumpWidget(buildLoginScreen());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'bad-key');
        await tester.tap(find.text('Login'));
        await tester.pumpAndSettle();

        expect(find.text('Test error'), findsOneWidget);
      });
    });

    group('nsec login', () {
      testWidgets('login shows device registration prompt before chats', (
        tester,
      ) async {
        final nsec = _validNsec();

        when(
          () => mockAuthRepo.login(
            any(),
            devicePrivkeyHex: any(named: 'devicePrivkeyHex'),
          ),
        ).thenAnswer((_) async => const Identity(pubkeyHex: testPubkeyHex));

        await tester.pumpWidget(buildLoginScreenRouter());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), nsec);
        await tester.tap(find.text('Login'));
        await tester.pumpAndSettle();

        expect(find.text('Register This Device?'), findsWidgets);
        expect(find.text('Previously active devices'), findsWidgets);
        expect(
          find.text('Active devices after registering this one'),
          findsWidgets,
        );
        expect(find.text('Chats Screen'), findsNothing);
        verify(
          () => mockLoginDeviceRegistrationService
              .buildPreviewFromPrivateKeyNsec(nsec),
        ).called(1);
        verify(
          () => mockAuthRepo.login(
            nsec,
            devicePrivkeyHex: generatedDevicePrivkeyHex,
          ),
        ).called(1);
      });

      testWidgets('registering from prompt publishes generated device key', (
        tester,
      ) async {
        final nsec = _validNsec();

        when(
          () => mockAuthRepo.login(
            any(),
            devicePrivkeyHex: any(named: 'devicePrivkeyHex'),
          ),
        ).thenAnswer((_) async => const Identity(pubkeyHex: testPubkeyHex));

        await tester.pumpWidget(buildLoginScreenRouter());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), nsec);
        await tester.tap(find.text('Login'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Register Device').last,
        );
        await tester.pumpAndSettle();

        verify(
          () => mockAuthRepo.login(
            nsec,
            devicePrivkeyHex: generatedDevicePrivkeyHex,
          ),
        ).called(1);
        verify(
          () => mockLoginDeviceRegistrationService.registerDevice(
            ownerPubkeyHex: testPubkeyHex,
            ownerPrivkeyHex: testPrivkeyHex,
            devicePubkeyHex: generatedDevicePubkeyHex,
          ),
        ).called(1);
        expect(find.text('Chats Screen'), findsOneWidget);
      });

      testWidgets(
        'pasting valid nsec auto-starts login and opens registration prompt',
        (tester) async {
          when(
            () => mockAuthRepo.login(
              any(),
              devicePrivkeyHex: any(named: 'devicePrivkeyHex'),
            ),
          ).thenAnswer((_) async => const Identity(pubkeyHex: testPubkeyHex));

          final nsec = nostr.Nip19.encodePrivkey(testPrivkeyHex) as String;

          await tester.pumpWidget(buildLoginScreenRouter());
          await tester.pumpAndSettle();

          await tester.tap(find.text('Import Existing Key'));
          await tester.pumpAndSettle();

          await tester.enterText(find.byType(TextField), nsec);
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pumpAndSettle();

          expect(find.text('Register This Device?'), findsWidgets);
          expect(find.text('Chats Screen'), findsNothing);
          verify(
            () => mockAuthRepo.login(
              nsec,
              devicePrivkeyHex: generatedDevicePrivkeyHex,
            ),
          ).called(1);
        },
      );

      testWidgets('skip keeps login successful without registering device', (
        tester,
      ) async {
        final nsec = _validNsec();

        when(
          () => mockAuthRepo.login(
            any(),
            devicePrivkeyHex: any(named: 'devicePrivkeyHex'),
          ),
        ).thenAnswer((_) async => const Identity(pubkeyHex: testPubkeyHex));

        await tester.pumpWidget(buildLoginScreenRouter());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), nsec);
        await tester.tap(find.text('Login'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Skip for now').last);
        await tester.pumpAndSettle();

        verify(
          () => mockAuthRepo.login(
            nsec,
            devicePrivkeyHex: generatedDevicePrivkeyHex,
          ),
        ).called(1);
        verifyNever(
          () => mockLoginDeviceRegistrationService.registerDevice(
            ownerPubkeyHex: any(named: 'ownerPubkeyHex'),
            ownerPrivkeyHex: any(named: 'ownerPrivkeyHex'),
            devicePubkeyHex: any(named: 'devicePubkeyHex'),
          ),
        );
        expect(find.text('Chats Screen'), findsOneWidget);
      });

      testWidgets('dialog warns when no previous devices were found', (
        tester,
      ) async {
        final nsec = _validNsec();

        when(
          () => mockLoginDeviceRegistrationService
              .buildPreviewFromPrivateKeyNsec(any()),
        ).thenAnswer((_) async => _buildPreview(existingDevices: const []));

        await tester.pumpWidget(buildLoginScreenRouter());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Import Existing Key'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), nsec);
        await tester.tap(find.text('Login'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'No previous devices were found. Registering now will publish this device as the first active device for this account.',
          ),
          findsWidgets,
        );
      });
    });
  });
}
