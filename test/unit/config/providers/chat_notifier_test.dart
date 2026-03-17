import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/core/ffi/models/send_text_with_inner_id_result.dart';
import 'package:iris_chat/core/services/app_focus_service.dart';
import 'package:iris_chat/core/services/desktop_notification_service.dart';
import 'package:iris_chat/core/services/inbound_activity_policy.dart';
import 'package:iris_chat/core/services/logger_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/features/chat/data/datasources/message_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/session_local_datasource.dart';
import 'package:iris_chat/features/chat/domain/models/message.dart';
import 'package:iris_chat/features/chat/domain/models/session.dart';
import 'package:mocktail/mocktail.dart';

class MockMessageLocalDatasource extends Mock
    implements MessageLocalDatasource {}

class MockSessionLocalDatasource extends Mock
    implements SessionLocalDatasource {}

class MockSessionManagerService extends Mock implements SessionManagerService {}

class FakeDesktopNotificationService implements DesktopNotificationService {
  int messageCalls = 0;
  int reactionCalls = 0;
  bool? lastMessageEnabled;
  bool? lastReactionEnabled;

  @override
  bool get isSupported => true;

  @override
  Future<void> showIncomingMessage({
    required bool enabled,
    required String conversationTitle,
    required String body,
  }) async {
    messageCalls += 1;
    lastMessageEnabled = enabled;
  }

  @override
  Future<void> showIncomingReaction({
    required bool enabled,
    required String conversationTitle,
    required String emoji,
    required String targetPreview,
  }) async {
    reactionCalls += 1;
    lastReactionEnabled = enabled;
  }
}

class FakeAppFocusState implements AppFocusState {
  FakeAppFocusState({required this.isAppFocused});

  @override
  bool isAppFocused;
}

