import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/app_bootstrap_provider.dart';
import 'package:iris_chat/config/providers/auth_provider.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/config/providers/invite_provider.dart';
import 'package:iris_chat/config/providers/nostr_provider.dart';
import 'package:iris_chat/core/services/profile_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/features/auth/domain/repositories/auth_repository.dart';
import 'package:iris_chat/features/chat/data/datasources/group_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/group_message_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/session_local_datasource.dart';
import 'package:iris_chat/features/invite/data/datasources/invite_local_datasource.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockSessionManagerService extends Mock
    implements SessionManagerService {}

class _MockSessionLocalDatasource extends Mock
    implements SessionLocalDatasource {}

class _MockProfileService extends Mock implements ProfileService {}

class _MockGroupLocalDatasource extends Mock implements GroupLocalDatasource {}

class _MockGroupMessageLocalDatasource extends Mock
    implements GroupMessageLocalDatasource {}

class _MockInviteLocalDatasource extends Mock
    implements InviteLocalDatasource {}

class _MockRef extends Mock implements Ref {}

class _TestAuthNotifier extends AuthNotifier {
  _TestAuthNotifier(super.repository) : super();

  set authState(AuthState nextState) {
    state = nextState;
  }
}

Future<void> _completeVoidAnswer(Invocation _) async {}

Future<bool> _completeFalseAnswer(Invocation _) async => false;

class _TrackingSessionNotifier extends SessionNotifier {
  _TrackingSessionNotifier(
    this.log,
    SessionLocalDatasource datasource,
    ProfileService profileService,
    SessionManagerService sessionManagerService,
  ) : super(datasource, profileService, sessionManagerService);

  final List<String> log;

  @override
  Future<void> loadSessions() async {
    log.add('loadSessions');
  }
}

class _TrackingGroupNotifier extends GroupNotifier {
  _TrackingGroupNotifier(
    this.log,
    GroupLocalDatasource groupDatasource,
    GroupMessageLocalDatasource groupMessageDatasource,
    SessionManagerService sessionManagerService,
  ) : super(groupDatasource, groupMessageDatasource, sessionManagerService);

  final List<String> log;

  @override
  Future<void> loadGroups() async {
    log.add('loadGroups');
  }
}

class _TrackingInviteNotifier extends InviteNotifier {
  _TrackingInviteNotifier(this.log, InviteLocalDatasource datasource, Ref ref)
    : super(datasource, ref);

  final List<String> log;

  @override
  Future<void> loadInvites() async {
    log.add('loadInvites');
  }

  @override
  Future<void> bootstrapInviteResponsesFromRelay({
    Duration timeout = const Duration(seconds: 1),
  }) async {
    log.add('bootstrapInviteResponsesFromRelay');
  }

  @override
  Future<void> ensurePublishedPublicInvite() async {
    log.add('ensurePublishedPublicInvite');
  }
}

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

  group('AppBootstrapNotifier', () {
    test('starts message subscription before session bootstrap work', () async {
      final log = <String>[];
      final authNotifier = _TestAuthNotifier(_MockAuthRepository());
      final sessionManager = _MockSessionManagerService();

      when(() => sessionManager.ownerPubkeyHex).thenReturn(
        '1111111111111111111111111111111111111111111111111111111111111111',
      );
      when(() => sessionManager.setupUsers(any())).thenAnswer((_) async {});
      when(
        () => sessionManager.bootstrapUsersFromRelay(any()),
      ).thenAnswer((_) async {});
      when(
        () => sessionManager.getActiveSessionState(any()),
      ).thenAnswer((_) async => null);
      when(sessionManager.refreshSubscription).thenAnswer(_completeVoidAnswer);
      when(
        () => sessionManager.repairRecentlyActiveLinkedDeviceRecords(any()),
      ).thenAnswer((_) async {});
      when(
        sessionManager.bootstrapOwnerSelfSessionIfNeeded,
      ).thenAnswer(_completeFalseAnswer);

      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith((ref) => authNotifier),
          sessionManagerServiceProvider.overrideWithValue(sessionManager),
          sessionStateProvider.overrideWith(
            (ref) => _TrackingSessionNotifier(
              log,
              _MockSessionLocalDatasource(),
              _MockProfileService(),
              sessionManager,
            ),
          ),
          groupStateProvider.overrideWith(
            (ref) => _TrackingGroupNotifier(
              log,
              _MockGroupLocalDatasource(),
              _MockGroupMessageLocalDatasource(),
              sessionManager,
            ),
          ),
          inviteStateProvider.overrideWith(
            (ref) => _TrackingInviteNotifier(
              log,
              _MockInviteLocalDatasource(),
              _MockRef(),
            ),
          ),
          messageSubscriptionProvider.overrideWith((ref) {
            log.add('messageSubscription');
            return sessionManager;
          }),
        ],
      );
      addTearDown(container.dispose);

      container.read(appBootstrapProvider);
      authNotifier.authState = const AuthState(
        isAuthenticated: true,
        isInitialized: true,
        pubkeyHex:
            '1111111111111111111111111111111111111111111111111111111111111111',
        devicePubkeyHex:
            '2222222222222222222222222222222222222222222222222222222222222222',
        isLinkedDevice: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(log, isNotEmpty);
      expect(
        log.first,
        'messageSubscription',
        reason:
            'Realtime decrypted-message listeners must attach before the slower '
            'bootstrap sequence, otherwise early messages can be dropped.',
      );
    });
  });
}
