import 'dart:convert';

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
  const peerDevicePubkey =
      '3333333333333333333333333333333333333333333333333333333333333333';

  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue(
      ChatGroup(
        id: 'fallback-group',
        name: 'Fallback Group',
        members: const [myPubkey],
        admins: const [myPubkey],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
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

    when(
      () => mockSessionManagerService.groupUpsert(
        id: any(named: 'id'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        picture: any(named: 'picture'),
        members: any(named: 'members'),
        admins: any(named: 'admins'),
        createdAtMs: any(named: 'createdAtMs'),
        secret: any(named: 'secret'),
        accepted: any(named: 'accepted'),
      ),
    ).thenAnswer((_) async {});
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
    'duplicate incoming group message clears typing and suppresses older typing',
    () async {
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

      when(() => mockGroupMessageDatasource.messageExists(any())).thenAnswer((
        invocation,
      ) async {
        final key = invocation.positionalArguments.single as String;
        return key == 'msg-duplicate-newer';
      });

      const typingRumorJson =
          '{"id":"typing-before-duplicate","pubkey":"$peerPubkey","created_at":1700000001,"kind":25,"content":"typing","tags":[["l","$groupId"],["ms","1700000001000"]]}';
      const duplicateMessageRumorJson =
          '{"id":"msg-duplicate-newer","pubkey":"$peerPubkey","created_at":1700000002,"kind":14,"content":"hello","tags":[["l","$groupId"],["ms","1700000002000"]]}';
      const staleTypingRumorJson =
          '{"id":"typing-stale-after-duplicate","pubkey":"$peerPubkey","created_at":1700000001,"kind":25,"content":"typing","tags":[["l","$groupId"],["ms","1700000001000"]]}';

      await notifier.handleIncomingGroupRumorJson(typingRumorJson);
      expect(notifier.state.typingStates[groupId] ?? false, isTrue);

      await notifier.handleIncomingGroupRumorJson(duplicateMessageRumorJson);
      expect(
        notifier.state.typingStates[groupId] ?? false,
        isFalse,
        reason:
            'A newer incoming group message should clear typing even when the '
            'message is already persisted.',
      );

      await notifier.handleIncomingGroupRumorJson(staleTypingRumorJson);
      expect(
        notifier.state.typingStates[groupId] ?? false,
        isFalse,
        reason:
            'A duplicate newer group message should still advance the last '
            'message timestamp so older typing remains suppressed.',
      );
    },
  );

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

  test(
    'incoming group metadata uses authenticated sender owner when rumor pubkey is a device key',
    () async {
      const groupId = 'group-owner-metadata';
      const content =
          '{"id":"$groupId","name":"Owner Group","members":["$myPubkey","$peerPubkey"],"admins":["$peerPubkey"],"secret":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}';
      final metadataRumorJson = jsonEncode({
        'id': 'metadata-1',
        'pubkey': peerDevicePubkey,
        'created_at': 1700000001,
        'kind': 40,
        'content': content,
        'tags': [
          ['l', groupId],
        ],
      });

      when(
        () => mockGroupDatasource.getGroup(groupId),
      ).thenAnswer((_) async => null);
      when(() => mockGroupDatasource.saveGroup(any())).thenAnswer((_) async {});

      await notifier.handleIncomingGroupRumorJson(
        metadataRumorJson,
        senderPubkeyHex: peerPubkey,
      );

      expect(notifier.state.groups, hasLength(1));
      expect(notifier.state.groups.single.id, groupId);
      expect(notifier.state.groups.single.name, 'Owner Group');
      expect(notifier.state.groups.single.members, [myPubkey, peerPubkey]);
      expect(notifier.state.groups.single.accepted, isFalse);
    },
  );

  test('incoming group message stores authenticated sender owner', () async {
    const groupId = 'group-owner-message';

    notifier.state = notifier.state.copyWith(
      groups: [
        ChatGroup(
          id: groupId,
          name: 'Group 1',
          members: [myPubkey, peerPubkey],
          admins: [peerPubkey],
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

    final messageRumorJson = jsonEncode({
      'id': 'msg-owner-1',
      'pubkey': peerDevicePubkey,
      'created_at': 1700000002,
      'kind': 14,
      'content': 'hello from owner',
      'tags': [
        ['l', groupId],
      ],
    });

    await notifier.handleIncomingGroupRumorJson(
      messageRumorJson,
      senderPubkeyHex: peerPubkey,
    );

    final messages = notifier.state.messages[groupId] ?? const <ChatMessage>[];
    expect(messages, hasLength(1));
    expect(messages.single.senderPubkeyHex, peerPubkey);
    expect(messages.single.isIncoming, isTrue);
  });
}
