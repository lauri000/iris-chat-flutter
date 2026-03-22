import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/auth_provider.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/config/providers/invite_provider.dart';
import 'package:iris_chat/config/providers/nostr_provider.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/services/profile_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/features/auth/domain/models/identity.dart';
import 'package:iris_chat/features/auth/domain/repositories/auth_repository.dart';
import 'package:iris_chat/features/chat/data/datasources/group_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/group_message_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/message_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/session_local_datasource.dart';
import 'package:iris_chat/features/chat/domain/models/session.dart';
import 'package:iris_chat/features/invite/data/datasources/invite_local_datasource.dart';
import 'package:mocktail/mocktail.dart';

class _NoopAuthRepository implements AuthRepository {
  @override
  Future<Identity> createIdentity() {
    throw UnimplementedError();
  }

  @override
  Future<Identity> login(String privkeyHex, {String? devicePrivkeyHex}) {
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
  Future<Identity?> getCurrentIdentity() async => null;

  @override
  Future<bool> hasIdentity() async => false;

  @override
  Future<void> logout() async {}

  @override
  Future<String?> getPrivateKey() async => null;

  @override
  Future<String?> getOwnerPrivateKey() async => null;

  @override
  Future<String?> getDevicePubkeyHex() async => null;
}

class _TestAuthNotifier extends AuthNotifier {
  _TestAuthNotifier() : super(_NoopAuthRepository());

  set authState(AuthState next) {
    state = next;
  }
}

class _MockSessionManagerService extends Mock
    implements SessionManagerService {}

class _MockInviteLocalDatasource extends Mock
    implements InviteLocalDatasource {}

class _MockSessionLocalDatasource extends Mock
    implements SessionLocalDatasource {}

class _MockMessageLocalDatasource extends Mock
    implements MessageLocalDatasource {}

class _MockGroupLocalDatasource extends Mock implements GroupLocalDatasource {}

class _MockGroupMessageLocalDatasource extends Mock
    implements GroupMessageLocalDatasource {}

class _MockProfileService extends Mock implements ProfileService {}

class _StaticSessionNotifier extends SessionNotifier {
  _StaticSessionNotifier(
    List<ChatSession> sessions,
    SessionLocalDatasource datasource,
    ProfileService profileService,
    SessionManagerService sessionManagerService,
  ) : super(datasource, profileService, sessionManagerService) {
    state = SessionState(sessions: sessions);
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(<String>[]);
  });

  group('nostr_provider', () {
    test(
      'sessionManagerServiceProvider rebuilds when auth identity changes',
      () async {
        final authNotifier = _TestAuthNotifier();

        final container = ProviderContainer(
          overrides: [
            // Avoid real network connections in unit tests.
            nostrServiceProvider.overrideWith(
              (ref) => NostrService(relayUrls: const []),
            ),
            authRepositoryProvider.overrideWith((ref) => _NoopAuthRepository()),
            authStateProvider.overrideWith((ref) => authNotifier),
          ],
        );
        addTearDown(container.dispose);

        final instances = <Object>[];
        final sub = container.listen(
          sessionManagerServiceProvider,
          (prev, next) => instances.add(next),
          fireImmediately: true,
        );
        addTearDown(sub.close);

        expect(instances, hasLength(1));
        final first = instances.first;

        authNotifier.authState = const AuthState(
          isAuthenticated: true,
          isInitialized: true,
          pubkeyHex: 'a',
          devicePubkeyHex: 'a',
        );
        await Future<void>.delayed(Duration.zero);

        expect(instances, hasLength(2));
        expect(identical(instances[1], first), isFalse);
      },
    );

    test(
      'messageSubscriptionProvider periodically backfills recent messages for active sessions',
      () async {
        final sessionManager = _MockSessionManagerService();
        final inviteDatasource = _MockInviteLocalDatasource();
        final sessionDatasource = _MockSessionLocalDatasource();
        final messageDatasource = _MockMessageLocalDatasource();
        final groupDatasource = _MockGroupLocalDatasource();
        final groupMessageDatasource = _MockGroupMessageLocalDatasource();
        final profileService = _MockProfileService();

        when(
          () => sessionManager.decryptedMessages,
        ).thenAnswer((_) => const Stream<DecryptedMessage>.empty());
        when(() => sessionManager.ownerPubkeyHex).thenReturn(
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );
        when(
          () => sessionManager.bootstrapRecentMessageEventsFromRelay(
            any(),
            window: const Duration(minutes: 1),
          ),
        ).thenAnswer((_) async {});
        when(
          () => inviteDatasource.getActiveInvites(),
        ).thenAnswer((_) async => const []);

        final container = ProviderContainer(
          overrides: [
            nostrServiceProvider.overrideWith(
              (ref) => NostrService(relayUrls: const []),
            ),
            authRepositoryProvider.overrideWith((ref) => _NoopAuthRepository()),
            sessionManagerServiceProvider.overrideWithValue(sessionManager),
            inviteDatasourceProvider.overrideWith((ref) => inviteDatasource),
            sessionDatasourceProvider.overrideWith((ref) => sessionDatasource),
            messageDatasourceProvider.overrideWith((ref) => messageDatasource),
            groupDatasourceProvider.overrideWith((ref) => groupDatasource),
            groupMessageDatasourceProvider.overrideWith(
              (ref) => groupMessageDatasource,
            ),
            profileServiceProvider.overrideWith((ref) => profileService),
            sessionStateProvider.overrideWith(
              (ref) => _StaticSessionNotifier(
                [
                  ChatSession(
                    id: 'peer',
                    recipientPubkeyHex:
                        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
                  ),
                ],
                sessionDatasource,
                profileService,
                sessionManager,
              ),
            ),
            relayMessageBackfillDebounceProvider.overrideWith(
              (ref) => Duration.zero,
            ),
            relayMessageBackfillIntervalProvider.overrideWith(
              (ref) => const Duration(milliseconds: 50),
            ),
            relayMessageBackfillWindowProvider.overrideWith(
              (ref) => const Duration(minutes: 1),
            ),
          ],
        );
        addTearDown(container.dispose);

        container.read(messageSubscriptionProvider);
        await Future<void>.delayed(const Duration(milliseconds: 180));

        verify(
          () => sessionManager.bootstrapRecentMessageEventsFromRelay([
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ], window: const Duration(minutes: 1)),
        ).called(greaterThanOrEqualTo(2));
      },
    );
  });
}
