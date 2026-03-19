import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/config/providers/connectivity_provider.dart';
import 'package:iris_chat/config/providers/imgproxy_settings_provider.dart';
import 'package:iris_chat/config/providers/invite_provider.dart';
import 'package:iris_chat/config/providers/nostr_provider.dart';
import 'package:iris_chat/core/services/connectivity_service.dart';
import 'package:iris_chat/core/services/imgproxy_settings_service.dart';
import 'package:iris_chat/core/services/profile_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/features/chat/data/datasources/group_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/group_message_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/message_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/session_local_datasource.dart';
import 'package:iris_chat/features/chat/domain/models/message.dart';
import 'package:iris_chat/features/chat/domain/models/session.dart';
import 'package:iris_chat/features/chat/presentation/screens/chat_list_screen.dart';
import 'package:iris_chat/features/chat/presentation/screens/chat_screen.dart';
import 'package:iris_chat/features/chat/presentation/screens/chats_shell_screen.dart';
import 'package:iris_chat/features/chat/presentation/widgets/unseen_badge.dart';
import 'package:iris_chat/features/invite/data/datasources/invite_local_datasource.dart';
import 'package:iris_chat/shared/utils/animal_names.dart';
import 'package:mocktail/mocktail.dart';

import '../test_helpers.dart';

class MockSessionLocalDatasource extends Mock
    implements SessionLocalDatasource {}

class MockInviteLocalDatasource extends Mock implements InviteLocalDatasource {}

class MockSessionManagerService extends Mock implements SessionManagerService {}

class MockProfileService extends Mock implements ProfileService {}

class MockGroupLocalDatasource extends Mock implements GroupLocalDatasource {}

class MockGroupMessageLocalDatasource extends Mock
    implements GroupMessageLocalDatasource {}

class MockMessageLocalDatasource extends Mock
    implements MessageLocalDatasource {}

class FakeImgproxySettingsService implements ImgproxySettingsService {
  const FakeImgproxySettingsService();

  @override
  Future<ImgproxySettingsSnapshot> load() async {
    return const ImgproxySettingsSnapshot(
      enabled: false,
      url: 'https://imgproxy.iris.to',
      keyHex:
          'f66233cb160ea07078ff28099bfa3e3e654bc10aa4a745e12176c433d79b8996',
      saltHex:
          '5e608e60945dcd2a787e8465d76ba34149894765061d39287609fb9d776caa0c',
    );
  }

  @override
  Future<ImgproxySettingsSnapshot> setEnabled(bool value) => load();

  @override
  Future<ImgproxySettingsSnapshot> setKeyHex(String value) => load();

  @override
  Future<ImgproxySettingsSnapshot> setSaltHex(String value) => load();

  @override
  Future<ImgproxySettingsSnapshot> setUrl(String value) => load();

  @override
  Future<ImgproxySettingsSnapshot> resetDefaults() => load();
}

