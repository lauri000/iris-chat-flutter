import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/utils/invite_response_subscription.dart';
import 'package:iris_chat/features/invite/data/datasources/invite_local_datasource.dart';
import 'package:iris_chat/features/invite/domain/models/invite.dart';
import 'package:mocktail/mocktail.dart';

class MockNostrService extends Mock implements NostrService {}

class MockInviteLocalDatasource extends Mock implements InviteLocalDatasource {}

void main() {
  late MockNostrService nostrService;
  late MockInviteLocalDatasource inviteDatasource;

  setUp(() {
    nostrService = MockNostrService();
    inviteDatasource = MockInviteLocalDatasource();

    when(
      () => nostrService.subscribeWithIdRaw(any(), any()),
    ).thenReturn(appInviteResponsesSubId);
    when(() => nostrService.closeSubscription(any())).thenReturn(null);
  });

  test('subscribes to active invite response ephemeral pubkeys', () async {
    when(() => inviteDatasource.getActiveInvites()).thenAnswer(
      (_) async => <Invite>[
        Invite(
          id: 'invite-a',
          inviterPubkeyHex: 'pubkey-a',
          createdAt: DateTime(2026, 1, 1),
          serializedState: '{"ephemeralKey":"bbbb"}',
        ),
        Invite(
          id: 'invite-b',
          inviterPubkeyHex: 'pubkey-b',
          createdAt: DateTime(2026, 1, 1),
          serializedState: '{"ephemeralKey":"aaaa"}',
        ),
      ],
    );

    await refreshInviteResponseSubscription(
      nostrService: nostrService,
      inviteDatasource: inviteDatasource,
    );

    final captured =
        verify(
              () => nostrService.subscribeWithIdRaw(
                appInviteResponsesSubId,
                captureAny(),
              ),
            ).captured.single
            as Map<String, dynamic>;
    expect(captured['kinds'], const [1059]);
    expect(captured['#p'], ['aaaa', 'bbbb']);
    verifyNever(() => nostrService.closeSubscription(any()));
  });

  test('closes response subscription when no active invites remain', () async {
    when(
      () => inviteDatasource.getActiveInvites(),
    ).thenAnswer((_) async => const <Invite>[]);

    await refreshInviteResponseSubscription(
      nostrService: nostrService,
      inviteDatasource: inviteDatasource,
    );

    verify(
      () => nostrService.closeSubscription(appInviteResponsesSubId),
    ).called(1);
    verifyNever(() => nostrService.subscribeWithIdRaw(any(), any()));
  });
}