void main() {
  late ChatNotifier notifier;
  late MockMessageLocalDatasource mockMessageDatasource;
  late MockSessionLocalDatasource mockSessionDatasource;
  late MockSessionManagerService mockSessionManagerService;
  late FakeDesktopNotificationService fakeDesktopNotificationService;
  late FakeAppFocusState fakeAppFocusState;
  late bool previousLoggerEnabled;

  setUp(() {
    mockMessageDatasource = MockMessageLocalDatasource();
    mockSessionDatasource = MockSessionLocalDatasource();
    mockSessionManagerService = MockSessionManagerService();
    fakeDesktopNotificationService = FakeDesktopNotificationService();
    fakeAppFocusState = FakeAppFocusState(isAppFocused: true);
    notifier = ChatNotifier(
      mockMessageDatasource,
      mockSessionDatasource,
      mockSessionManagerService,
      desktopNotificationService: fakeDesktopNotificationService,
      inboundActivityPolicy: InboundActivityPolicy(
        appFocusState: fakeAppFocusState,
        appOpenedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    when(
      () => mockSessionManagerService.setupUser(any()),
    ).thenAnswer((_) async {});
    when(
      () => mockSessionManagerService.setupUsers(any()),
    ).thenAnswer((_) async {});
    when(
      () => mockSessionManagerService.bootstrapUsersFromRelay(any()),
    ).thenAnswer((_) async {});
    when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
    when(() => mockSessionManagerService.devicePubkeyHex).thenReturn(null);
  });

  setUpAll(() {
    previousLoggerEnabled = Logger.enabled;
    Logger.enabled = false;
    registerFallbackValue(
      ChatMessage(
        id: 'fallback',
        sessionId: 'session',
        text: 'text',
        timestamp: DateTime.now(),
        direction: MessageDirection.outgoing,
        status: MessageStatus.pending,
      ),
    );
    registerFallbackValue(
      ChatSession(
        id: 'fallback-session',
        recipientPubkeyHex:
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    registerFallbackValue(MessageStatus.pending);
  });

  tearDownAll(() {
    Logger.enabled = previousLoggerEnabled;
  });

  group('ChatNotifier', () {
    group('initial state', () {
      test('has empty messages map', () {
        expect(notifier.state.messages, isEmpty);
      });

      test('has empty unreadCounts map', () {
        expect(notifier.state.unreadCounts, isEmpty);
      });

      test('has empty sendingStates map', () {
        expect(notifier.state.sendingStates, isEmpty);
      });

      test('has no error', () {
        expect(notifier.state.error, isNull);
      });
    });

    group('loadMessages', () {
      test('loads messages for a session', () async {
        final messages = [
          ChatMessage(
            id: 'msg-1',
            sessionId: 'session-1',
            text: 'Hello',
            timestamp: DateTime.now(),
            direction: MessageDirection.outgoing,
            status: MessageStatus.sent,
          ),
          ChatMessage(
            id: 'msg-2',
            sessionId: 'session-1',
            text: 'Hi there',
            timestamp: DateTime.now(),
            direction: MessageDirection.incoming,
            status: MessageStatus.delivered,
          ),
        ];

        when(
          () => mockMessageDatasource.getMessagesForSession(
            'session-1',
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => messages);

        await notifier.loadMessages('session-1');

        expect(notifier.state.messages['session-1'], messages);
      });

      test('sets error on failure', () async {
        when(
          () => mockMessageDatasource.getMessagesForSession(
            any(),
            limit: any(named: 'limit'),
          ),
        ).thenThrow(Exception('Load failed'));

        await notifier.loadMessages('session-1');

        // Error is mapped to user-friendly message
        expect(notifier.state.error, isNotNull);
        expect(notifier.state.error, isNotEmpty);
      });
    });

    group('addMessageOptimistic', () {
      test('adds message to session messages', () {
        final message = ChatMessage(
          id: 'msg-1',
          sessionId: 'session-1',
          text: 'Hello',
          timestamp: DateTime.now(),
          direction: MessageDirection.outgoing,
          status: MessageStatus.pending,
        );

        notifier.addMessageOptimistic(message);

        expect(notifier.state.messages['session-1'], contains(message));
      });

      test('sets sending state for message', () {
        final message = ChatMessage(
          id: 'msg-1',
          sessionId: 'session-1',
          text: 'Hello',
          timestamp: DateTime.now(),
          direction: MessageDirection.outgoing,
          status: MessageStatus.pending,
        );

        notifier.addMessageOptimistic(message);

        expect(notifier.state.sendingStates['msg-1'], true);
      });

      test('appends to existing messages', () {
        final message1 = ChatMessage(
          id: 'msg-1',
          sessionId: 'session-1',
          text: 'First',
          timestamp: DateTime.now(),
          direction: MessageDirection.outgoing,
          status: MessageStatus.sent,
        );
        final message2 = ChatMessage(
          id: 'msg-2',
          sessionId: 'session-1',
          text: 'Second',
          timestamp: DateTime.now(),
          direction: MessageDirection.outgoing,
          status: MessageStatus.pending,
        );

        notifier.addMessageOptimistic(message1);
        notifier.addMessageOptimistic(message2);

        expect(notifier.state.messages['session-1']!.length, 2);
        expect(notifier.state.messages['session-1']!.last.id, 'msg-2');
      });
    });

    group('updateMessage', () {
      test('updates message in state and saves to datasource', () async {
        final message = ChatMessage(
          id: 'msg-1',
          sessionId: 'session-1',
          text: 'Hello',
          timestamp: DateTime.now(),
          direction: MessageDirection.outgoing,
          status: MessageStatus.pending,
        );

        when(
          () => mockMessageDatasource.saveMessage(any()),
        ).thenAnswer((_) async {});

        notifier.addMessageOptimistic(message);

        final updatedMessage = message.copyWith(status: MessageStatus.sent);
        await notifier.updateMessage(updatedMessage);

        expect(
          notifier.state.messages['session-1']!.first.status,
          MessageStatus.sent,
        );
        verify(
          () => mockMessageDatasource.saveMessage(updatedMessage),
        ).called(1);
      });

      test('removes message from sendingStates', () async {
        final message = ChatMessage(
          id: 'msg-1',
          sessionId: 'session-1',
          text: 'Hello',
          timestamp: DateTime.now(),
          direction: MessageDirection.outgoing,
          status: MessageStatus.pending,
        );

        when(
          () => mockMessageDatasource.saveMessage(any()),
        ).thenAnswer((_) async {});

        notifier.addMessageOptimistic(message);
        expect(notifier.state.sendingStates.containsKey('msg-1'), true);

        await notifier.updateMessage(
          message.copyWith(status: MessageStatus.sent),
        );

        expect(notifier.state.sendingStates.containsKey('msg-1'), false);
      });
    });

    group('addReceivedMessage', () {
      test('adds new message to state', () async {
        final message = ChatMessage(
          id: 'msg-1',
          sessionId: 'session-1',
          text: 'Hello from friend',
          timestamp: DateTime.now(),
          direction: MessageDirection.incoming,
          status: MessageStatus.delivered,
        );

        when(
          () => mockMessageDatasource.messageExists(any()),
        ).thenAnswer((_) async => false);
        when(
          () => mockMessageDatasource.saveMessage(any()),
        ).thenAnswer((_) async {});

        await notifier.addReceivedMessage(message);

        expect(notifier.state.messages['session-1'], contains(message));
        verify(() => mockMessageDatasource.saveMessage(message)).called(1);
      });

      test('skips duplicate messages with eventId', () async {
        final message = ChatMessage(
          id: 'msg-1',
          sessionId: 'session-1',
          text: 'Hello',
          timestamp: DateTime.now(),
          direction: MessageDirection.incoming,
          status: MessageStatus.delivered,
          eventId: 'event-123',
        );

        when(
          () => mockMessageDatasource.messageExists('event-123'),
        ).thenAnswer((_) async => true);

        await notifier.addReceivedMessage(message);

        expect(notifier.state.messages['session-1'], isNull);
        verifyNever(() => mockMessageDatasource.saveMessage(any()));
      });
    });

    group('updateMessageStatus', () {
      test('updates status of specific message', () async {
        final message = ChatMessage(
          id: 'msg-1',
          sessionId: 'session-1',
          text: 'Hello',
          timestamp: DateTime.now(),
          direction: MessageDirection.outgoing,
          status: MessageStatus.sent,
        );

        when(
          () => mockMessageDatasource.updateMessageStatus(any(), any()),
        ).thenAnswer((_) async {});
        when(
          () => mockMessageDatasource.saveMessage(any()),
        ).thenAnswer((_) async {});

        notifier.addMessageOptimistic(message);

        await notifier.updateMessageStatus('msg-1', MessageStatus.delivered);

        expect(
          notifier.state.messages['session-1']!.first.status,
          MessageStatus.delivered,
        );
      });
    });

    group('clearError', () {
      test('clears error state', () async {
        when(
          () => mockMessageDatasource.getMessagesForSession(
            any(),
            limit: any(named: 'limit'),
          ),
        ).thenThrow(Exception('Error'));

        await notifier.loadMessages('session-1');
        expect(notifier.state.error, isNotNull);

        notifier.clearError();

        expect(notifier.state.error, isNull);
      });
    });

    group('loadMoreMessages', () {
      test('loads messages before oldest message', () async {
        final existingMessages = [
          ChatMessage(
            id: 'msg-2',
            sessionId: 'session-1',
            text: 'Second',
            timestamp: DateTime.now(),
            direction: MessageDirection.outgoing,
            status: MessageStatus.sent,
          ),
        ];

        final olderMessages = [
          ChatMessage(
            id: 'msg-1',
            sessionId: 'session-1',
            text: 'First',
            timestamp: DateTime.now().subtract(const Duration(hours: 1)),
            direction: MessageDirection.incoming,
            status: MessageStatus.delivered,
          ),
        ];

        when(
          () => mockMessageDatasource.getMessagesForSession(
            'session-1',
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => existingMessages);

        when(
          () => mockMessageDatasource.getMessagesForSession(
            'session-1',
            limit: any(named: 'limit'),
            beforeId: 'msg-2',
          ),
        ).thenAnswer((_) async => olderMessages);

        await notifier.loadMessages('session-1');
        await notifier.loadMoreMessages('session-1');

        final messages = notifier.state.messages['session-1']!;
        expect(messages.length, 2);
        expect(messages.first.id, 'msg-1');
        expect(messages.last.id, 'msg-2');
      });

      test('calls loadMessages when no existing messages', () async {
        when(
          () => mockMessageDatasource.getMessagesForSession(
            'session-1',
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => []);

        await notifier.loadMoreMessages('session-1');

        verify(
          () => mockMessageDatasource.getMessagesForSession(
            'session-1',
            limit: any(named: 'limit'),
          ),
        ).called(1);
      });
    });

    group('typing indicators', () {
      test(
        'notifyTyping sends kind-25 typing event via SessionManagerService',
        () async {
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'peer-pubkey',
            createdAt: DateTime.now(),
          );

          when(
            () => mockSessionDatasource.getSession('session-1'),
          ).thenAnswer((_) async => session);
          when(
            () => mockSessionManagerService.sendTyping(
              recipientPubkeyHex: 'peer-pubkey',
              expiresAtSeconds: any(named: 'expiresAtSeconds'),
            ),
          ).thenAnswer((_) async {});

          await notifier.notifyTyping('session-1');

          verify(
            () => mockSessionManagerService.sendTyping(
              recipientPubkeyHex: 'peer-pubkey',
              expiresAtSeconds: null,
            ),
          ).called(1);
        },
      );

      test(
        'notifyTyping does not send when typing indicators are disabled',
        () async {
          notifier.setOutboundSignalSettings(
            typingIndicatorsEnabled: false,
            deliveryReceiptsEnabled: true,
            readReceiptsEnabled: true,
            desktopNotificationsEnabled: true,
          );

          await notifier.notifyTyping('session-1');

          verifyNever(
            () => mockSessionManagerService.sendTyping(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              expiresAtSeconds: any(named: 'expiresAtSeconds'),
            ),
          );
        },
      );

      test(
        'notifyTypingStopped sends typing stop with expiration tag',
        () async {
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'peer-pubkey',
            createdAt: DateTime.now(),
          );

          when(
            () => mockSessionDatasource.getSession('session-1'),
          ).thenAnswer((_) async => session);
          when(
            () => mockSessionManagerService.sendTyping(
              recipientPubkeyHex: 'peer-pubkey',
              expiresAtSeconds: any(named: 'expiresAtSeconds'),
            ),
          ).thenAnswer((_) async {});

          await notifier.notifyTypingStopped('session-1');

          final captured = verify(
            () => mockSessionManagerService.sendTyping(
              recipientPubkeyHex: 'peer-pubkey',
              expiresAtSeconds: captureAny(named: 'expiresAtSeconds'),
            ),
          ).captured;

          expect(captured, hasLength(1));
          expect(captured.first, isA<int>());
          expect(captured.first as int, greaterThan(0));
        },
      );

      test(
        'typing state is set for both session id and recipient pubkey key',
        () async {
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          final session = ChatSession(
            id: 'legacy-session-id',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );

          when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);

          const typingRumorJson =
              '{"id":"typing-alias","pubkey":"$peerPubkey","created_at":1700000000,"kind":25,"content":"typing","tags":[]}';

          await notifier.receiveDecryptedMessage(peerPubkey, typingRumorJson);

          expect(notifier.state.typingStates[session.id] ?? false, isTrue);
          expect(notifier.state.typingStates[peerPubkey] ?? false, isTrue);
        },
      );

      test(
        'typing resolves to existing session via decrypted sender pubkey alias',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const peerOwnerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const peerDevicePubkey =
              '3333333333333333333333333333333333333333333333333333333333333333';

          final session = ChatSession(
            id: 'session-owner-key',
            recipientPubkeyHex: peerOwnerPubkey,
            createdAt: DateTime.now(),
          );

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerDevicePubkey),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerOwnerPubkey),
          ).thenAnswer((_) async => session);

          const typingRumorJson =
              '{"id":"typing-device","pubkey":"$peerDevicePubkey","created_at":1700000000,"kind":25,"content":"typing","tags":[["p","$ownerPubkey"]]}';

          await notifier.receiveDecryptedMessage(
            peerOwnerPubkey,
            typingRumorJson,
          );

          expect(notifier.state.typingStates[session.id] ?? false, isTrue);
          expect(notifier.state.typingStates[peerOwnerPubkey] ?? false, isTrue);
          expect(
            notifier.state.typingStates[peerDevicePubkey] ?? false,
            isFalse,
          );
        },
      );
    });

    group('receipts preferences', () {
      test('markSessionSeen does nothing while app is unfocused', () async {
        final unfocusedNotifier = ChatNotifier(
          mockMessageDatasource,
          mockSessionDatasource,
          mockSessionManagerService,
          desktopNotificationService: fakeDesktopNotificationService,
          inboundActivityPolicy: InboundActivityPolicy(
            appFocusState: FakeAppFocusState(isAppFocused: false),
            appOpenedAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );

        await unfocusedNotifier.markSessionSeen('session-1');

        verifyNever(() => mockSessionDatasource.getSession(any()));
        verifyNever(
          () =>
              mockMessageDatasource.updateIncomingStatusByRumorId(any(), any()),
        );
        verifyNever(
          () => mockSessionManagerService.sendReceipt(
            recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
            receiptType: any(named: 'receiptType'),
            messageIds: any(named: 'messageIds'),
          ),
        );
      });

      test(
        'markSessionSeen updates local state without sending when read receipts disabled',
        () async {
          final incoming = ChatMessage(
            id: 'msg-1',
            sessionId: 'session-1',
            text: 'hello',
            timestamp: DateTime.now(),
            direction: MessageDirection.incoming,
            status: MessageStatus.delivered,
            rumorId: 'rumor-1',
          );
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'peer-pubkey',
            createdAt: DateTime.now(),
          );

          notifier.setOutboundSignalSettings(
            typingIndicatorsEnabled: true,
            deliveryReceiptsEnabled: true,
            readReceiptsEnabled: false,
            desktopNotificationsEnabled: true,
          );

          when(
            () => mockSessionDatasource.getSession('session-1'),
          ).thenAnswer((_) async => session);
          when(
            () => mockMessageDatasource.getMessagesForSession(
              'session-1',
              limit: any(named: 'limit'),
            ),
          ).thenAnswer((_) async => [incoming]);
          when(
            () => mockMessageDatasource.updateIncomingStatusByRumorId(
              'rumor-1',
              MessageStatus.seen,
            ),
          ).thenAnswer((_) async {});

          await notifier.markSessionSeen('session-1');

          verifyNever(
            () => mockSessionManagerService.sendReceipt(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              receiptType: any(named: 'receiptType'),
              messageIds: any(named: 'messageIds'),
            ),
          );
          verify(
            () => mockMessageDatasource.updateIncomingStatusByRumorId(
              'rumor-1',
              MessageStatus.seen,
            ),
          ).called(1);
        },
      );

      test(
        'markSessionSeen does not send seen receipts for sender-copy self messages',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const otherClientPubkey =
              '3333333333333333333333333333333333333333333333333333333333333333';
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionDatasource.getSessionByRecipient(any()),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);
          when(
            () => mockSessionDatasource.getSession(session.id),
          ).thenAnswer((_) async => session);
          when(
            () => mockSessionManagerService.sendReceipt(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              receiptType: any(named: 'receiptType'),
              messageIds: any(named: 'messageIds'),
            ),
          ).thenAnswer((_) async {});

          const senderCopyRumorJson =
              '{"id":"self-copy-1","pubkey":"$otherClientPubkey","created_at":1700000003,"kind":14,"content":"hello from another client","tags":[["p","$peerPubkey"]]}';

          final received = await notifier.receiveDecryptedMessage(
            peerPubkey,
            senderCopyRumorJson,
          );

          expect(received, isNotNull);
          expect(received!.isOutgoing, isTrue);

          await notifier.markSessionSeen(session.id);

          verifyNever(
            () => mockSessionManagerService.sendReceipt(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              receiptType: 'seen',
              messageIds: any(named: 'messageIds'),
            ),
          );
          verifyNever(
            () => mockMessageDatasource.updateIncomingStatusByRumorId(
              any(),
              any(),
            ),
          );
        },
      );
    });

    group('receiveDecryptedMessage', () {
      test(
        'arms peer setup using resolved owner pubkey for linked sender',
        () async {
          const ourOwnerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const peerOwnerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const peerLinkedDevicePubkey =
              '3333333333333333333333333333333333333333333333333333333333333333';

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ourOwnerPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockSessionDatasource.getSessionByRecipient(any()),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.saveSession(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionManagerService.sendReceipt(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              receiptType: any(named: 'receiptType'),
              messageIds: any(named: 'messageIds'),
            ),
          ).thenAnswer((_) async {});

          const rumorJson =
              '{"id":"linked-msg-1","pubkey":"$peerOwnerPubkey","created_at":1700000001,"kind":14,"content":"hello from linked device","tags":[["p","$ourOwnerPubkey"]]}';

          final received = await notifier.receiveDecryptedMessage(
            peerLinkedDevicePubkey,
            rumorJson,
          );
          await Future<void>.delayed(Duration.zero);

          expect(received, isNotNull);
          expect(received!.sessionId, peerOwnerPubkey);
          verify(
            () => mockSessionManagerService.setupUser(peerOwnerPubkey),
          ).called(1);
        },
      );

      test('does not notify for messages created before app launch', () async {
        const peerPubkey =
            '2222222222222222222222222222222222222222222222222222222222222222';
        final session = ChatSession(
          id: 'session-1',
          recipientPubkeyHex: peerPubkey,
          createdAt: DateTime.now(),
        );

        final localNotificationService = FakeDesktopNotificationService();
        final localNotifier = ChatNotifier(
          mockMessageDatasource,
          mockSessionDatasource,
          mockSessionManagerService,
          desktopNotificationService: localNotificationService,
          inboundActivityPolicy: InboundActivityPolicy(
            appFocusState: FakeAppFocusState(isAppFocused: false),
            appOpenedAt: DateTime.fromMillisecondsSinceEpoch(1700000010000),
          ),
        );

        when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
        when(
          () => mockMessageDatasource.messageExists(any()),
        ).thenAnswer((_) async => false);
        when(
          () => mockMessageDatasource.saveMessage(any()),
        ).thenAnswer((_) async {});
        when(
          () => mockSessionDatasource.getSessionByRecipient(any()),
        ).thenAnswer((_) async => session);
        when(
          () => mockSessionManagerService.sendReceipt(
            recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
            receiptType: any(named: 'receiptType'),
            messageIds: any(named: 'messageIds'),
          ),
        ).thenAnswer((_) async {});

        const messageRumorJson =
            '{"id":"msg-old","pubkey":"$peerPubkey","created_at":1700000000,"kind":14,"content":"hello","tags":[]}';

        await localNotifier.receiveDecryptedMessage(
          peerPubkey,
          messageRumorJson,
        );

        expect(localNotificationService.messageCalls, 0);
      });

      test('notifies for messages created after app launch', () async {
        const peerPubkey =
            '2222222222222222222222222222222222222222222222222222222222222222';
        final session = ChatSession(
          id: 'session-1',
          recipientPubkeyHex: peerPubkey,
          createdAt: DateTime.now(),
        );

        final localNotificationService = FakeDesktopNotificationService();
        final localNotifier = ChatNotifier(
          mockMessageDatasource,
          mockSessionDatasource,
          mockSessionManagerService,
          desktopNotificationService: localNotificationService,
          inboundActivityPolicy: InboundActivityPolicy(
            appFocusState: FakeAppFocusState(isAppFocused: false),
            appOpenedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          ),
        );

        when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
        when(
          () => mockMessageDatasource.messageExists(any()),
        ).thenAnswer((_) async => false);
        when(
          () => mockMessageDatasource.saveMessage(any()),
        ).thenAnswer((_) async {});
        when(
          () => mockSessionDatasource.getSessionByRecipient(any()),
        ).thenAnswer((_) async => session);
        when(
          () => mockSessionDatasource.getSession('session-1'),
        ).thenAnswer((_) async => session);
        when(
          () => mockSessionManagerService.sendReceipt(
            recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
            receiptType: any(named: 'receiptType'),
            messageIds: any(named: 'messageIds'),
          ),
        ).thenAnswer((_) async {});

        const messageRumorJson =
            '{"id":"msg-new","pubkey":"$peerPubkey","created_at":1700000001,"kind":14,"content":"hello","tags":[]}';

        await localNotifier.receiveDecryptedMessage(
          peerPubkey,
          messageRumorJson,
        );

        expect(localNotificationService.messageCalls, 1);
      });

      test(
        'marks incoming messages seen when self receipt references them',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );
          final incoming = ChatMessage(
            id: 'in-1',
            sessionId: session.id,
            text: 'hello',
            timestamp: DateTime.now(),
            direction: MessageDirection.incoming,
            status: MessageStatus.delivered,
            rumorId: 'in-1',
          );

          notifier.state = notifier.state.copyWith(
            messages: {
              session.id: [incoming],
            },
          );

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockSessionDatasource.getSessionByRecipient(any()),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);
          when(
            () => mockMessageDatasource.updateIncomingStatusByRumorId(
              'in-1',
              MessageStatus.seen,
            ),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionDatasource.recomputeDerivedFieldsFromMessages(
              session.id,
            ),
          ).thenAnswer((_) async {});

          const receiptRumorJson =
              '{"id":"rcpt-1","pubkey":"$ownerPubkey","created_at":1700000001,"kind":15,"content":"seen","tags":[["p","$peerPubkey"],["e","in-1"]]}';

          await notifier.receiveDecryptedMessage(peerPubkey, receiptRumorJson);

          final updated = notifier.state.messages[session.id];
          expect(updated, isNotNull);
          expect(updated![0].status, MessageStatus.seen);
          verify(
            () => mockMessageDatasource.updateIncomingStatusByRumorId(
              'in-1',
              MessageStatus.seen,
            ),
          ).called(1);
          verify(
            () => mockSessionDatasource.recomputeDerivedFieldsFromMessages(
              session.id,
            ),
          ).called(1);
        },
      );

      test(
        'treats sender-copy receipts from another client as self receipts',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const otherClientPubkey =
              '3333333333333333333333333333333333333333333333333333333333333333';
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );
          final incoming = ChatMessage(
            id: 'in-2',
            sessionId: session.id,
            text: 'hello',
            timestamp: DateTime.now(),
            direction: MessageDirection.incoming,
            status: MessageStatus.delivered,
            rumorId: 'in-2',
          );

          notifier.state = notifier.state.copyWith(
            messages: {
              session.id: [incoming],
            },
          );

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockSessionDatasource.getSessionByRecipient(any()),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);
          when(
            () => mockMessageDatasource.updateIncomingStatusByRumorId(
              'in-2',
              MessageStatus.seen,
            ),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionDatasource.recomputeDerivedFieldsFromMessages(
              session.id,
            ),
          ).thenAnswer((_) async {});

          const receiptRumorJson =
              '{"id":"rcpt-2","pubkey":"$otherClientPubkey","created_at":1700000002,"kind":15,"content":"seen","tags":[["p","$peerPubkey"],["e","in-2"]]}';

          await notifier.receiveDecryptedMessage(peerPubkey, receiptRumorJson);

          final updated = notifier.state.messages[session.id];
          expect(updated, isNotNull);
          expect(updated![0].status, MessageStatus.seen);
          verify(
            () => mockMessageDatasource.updateIncomingStatusByRumorId(
              'in-2',
              MessageStatus.seen,
            ),
          ).called(1);
        },
      );

      test(
        'marks sender-copy messages from another client as outgoing in peer chat',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const otherClientPubkey =
              '3333333333333333333333333333333333333333333333333333333333333333';
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionDatasource.getSessionByRecipient(any()),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);

          const messageRumorJson =
              '{"id":"msg-sender-copy-1","pubkey":"$otherClientPubkey","created_at":1700000003,"kind":14,"content":"hello from another client","tags":[["p","$peerPubkey"]]}';

          final received = await notifier.receiveDecryptedMessage(
            peerPubkey,
            messageRumorJson,
          );

          expect(received, isNotNull);
          expect(received!.sessionId, session.id);
          expect(received.isOutgoing, isTrue);
          expect(notifier.state.messages[session.id], isNotNull);
          expect(
            notifier.state.messages[session.id]!.single.text,
            'hello from another client',
          );
          expect(fakeDesktopNotificationService.messageCalls, 0);
          verify(() => mockMessageDatasource.saveMessage(any())).called(1);
        },
      );

      test(
        'routes self-chat rumor to owner session instead of dropping it',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockSessionDatasource.getSessionByRecipient(ownerPubkey),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.saveSession(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});

          const selfRumorJson =
              '{"id":"self-msg-1","pubkey":"$ownerPubkey","created_at":1700000003,"kind":14,"content":"hello self","tags":[["p","$ownerPubkey"]]}';

          final received = await notifier.receiveDecryptedMessage(
            ownerPubkey,
            selfRumorJson,
          );

          expect(received, isNotNull);
          expect(received!.sessionId, ownerPubkey);
          expect(received.isOutgoing, isTrue);
          expect(notifier.state.messages[ownerPubkey], isNotNull);
          expect(
            notifier.state.messages[ownerPubkey]!.single.text,
            'hello self',
          );
          verify(() => mockSessionDatasource.saveSession(any())).called(1);
          verify(() => mockMessageDatasource.saveMessage(any())).called(1);
        },
      );

      test(
        'prefers an existing direct sender-device session for self-targeted rumors',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const senderDevicePubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          final directSession = ChatSession(
            id: 'session-direct-device',
            recipientPubkeyHex: senderDevicePubkey,
            createdAt: DateTime.now(),
          );

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockSessionDatasource.getSessionByRecipient(senderDevicePubkey),
          ).thenAnswer((_) async => directSession);
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});

          const selfRumorJson =
              '{"id":"self-msg-direct-1","pubkey":"$ownerPubkey","created_at":1700000004,"kind":14,"content":"hello from my other device","tags":[["p","$ownerPubkey"]]}';

          final received = await notifier.receiveDecryptedMessage(
            senderDevicePubkey,
            selfRumorJson,
          );

          expect(received, isNotNull);
          expect(received!.sessionId, directSession.id);
          expect(received.isOutgoing, isTrue);
          expect(notifier.state.messages[directSession.id], isNotNull);
          expect(
            notifier.state.messages[directSession.id]!.single.text,
            'hello from my other device',
          );
          verify(
            () => mockSessionManagerService.setupUser(senderDevicePubkey),
          ).called(1);
          verifyNever(() => mockSessionDatasource.saveSession(any()));
          verify(() => mockMessageDatasource.saveMessage(any())).called(1);
        },
      );

      test(
        'routes self-targeted rumor from linked own device to owner session when sender normalizes to owner',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const linkedOwnDevicePubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockSessionDatasource.getSessionByRecipient(linkedOwnDevicePubkey),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.getSessionByRecipient(ownerPubkey),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.saveSession(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});

          const selfRumorJson =
              '{"id":"self-msg-linked-owner-1","pubkey":"$linkedOwnDevicePubkey","created_at":1700000005,"kind":14,"content":"hello from my linked device via owner sender","tags":[["p","$ownerPubkey"]]}';

          final received = await notifier.receiveDecryptedMessage(
            ownerPubkey,
            selfRumorJson,
          );

          expect(received, isNotNull);
          expect(received!.sessionId, ownerPubkey);
          expect(received.isOutgoing, isTrue);
          expect(notifier.state.messages[ownerPubkey], isNotNull);
          expect(
            notifier.state.messages[ownerPubkey]!.single.text,
            'hello from my linked device via owner sender',
          );
          verify(() => mockSessionManagerService.setupUser(ownerPubkey)).called(1);
          verify(() => mockSessionDatasource.saveSession(any())).called(1);
          verify(() => mockMessageDatasource.saveMessage(any())).called(1);
        },
      );

      test(
        'prefers existing rumor-author device session when sender normalizes to owner',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const linkedOwnDevicePubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          final directSession = ChatSession(
            id: 'session-linked-device',
            recipientPubkeyHex: linkedOwnDevicePubkey,
            createdAt: DateTime.now(),
          );

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockSessionDatasource.getSessionByRecipient(linkedOwnDevicePubkey),
          ).thenAnswer((_) async => directSession);
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});

          const selfRumorJson =
              '{"id":"self-msg-linked-owner-2","pubkey":"$linkedOwnDevicePubkey","created_at":1700000006,"kind":14,"content":"hello from my linked device on direct session","tags":[["p","$ownerPubkey"]]}';

          final received = await notifier.receiveDecryptedMessage(
            ownerPubkey,
            selfRumorJson,
          );

          expect(received, isNotNull);
          expect(received!.sessionId, directSession.id);
          expect(received.isOutgoing, isTrue);
          expect(notifier.state.messages[directSession.id], isNotNull);
          expect(
            notifier.state.messages[directSession.id]!.single.text,
            'hello from my linked device on direct session',
          );
          verify(
            () => mockSessionManagerService.setupUser(linkedOwnDevicePubkey),
          ).called(1);
          verifyNever(() => mockSessionDatasource.saveSession(any()));
          verify(() => mockMessageDatasource.saveMessage(any())).called(1);
        },
      );

      test(
        'routes sender-copy self message from a linked own device to the peer session',
        () async {
          const ownerPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const linkedOwnDevicePubkey =
              '3333333333333333333333333333333333333333333333333333333333333333';

          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(ownerPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionDatasource.getSessionByRecipient(any()),
          ).thenAnswer((_) async => null);
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);
          when(
            () => mockSessionDatasource.saveSession(any()),
          ).thenAnswer((_) async {});

          const rumorJson =
              '{"id":"self-copy-linked-1","pubkey":"$linkedOwnDevicePubkey","created_at":1700000003,"kind":14,"content":"hello from my linked device","tags":[["p","$peerPubkey"]]}';

          final received = await notifier.receiveDecryptedMessage(
            ownerPubkey,
            rumorJson,
          );

          expect(received, isNotNull);
          expect(received!.sessionId, session.id);
          expect(received.isOutgoing, isTrue);
          expect(notifier.state.messages[session.id], isNotNull);
          expect(
            notifier.state.messages[session.id]!.single.text,
            'hello from my linked device',
          );
          verify(() => mockSessionManagerService.setupUser(peerPubkey)).called(1);
          verify(() => mockMessageDatasource.saveMessage(any())).called(1);
        },
      );

      test(
        'ignores typing when event second matches the last incoming message second',
        () async {
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );

          when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionManagerService.sendReceipt(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              receiptType: any(named: 'receiptType'),
              messageIds: any(named: 'messageIds'),
            ),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);

          const messageRumorJson =
              '{"id":"msg-1","pubkey":"$peerPubkey","created_at":1700000000,"kind":14,"content":"hello","tags":[["ms","1700000000123"]]}';
          const typingRumorJson =
              '{"id":"typing-1","pubkey":"$peerPubkey","created_at":1700000000,"kind":25,"content":"typing","tags":[]}';

          await notifier.receiveDecryptedMessage(peerPubkey, messageRumorJson);
          expect(notifier.state.typingStates[session.id] ?? false, isFalse);

          await notifier.receiveDecryptedMessage(peerPubkey, typingRumorJson);

          expect(
            notifier.state.typingStates[session.id] ?? false,
            isFalse,
            reason:
                'Match iris-chat behavior: once an incoming message is seen for a '
                'second, typing from that same second should not re-appear.',
          );
        },
      );

      test(
        'ignores typing when typing timestamp is older than latest incoming message',
        () async {
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );

          when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionManagerService.sendReceipt(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              receiptType: any(named: 'receiptType'),
              messageIds: any(named: 'messageIds'),
            ),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);

          const messageRumorJson =
              '{"id":"msg-2","pubkey":"$peerPubkey","created_at":1700000001,"kind":14,"content":"hello","tags":[["ms","1700000001123"]]}';
          const staleTypingRumorJson =
              '{"id":"typing-2","pubkey":"$peerPubkey","created_at":1700000000,"kind":25,"content":"typing","tags":[]}';

          await notifier.receiveDecryptedMessage(peerPubkey, messageRumorJson);
          await notifier.receiveDecryptedMessage(
            peerPubkey,
            staleTypingRumorJson,
          );

          expect(
            notifier.state.typingStates[session.id] ?? false,
            isFalse,
            reason:
                'Match iris-chat behavior: stale typing events should be ignored '
                'after a newer incoming message is processed.',
          );
        },
      );

      test(
        'does not suppress incoming typing because of a newer outgoing self message',
        () async {
          const myPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(myPubkey);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionManagerService.sendReceipt(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              receiptType: any(named: 'receiptType'),
              messageIds: any(named: 'messageIds'),
            ),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);

          const outgoingSelfRumorJson =
              '{"id":"msg-self","pubkey":"$myPubkey","created_at":1700000002,"kind":14,"content":"local echo","tags":[["p","$peerPubkey"],["ms","1700000002500"]]}';
          const incomingTypingRumorJson =
              '{"id":"typing-3","pubkey":"$peerPubkey","created_at":1700000001,"kind":25,"content":"typing","tags":[["ms","1700000001500"]]}';

          await notifier.receiveDecryptedMessage(
            myPubkey,
            outgoingSelfRumorJson,
          );
          expect(notifier.state.typingStates[session.id] ?? false, isFalse);

          await notifier.receiveDecryptedMessage(
            peerPubkey,
            incomingTypingRumorJson,
          );

          expect(
            notifier.state.typingStates[session.id],
            isTrue,
            reason:
                'A self/outgoing message should not make subsequent incoming typing '
                'events look stale.',
          );
        },
      );

      test('clears typing when an incoming message replay arrives', () async {
        const peerPubkey =
            '2222222222222222222222222222222222222222222222222222222222222222';
        final session = ChatSession(
          id: 'session-1',
          recipientPubkeyHex: peerPubkey,
          createdAt: DateTime.now(),
        );

        when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
        when(
          () => mockMessageDatasource.messageExists(any()),
        ).thenAnswer((_) async => false);
        when(
          () => mockMessageDatasource.saveMessage(any()),
        ).thenAnswer((_) async {});
        when(
          () => mockSessionManagerService.sendReceipt(
            recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
            receiptType: any(named: 'receiptType'),
            messageIds: any(named: 'messageIds'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
        ).thenAnswer((_) async => session);

        const typingRumorJson =
            '{"id":"typing-new","pubkey":"$peerPubkey","created_at":1700000005,"kind":25,"content":"typing","tags":[["ms","1700000005000"]]}';
        const olderMessageRumorJson =
            '{"id":"msg-old","pubkey":"$peerPubkey","created_at":1700000004,"kind":14,"content":"older replay","tags":[["ms","1700000004000"]]}';

        await notifier.receiveDecryptedMessage(peerPubkey, typingRumorJson);
        expect(notifier.state.typingStates[session.id] ?? false, isTrue);

        await notifier.receiveDecryptedMessage(
          peerPubkey,
          olderMessageRumorJson,
        );

        expect(
          notifier.state.typingStates[session.id] ?? false,
          isFalse,
          reason:
              'Match iris-chat behavior: incoming messages clear typing state.',
        );
      });

      test(
        'does not auto-send delivered receipt when delivery receipts are disabled',
        () async {
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );

          notifier.setOutboundSignalSettings(
            typingIndicatorsEnabled: true,
            deliveryReceiptsEnabled: false,
            readReceiptsEnabled: true,
            desktopNotificationsEnabled: true,
          );

          when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockMessageDatasource.saveMessage(any()),
          ).thenAnswer((_) async {});
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);

          const messageRumorJson =
              '{"id":"msg-no-delivery","pubkey":"$peerPubkey","created_at":1700000002,"kind":14,"content":"hello","tags":[]}';

          await notifier.receiveDecryptedMessage(peerPubkey, messageRumorJson);

          verifyNever(
            () => mockSessionManagerService.sendReceipt(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              receiptType: 'delivered',
              messageIds: any(named: 'messageIds'),
            ),
          );
        },
      );

      test('clears typing when receiving an expired typing stop rumor', () async {
        const peerPubkey =
            '2222222222222222222222222222222222222222222222222222222222222222';
        final session = ChatSession(
          id: 'session-1',
          recipientPubkeyHex: peerPubkey,
          createdAt: DateTime.now(),
        );

        when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
        when(
          () => mockMessageDatasource.messageExists(any()),
        ).thenAnswer((_) async => false);
        when(
          () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
        ).thenAnswer((_) async => session);

        const typingStartRumorJson =
            '{"id":"typing-start","pubkey":"$peerPubkey","created_at":1700000001,"kind":25,"content":"typing","tags":[]}';
        const typingStopRumorJson =
            '{"id":"typing-stop","pubkey":"$peerPubkey","created_at":1700000002,"kind":25,"content":"typing","tags":[["expiration","1"]]}';

        await notifier.receiveDecryptedMessage(
          peerPubkey,
          typingStartRumorJson,
        );
        expect(notifier.state.typingStates[session.id] ?? false, isTrue);

        await notifier.receiveDecryptedMessage(peerPubkey, typingStopRumorJson);
        expect(notifier.state.typingStates[session.id] ?? false, isFalse);
      });

      test(
        'clears typing when stop rumor expiration equals sender created_at in the future',
        () async {
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: peerPubkey,
            createdAt: DateTime.now(),
          );
          final futureSeconds =
              DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120;

          when(() => mockSessionManagerService.ownerPubkeyHex).thenReturn(null);
          when(
            () => mockMessageDatasource.messageExists(any()),
          ).thenAnswer((_) async => false);
          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer((_) async => session);

          const typingStartRumorJson =
              '{"id":"typing-start-future","pubkey":"$peerPubkey","created_at":1700000001,"kind":25,"content":"typing","tags":[]}';
          final typingStopRumorJson =
              '{"id":"typing-stop-future","pubkey":"$peerPubkey","created_at":$futureSeconds,"kind":25,"content":"typing","tags":[["expiration","$futureSeconds"]]}';

          await notifier.receiveDecryptedMessage(
            peerPubkey,
            typingStartRumorJson,
          );
          expect(notifier.state.typingStates[session.id] ?? false, isTrue);

          await notifier.receiveDecryptedMessage(
            peerPubkey,
            typingStopRumorJson,
          );
          expect(notifier.state.typingStates[session.id] ?? false, isFalse);
        },
      );

      test(
        'backfills outgoing eventId when receiving self-echo by rumor id',
        () async {
          const myPubkey =
              '1111111111111111111111111111111111111111111111111111111111111111';
          const peerPubkey =
              '2222222222222222222222222222222222222222222222222222222222222222';
          const rumorId = 'rumor-123';
          const outerEventId = 'outer-456';

          when(
            () => mockSessionManagerService.ownerPubkeyHex,
          ).thenReturn(myPubkey);

          when(
            () => mockMessageDatasource.messageExists(outerEventId),
          ).thenAnswer((_) async => false);
          when(
            () => mockMessageDatasource.messageExists(rumorId),
          ).thenAnswer((_) async => true);
          when(
            () => mockMessageDatasource.updateOutgoingEventIdByRumorId(
              rumorId,
              outerEventId,
            ),
          ).thenAnswer((_) async {});

          when(
            () => mockSessionDatasource.getSessionByRecipient(peerPubkey),
          ).thenAnswer(
            (_) async => ChatSession(
              id: peerPubkey,
              recipientPubkeyHex: peerPubkey,
              createdAt: DateTime.now(),
            ),
          );

          final outgoing = ChatMessage(
            id: 'local-1',
            sessionId: peerPubkey,
            text: 'hi',
            timestamp: DateTime.now(),
            direction: MessageDirection.outgoing,
            status: MessageStatus.pending,
            rumorId: rumorId,
          );
          notifier.addMessageOptimistic(outgoing);

          const rumorJson =
              '{"id":"$rumorId","pubkey":"$myPubkey","created_at":123,"kind":14,"content":"hi","tags":[["p","$peerPubkey"]]}';

          final result = await notifier.receiveDecryptedMessage(
            'ignored',
            rumorJson,
            eventId: outerEventId,
            createdAt: 123,
          );

          expect(result, isNull);
          verify(
            () => mockMessageDatasource.updateOutgoingEventIdByRumorId(
              rumorId,
              outerEventId,
            ),
          ).called(1);

          final updated = notifier.state.messages[peerPubkey]!.firstWhere(
            (m) => m.id == 'local-1',
          );
          expect(updated.eventId, outerEventId);
          expect(updated.status, MessageStatus.sent);
        },
      );
    });

    group('sendReaction', () {
      test(
        'uses rumor id for SessionManagerService.sendReaction and updates local reactions',
        () async {
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'peer-pubkey',
            createdAt: DateTime.now(),
            isInitiator: true,
          );

          when(
            () => mockSessionDatasource.getSession('session-1'),
          ).thenAnswer((_) async => session);
          when(
            () => mockSessionManagerService.sendReaction(
              recipientPubkeyHex: 'peer-pubkey',
              messageId: 'rumor-123',
              emoji: '❤️',
            ),
          ).thenAnswer((_) async {});

          notifier.state = notifier.state.copyWith(
            messages: {
              'session-1': [
                ChatMessage(
                  id: 'msg-1',
                  sessionId: 'session-1',
                  text: 'Hello',
                  timestamp: DateTime.now(),
                  direction: MessageDirection.outgoing,
                  status: MessageStatus.sent,
                  eventId: 'event-123',
                  rumorId: 'rumor-123',
                ),
              ],
            },
          );

          await notifier.sendReaction('session-1', 'msg-1', '❤️', 'my-pubkey');

          verify(
            () => mockSessionManagerService.sendReaction(
              recipientPubkeyHex: 'peer-pubkey',
              messageId: 'rumor-123',
              emoji: '❤️',
            ),
          ).called(1);
          verifyNever(
            () => mockSessionManagerService.getActiveSessionState(any()),
          );

          final updated = notifier.state.messages['session-1']!.first;
          expect(updated.reactions['❤️'], ['my-pubkey']);
          expect(notifier.state.error, isNull);
        },
      );

      test(
        'falls back to outer event id when rumor id is unavailable',
        () async {
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'peer-pubkey',
            createdAt: DateTime.now(),
            isInitiator: true,
          );

          when(
            () => mockSessionDatasource.getSession('session-1'),
          ).thenAnswer((_) async => session);
          when(
            () => mockSessionManagerService.sendReaction(
              recipientPubkeyHex: 'peer-pubkey',
              messageId: 'event-only-123',
              emoji: '👍',
            ),
          ).thenAnswer((_) async {});

          notifier.state = notifier.state.copyWith(
            messages: {
              'session-1': [
                ChatMessage(
                  id: 'msg-1',
                  sessionId: 'session-1',
                  text: 'Hello',
                  timestamp: DateTime.now(),
                  direction: MessageDirection.outgoing,
                  status: MessageStatus.sent,
                  eventId: 'event-only-123',
                  rumorId: null,
                ),
              ],
            },
          );

          await notifier.sendReaction('session-1', 'msg-1', '👍', 'my-pubkey');

          verify(
            () => mockSessionManagerService.sendReaction(
              recipientPubkeyHex: 'peer-pubkey',
              messageId: 'event-only-123',
              emoji: '👍',
            ),
          ).called(1);
        },
      );
    });

    group('sendMessage bootstrap', () {
      test('send does not replay relay bootstrap during dispatch', () async {
        final session = ChatSession(
          id: 'session-1',
          recipientPubkeyHex:
              'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          createdAt: DateTime.now(),
        );

        when(
          () => mockSessionDatasource.getSession('session-1'),
        ).thenAnswer((_) async => session);
        when(
          () => mockSessionManagerService.sendTextWithInnerId(
            recipientPubkeyHex: session.recipientPubkeyHex,
            text: 'hello',
            expiresAtSeconds: any(named: 'expiresAtSeconds'),
          ),
        ).thenAnswer(
          (_) async => const SendTextWithInnerIdResult(
            innerId: 'rumor-1',
            outerEventIds: ['outer-1'],
          ),
        );

        await notifier.sendMessage('session-1', 'hello');

        verifyNever(
          () => mockSessionManagerService.setupUser(session.recipientPubkeyHex),
        );
        verifyNever(
          () => mockSessionManagerService.bootstrapUsersFromRelay(any()),
        );
        verifyNever(() => mockSessionManagerService.setupUsers(any()));
      });
    });
  });
}
