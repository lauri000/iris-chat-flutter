import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../config/providers/chat_provider.dart';
import '../../../../config/providers/connectivity_provider.dart';
import '../../../../config/providers/nostr_provider.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/services/profile_service.dart';
import '../../../../shared/utils/formatters.dart';
import '../../domain/models/group.dart';
import '../../domain/models/session.dart';
import '../widgets/group_avatar.dart';
import '../widgets/iris_brand_title.dart';
import '../widgets/offline_indicator.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/unseen_badge.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const IrisBrandTitle(),
        actions: [
          RelayConnectivityIndicator(onTap: () => context.push('/settings')),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/chats/new'),
            tooltip: 'New Chat',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: const Column(
        children: [
          OfflineBanner(),
          Expanded(child: ChatListPane()),
        ],
      ),
    );
  }
}

class ChatListPane extends ConsumerStatefulWidget {
  const ChatListPane({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<ChatListPane> createState() => _ChatListPaneState();
}

class _ChatListPaneState extends ConsumerState<ChatListPane> {
  bool _initialProbeDone = false;
  bool _redirected = false;

  bool get _shouldRedirectWhenEmpty => !widget.embedded;

  Future<void> _probePersistedThreads() async {
    final sessionState = ref.read(sessionStateProvider);
    final groupState = ref.read(groupStateProvider);
    final hasPersistedThreads =
        sessionState.sessions.isNotEmpty || groupState.groups.isNotEmpty;

    if (!hasPersistedThreads) {
      await ref.read(sessionStateProvider.notifier).loadSessions();
      await ref.read(groupStateProvider.notifier).loadGroups();
    }

    if (mounted) {
      setState(() => _initialProbeDone = true);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_probePersistedThreads());
    });
  }

  void _openThread(BuildContext context, _Thread thread) {
    final path = thread.group != null
        ? '/groups/${thread.group!.id}'
        : '/chats/${thread.session!.id}';
    if (widget.embedded) {
      context.go(path);
      return;
    }
    context.push(path);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(profileUpdatesProvider);
    final profileService = ref.watch(profileServiceProvider);
    final sessionsLoading = ref.watch(
      sessionStateProvider.select((s) => s.isLoading),
    );
    final groupsLoading = ref.watch(
      groupStateProvider.select((s) => s.isLoading),
    );
    final sessionsError = ref.watch(
      sessionStateProvider.select((s) => s.error),
    );
    final groupsError = ref.watch(groupStateProvider.select((s) => s.error));
    final sessions = ref.watch(sessionStateProvider.select((s) => s.sessions));
    final groups = ref.watch(groupStateProvider.select((s) => s.groups));
    final showInitialLoading =
        (!_initialProbeDone || sessionsLoading || groupsLoading) &&
        sessions.isEmpty &&
        groups.isEmpty;

    if (_shouldRedirectWhenEmpty &&
        _initialProbeDone &&
        !sessionsLoading &&
        !groupsLoading &&
        sessionsError == null &&
        groupsError == null &&
        sessions.isEmpty &&
        groups.isEmpty &&
        !_redirected) {
      _redirected = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final router = GoRouter.maybeOf(context);
        if (router != null) {
          router.go('/chats/new');
        }
      });
    }

    final body = showInitialLoading
        ? const Center(child: CircularProgressIndicator())
        : _buildChatList(
            sessions: sessions,
            groups: groups,
            profileService: profileService,
          );

    if (!widget.embedded) {
      return body;
    }

    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
              child: Row(
                children: [
                  const Expanded(child: IrisBrandTitle()),
                  RelayConnectivityIndicator(
                    onTap: () => context.push('/settings'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () => context.go('/chats/new'),
                    tooltip: 'New Chat',
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings),
                    onPressed: () => context.push('/settings'),
                  ),
                ],
              ),
            ),
            const OfflineBanner(),
            const Divider(height: 1),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _buildChatList({
    required List<ChatSession> sessions,
    required List<ChatGroup> groups,
    required ProfileService profileService,
  }) {
    final threads = <_Thread>[
      ...groups.map(_Thread.group),
      ...sessions.map(_Thread.session),
    ]..sort((a, b) => b.sortTime.compareTo(a.sortTime));

    return ListView.builder(
      itemCount: threads.length,
      cacheExtent: 80.0 * 3,
      itemBuilder: (context, index) {
        final thread = threads[index];
        final group = thread.group;
        if (group != null) {
          return _GroupListItem(
            key: ValueKey('group:${group.id}'),
            group: group,
            onTap: () => _openThread(context, thread),
            onDelete: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete group?'),
                  content: const Text(
                    'This will delete the group and all its messages from this device. This action cannot be undone.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (confirmed ?? false) {
                await ref
                    .read(groupStateProvider.notifier)
                    .deleteGroup(group.id);
              }
            },
          );
        }

        final session = thread.session!;
        final profile = profileService.getCachedProfile(
          session.recipientPubkeyHex,
        );
        final displayName = profile?.bestName ?? session.displayName;
        return _ChatListItem(
          key: ValueKey(session.id),
          session: session,
          displayName: displayName,
          pictureUrl: profile?.picture,
          onTap: () => _openThread(context, thread),
          onDelete: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Delete conversation?'),
                content: const Text(
                  'This will delete all messages in this conversation. This action cannot be undone.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
            if (confirmed ?? false) {
              await ref
                  .read(sessionStateProvider.notifier)
                  .deleteSession(session.id);
            }
          },
        );
      },
    );
  }
}

