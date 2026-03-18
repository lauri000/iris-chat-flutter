import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../config/providers/chat_provider.dart';
import '../../../../config/providers/hashtree_attachment_provider.dart';
import '../../../../core/services/hashtree_attachment_service.dart';
import '../../../../core/utils/hashtree_attachments.dart';
import '../../../../shared/utils/formatters.dart';
import '../../domain/models/group.dart';
import '../../domain/models/message.dart';
import '../utils/attachment_upload.dart';
import '../utils/seen_sync_mixin.dart';
import '../widgets/chat_message_bubble.dart';
import '../widgets/chats_back_button.dart';
import '../widgets/group_avatar.dart';
import '../widgets/message_input.dart';
import '../widgets/typing_dots.dart';

const double _kEstimatedMessageHeight = 80.0;

class GroupChatScreen extends ConsumerStatefulWidget {
  const GroupChatScreen({super.key, required this.groupId});

  final String groupId;

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen>
    with SeenSyncMixin<GroupChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _composerFocusNode = FocusNode();
  final List<_PendingAttachment> _pendingAttachments = [];
  bool _isAtBottom = true;
  bool _isUploadingAttachment = false;
  bool _composerHadText = false;
  DateTime? _pinBottomUntil;
  ChatMessage? _replyingTo;

