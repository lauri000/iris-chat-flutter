import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/features/chat/data/datasources/group_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/group_message_local_datasource.dart';
import 'package:iris_chat/features/chat/domain/models/group.dart';
import 'package:iris_chat/features/chat/domain/models/message.dart';
import 'package:mocktail/mocktail.dart';

class MockGroupLocalDatasource extends Mock implements GroupLocalDatasource {}

class MockGroupMessageLocalDatasource extends Mock
    implements GroupMessageLocalDatasource {}

class MockSessionManagerService extends Mock implements SessionManagerService {}

void main() {
  late GroupNotifier notifier;
  late MockGroupLocalDatasource mockGroupDatasource;
  late MockGroupMessageLocalDatasource mockGroupMessageDatasource;
  late MockSessionManagerService mockSessionManagerService;

  const myPubkey =
      '1111111111111111111111111111111111111111111111111111111111111111';
  const peerPubkey =
      '2222222222222222222222222222222222222222222222222222222222222222';

  setUpAll(() {
    registerFallbackValue(
      ChatMessage(
        id: 'fallback',
        sessionId: 'group:fallback',
        text: 'fallback',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        direction: MessageDirection.incoming,
        status: MessageStatus.delivered,
      ),
    );
  });

  setUp(() {
    mockGroupDatasource = MockGroupLocalDatasource();
    mockGroupMessageDatasource = MockGroupMessageLocalDatasource();
    mockSessionManagerService = MockSessionManagerService();

    when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(myPubkey);
    notifier = GroupNotifier(
      mockGroupDatasource,
      mockGroupMessageDatasource,
      mockSessionManagerService,
    );
  });

  test('incoming group message clears active typing indicator', () async {
    const groupId = 'group-1';

    notifier.state = notifier.state.copyWith(
      groups: [
        ChatGroup(
          id: groupId,
          name: 'Group 1',
          members: [myPubkey, peerPubkey],
          admins: [myPubkey],
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          accepted: true,
        ),
      ],
    );

    when(
      () => mockGroupMessageDatasource.messageExists(any()),
    ).thenAnswer((_) async => false);
    when(
      () => mockGroupMessageDatasource.saveMessage(any()),
    ).thenAnswer((_) async {});
    when(
      () => mockGroupDatasource.updateMetadata(
        any(),
        lastMessageAt: any(named: 'lastMessageAt'),
        lastMessagePreview: any(named: 'lastMessagePreview'),
        unreadCount: any(named: 'unreadCount'),
        accepted: any(named: 'accepted'),
        messageTtlSeconds: any(named: 'messageTtlSeconds'),
      ),
    ).thenAnswer((_) async {});

    const typingRumorJson =
        '{"id":"typing-1","pubkey":"$peerPubkey","created_at":1700000001,"kind":25,"content":"typing","tags":[["l","$groupId"]]}';
    const messageRumorJson =
        '{"id":"msg-1","pubkey":"$peerPubkey","created_at":1700000002,"kind":14,"content":"hello","tags":[["l","$groupId"]]}';

    await notifier.handleIncomingGroupRumorJson(typingRumorJson);
    expect(notifier.state.typingStates[groupId] ?? false, isTrue);

    await notifier.handleIncomingGroupRumorJson(messageRumorJson);
    expect(notifier.state.typingStates[groupId] ?? false, isFalse);
  });

  test(
    'group typing stop clears indicator when expiration equals future created_at',
    () async {
      const groupId = 'group-1';
      final futureSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120;

      notifier.state = notifier.state.copyWith(
        groups: [
          ChatGroup(
            id: groupId,
            name: 'Group 1',
            members: [myPubkey, peerPubkey],
            admins: [myPubkey],
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            accepted: true,
          ),
        ],
      );

      const typingRumorJson =
          '{"id":"typing-2","pubkey":"$peerPubkey","created_at":1700000001,"kind":25,"content":"typing","tags":[["l","$groupId"]]}';
      final stopRumorJson =
          '{"id":"typing-stop-2","pubkey":"$peerPubkey","created_at":$futureSeconds,"kind":25,"content":"typing","tags":[["l","$groupId"],["expiration","$futureSeconds"]]}';

      await notifier.handleIncomingGroupRumorJson(typingRumorJson);
      expect(notifier.state.typingStates[groupId] ?? false, isTrue);

      await notifier.handleIncomingGroupRumorJson(stopRumorJson);
      expect(notifier.state.typingStates[groupId] ?? false, isFalse);
    },
  );
}
