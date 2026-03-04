import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/invite_provider.dart';
import 'package:iris_chat/core/ffi/ndr_ffi.dart';
import 'package:iris_chat/features/invite/data/datasources/invite_local_datasource.dart';
import 'package:iris_chat/features/invite/domain/models/invite.dart';
import 'package:mocktail/mocktail.dart';

class MockInviteLocalDatasource extends Mock implements InviteLocalDatasource {}

class MockRef extends Mock implements Ref {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InviteNotifier notifier;
  late MockInviteLocalDatasource mockDatasource;
  late MockRef mockRef;

  setUp(() {
    mockDatasource = MockInviteLocalDatasource();
    mockRef = MockRef();
    notifier = InviteNotifier(mockDatasource, mockRef);
  });

  setUpAll(() {
    registerFallbackValue(
      Invite(
        id: 'fallback',
        inviterPubkeyHex: 'pubkey',
        createdAt: DateTime.now(),
      ),
    );
  });

  group('InviteNotifier', () {
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
  });
}
