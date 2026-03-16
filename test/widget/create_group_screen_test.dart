import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/config/providers/nostr_provider.dart';
import 'package:iris_chat/core/services/profile_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/features/chat/data/datasources/group_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/group_message_local_datasource.dart';
import 'package:iris_chat/features/chat/data/datasources/session_local_datasource.dart';
import 'package:iris_chat/features/chat/domain/models/session.dart';
import 'package:iris_chat/features/chat/presentation/screens/create_group_screen.dart';
import 'package:iris_chat/shared/utils/formatters.dart';
import 'package:mocktail/mocktail.dart';

import '../test_helpers.dart';

class _MockSessionLocalDatasource extends Mock
    implements SessionLocalDatasource {}

class _MockProfileService extends Mock implements ProfileService {}

class _MockGroupLocalDatasource extends Mock implements GroupLocalDatasource {}

class _MockGroupMessageLocalDatasource extends Mock
    implements GroupMessageLocalDatasource {}

class _MockSessionManagerService extends Mock
    implements SessionManagerService {}

class _TestGroupNotifier extends GroupNotifier {
  _TestGroupNotifier()
    : super(
        _MockGroupLocalDatasource(),
        _MockGroupMessageLocalDatasource(),
        _MockSessionManagerService(),
      );

  int createGroupCalls = 0;
  String? lastGroupName;
  List<String>? lastMembers;

  @override
  Future<String?> createGroup({
    required String name,
    required List<String> memberPubkeysHex,
  }) async {
    createGroupCalls++;
    lastGroupName = name;
    lastMembers = List<String>.from(memberPubkeysHex);
    return null;
  }
}

void main() {
  testWidgets('shows profile names and hides pubkeys in member list', (
    tester,
  ) async {
    final mockSessions = _MockSessionLocalDatasource();
    final mockProfiles = _MockProfileService();
    final mockSessionManagerService = _MockSessionManagerService();
    const memberPubkeyHex =
        'b1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b3';

    when(
      () => mockProfiles.profileUpdates,
    ).thenAnswer((_) => const Stream<String>.empty());
    when(() => mockProfiles.getCachedProfile(any())).thenReturn(null);
    when(() => mockProfiles.getCachedProfile(memberPubkeyHex)).thenReturn(
      NostrProfile(
        pubkey: memberPubkeyHex,
        displayName: 'Alice',
        updatedAt: DateTime(2026, 1, 1),
      ),
    );
    when(
      () => mockSessionManagerService.setupUser(any()),
    ).thenAnswer((_) async {});

    final sessionNotifier =
        SessionNotifier(mockSessions, mockProfiles, mockSessionManagerService)
          ..state = SessionState(
            sessions: [
              ChatSession(
                id: 's1',
                recipientPubkeyHex: memberPubkeyHex,
                createdAt: DateTime(2026, 1, 1),
              ),
            ],
          );

    await tester.pumpWidget(
      createTestApp(
        const CreateGroupScreen(),
        overrides: [
          sessionStateProvider.overrideWith((ref) => sessionNotifier),
          profileServiceProvider.overrideWithValue(mockProfiles),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text(formatPubkeyForDisplay(memberPubkeyHex)), findsNothing);
  });

  testWidgets('allows create submit with no selected members', (tester) async {
    final mockSessions = _MockSessionLocalDatasource();
    final mockProfiles = _MockProfileService();
    final mockSessionManagerService = _MockSessionManagerService();
    final groupNotifier = _TestGroupNotifier();
    when(
      () => mockSessionManagerService.setupUser(any()),
    ).thenAnswer((_) async {});

    final sessionNotifier = SessionNotifier(
      mockSessions,
      mockProfiles,
      mockSessionManagerService,
    )..state = const SessionState(sessions: []);

    await tester.pumpWidget(
      createTestApp(
        const CreateGroupScreen(),
        overrides: [
          sessionStateProvider.overrideWith((ref) => sessionNotifier),
          groupStateProvider.overrideWith((ref) => groupNotifier),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Solo Group');
    await tester.pumpAndSettle();

    final createButton = find.widgetWithText(FilledButton, 'Create Group');
    expect(createButton, findsOneWidget);
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(groupNotifier.createGroupCalls, 1);
    expect(groupNotifier.lastGroupName, 'Solo Group');
    expect(groupNotifier.lastMembers, isEmpty);
  });
}