class RelayConnectivityIndicator extends ConsumerWidget {
  const RelayConnectivityIndicator({super.key, this.onTap});

  final VoidCallback? onTap;

  static const _iconKey = ValueKey('relay-connectivity-icon');
  static const _countKey = ValueKey('relay-connectivity-count');
  static const _indicatorKey = ValueKey('relay-connectivity-indicator');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionStatus =
        ref.watch(nostrConnectionStatusProvider).valueOrNull ??
        const <String, bool>{};
    final connectivity = ref.watch(connectivityStatusProvider).valueOrNull;

    final connectedCount = connectionStatus.values
        .where((connected) => connected)
        .length;
    final totalCount = connectionStatus.length;
    final isOffline = connectivity == ConnectivityStatus.offline;
    final color = _statusColor(
      isOffline: isOffline,
      connectedCount: connectedCount,
      totalCount: totalCount,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: _statusLabel(
          isOffline: isOffline,
          connectedCount: connectedCount,
          totalCount: totalCount,
        ),
        child: InkWell(
          key: _indicatorKey,
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi, key: _iconKey, size: 16, color: color),
                const SizedBox(width: 4),
                Text(
                  '$connectedCount',
                  key: _countKey,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColor({
    required bool isOffline,
    required int connectedCount,
    required int totalCount,
  }) {
    if (isOffline) return Colors.red;
    if (connectedCount == 0) {
      return totalCount > 0 ? Colors.orange : Colors.red;
    }
    return Colors.green;
  }

  String _statusLabel({
    required bool isOffline,
    required int connectedCount,
    required int totalCount,
  }) {
    if (isOffline) return 'Offline';
    if (connectedCount == 0) {
      if (totalCount > 0) {
        return 'Connecting to $totalCount relay${totalCount == 1 ? '' : 's'}';
      }
      return 'No relays configured';
    }
    return '$connectedCount/$totalCount relay${totalCount == 1 ? '' : 's'} connected';
  }
}

class _Thread {
  const _Thread._({this.session, this.group});

  factory _Thread.session(ChatSession session) => _Thread._(session: session);
  factory _Thread.group(ChatGroup group) => _Thread._(group: group);

  final ChatSession? session;
  final ChatGroup? group;

  DateTime get sortTime {
    final s = session;
    if (s != null) {
      return s.lastMessageAt ?? s.createdAt;
    }
    final g = group!;
    return g.lastMessageAt ?? g.createdAt;
  }
}

class _GroupListItem extends StatelessWidget {
  const _GroupListItem({
    super.key,
    required this.group,
    required this.onTap,
    required this.onDelete,
  });

  final ChatGroup group;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  static const _dismissiblePadding = EdgeInsets.only(right: 16);
  static const _unreadSpacing = SizedBox(height: 4);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = group.accepted
        ? group.lastMessagePreview
        : (group.lastMessagePreview ?? 'Group invitation');

    return Dismissible(
      key: Key('group:${group.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.error,
        alignment: Alignment.centerRight,
        padding: _dismissiblePadding,
        child: Icon(Icons.delete, color: theme.colorScheme.onError),
      ),
      onDismissed: (_) => onDelete(),
      child: ListTile(
        leading: GroupAvatar(
          groupName: group.name,
          picture: group.picture,
          radius: 20,
          backgroundColor: theme.colorScheme.secondaryContainer,
          iconColor: theme.colorScheme.onSecondaryContainer,
        ),
        title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle != null
            ? Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              )
            : null,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (group.lastMessageAt != null)
              Text(
                formatRelativeDateTime(group.lastMessageAt!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (group.unreadCount > 0) ...[
              _unreadSpacing,
              UnseenBadge(count: group.unreadCount),
            ],
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _ChatListItem extends StatelessWidget {
  const _ChatListItem({
    super.key,
    required this.session,
    required this.displayName,
    this.pictureUrl,
    required this.onTap,
    required this.onDelete,
  });

  final ChatSession session;
  final String displayName;
  final String? pictureUrl;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  static const _dismissiblePadding = EdgeInsets.only(right: 16);
  static const _unreadSpacing = SizedBox(height: 4);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dismissible(
      key: Key(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.error,
        alignment: Alignment.centerRight,
        padding: _dismissiblePadding,
        child: Icon(Icons.delete, color: theme.colorScheme.onError),
      ),
      onDismissed: (_) => onDelete(),
      child: ListTile(
        leading: ProfileAvatar(
          pubkeyHex: session.recipientPubkeyHex,
          displayName: displayName,
          pictureUrl: pictureUrl,
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundTextColor: theme.colorScheme.onPrimaryContainer,
        ),
        title: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: session.lastMessagePreview != null
            ? Text(
                session.lastMessagePreview!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              )
            : null,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (session.lastMessageAt != null)
              Text(
                formatRelativeDateTime(session.lastMessageAt!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (session.unreadCount > 0) ...[
              _unreadSpacing,
              UnseenBadge(count: session.unreadCount),
            ],
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
