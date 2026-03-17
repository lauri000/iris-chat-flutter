import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../core/ffi/ndr_ffi.dart';
import '../../core/services/app_focus_service.dart';
import '../../core/services/database_service.dart';
import '../../core/services/desktop_notification_service.dart';
import '../../core/services/error_service.dart';
import '../../core/services/inbound_activity_policy.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/session_manager_service.dart';
import '../../core/utils/hashtree_attachments.dart';
import '../../core/utils/nostr_rumor.dart';
import '../../core/utils/reaction_updates.dart';
import '../../core/utils/typing_rumor.dart';
import '../../features/chat/data/datasources/group_local_datasource.dart';
import '../../features/chat/data/datasources/group_message_local_datasource.dart';
import '../../features/chat/data/datasources/message_local_datasource.dart';
import '../../features/chat/data/datasources/session_local_datasource.dart';
import '../../features/chat/domain/models/group.dart';
import '../../features/chat/domain/models/message.dart';
import '../../features/chat/domain/models/session.dart';
import '../../features/chat/domain/utils/chat_settings.dart';
import '../../features/chat/domain/utils/group_metadata.dart';
import '../../features/chat/domain/utils/message_status_utils.dart';
import '../../shared/utils/formatters.dart';
import 'desktop_notification_provider.dart';
import 'messaging_preferences_provider.dart';
import 'nostr_provider.dart';

part 'chat_provider.freezed.dart';
part 'chat_provider_session_notifier.dart';
part 'chat_provider_chat_notifier.dart';
part 'chat_provider_group_notifier.dart';

/// State for chat sessions.
@freezed
abstract class SessionState with _$SessionState {
  const factory SessionState({
    @Default([]) List<ChatSession> sessions,
    @Default(false) bool isLoading,
    String? error,
  }) = _SessionState;
}

/// State for messages in a chat.
@freezed
abstract class ChatState with _$ChatState {
  const factory ChatState({
    @Default({}) Map<String, List<ChatMessage>> messages,
    @Default({}) Map<String, int> unreadCounts,
    @Default({}) Map<String, bool> sendingStates,
    @Default({}) Map<String, bool> typingStates,
    String? error,
  }) = _ChatState;
}

/// State for group chats.
@freezed
abstract class GroupState with _$GroupState {
  const factory GroupState({
    @Default([]) List<ChatGroup> groups,
    @Default(false) bool isLoading,
    @Default({}) Map<String, List<ChatMessage>> messages,
    @Default({}) Map<String, bool> typingStates,
    String? error,
  }) = _GroupState;
}

// Providers

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService();
});

final sessionDatasourceProvider = Provider<SessionLocalDatasource>((ref) {
  final db = ref.watch(databaseServiceProvider);
  return SessionLocalDatasource(db);
});

final messageDatasourceProvider = Provider<MessageLocalDatasource>((ref) {
  final db = ref.watch(databaseServiceProvider);
  return MessageLocalDatasource(db);
});

final groupDatasourceProvider = Provider<GroupLocalDatasource>((ref) {
  final db = ref.watch(databaseServiceProvider);
  return GroupLocalDatasource(db);
});

final groupMessageDatasourceProvider = Provider<GroupMessageLocalDatasource>((
  ref,
) {
  final db = ref.watch(databaseServiceProvider);
  return GroupMessageLocalDatasource(db);
});

final sessionStateProvider =
    StateNotifierProvider<SessionNotifier, SessionState>((ref) {
      final datasource = ref.watch(sessionDatasourceProvider);
      final profileService = ref.watch(profileServiceProvider);
      final sessionManagerService = ref.watch(sessionManagerServiceProvider);
      return SessionNotifier(datasource, profileService, sessionManagerService);
    });

final chatStateProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  final messageDatasource = ref.watch(messageDatasourceProvider);
  final sessionDatasource = ref.watch(sessionDatasourceProvider);
  final sessionManagerService = ref.watch(sessionManagerServiceProvider);
  final desktopNotificationService = ref.watch(
    desktopNotificationServiceProvider,
  );
  final inboundActivityPolicy = ref.watch(inboundActivityPolicyProvider);
  final notifier = ChatNotifier(
    messageDatasource,
    sessionDatasource,
    sessionManagerService,
    desktopNotificationService: desktopNotificationService,
    inboundActivityPolicy: inboundActivityPolicy,
  );
  final initialPrefs = ref.read(messagingPreferencesProvider);
  notifier.setOutboundSignalSettings(
    typingIndicatorsEnabled: initialPrefs.typingIndicatorsEnabled,
    deliveryReceiptsEnabled: initialPrefs.deliveryReceiptsEnabled,
    readReceiptsEnabled: initialPrefs.readReceiptsEnabled,
    desktopNotificationsEnabled: initialPrefs.desktopNotificationsEnabled,
  );
  ref.listen<MessagingPreferencesState>(messagingPreferencesProvider, (
    _,
    next,
  ) {
    notifier.setOutboundSignalSettings(
      typingIndicatorsEnabled: next.typingIndicatorsEnabled,
      deliveryReceiptsEnabled: next.deliveryReceiptsEnabled,
      readReceiptsEnabled: next.readReceiptsEnabled,
      desktopNotificationsEnabled: next.desktopNotificationsEnabled,
    );
  });
  return notifier;
});

final groupStateProvider = StateNotifierProvider<GroupNotifier, GroupState>((
  ref,
) {
  final groupDatasource = ref.watch(groupDatasourceProvider);
  final groupMessageDatasource = ref.watch(groupMessageDatasourceProvider);
  final sessionManagerService = ref.watch(sessionManagerServiceProvider);
  final desktopNotificationService = ref.watch(
    desktopNotificationServiceProvider,
  );
  final inboundActivityPolicy = ref.watch(inboundActivityPolicyProvider);
  final notifier = GroupNotifier(
    groupDatasource,
    groupMessageDatasource,
    sessionManagerService,
    desktopNotificationService: desktopNotificationService,
    inboundActivityPolicy: inboundActivityPolicy,
  );
  final initialPrefs = ref.read(messagingPreferencesProvider);
  notifier.typingIndicatorsEnabled = initialPrefs.typingIndicatorsEnabled;
  notifier.desktopNotificationsEnabled =
      initialPrefs.desktopNotificationsEnabled;
  ref.listen<MessagingPreferencesState>(messagingPreferencesProvider, (
    _,
    next,
  ) {
    notifier.typingIndicatorsEnabled = next.typingIndicatorsEnabled;
    notifier.desktopNotificationsEnabled = next.desktopNotificationsEnabled;
  });
  return notifier;
});

final groupMessagesProvider = Provider.family<List<ChatMessage>, String>((
  ref,
  groupId,
) {
  return ref.watch(
    groupStateProvider.select(
      (s) => s.messages[groupId] ?? const <ChatMessage>[],
    ),
  );
});

/// Provider for messages in a specific session.
/// Performance: Uses select() to only rebuild when messages for this specific session change.
final sessionMessagesProvider = Provider.family<List<ChatMessage>, String>((
  ref,
  sessionId,
) {
  // Use select to only watch messages for this specific session
  return ref.watch(
    chatStateProvider.select((state) => state.messages[sessionId] ?? []),
  );
});

/// Provider for message count in a specific session.
/// Useful for UI that only needs to know if there are messages without watching the full list.
final sessionMessageCountProvider = Provider.family<int, String>((
  ref,
  sessionId,
) {
  return ref.watch(
    chatStateProvider.select((state) => state.messages[sessionId]?.length ?? 0),
  );
});

/// Provider for checking if a session has messages.
/// More efficient than watching the full message list when you only need a boolean.
final sessionHasMessagesProvider = Provider.family<bool, String>((
  ref,
  sessionId,
) {
  return ref.watch(
    chatStateProvider.select(
      (state) => state.messages[sessionId]?.isNotEmpty ?? false,
    ),
  );
});
