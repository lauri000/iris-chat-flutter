import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/auth_provider.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/config/providers/invite_provider.dart';
import 'package:iris_chat/config/providers/nostr_provider.dart';
import 'package:iris_chat/core/ffi/ndr_ffi.dart';
import 'package:iris_chat/core/services/logger_service.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/features/auth/domain/repositories/auth_repository.dart';
import 'package:iris_chat/features/chat/data/datasources/session_local_datasource.dart';
import 'package:iris_chat/features/chat/domain/models/session.dart';
import 'package:iris_chat/features/invite/data/datasources/invite_local_datasource.dart';
import 'package:iris_chat/features/invite/domain/models/invite.dart';
import 'package:mocktail/mocktail.dart';

class MockInviteLocalDatasource extends Mock implements InviteLocalDatasource {}

class MockAuthRepository extends Mock implements AuthRepository {}

class MockSessionManagerService extends Mock implements SessionManagerService {}

class MockSessionLocalDatasource extends Mock
    implements SessionLocalDatasource {}

class MockNostrService extends Mock implements NostrService {}

class MockRef extends Mock implements Ref {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InviteNotifier notifier;
  late MockInviteLocalDatasource mockDatasource;
  late MockRef mockRef;
  late MockAuthRepository mockAuthRepository;
  late MockSessionManagerService mockSessionManagerService;
  late MockSessionLocalDatasource mockSessionDatasource;
  late MockNostrService mockNostrService;
  late bool previousLoggerEnabled;

  setUp(() {
    mockDatasource = MockInviteLocalDatasource();
    mockRef = MockRef();
    mockAuthRepository = MockAuthRepository();
    mockSessionManagerService = MockSessionManagerService();
    mockSessionDatasource = MockSessionLocalDatasource();
    mockNostrService = MockNostrService();
    notifier = InviteNotifier(mockDatasource, mockRef);
  });

  setUpAll(() {
    previousLoggerEnabled = Logger.enabled;
    Logger.enabled = false;
    registerFallbackValue(
      Invite(
        id: 'fallback',
        inviterPubkeyHex: 'pubkey',
        createdAt: DateTime.now(),
      ),
    );
    registerFallbackValue(
      ChatSession(
        id: 'fallback-session',
        recipientPubkeyHex:
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        createdAt: DateTime.now(),
      ),
    );
    registerFallbackValue(<String, dynamic>{});
  });

  tearDownAll(() {
    Logger.enabled = previousLoggerEnabled;
  });