  @override
  void initState() {
    super.initState();
    initSeenSyncObserver();
    _scrollController.addListener(_onScroll);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        // Best-effort load: navigation can happen before the list screen initializes.
        await ref.read(groupStateProvider.notifier).loadGroups();
        await ref
            .read(groupStateProvider.notifier)
            .loadGroupMessages(widget.groupId);
        scheduleSeenSync();
      }());
    });
  }

  @override
  void dispose() {
    disposeSeenSyncObserver();
    _messageController.dispose();
    _scrollController.dispose();
    _composerFocusNode.dispose();
    super.dispose();
  }

  @override
  bool get hasUnseenIncomingMessages {
    final messages = ref.read(groupMessagesProvider(widget.groupId));
    return messages.any((m) => m.isIncoming && m.status != MessageStatus.seen);
  }

  @override
  bool get hasUnreadIndicator {
    final groups = ref.read(groupStateProvider).groups;
    for (final group in groups) {
      if (group.id == widget.groupId) {
        return group.unreadCount > 0 || hasUnseenIncomingMessages;
      }
    }
    return hasUnseenIncomingMessages;
  }

  @override
  Future<void> markConversationSeen() {
    return ref.read(groupStateProvider.notifier).markGroupSeen(widget.groupId);
  }

  void _onScroll() {
    final isAtBottom =
        _scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 50;
    if (isAtBottom != _isAtBottom) {
      setState(() => _isAtBottom = isAtBottom);
    }
    if (!isAtBottom) {
      _pinBottomUntil = null;
    }
  }

  void _scrollToBottom({bool animated = true}) {
    if (!_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (animated) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      return;
    }
    _scrollController.jumpTo(target);
  }

  void _scheduleScrollToBottom({int retries = 3}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToBottom(animated: false);
      if (retries <= 0) return;
      _scheduleScrollToBottom(retries: retries - 1);
    });
  }

  bool get _shouldKeepBottomPinned {
    final pinUntil = _pinBottomUntil;
    return _isAtBottom ||
        (pinUntil != null && pinUntil.isAfter(DateTime.now()));
  }

  void _pinBottomFor(Duration duration) {
    _pinBottomUntil = DateTime.now().add(duration);
  }

  void _onMessageMediaLayoutChanged() {
    if (!_shouldKeepBottomPinned) return;
    _scheduleScrollToBottom(retries: 6);
  }

  void _scrollToTimelineMessage(List<ChatMessage> messages, String messageId) {
    if (!_scrollController.hasClients) return;
    final targetIndex = messages.indexWhere((message) {
      return message.id == messageId ||
          message.eventId == messageId ||
          message.rumorId == messageId;
    });
    if (targetIndex < 0) return;

    final targetOffset = (targetIndex * _kEstimatedMessageHeight).toDouble();
    final clamped = targetOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    final attachmentsToSend = List<_PendingAttachment>.from(
      _pendingAttachments,
    );
    final attachmentLinks = attachmentsToSend
        .map((a) => a.link)
        .toList(growable: false);
    if (text.isEmpty && attachmentLinks.isEmpty) return;

    if (attachmentLinks.isNotEmpty) {
      _pinBottomFor(const Duration(seconds: 6));
    }

    final content = appendHashtreeLinksToMessage(text, attachmentLinks);
    final replyToId = _replyingTo?.id;

    _messageController.clear();
    if (_composerHadText) {
      _composerHadText = false;
      await ref
          .read(groupStateProvider.notifier)
          .sendGroupTyping(widget.groupId, isTyping: false);
    }
    setState(() {
      _pendingAttachments.clear();
      _replyingTo = null;
    });
    _scheduleScrollToBottom();

    await ref
        .read(groupStateProvider.notifier)
        .sendGroupMessage(widget.groupId, content, replyToId: replyToId);
    for (final attachment in attachmentsToSend) {
      if (attachment.uploaded) continue;
      unawaited(_uploadAttachmentOnce(attachment, showFailureSnack: false));
    }
    _scheduleScrollToBottom();
  }

  Future<void> _uploadAttachmentOnce(
    _PendingAttachment attachment, {
    required bool showFailureSnack,
  }) async {
    if (_isUploadingAttachment) return;
    if (mounted) setState(() => _isUploadingAttachment = true);
    try {
      await ref
          .read(hashtreeAttachmentServiceProvider)
          .uploadPreparedAttachment(attachment.prepared);

      if (!mounted) return;
      setState(() {
        final pendingIndex = _pendingAttachments.indexWhere(
          (a) => a.link == attachment.link,
        );
        if (pendingIndex != -1) {
          _pendingAttachments[pendingIndex] = _pendingAttachments[pendingIndex]
              .copyWith(uploaded: true);
        }
      });
    } catch (e) {
      if (showFailureSnack && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Attachment upload failed for now: $e'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingAttachment = false);
    }
  }

  Future<void> _pickAttachment() async {
    if (_isUploadingAttachment) return;

    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
      );
    } on MissingPluginException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Attachment picker is unavailable on this platform.'),
        ),
      );
      return;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to open file picker: $e')));
      return;
    }
    if (picked == null || picked.files.isEmpty) return;

    final file = picked.files.first;

    try {
      final prepared = await preparePickedAttachment(
        pickedFile: file,
        service: ref.read(hashtreeAttachmentServiceProvider),
      );

      if (!mounted) return;
      final attachment = _PendingAttachment(
        filename: prepared.filename,
        link: prepared.link,
        prepared: prepared,
        previewBytes: await _extractPreviewBytes(file),
      );
      setState(() {
        _pendingAttachments.add(attachment);
      });
      _composerFocusNode.requestFocus();
      unawaited(_uploadAttachmentOnce(attachment, showFailureSnack: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Attachment upload failed: $e')));
    }
  }

  void _removeAttachment(int index) {
    if (index < 0 || index >= _pendingAttachments.length) return;
    setState(() => _pendingAttachments.removeAt(index));
    _composerFocusNode.requestFocus();
  }

  Future<Uint8List?> _extractPreviewBytes(PlatformFile file) async {
    if (!isImageFilename(file.name)) return null;

    final bytes = file.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Uint8List.fromList(bytes);
    }

    final filePath = file.path?.trim();
    if (filePath == null || filePath.isEmpty) return null;

    try {
      return Uint8List.fromList(await File(filePath).readAsBytes());
    } catch (_) {
      return null;
    }
  }

  double? get _attachmentUploadProgress {
    if (!_isUploadingAttachment) return null;
    final total = _pendingAttachments.length;
    if (total <= 0) return null;
    final uploadedCount = _pendingAttachments.where((a) => a.uploaded).length;
    final coarseCompleted = uploadedCount + 0.5;
    return (coarseCompleted / total).clamp(0.0, 1.0).toDouble();
  }

  void _quoteReply(ChatMessage message) {
    setState(() => _replyingTo = message);
    _composerFocusNode.requestFocus();
  }

  void _handleComposerChanged(String text) {
    final hasText = text.trim().isNotEmpty;
    final notifier = ref.read(groupStateProvider.notifier);
    if (hasText) {
      _composerHadText = true;
      notifier.sendGroupTyping(widget.groupId);
    } else {
      if (!_composerHadText) return;
      _composerHadText = false;
      notifier.sendGroupTyping(widget.groupId, isTyping: false);
    }
  }

  String _resolveSenderLabel(String pubkeyHex) {
    final sessions = ref.read(sessionStateProvider).sessions;
    for (final s in sessions) {
      if (s.recipientPubkeyHex == pubkeyHex) return s.displayName;
    }
    return formatPubkeyForDisplay(pubkeyHex);
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(groupStateProvider.select((s) => s.groups));

    ChatGroup? group;
    for (final g in groups) {
      if (g.id == widget.groupId) {
        group = g;
        break;
      }
    }

    final messages = ref.watch(groupMessagesProvider(widget.groupId));
    scheduleSeenSync();
    final isTyping = ref.watch(
      groupStateProvider.select((s) => s.typingStates[widget.groupId] ?? false),
    );
    final messageById = <String, ChatMessage>{};
    for (final message in messages) {
      messageById[message.id] = message;
      final eventId = message.eventId;
      if (eventId != null && eventId.isNotEmpty) {
        messageById[eventId] = message;
      }
      final rumorId = message.rumorId;
      if (rumorId != null && rumorId.isNotEmpty) {
        messageById[rumorId] = message;
      }
    }

    final theme = Theme.of(context);

    if (group == null) {
      return Scaffold(
        appBar: AppBar(
          leading: ChatsBackButton(excludeGroupId: widget.groupId),
          title: const Text('Group'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final activeGroup = group;

    return Scaffold(
      appBar: AppBar(
        leading: ChatsBackButton(excludeGroupId: widget.groupId),
        title: InkWell(
          key: const Key('group-header-info-button'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => context.push('/groups/${activeGroup.id}/info'),
          child: Row(
            children: [
              GroupAvatar(
                groupName: activeGroup.name,
                picture: activeGroup.picture,
                radius: 16,
                backgroundColor: theme.colorScheme.secondaryContainer,
                iconColor: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  activeGroup.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (!activeGroup.accepted)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  'Invite',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!group.accepted)
            _InviteBanner(
              onAccept: () async {
                await ref
                    .read(groupStateProvider.notifier)
                    .acceptGroupInvitation(widget.groupId);
              },
            ),
          Expanded(
            child: messages.isEmpty
                ? _buildEmptyMessages(theme)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    cacheExtent: _kEstimatedMessageHeight * 5,
                    addAutomaticKeepAlives: true,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final replyToMessage =
                          message.replyToId != null &&
                              message.replyToId!.isNotEmpty
                          ? messageById[message.replyToId!]
                          : null;
                      final showDate =
                          index == 0 ||
                          !_isSameDay(
                            messages[index - 1].timestamp,
                            message.timestamp,
                          );

                      return Column(
                        key: ValueKey(
                          'group_timeline_message_${message.id}_${message.timestamp.microsecondsSinceEpoch}_$index',
                        ),
                        children: [
                          if (showDate) _DateSeparator(date: message.timestamp),
                          ChatMessageBubble(
                            key: ValueKey(
                              'bubble_${message.id}_${message.timestamp.microsecondsSinceEpoch}_$index',
                            ),
                            message: message,
                            replyToMessage: replyToMessage,
                            onOpenReply: replyToMessage == null
                                ? null
                                : () => _scrollToTimelineMessage(
                                    messages,
                                    replyToMessage.id,
                                  ),
                            onMediaLayoutChanged: _onMessageMediaLayoutChanged,
                            senderLabel:
                                (!message.isOutgoing &&
                                    message.senderPubkeyHex != null &&
                                    message.senderPubkeyHex!.isNotEmpty)
                                ? _resolveSenderLabel(message.senderPubkeyHex!)
                                : null,
                            onReply: () => _quoteReply(message),
                            onReact: (emoji) async {
                              await ref
                                  .read(groupStateProvider.notifier)
                                  .sendGroupReaction(
                                    groupId: widget.groupId,
                                    messageId: message.id,
                                    emoji: emoji,
                                  );
                            },
                            onDeleteLocal: () async {
                              await ref
                                  .read(groupStateProvider.notifier)
                                  .deleteGroupMessageLocal(
                                    widget.groupId,
                                    message.id,
                                  );
                            },
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (!_isAtBottom && messages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FloatingActionButton.small(
                onPressed: _scrollToBottom,
                child: const Icon(Icons.arrow_downward),
              ),
            ),
          if (isTyping)
            const Padding(
              padding: EdgeInsets.only(left: 16, right: 16, bottom: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TypingDots(),
              ),
            ),
          if (_replyingTo != null)
            _ReplyComposerPreview(
              message: _replyingTo!,
              onCancel: () => setState(() => _replyingTo = null),
            ),
          if (group.accepted)
            MessageInput(
              controller: _messageController,
              onSend: _sendMessage,
              onPickAttachment: _pickAttachment,
              attachments: _pendingAttachments
                  .map(
                    (a) => MessageInputAttachment(
                      label: a.uploaded
                          ? a.filename
                          : '${a.filename} (pending upload)',
                      thumbnailBytes: a.previewBytes,
                    ),
                  )
                  .toList(growable: false),
              onRemoveAttachment: _removeAttachment,
              isUploadingAttachment: _isUploadingAttachment,
              attachmentUploadProgress: _attachmentUploadProgress,
              autofocus: true,
              focusNode: _composerFocusNode,
              onChanged: _handleComposerChanged,
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyMessages(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.groups, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text('Private group chat', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Messages are end-to-end encrypted and fanned out to members.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

class _ReplyComposerPreview extends StatelessWidget {
  const _ReplyComposerPreview({required this.message, required this.onCancel});

  final ChatMessage message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = message.isOutgoing ? 'You' : 'Them';
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: theme.colorScheme.primary, width: 2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    author,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    buildAttachmentAwarePreview(message.text, maxLength: 120),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Cancel reply',
            onPressed: onCancel,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _PendingAttachment {
  const _PendingAttachment({
    required this.filename,
    required this.link,
    required this.prepared,
    this.previewBytes,
    this.uploaded = false,
  });

  final String filename;
  final String link;
  final HashtreePreparedAttachment prepared;
  final Uint8List? previewBytes;
  final bool uploaded;

  _PendingAttachment copyWith({bool? uploaded}) {
    return _PendingAttachment(
      filename: filename,
      link: link,
      prepared: prepared,
      previewBytes: previewBytes,
      uploaded: uploaded ?? this.uploaded,
    );
  }
}

class _InviteBanner extends StatelessWidget {
  const _InviteBanner({required this.onAccept});

  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Group invitation. Accept to start chatting.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            FilledButton(onPressed: onAccept, child: const Text('Accept')),
          ],
        ),
      ),
    );
  }
}

class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final diff = now.difference(date);

    String text;
    if (diff.inDays == 0) {
      text = 'Today';
    } else if (diff.inDays == 1) {
      text = 'Yesterday';
    } else {
      text = '${date.day}/${date.month}/${date.year}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