void main() {
  late MockSessionLocalDatasource mockSessionDatasource;
  late MockInviteLocalDatasource mockInviteDatasource;
  late MockSessionManagerService mockSessionManagerService;
  late MockProfileService mockProfileService;
  late MockGroupLocalDatasource mockGroupDatasource;
  late MockGroupMessageLocalDatasource mockGroupMessageDatasource;
  late MockMessageLocalDatasource mockMessageDatasource;
  const fakeImgproxySettingsService = FakeImgproxySettingsService();

  setUp(() {
    mockSessionDatasource = MockSessionLocalDatasource();
    mockInviteDatasource = MockInviteLocalDatasource();
    mockSessionManagerService = MockSessionManagerService();
    mockProfileService = MockProfileService();
    mockGroupDatasource = MockGroupLocalDatasource();
    mockGroupMessageDatasource = MockGroupMessageLocalDatasource();
    mockMessageDatasource = MockMessageLocalDatasource();

    when(
      () => mockProfileService.fetchProfiles(any()),
    ).thenAnswer((_) async {});
    when(
      () => mockProfileService.getProfile(any()),
    ).thenAnswer((_) async => null);
    when(() => mockProfileService.getCachedProfile(any())).thenReturn(null);
    when(
      () => mockProfileService.profileUpdates,
    ).thenAnswer((_) => const Stream<String>.empty());
    when(() => mockGroupDatasource.getAllGroups()).thenAnswer((_) async => []);
    when(
      () => mockSessionManagerService.sendReceipt(
        recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
        receiptType: any(named: 'receiptType'),
        messageIds: any(named: 'messageIds'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => mockSessionManagerService.sendTyping(
        recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
        expiresAtSeconds: any(named: 'expiresAtSeconds'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => mockSessionDatasource.updateMetadata(
        any(),
        unreadCount: any(named: 'unreadCount'),
      ),
    ).thenAnswer((_) async {});
  });

  setUpAll(() {
    registerFallbackValue(
      ChatSession(
        id: 'fallback',
        recipientPubkeyHex: 'abc123',
        createdAt: DateTime.now(),
        isInitiator: true,
      ),
    );
  });

  Widget buildChatListScreen({
    List<ChatSession> sessions = const [],
    Map<String, List<ChatMessage>>? messagesBySession,
    Map<String, bool>? relayConnectionStatus,
    ConnectivityStatus connectivityStatus = ConnectivityStatus.online,
    bool throwOnMessageSubscriptionInit = false,
    int failSessionLoadsBeforeSuccess = 0,
    int failGroupLoadsBeforeSuccess = 0,
    bool includeChatRoute = false,
    bool seedSessionState = false,
  }) {
    var sessionLoadAttempts = 0;
    when(() => mockSessionDatasource.getAllSessions()).thenAnswer((_) async {
      if (sessionLoadAttempts < failSessionLoadsBeforeSuccess) {
        sessionLoadAttempts++;
        throw Exception('database is locked');
      }
      return sessions;
    });
    when(() => mockSessionDatasource.getSession(any())).thenAnswer((
      invocation,
    ) async {
      final requestedSessionId = invocation.positionalArguments.first as String;
      for (final session in sessions) {
        if (session.id == requestedSessionId) return session;
      }
      return null;
    });
    var groupLoadAttempts = 0;
    when(() => mockGroupDatasource.getAllGroups()).thenAnswer((_) async {
      if (groupLoadAttempts < failGroupLoadsBeforeSuccess) {
        groupLoadAttempts++;
        throw Exception('database is locked');
      }
      return [];
    });
    when(
      () => mockSessionDatasource.getSessionState(any()),
    ).thenAnswer((_) async => null);
    when(
      () => mockInviteDatasource.getActiveInvites(),
    ).thenAnswer((_) async => []);
    when(
      () => mockMessageDatasource.getMessagesForSession(
        any(),
        limit: any(named: 'limit'),
        beforeId: any(named: 'beforeId'),
      ),
    ).thenAnswer((invocation) async {
      final requestedSessionId = invocation.positionalArguments.first as String;
      return messagesBySession?[requestedSessionId] ?? const <ChatMessage>[];
    });

    final router = GoRouter(
      initialLocation: '/chats',
      routes: [
        GoRoute(
          path: '/chats',
          builder: (context, state) => const ChatListScreen(),
          routes: [
            GoRoute(
              path: 'new',
              builder: (context, state) =>
                  const Scaffold(body: Text('New Chat')),
            ),
            if (includeChatRoute)
              GoRoute(
                path: ':id',
                builder: (context, state) =>
                    ChatScreen(sessionId: state.pathParameters['id']!),
              ),
          ],
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(body: Text('Settings')),
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        sessionDatasourceProvider.overrideWithValue(mockSessionDatasource),
        inviteDatasourceProvider.overrideWithValue(mockInviteDatasource),
        if (throwOnMessageSubscriptionInit)
          messageSubscriptionProvider.overrideWith((_) {
            throw Exception('message subscription init failed');
          })
        else
          messageSubscriptionProvider.overrideWithValue(
            mockSessionManagerService,
          ),
        sessionManagerServiceProvider.overrideWithValue(
          mockSessionManagerService,
        ),
        groupDatasourceProvider.overrideWithValue(mockGroupDatasource),
        groupMessageDatasourceProvider.overrideWithValue(
          mockGroupMessageDatasource,
        ),
        messageDatasourceProvider.overrideWithValue(mockMessageDatasource),
        profileServiceProvider.overrideWithValue(mockProfileService),
        imgproxySettingsServiceProvider.overrideWithValue(
          fakeImgproxySettingsService,
        ),
        if (seedSessionState)
          sessionStateProvider.overrideWith((ref) {
            final notifier = SessionNotifier(
              mockSessionDatasource,
              mockProfileService,
              mockSessionManagerService,
            );
            notifier.state = SessionState(sessions: sessions, isLoading: false);
            return notifier;
          }),
        connectivityStatusProvider.overrideWith(
          (_) => Stream.value(connectivityStatus),
        ),
        nostrConnectionStatusProvider.overrideWith(
          (_) => Stream.value(
            relayConnectionStatus ??
                const <String, bool>{
                  'wss://relay.damus.io': false,
                  'wss://relay.snort.social': false,
                },
          ),
        ),
        queuedMessageCountProvider.overrideWithValue(0),
      ],
      child: ScreenUtilInit(
        designSize: const Size(390, 844),
        minTextAdapt: true,
        builder: (context, _) {
          return MaterialApp.router(
            theme: createTestTheme(),
            routerConfig: router,
          );
        },
      ),
    );
  }

  Widget buildChatsShell({
    required String initialLocation,
    List<ChatSession> sessions = const [],
    List<ChatMessage> groups = const [],
  }) {
    when(() => mockSessionDatasource.getAllSessions()).thenAnswer(
      (_) async => sessions,
    );
    when(() => mockSessionDatasource.getSession(any())).thenAnswer((
      invocation,
    ) async {
      final requestedSessionId = invocation.positionalArguments.first as String;
      for (final session in sessions) {
        if (session.id == requestedSessionId) return session;
      }
      return null;
    });
    when(() => mockGroupDatasource.getAllGroups()).thenAnswer((_) async => []);
    when(
      () => mockSessionDatasource.getSessionState(any()),
    ).thenAnswer((_) async => null);
    when(
      () => mockInviteDatasource.getActiveInvites(),
    ).thenAnswer((_) async => []);
    when(
      () => mockMessageDatasource.getMessagesForSession(
        any(),
        limit: any(named: 'limit'),
        beforeId: any(named: 'beforeId'),
      ),
    ).thenAnswer((_) async => const <ChatMessage>[]);

    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/chats',
          builder: (context, state) => const ChatListScreen(),
        ),
        ShellRoute(
          builder: (context, state, child) => ChatsShellScreen(child: child),
          routes: [
            GoRoute(
              path: '/chats/new',
              builder: (context, state) =>
                  const Scaffold(body: Center(child: Text('New Chat Detail'))),
            ),
            GoRoute(
              path: '/chats/:id',
              builder: (context, state) => Scaffold(
                appBar: AppBar(title: const Text('Chat Detail')),
                body: Center(
                  child: Text('Detail ${state.pathParameters['id']}'),
                ),
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(body: Text('Settings')),
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        sessionDatasourceProvider.overrideWithValue(mockSessionDatasource),
        inviteDatasourceProvider.overrideWithValue(mockInviteDatasource),
        messageSubscriptionProvider.overrideWithValue(mockSessionManagerService),
        sessionManagerServiceProvider.overrideWithValue(
          mockSessionManagerService,
        ),
        groupDatasourceProvider.overrideWithValue(mockGroupDatasource),
        groupMessageDatasourceProvider.overrideWithValue(
          mockGroupMessageDatasource,
        ),
        messageDatasourceProvider.overrideWithValue(mockMessageDatasource),
        profileServiceProvider.overrideWithValue(mockProfileService),
        imgproxySettingsServiceProvider.overrideWithValue(
          fakeImgproxySettingsService,
        ),
        connectivityStatusProvider.overrideWith(
          (_) => Stream.value(ConnectivityStatus.online),
        ),
        nostrConnectionStatusProvider.overrideWith(
          (_) => Stream.value(
            const <String, bool>{'wss://relay.one': true},
          ),
        ),
        queuedMessageCountProvider.overrideWithValue(0),
      ],
      child: ScreenUtilInit(
        designSize: const Size(390, 844),
        minTextAdapt: true,
        builder: (context, _) {
          return MaterialApp.router(
            theme: createTestTheme(),
            routerConfig: router,
          );
        },
      ),
    );
  }

  group('ChatListScreen', () {
    group('app bar', () {
      testWidgets('shows iris chat title', (tester) async {
        await tester.pumpWidget(buildChatListScreen());
        await tester.pump();

        expect(find.text('iris chat'), findsOneWidget);
      });

      testWidgets('shows settings icon button', (tester) async {
        await tester.pumpWidget(buildChatListScreen());
        await tester.pump();

        expect(find.byIcon(Icons.settings), findsOneWidget);
      });

      testWidgets('shows add icon button', (tester) async {
        await tester.pumpWidget(buildChatListScreen());
        await tester.pump();

        expect(find.byIcon(Icons.add), findsOneWidget);
      });

      testWidgets('shows relay connectivity indicator in header', (
        tester,
      ) async {
        await tester.pumpWidget(
          buildChatListScreen(
            relayConnectionStatus: const {
              'wss://relay.one': true,
              'wss://relay.two': false,
            },
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('relay-connectivity-indicator')),
          findsOneWidget,
        );
        final countText = tester.widget<Text>(
          find.byKey(const ValueKey('relay-connectivity-count')),
        );
        expect(countText.data, '1');
      });

      testWidgets(
        'shows green relay indicator when at least one relay connected',
        (tester) async {
          await tester.pumpWidget(
            buildChatListScreen(
              relayConnectionStatus: const {
                'wss://relay.one': true,
                'wss://relay.two': false,
              },
            ),
          );
          await tester.pump();

          final icon = tester.widget<Icon>(
            find.byKey(const ValueKey('relay-connectivity-icon')),
          );
          expect(icon.color, Colors.green);
        },
      );

      testWidgets('shows orange relay indicator while connecting', (
        tester,
      ) async {
        await tester.pumpWidget(
          buildChatListScreen(
            relayConnectionStatus: const {
              'wss://relay.one': false,
              'wss://relay.two': false,
            },
          ),
        );
        await tester.pump();

        final icon = tester.widget<Icon>(
          find.byKey(const ValueKey('relay-connectivity-icon')),
        );
        expect(icon.color, Colors.orange);
      });

      testWidgets('shows red relay indicator when device is offline', (
        tester,
      ) async {
        await tester.pumpWidget(
          buildChatListScreen(
            relayConnectionStatus: const {
              'wss://relay.one': true,
              'wss://relay.two': true,
            },
            connectivityStatus: ConnectivityStatus.offline,
          ),
        );
        await tester.pump();

        final icon = tester.widget<Icon>(
          find.byKey(const ValueKey('relay-connectivity-icon')),
        );
        expect(icon.color, Colors.red);
      });

      testWidgets(
        'opens settings when relay connectivity indicator is tapped',
        (tester) async {
          await tester.pumpWidget(buildChatListScreen());
          await tester.pump();

          await tester.tap(
            find.byKey(const ValueKey('relay-connectivity-indicator')),
          );
          await tester.pumpAndSettle();

          expect(find.text('Settings'), findsOneWidget);
        },
      );
    });

    group('empty state', () {
      testWidgets('renders scaffold when no sessions', (tester) async {
        await tester.pumpWidget(buildChatListScreen(sessions: []));
        await tester.pump();

        expect(find.byType(Scaffold), findsWidgets);
      });

      testWidgets(
        'redirects to new chat when there are no sessions or groups',
        (tester) async {
          await tester.pumpWidget(buildChatListScreen(sessions: []));
          await tester.pumpAndSettle();

          expect(find.text('New Chat'), findsOneWidget);
        },
      );

      testWidgets(
        'still redirects to new chat when message subscription init fails',
        (tester) async {
          await tester.pumpWidget(
            buildChatListScreen(
              sessions: [],
              throwOnMessageSubscriptionInit: true,
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('New Chat'), findsOneWidget);
        },
      );
    });

    group('session list', () {
      testWidgets('displays sessions when available', (tester) async {
        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'abcd1234567890abcd1234567890abcd',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
          ),
          ChatSession(
            id: 'session-2',
            recipientPubkeyHex: 'efgh1234567890efgh1234567890efgh',
            recipientName: 'Bob',
            createdAt: DateTime.now(),
          ),
        ];

        await tester.pumpWidget(buildChatListScreen(sessions: sessions));
        await tester.pump();

        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Bob'), findsOneWidget);
      });

      testWidgets('shows avatar with first letter of name', (tester) async {
        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'abcd1234567890abcd1234567890abcd',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
          ),
        ];

        await tester.pumpWidget(buildChatListScreen(sessions: sessions));
        await tester.pump();

        expect(find.text('A'), findsOneWidget);
        expect(find.byType(CircleAvatar), findsOneWidget);
      });

      testWidgets('shows last message preview', (tester) async {
        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'abcd1234567890abcd1234567890abcd',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
            lastMessagePreview: 'Hey, how are you?',
          ),
        ];

        await tester.pumpWidget(buildChatListScreen(sessions: sessions));
        await tester.pump();

        expect(find.text('Hey, how are you?'), findsOneWidget);
      });

      testWidgets('shows unread count badge when unread messages exist', (
        tester,
      ) async {
        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'abcd1234567890abcd1234567890abcd',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
            unreadCount: 5,
          ),
        ];

        await tester.pumpWidget(buildChatListScreen(sessions: sessions));
        await tester.pump();

        expect(find.text('5'), findsOneWidget);
      });

      testWidgets('does not show unread badge when count is zero', (
        tester,
      ) async {
        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'abcd1234567890abcd1234567890abcd',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
            unreadCount: 0,
          ),
        ];

        await tester.pumpWidget(buildChatListScreen(sessions: sessions));
        await tester.pump();

        expect(find.byType(UnseenBadge), findsNothing);
      });

      testWidgets('shows animal name when no recipient name', (tester) async {
        const pubkey = 'abcd1234567890abcd1234567890abcd';
        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex: pubkey,
            createdAt: DateTime.now(),
          ),
        ];

        await tester.pumpWidget(buildChatListScreen(sessions: sessions));
        await tester.pump();

        expect(find.text(getAnimalName(pubkey)), findsOneWidget);
      });

      testWidgets('prefers Nostr profile name when cached profile exists', (
        tester,
      ) async {
        const pubkey =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        when(() => mockProfileService.getCachedProfile(pubkey)).thenReturn(
          NostrProfile(
            pubkey: pubkey,
            displayName: 'Alice From Nostr',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        );

        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex: pubkey,
            createdAt: DateTime.now(),
          ),
        ];

        await tester.pumpWidget(buildChatListScreen(sessions: sessions));
        await tester.pump();

        expect(find.text('Alice From Nostr'), findsOneWidget);
      });
    });

    group('loading state', () {
      testWidgets('shows loading indicator when loading', (tester) async {
        await tester.pumpWidget(buildChatListScreen());
        await tester.pump();

        expect(find.byType(Scaffold), findsOneWidget);
      });
    });

    group('session interactions', () {
      testWidgets('session item is present as ListTile', (tester) async {
        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'abcd1234567890abcd1234567890abcd',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
          ),
        ];

        await tester.pumpWidget(buildChatListScreen(sessions: sessions));
        await tester.pump();

        expect(find.byType(ListTile), findsOneWidget);
        expect(find.text('Alice'), findsOneWidget);
      });

      testWidgets('session item is dismissible', (tester) async {
        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex: 'abcd1234567890abcd1234567890abcd',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
          ),
        ];

        await tester.pumpWidget(buildChatListScreen(sessions: sessions));
        await tester.pump();

        expect(find.byType(Dismissible), findsOneWidget);
      });

      testWidgets(
        'unread badge clears after opening a chat even when messages are already seen',
        (tester) async {
          final session = ChatSession(
            id: 'session-1',
            recipientPubkeyHex:
                'abcd1234567890abcd1234567890abcdabcd1234567890abcd1234567890',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
            unreadCount: 3,
          );
          final seenMessage = ChatMessage(
            id: 'msg-1',
            sessionId: session.id,
            text: 'Already seen',
            timestamp: DateTime.now(),
            direction: MessageDirection.incoming,
            status: MessageStatus.seen,
            rumorId: 'rumor-1',
          );

          await tester.pumpWidget(
            buildChatListScreen(
              sessions: [session],
              messagesBySession: {
                session.id: [seenMessage],
              },
              includeChatRoute: true,
              seedSessionState: true,
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('3'), findsOneWidget);

          await tester.tap(find.text('Alice'));
          await tester.pumpAndSettle();

          expect(find.byType(ChatScreen), findsOneWidget);

          await tester.pageBack();
          await tester.pumpAndSettle();

          expect(find.byType(ChatListScreen), findsOneWidget);
          expect(find.byType(UnseenBadge), findsNothing);
          expect(find.text('3'), findsNothing);
          verify(
            () => mockSessionDatasource.updateMetadata(
              session.id,
              unreadCount: 0,
            ),
          ).called(1);
          verifyNever(
            () => mockSessionManagerService.sendReceipt(
              recipientPubkeyHex: any(named: 'recipientPubkeyHex'),
              receiptType: 'seen',
              messageIds: any(named: 'messageIds'),
            ),
          );
        },
      );
    });

    group('wide layout', () {
      testWidgets('shows chat list beside detail screen on wide windows', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1400, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
          ),
          ChatSession(
            id: 'session-2',
            recipientPubkeyHex:
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            recipientName: 'Bob',
            createdAt: DateTime.now(),
          ),
        ];

        await tester.pumpWidget(
          buildChatsShell(
            initialLocation: '/chats/session-1',
            sessions: sessions,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Detail session-1'), findsOneWidget);
      });

      testWidgets('tapping another thread replaces the wide detail pane', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1400, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
          ),
          ChatSession(
            id: 'session-2',
            recipientPubkeyHex:
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            recipientName: 'Bob',
            createdAt: DateTime.now(),
          ),
        ];

        await tester.pumpWidget(
          buildChatsShell(
            initialLocation: '/chats/session-1',
            sessions: sessions,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Bob'));
        await tester.pumpAndSettle();

        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Detail session-2'), findsOneWidget);
        expect(find.text('Detail session-1'), findsNothing);
      });

      testWidgets('keeps detail routes single-pane on narrow windows', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(430, 932);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final sessions = [
          ChatSession(
            id: 'session-1',
            recipientPubkeyHex:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            recipientName: 'Alice',
            createdAt: DateTime.now(),
          ),
        ];

        await tester.pumpWidget(
          buildChatsShell(
            initialLocation: '/chats/session-1',
            sessions: sessions,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Detail session-1'), findsOneWidget);
        expect(find.text('Alice'), findsNothing);
      });
    });
  });
}