  group('InviteNotifier', () {
    group('effectiveInviteMaxUses', () {
      test('defaults chat invites to single-use', () {
        expect(effectiveInviteMaxUses(requestedMaxUses: null), 1);
      });

      test('preserves unlimited invites when requested explicitly', () {
        expect(
          effectiveInviteMaxUses(
            requestedMaxUses: null,
            defaultToSingleUse: false,
          ),
          isNull,
        );
      });

      test('preserves explicit maxUses values', () {
        expect(
          effectiveInviteMaxUses(
            requestedMaxUses: 7,
            defaultToSingleUse: false,
          ),
          7,
        );
      });
    });

    group('initial state', () {
      test('has empty invites list', () {
        expect(notifier.state.invites, isEmpty);
      });

      test('is not loading', () {
        expect(notifier.state.isLoading, false);
      });

      test('is not creating', () {
        expect(notifier.state.isCreating, false);
      });

      test('is not accepting', () {
        expect(notifier.state.isAccepting, false);
      });

      test('has no error', () {
        expect(notifier.state.error, isNull);
      });
    });

    group('loadInvites', () {
      test('sets isLoading true while loading', () async {
        when(
          () => mockDatasource.getActiveInvites(),
        ).thenAnswer((_) async => []);

        final future = notifier.loadInvites();
        await future;

        expect(notifier.state.isLoading, false);
      });

      test('populates invites on success', () async {
        final invites = [
          Invite(
            id: 'invite-1',
            inviterPubkeyHex: 'pubkey1',
            createdAt: DateTime.now(),
          ),
          Invite(
            id: 'invite-2',
            inviterPubkeyHex: 'pubkey1',
            createdAt: DateTime.now(),
            label: 'Work',
          ),
        ];

        when(
          () => mockDatasource.getActiveInvites(),
        ).thenAnswer((_) async => invites);

        await notifier.loadInvites();

        expect(notifier.state.invites, invites);
        expect(notifier.state.isLoading, false);
        expect(notifier.state.error, isNull);
      });

      test('sets error on failure', () async {
        when(
          () => mockDatasource.getActiveInvites(),
        ).thenThrow(Exception('Database error'));

        await notifier.loadInvites();

        expect(notifier.state.invites, isEmpty);
        expect(notifier.state.isLoading, false);
        // Error messages are mapped to user-friendly text; just ensure we
        // surface an error rather than crashing.
        expect(notifier.state.error, isNotNull);
      });

      test('sets error when datasource read hangs', () async {
        final completer = Completer<List<Invite>>();
        when(
          () => mockDatasource.getActiveInvites(),
        ).thenAnswer((_) => completer.future);

        await notifier.loadInvites().timeout(const Duration(seconds: 4));

        expect(notifier.state.invites, isEmpty);
        expect(notifier.state.isLoading, false);
        expect(notifier.state.error, isNotNull);
      });

      test(
        'does not throw if notifier is disposed during pending load',
        () async {
          final completer = Completer<List<Invite>>();
          when(
            () => mockDatasource.getActiveInvites(),
          ).thenAnswer((_) => completer.future);

          final loadFuture = notifier.loadInvites();
          notifier.dispose();
          completer.complete(const <Invite>[]);

          await expectLater(loadFuture, completes);
        },
      );
    });

    group('deleteInvite', () {
      test('removes invite from datasource and state', () async {
        final invite = Invite(
          id: 'invite-1',
          inviterPubkeyHex: 'pubkey1',
          createdAt: DateTime.now(),
        );

        when(
          () => mockDatasource.getActiveInvites(),
        ).thenAnswer((_) async => [invite]);
        when(
          () => mockDatasource.deleteInvite('invite-1'),
        ).thenAnswer((_) async {});

        await notifier.loadInvites();
        expect(notifier.state.invites, isNotEmpty);

        await notifier.deleteInvite('invite-1');

        expect(notifier.state.invites, isEmpty);
        verify(() => mockDatasource.deleteInvite('invite-1')).called(1);
      });
    });

    group('updateLabel', () {
      test('updates invite label in datasource and state', () async {
        final invite = Invite(
          id: 'invite-1',
          inviterPubkeyHex: 'pubkey1',
          createdAt: DateTime.now(),
        );

        when(
          () => mockDatasource.getActiveInvites(),
        ).thenAnswer((_) async => [invite]);
        when(() => mockDatasource.updateInvite(any())).thenAnswer((_) async {});

        await notifier.loadInvites();
        await notifier.updateLabel('invite-1', 'Friends');

        expect(notifier.state.invites.first.label, 'Friends');
        verify(() => mockDatasource.updateInvite(any())).called(1);
      });
    });

    group('clearError', () {
      test('clears error state', () async {
        when(
          () => mockDatasource.getActiveInvites(),
        ).thenThrow(Exception('Error'));

        await notifier.loadInvites();
        expect(notifier.state.error, isNotNull);

        notifier.clearError();

        expect(notifier.state.error, isNull);
      });
    });

    group('getInviteUrl defaults', () {
      test('uses chat.iris.to root when root is not provided', () async {
        const channel = MethodChannel('to.iris.chat/ndr_ffi');
        final calls = <MethodCall>[];

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              switch (call.method) {
                case 'inviteDeserialize':
                  return <String, dynamic>{'id': 'mock-invite-handle'};
                case 'inviteToUrl':
                  final args = Map<String, dynamic>.from(call.arguments as Map);
                  return '${args['root']}/invite/invite-123';
                case 'inviteDispose':
                  return null;
              }
              return null;
            });

        when(() => mockDatasource.getInvite('invite-123')).thenAnswer(
          (_) async => Invite(
            id: 'invite-123',
            inviterPubkeyHex: 'pubkey1',
            createdAt: DateTime(2026, 1, 1),
            serializedState: 'serialized-state',
          ),
        );

        try {
          final result = await notifier.getInviteUrl('invite-123');

          expect(result, 'https://chat.iris.to/invite/invite-123');
          final inviteToUrlCalls = calls
              .where((c) => c.method == 'inviteToUrl')
              .toList();
          expect(inviteToUrlCalls, hasLength(1));
          final inviteToUrlArgs = Map<String, dynamic>.from(
            inviteToUrlCalls.first.arguments as Map,
          );
          expect(inviteToUrlArgs['root'], 'https://chat.iris.to');
        } finally {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        }
      });
    });

    group('ensurePublishedPublicInvite', () {
      test(
        'creates a canonical public-addressed invite when only legacy unlimited invites exist',
        () async {
          const channel = MethodChannel('to.iris.chat/ndr_ffi');
          const ownerPubkeyHex =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const devicePubkeyHex =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const devicePrivkeyHex =
              '3333333333333333333333333333333333333333333333333333333333333333';
          final legacyUnlimitedInvite = Invite(
            id: 'legacy-public',
            inviterPubkeyHex: devicePubkeyHex,
            createdAt: DateTime(2026, 1, 1),
            maxUses: null,
            serializedState:
                '{"deviceId":"$devicePubkeyHex","inviterEphemeralPublicKey":"legacy-eph"}',
          );

          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                switch (call.method) {
                  case 'derivePublicKey':
                    return devicePubkeyHex;
                  case 'createInvite':
                    return <String, dynamic>{'id': 'created-public-invite'};
                  case 'inviteSetPurpose':
                  case 'inviteSetOwnerPubkeyHex':
                  case 'inviteDispose':
                    return null;
                  case 'inviteDeserialize':
                    return <String, dynamic>{'id': 'created-public-invite'};
                  case 'inviteSerialize':
                    return '{"deviceId":"public","inviterEphemeralPublicKey":"new-public-eph"}';
                  case 'inviteGetInviterPubkeyHex':
                    return devicePubkeyHex;
                  case 'inviteToEventJson':
                    return '''
{"kind":30078,"content":"","tags":[["ephemeralKey","new-public-eph"],["sharedSecret","shared"],["d","double-ratchet/invites/public"],["l","double-ratchet/invites"]]}''';
                }
                return null;
              });

          when(
            () => mockDatasource.getActiveInvites(),
          ).thenAnswer((_) async => [legacyUnlimitedInvite]);
          when(() => mockDatasource.saveInvite(any())).thenAnswer((_) async {});

          when(() => mockRef.read(authStateProvider)).thenReturn(
            const AuthState(
              isAuthenticated: true,
              isInitialized: true,
              hasOwnerKey: true,
              pubkeyHex: ownerPubkeyHex,
              devicePubkeyHex: devicePubkeyHex,
            ),
          );
          when(
            () => mockRef.read(authRepositoryProvider),
          ).thenReturn(mockAuthRepository);
          when(
            () => mockAuthRepository.getPrivateKey(),
          ).thenAnswer((_) async => devicePrivkeyHex);
          when(
            () => mockRef.read(nostrServiceProvider),
          ).thenReturn(mockNostrService);
          when(
            () => mockNostrService.closeSubscription(any()),
          ).thenReturn(null);
          when(
            () => mockNostrService.subscribeWithIdRaw(any(), any()),
          ).thenAnswer(
            (invocation) => invocation.positionalArguments[0] as String,
          );
          when(
            () => mockNostrService.publishEvent(any()),
          ).thenAnswer((_) async {});

          try {
            await notifier.ensurePublishedPublicInvite();
          } finally {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
          }

          final savedInvite =
              verify(
                    () => mockDatasource.saveInvite(captureAny()),
                  ).captured.single
                  as Invite;
          expect(
            InviteNotifier.serializedInviteDeviceId(
              savedInvite.serializedState!,
            ),
            canonicalPublicInviteDeviceId,
          );
          verify(() => mockNostrService.publishEvent(any())).called(1);
        },
      );
    });

    group('buildMergedDeviceMap', () {
      test('keeps local devices when relay list is empty', () {
        final devices = InviteNotifier.buildMergedDeviceMap(
          localDevices: const <FfiDeviceEntry>[
            FfiDeviceEntry(identityPubkeyHex: 'aaaa', createdAt: 100),
            FfiDeviceEntry(identityPubkeyHex: 'bbbb', createdAt: 200),
          ],
          relayDevices: const <FfiDeviceEntry>[],
          ensurePubkeys: const <String>{'cccc'},
          nowSeconds: 999,
        );

        expect(devices.keys.toSet(), {'aaaa', 'bbbb', 'cccc'});
        expect(devices['aaaa'], 100);
        expect(devices['bbbb'], 200);
        expect(devices['cccc'], 999);
      });
    });

    group('handleInviteResponse', () {
      test(
        'does not import identical owner-device state when an active native session already exists',
        () async {
          const channel = MethodChannel('to.iris.chat/ndr_ffi');
          const inviteId = 'invite-1';
          const inviteSerializedState = '{"invite":"serialized"}';
          const ownerPubkeyHex =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const devicePubkeyHex =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const devicePrivkeyHex =
              '3333333333333333333333333333333333333333333333333333333333333333';
          final invite = Invite(
            id: inviteId,
            inviterPubkeyHex: ownerPubkeyHex,
            createdAt: DateTime(2026, 1, 1),
            serializedState: inviteSerializedState,
          );
          final existingSession = ChatSession(
            id: ownerPubkeyHex,
            recipientPubkeyHex: ownerPubkeyHex,
            createdAt: DateTime(2026, 1, 1),
          );

          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                switch (call.method) {
                  case 'inviteDeserialize':
                    return <String, dynamic>{'id': 'mock-invite-handle'};
                  case 'inviteProcessResponse':
                    return <String, dynamic>{
                      'session': <String, dynamic>{'id': 'mock-session-handle'},
                      'inviteePubkeyHex': ownerPubkeyHex,
                      'ownerPubkeyHex': ownerPubkeyHex,
                    };
                  case 'sessionStateJson':
                    return '{"receiving_chain_key":"active-receive"}';
                  case 'sessionDispose':
                  case 'inviteDispose':
                    return null;
                }
                return null;
              });

          when(
            () => mockDatasource.getInvite(inviteId),
          ).thenAnswer((_) async => invite);
          when(
            () => mockDatasource.markUsed(inviteId, ownerPubkeyHex),
          ).thenAnswer((_) async {});

          when(() => mockRef.read(authStateProvider)).thenReturn(
            const AuthState(
              isAuthenticated: true,
              isInitialized: true,
              hasOwnerKey: true,
              pubkeyHex: ownerPubkeyHex,
              devicePubkeyHex: devicePubkeyHex,
            ),
          );
          when(
            () => mockRef.read(authRepositoryProvider),
          ).thenReturn(mockAuthRepository);
          when(
            () => mockAuthRepository.getPrivateKey(),
          ).thenAnswer((_) async => devicePrivkeyHex);
          when(
            () => mockRef.read(sessionManagerServiceProvider),
          ).thenReturn(mockSessionManagerService);
          when(
            () =>
                mockSessionManagerService.getActiveSessionState(ownerPubkeyHex),
          ).thenAnswer((_) async => '{"receiving_chain_key":"active-receive"}');
          when(
            () => mockSessionManagerService.refreshSubscription(),
          ).thenAnswer((_) async {});
          when(
            () => mockRef.read(sessionDatasourceProvider),
          ).thenReturn(mockSessionDatasource);
          when(
            () => mockSessionDatasource.getSessionByRecipient(ownerPubkeyHex),
          ).thenAnswer((_) async => existingSession);

          try {
            await notifier.handleInviteResponse(inviteId, '{"kind":1059}');
          } finally {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
          }

          verify(
            () =>
                mockSessionManagerService.getActiveSessionState(ownerPubkeyHex),
          ).called(1);
          verifyNever(
            () => mockSessionManagerService.importSessionState(
              peerPubkeyHex: any(named: 'peerPubkeyHex'),
              stateJson: any(named: 'stateJson'),
              deviceId: any(named: 'deviceId'),
            ),
          );
          verify(
            () => mockDatasource.markUsed(inviteId, ownerPubkeyHex),
          ).called(1);
          verify(
            () => mockSessionManagerService.refreshSubscription(),
          ).called(1);
        },
      );

      test(
        'imports differing owner-device response state even when an active native session can receive',
        () async {
          const channel = MethodChannel('to.iris.chat/ndr_ffi');
          const inviteId = 'invite-1b';
          const inviteSerializedState = '{"invite":"serialized"}';
          const ownerPubkeyHex =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const devicePubkeyHex =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const devicePrivkeyHex =
              '3333333333333333333333333333333333333333333333333333333333333333';
          final invite = Invite(
            id: inviteId,
            inviterPubkeyHex: ownerPubkeyHex,
            createdAt: DateTime(2026, 1, 1),
            serializedState: inviteSerializedState,
          );
          final existingSession = ChatSession(
            id: ownerPubkeyHex,
            recipientPubkeyHex: ownerPubkeyHex,
            createdAt: DateTime(2026, 1, 1),
          );

          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                switch (call.method) {
                  case 'inviteDeserialize':
                    return <String, dynamic>{'id': 'mock-invite-handle'};
                  case 'inviteProcessResponse':
                    return <String, dynamic>{
                      'session': <String, dynamic>{'id': 'mock-session-handle'},
                      'inviteePubkeyHex': ownerPubkeyHex,
                      'ownerPubkeyHex': ownerPubkeyHex,
                    };
                  case 'sessionStateJson':
                    return '{"their_next_nostr_public_key":"fresh-next"}';
                  case 'sessionDispose':
                  case 'inviteDispose':
                    return null;
                }
                return null;
              });

          when(
            () => mockDatasource.getInvite(inviteId),
          ).thenAnswer((_) async => invite);
          when(
            () => mockDatasource.markUsed(inviteId, ownerPubkeyHex),
          ).thenAnswer((_) async {});

          when(() => mockRef.read(authStateProvider)).thenReturn(
            const AuthState(
              isAuthenticated: true,
              isInitialized: true,
              hasOwnerKey: true,
              pubkeyHex: ownerPubkeyHex,
              devicePubkeyHex: devicePubkeyHex,
            ),
          );
          when(
            () => mockRef.read(authRepositoryProvider),
          ).thenReturn(mockAuthRepository);
          when(
            () => mockAuthRepository.getPrivateKey(),
          ).thenAnswer((_) async => devicePrivkeyHex);
          when(
            () => mockRef.read(sessionManagerServiceProvider),
          ).thenReturn(mockSessionManagerService);
          when(
            () =>
                mockSessionManagerService.getActiveSessionState(ownerPubkeyHex),
          ).thenAnswer((_) async => '{"receiving_chain_key":"active-receive"}');
          when(
            () => mockSessionManagerService.importSessionState(
              peerPubkeyHex: any(named: 'peerPubkeyHex'),
              stateJson: any(named: 'stateJson'),
              deviceId: any(named: 'deviceId'),
            ),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionManagerService.refreshSubscription(),
          ).thenAnswer((_) async {});
          when(
            () => mockRef.read(sessionDatasourceProvider),
          ).thenReturn(mockSessionDatasource);
          when(
            () => mockSessionDatasource.getSessionByRecipient(ownerPubkeyHex),
          ).thenAnswer((_) async => existingSession);

          try {
            await notifier.handleInviteResponse(inviteId, '{"kind":1059}');
          } finally {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
          }

          verify(
            () =>
                mockSessionManagerService.getActiveSessionState(ownerPubkeyHex),
          ).called(1);
          verify(
            () => mockSessionManagerService.importSessionState(
              peerPubkeyHex: ownerPubkeyHex,
              stateJson: '{"their_next_nostr_public_key":"fresh-next"}',
              deviceId: ownerPubkeyHex,
            ),
          ).called(1);
          verify(
            () => mockSessionManagerService.refreshSubscription(),
          ).called(1);
        },
      );

      test(
        'imports linked-device response even when owner session already has receiving capability',
        () async {
          const channel = MethodChannel('to.iris.chat/ndr_ffi');
          const inviteId = 'invite-2';
          const inviteSerializedState = '{"invite":"serialized"}';
          const ownerPubkeyHex =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const devicePubkeyHex =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const linkedDeviceId = 'linked-device-id';
          const devicePrivkeyHex =
              '3333333333333333333333333333333333333333333333333333333333333333';
          final invite = Invite(
            id: inviteId,
            inviterPubkeyHex: ownerPubkeyHex,
            createdAt: DateTime(2026, 1, 1),
            serializedState: inviteSerializedState,
          );
          final existingSession = ChatSession(
            id: ownerPubkeyHex,
            recipientPubkeyHex: ownerPubkeyHex,
            createdAt: DateTime(2026, 1, 1),
          );

          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                switch (call.method) {
                  case 'inviteDeserialize':
                    return <String, dynamic>{'id': 'mock-invite-handle'};
                  case 'inviteProcessResponse':
                    return <String, dynamic>{
                      'session': <String, dynamic>{'id': 'mock-session-handle'},
                      'inviteePubkeyHex': devicePubkeyHex,
                      'deviceId': linkedDeviceId,
                      'ownerPubkeyHex': ownerPubkeyHex,
                    };
                  case 'sessionStateJson':
                    return '{"session":"replayed"}';
                  case 'sessionDispose':
                  case 'inviteDispose':
                    return null;
                }
                return null;
              });

          when(
            () => mockDatasource.getInvite(inviteId),
          ).thenAnswer((_) async => invite);
          when(
            () => mockDatasource.markUsed(inviteId, ownerPubkeyHex),
          ).thenAnswer((_) async {});

          when(() => mockRef.read(authStateProvider)).thenReturn(
            const AuthState(
              isAuthenticated: true,
              isInitialized: true,
              hasOwnerKey: true,
              pubkeyHex: ownerPubkeyHex,
              devicePubkeyHex: devicePubkeyHex,
            ),
          );
          when(
            () => mockRef.read(authRepositoryProvider),
          ).thenReturn(mockAuthRepository);
          when(
            () => mockAuthRepository.getPrivateKey(),
          ).thenAnswer((_) async => devicePrivkeyHex);
          when(
            () => mockRef.read(sessionManagerServiceProvider),
          ).thenReturn(mockSessionManagerService);
          when(
            () =>
                mockSessionManagerService.getActiveSessionState(ownerPubkeyHex),
          ).thenAnswer((_) async => '{"receiving_chain_key":"active-receive"}');
          when(
            () => mockSessionManagerService.importSessionState(
              peerPubkeyHex: any(named: 'peerPubkeyHex'),
              stateJson: any(named: 'stateJson'),
              deviceId: any(named: 'deviceId'),
            ),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionManagerService.refreshSubscription(),
          ).thenAnswer((_) async {});
          when(
            () => mockRef.read(sessionDatasourceProvider),
          ).thenReturn(mockSessionDatasource);
          when(
            () => mockSessionDatasource.getSessionByRecipient(ownerPubkeyHex),
          ).thenAnswer((_) async => existingSession);

          try {
            await notifier.handleInviteResponse(inviteId, '{"kind":1059}');
          } finally {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
          }

          verifyNever(
            () =>
                mockSessionManagerService.getActiveSessionState(ownerPubkeyHex),
          );
          verify(
            () => mockSessionManagerService.importSessionState(
              peerPubkeyHex: ownerPubkeyHex,
              stateJson: '{"session":"replayed"}',
              deviceId: linkedDeviceId,
            ),
          ).called(1);
        },
      );

      test(
        'imports replayed state when existing native owner session lacks receiving capability',
        () async {
          const channel = MethodChannel('to.iris.chat/ndr_ffi');
          const inviteId = 'invite-3';
          const inviteSerializedState = '{"invite":"serialized"}';
          const ownerPubkeyHex =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const devicePubkeyHex =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const linkedDeviceId = 'linked-device-id';
          const devicePrivkeyHex =
              '3333333333333333333333333333333333333333333333333333333333333333';
          final invite = Invite(
            id: inviteId,
            inviterPubkeyHex: ownerPubkeyHex,
            createdAt: DateTime(2026, 1, 1),
            serializedState: inviteSerializedState,
          );
          final existingSession = ChatSession(
            id: ownerPubkeyHex,
            recipientPubkeyHex: ownerPubkeyHex,
            createdAt: DateTime(2026, 1, 1),
          );

          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                switch (call.method) {
                  case 'inviteDeserialize':
                    return <String, dynamic>{'id': 'mock-invite-handle'};
                  case 'inviteProcessResponse':
                    return <String, dynamic>{
                      'session': <String, dynamic>{'id': 'mock-session-handle'},
                      'inviteePubkeyHex': devicePubkeyHex,
                      'deviceId': linkedDeviceId,
                      'ownerPubkeyHex': ownerPubkeyHex,
                    };
                  case 'sessionStateJson':
                    return '{"session":"replayed"}';
                  case 'sessionDispose':
                  case 'inviteDispose':
                    return null;
                }
                return null;
              });

          when(
            () => mockDatasource.getInvite(inviteId),
          ).thenAnswer((_) async => invite);
          when(
            () => mockDatasource.markUsed(inviteId, ownerPubkeyHex),
          ).thenAnswer((_) async {});

          when(() => mockRef.read(authStateProvider)).thenReturn(
            const AuthState(
              isAuthenticated: true,
              isInitialized: true,
              hasOwnerKey: true,
              pubkeyHex: ownerPubkeyHex,
              devicePubkeyHex: devicePubkeyHex,
            ),
          );
          when(
            () => mockRef.read(authRepositoryProvider),
          ).thenReturn(mockAuthRepository);
          when(
            () => mockAuthRepository.getPrivateKey(),
          ).thenAnswer((_) async => devicePrivkeyHex);
          when(
            () => mockRef.read(sessionManagerServiceProvider),
          ).thenReturn(mockSessionManagerService);
          when(
            () =>
                mockSessionManagerService.getActiveSessionState(ownerPubkeyHex),
          ).thenAnswer((_) async => '{"sending_chain_key":"send-only"}');
          when(
            () => mockSessionManagerService.importSessionState(
              peerPubkeyHex: any(named: 'peerPubkeyHex'),
              stateJson: any(named: 'stateJson'),
              deviceId: any(named: 'deviceId'),
            ),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionManagerService.refreshSubscription(),
          ).thenAnswer((_) async {});
          when(
            () => mockRef.read(sessionDatasourceProvider),
          ).thenReturn(mockSessionDatasource);
          when(
            () => mockSessionDatasource.getSessionByRecipient(ownerPubkeyHex),
          ).thenAnswer((_) async => existingSession);

          try {
            await notifier.handleInviteResponse(inviteId, '{"kind":1059}');
          } finally {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
          }

          verify(
            () => mockSessionManagerService.importSessionState(
              peerPubkeyHex: ownerPubkeyHex,
              stateJson: '{"session":"replayed"}',
              deviceId: linkedDeviceId,
            ),
          ).called(1);
        },
      );
    });

    group('acceptInviteFromUrl', () {
      test(
        'reuses an existing working session instead of accepting a duplicate chat invite',
        () async {
          const ownerPubkeyHex =
              '1111111111111111111111111111111111111111111111111111111111111111';
          final existingSession = ChatSession(
            id: ownerPubkeyHex,
            recipientPubkeyHex: ownerPubkeyHex,
            createdAt: DateTime(2026, 1, 1),
          );

          when(() => mockRef.read(authStateProvider)).thenReturn(
            const AuthState(
              isAuthenticated: true,
              isInitialized: true,
              hasOwnerKey: true,
              pubkeyHex:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              devicePubkeyHex:
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ),
          );
          when(
            () => mockRef.read(sessionManagerServiceProvider),
          ).thenReturn(mockSessionManagerService);
          when(
            () => mockRef.read(sessionDatasourceProvider),
          ).thenReturn(mockSessionDatasource);
          when(
            () => mockSessionDatasource.getSessionByRecipient(ownerPubkeyHex),
          ).thenAnswer((_) async => existingSession);
          when(
            () =>
                mockSessionManagerService.getActiveSessionState(ownerPubkeyHex),
          ).thenAnswer((_) async => '{"receiving_chain_key":"active-receive"}');
          when(
            () => mockSessionManagerService.setupUser(ownerPubkeyHex),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionManagerService.refreshSubscription(),
          ).thenAnswer((_) async {});

          final sessionId = await notifier.acceptInviteFromUrl(
            'https://iris.to/#invite=%7B%22purpose%22%3A%22chat%22%2C%22owner%22%3A%22$ownerPubkeyHex%22%7D',
          );

          expect(sessionId, ownerPubkeyHex);
          expect(notifier.state.isAccepting, isFalse);
          verify(
            () =>
                mockSessionManagerService.getActiveSessionState(ownerPubkeyHex),
          ).called(1);
          verify(() => mockSessionManagerService.setupUser(ownerPubkeyHex))
              .called(1);
          verify(
            () => mockSessionManagerService.refreshSubscription(),
          ).called(1);
          verifyNever(
            () => mockSessionManagerService.acceptInviteFromUrl(
              inviteUrl: any(named: 'inviteUrl'),
              ownerPubkeyHintHex: any(named: 'ownerPubkeyHintHex'),
            ),
          );
        },
      );
    });
  });
}
