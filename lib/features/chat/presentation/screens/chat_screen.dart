import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../config/providers/auth_provider.dart';
import '../../../../config/providers/chat_provider.dart';
import '../../../../config/providers/hashtree_attachment_provider.dart';
import '../../../../config/providers/imgproxy_settings_provider.dart';
import '../../../../config/providers/nostr_provider.dart';
import '../../../../core/services/hashtree_attachment_service.dart';
import '../../../../core/services/imgproxy_service.dart';
import '../../../../core/utils/hashtree_attachments.dart';
import '../../../../shared/utils/formatters.dart';
import '../../../../shared/widgets/image_viewer_modal.dart';
import '../../domain/models/message.dart';
import '../../domain/models/session.dart';
import '../../domain/utils/chat_settings.dart';
import '../utils/attachment_upload.dart';
import '../utils/seen_sync_mixin.dart';
import '../widgets/chat_message_bubble.dart';
import '../widgets/chats_back_button.dart';
import '../widgets/message_input.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/typing_dots.dart';

/// Estimated height for a typical message bubble.
/// Used for ListView performance optimization.
const double _kEstimatedMessageHeight = 80.0;

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with SeenSyncMixin<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _composerFocusNode = FocusNode();
  final List<_PendingAttachment> _pendingAttachments = [];
  bool _isAtBottom = true;
  bool _isUploadingAttachment = false;
  bool _composerHadText = false;
  bool _didInitializeTtlObservation = false;
  int? _lastObservedTtlSeconds;
  final List<_DisappearingNoticeEntry> _disappearingNotices = [];
  int _nextNoticeSequence = 0;
  DateTime? _pinBottomUntil;
  ChatMessage? _replyingTo;
  int _lastTimelineEntryCount = 0;
  DateTime? _lastTimelineEntryTimestamp;

  @override
  void initState() {
    super.initState();
    initSeenSyncObserver();
    _scrollController.addListener(_onScroll);

    // Load initial message history after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_reloadConversationState());
    });
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId == widget.sessionId) return;
    unawaited(_reloadConversationState());
  }

  Future<void> _reloadConversationState() async {
    await ref.read(chatStateProvider.notifier).loadMessages(widget.sessionId);
    scheduleSeenSync();
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
    final messages = ref.read(sessionMessagesProvider(widget.sessionId));
    return messages.any((m) => m.isIncoming && m.status != MessageStatus.seen);
  }

  @override
  bool get hasUnreadIndicator {
    final sessions = ref.read(sessionStateProvider).sessions;
    for (final session in sessions) {
      if (session.id == widget.sessionId) {
        return session.unreadCount > 0 || hasUnseenIncomingMessages;
      }
    }
    return hasUnseenIncomingMessages;
  }

  @override
  Future<void> markConversationSeen() {
    return ref
        .read(chatStateProvider.notifier)
        .markSessionSeen(widget.sessionId);
  }

  @override
  Future<void> afterConversationSeen() {
    return ref
        .read(sessionStateProvider.notifier)
        .clearUnread(widget.sessionId);
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

  void _scrollToTimelineMessage(
    List<_TimelineEntry> entries,
    String messageId,
  ) {
    if (!_scrollController.hasClients) return;
    final targetIndex = entries.indexWhere((entry) {
      final message = entry.message;
      if (message == null) return false;
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
          .read(chatStateProvider.notifier)
          .notifyTypingStopped(widget.sessionId);
    }
    setState(() {
      _pendingAttachments.clear();
      _replyingTo = null;
    });

    // Scroll now (for composer reset) and again after optimistic message insert.
    _scheduleScrollToBottom();

    // Send message via provider (handles optimistic update, encryption, and Nostr)
    await ref
        .read(chatStateProvider.notifier)
        .sendMessage(widget.sessionId, content, replyToId: replyToId);
    for (final attachment in attachmentsToSend) {
      if (attachment.uploaded) continue;
      unawaited(_uploadAttachmentOnce(attachment, showFailureSnack: false));
    }
    _scheduleScrollToBottom();

    // Update session metadata
    final messages = ref.read(sessionMessagesProvider(widget.sessionId));
    if (messages.isNotEmpty) {
      await ref
          .read(sessionStateProvider.notifier)
          .updateSessionWithMessage(widget.sessionId, messages.last);
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
      final attachmentService = ref.read(hashtreeAttachmentServiceProvider);
      final prepared = await preparePickedAttachment(
        pickedFile: file,
        service: attachmentService,
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
    final notifier = ref.read(chatStateProvider.notifier);
    if (hasText) {
      _composerHadText = true;
      notifier.notifyTyping(widget.sessionId);
    } else {
      if (!_composerHadText) return;
      _composerHadText = false;
      notifier.notifyTypingStopped(widget.sessionId);
    }
  }

  static const _expirationOptions = <int>[
    5 * 60, // 5 minutes
    60 * 60, // 1 hour
    24 * 60 * 60, // 24 hours
    7 * 24 * 60 * 60, // 1 week
    30 * 24 * 60 * 60, // 1 month
    90 * 24 * 60 * 60, // 3 months
  ];

  static String _ttlLabel(int? ttlSeconds) {
    return chatSettingsTtlLabel(ttlSeconds);
  }

  void _maybeNotifyDisappearingSettingsChange(int? ttlSeconds) {
    final normalized = (ttlSeconds != null && ttlSeconds > 0)
        ? ttlSeconds
        : null;

    if (!_didInitializeTtlObservation) {
      _didInitializeTtlObservation = true;
      _lastObservedTtlSeconds = normalized;
      return;
    }

    if (_lastObservedTtlSeconds == normalized) return;
    _lastObservedTtlSeconds = normalized;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _disappearingNotices.add(
          _DisappearingNoticeEntry(
            text: chatSettingsChangedNotice(normalized),
            timestamp: DateTime.now(),
            sequence: _nextNoticeSequence++,
          ),
        );
      });
      _scrollToBottom();
    });
  }

  List<_TimelineEntry> _buildTimelineEntries(List<ChatMessage> messages) {
    final entries = <_TimelineEntry>[
      for (var i = 0; i < messages.length; i++)
        _TimelineEntry.message(message: messages[i], sequence: i),
      for (final notice in _disappearingNotices)
        _TimelineEntry.notice(
          notice: notice,
          sequence: messages.length + notice.sequence,
        ),
    ];
    entries.sort((a, b) {
      final byTime = a.timestamp.compareTo(b.timestamp);
      if (byTime != 0) return byTime;
      return a.sequence.compareTo(b.sequence);
    });
    return entries;
  }

  void _maybeAutoScrollForNewTimelineEntries(List<_TimelineEntry> entries) {
    if (entries.isEmpty) {
      _lastTimelineEntryCount = 0;
      _lastTimelineEntryTimestamp = null;
      return;
    }

    final latest = entries.last.timestamp;
    final hasNewEntry =
        entries.length != _lastTimelineEntryCount ||
        _lastTimelineEntryTimestamp == null ||
        latest.isAfter(_lastTimelineEntryTimestamp!);

    _lastTimelineEntryCount = entries.length;
    _lastTimelineEntryTimestamp = latest;

    if (!hasNewEntry) return;
    if (!_shouldKeepBottomPinned) return;
    _scheduleScrollToBottom(retries: 4);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(profileUpdatesProvider);
    final profileService = ref.watch(profileServiceProvider);
    // Optimized: Use select() to only watch the specific session we need,
    // avoiding rebuilds when other sessions change
    final session = ref.watch(
      sessionStateProvider.select(
        (state) => state.sessions.firstWhere(
          (s) => s.id == widget.sessionId,
          orElse: () => throw Exception('Session not found'),
        ),
      ),
    );
    final messages = ref.watch(sessionMessagesProvider(widget.sessionId));
    scheduleSeenSync();
    final isTyping = ref.watch(
      chatStateProvider.select(
        (s) =>
            (s.typingStates[widget.sessionId] ?? false) ||
            (s.typingStates[session.recipientPubkeyHex.toLowerCase().trim()] ??
                false),
      ),
    );
    _maybeNotifyDisappearingSettingsChange(session.messageTtlSeconds);
    final profile = profileService.getCachedProfile(session.recipientPubkeyHex);
    final sessionDisplayName = profile?.bestName ?? session.displayName;
    final sessionPicture = profile?.picture;
    final timelineEntries = _buildTimelineEntries(messages);
    _maybeAutoScrollForNewTimelineEntries(timelineEntries);
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

    return Scaffold(
      appBar: AppBar(
        leading: ChatsBackButton(excludeSessionId: widget.sessionId),
        title: InkWell(
          key: const Key('chat-header-info-button'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => _showSessionInfo(
            context,
            session,
            displayName: sessionDisplayName,
            pictureUrl: sessionPicture,
          ),
          child: Row(
            children: [
              ProfileAvatar(
                pubkeyHex: session.recipientPubkeyHex,
                displayName: sessionDisplayName,
                pictureUrl: sessionPicture,
                radius: 16,
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundTextColor: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  sessionDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: timelineEntries.isEmpty
                ? _buildEmptyMessages(theme)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: timelineEntries.length,
                    // Performance: Add cacheExtent for smoother scrolling
                    cacheExtent: _kEstimatedMessageHeight * 5,
                    // Performance: addAutomaticKeepAlives helps with message state preservation
                    addAutomaticKeepAlives: true,
                    itemBuilder: (context, index) {
                      final entry = timelineEntries[index];
                      final message = entry.message;
                      final replyToMessage =
                          message?.replyToId != null &&
                              message!.replyToId!.isNotEmpty
                          ? messageById[message.replyToId!]
                          : null;
                      final showDate =
                          index == 0 ||
                          !_isSameDay(
                            timelineEntries[index - 1].timestamp,
                            entry.timestamp,
                          );

                      final rowKey = message != null
                          ? ValueKey(
                              'timeline_message_${message.id}_${message.timestamp.microsecondsSinceEpoch}_$index',
                            )
                          : ValueKey(
                              'timeline_notice_${entry.notice!.sequence}_${entry.notice!.timestamp.microsecondsSinceEpoch}_$index',
                            );

                      return Column(
                        key: rowKey,
                        children: [
                          if (showDate) _DateSeparator(date: entry.timestamp),
                          if (message != null)
                            ChatMessageBubble(
                              key: ValueKey(
                                'bubble_${message.id}_${message.timestamp.microsecondsSinceEpoch}_$index',
                              ),
                              message: message,
                              replyToMessage: replyToMessage,
                              onOpenReply: replyToMessage == null
                                  ? null
                                  : () => _scrollToTimelineMessage(
                                      timelineEntries,
                                      replyToMessage.id,
                                    ),
                              onMediaLayoutChanged:
                                  _onMessageMediaLayoutChanged,
                              onReply: () => _quoteReply(message),
                              onReact: (emoji) async {
                                final myPubkey =
                                    ref.read(authStateProvider).pubkeyHex ??
                                    'me';
                                await ref
                                    .read(chatStateProvider.notifier)
                                    .sendReaction(
                                      widget.sessionId,
                                      message.id,
                                      emoji,
                                      myPubkey,
                                    );
                              },
                              onDeleteLocal: () async {
                                await ref
                                    .read(chatStateProvider.notifier)
                                    .deleteMessageLocal(
                                      widget.sessionId,
                                      message.id,
                                    );
                                await ref
                                    .read(sessionStateProvider.notifier)
                                    .refreshSession(widget.sessionId);
                              },
                            )
                          else
                            _TimelineNoticeRow(text: entry.notice!.text),
                        ],
                      );
                    },
                  ),
          ),

          // Scroll to bottom button
          if (!_isAtBottom && timelineEntries.isNotEmpty)
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

          // Message input
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
            Icon(
              Icons.lock_outline,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('End-to-end encrypted', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Messages in this chat are secured with Double Ratchet encryption.',
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

  bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
  }

  void _showSessionInfo(
    BuildContext context,
    ChatSession session, {
    required String displayName,
    String? pictureUrl,
  }) {
    final theme = Theme.of(context);
    int? selectedTtl = session.messageTtlSeconds;
    bool isSavingTtl = false;
    final normalizedPicture = pictureUrl?.trim();
    final hasProfilePicture =
        normalizedPicture != null &&
        normalizedPicture.isNotEmpty &&
        _isHttpUrl(normalizedPicture);
    final imgproxyState = ref.read(imgproxySettingsProvider);
    final imgproxyService = ImgproxyService(imgproxyState.config);
    final viewerPictureUrl = hasProfilePicture
        ? imgproxyService.proxiedUrl(normalizedPicture)
        : null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> applyTtl(int? ttlSeconds) async {
            if (isSavingTtl) return;
            final normalized = (ttlSeconds != null && ttlSeconds > 0)
                ? ttlSeconds
                : null;
            if (selectedTtl == normalized) return;

            setSheetState(() {
              selectedTtl = normalized;
              isSavingTtl = true;
            });
            await ref
                .read(sessionStateProvider.notifier)
                .setMessageTtlSeconds(session.id, normalized);
            await ref
                .read(chatStateProvider.notifier)
                .sendChatSettingsSignal(session.id, normalized);
            if (!context.mounted) return;
            setSheetState(() {
              isSavingTtl = false;
            });
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        hasProfilePicture && viewerPictureUrl != null
                            ? InkResponse(
                                key: const ValueKey('user_info_avatar_button'),
                                onTap: () => showImageViewerModal(
                                  context,
                                  imageProvider: NetworkImage(viewerPictureUrl),
                                ),
                                radius: 34,
                                customBorder: const CircleBorder(),
                                child: ProfileAvatar(
                                  pubkeyHex: session.recipientPubkeyHex,
                                  displayName: displayName,
                                  pictureUrl: pictureUrl,
                                  radius: 28,
                                  backgroundColor:
                                      theme.colorScheme.primaryContainer,
                                  foregroundTextColor:
                                      theme.colorScheme.onPrimaryContainer,
                                ),
                              )
                            : ProfileAvatar(
                                pubkeyHex: session.recipientPubkeyHex,
                                displayName: displayName,
                                pictureUrl: pictureUrl,
                                radius: 28,
                                backgroundColor:
                                    theme.colorScheme.primaryContainer,
                                foregroundTextColor:
                                    theme.colorScheme.onPrimaryContainer,
                              ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                displayName,
                                style: theme.textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    Icons.lock,
                                    size: 14,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'End-to-end encrypted',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _InfoRow(
                      label: 'Public Key',
                      value: formatPubkeyAsNpub(session.recipientPubkeyHex),
                      copyable: true,
                    ),
                    const SizedBox(height: 12),
                    _InfoRow(
                      label: 'Session Created',
                      value: formatDate(session.createdAt),
                    ),
                    if (session.inviteId != null) ...[
                      const SizedBox(height: 12),
                      _InfoRow(label: 'Invite ID', value: session.inviteId!),
                    ],
                    const SizedBox(height: 24),
                    Text(
                      'Disappearing messages',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'New messages will disappear after the selected time.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ExpirationOptionTile(
                      label: 'Off',
                      selected: selectedTtl == null,
                      onTap: isSavingTtl ? null : () => applyTtl(null),
                    ),
                    const Divider(),
                    ..._expirationOptions.map((ttl) {
                      return _ExpirationOptionTile(
                        label: _ttlLabel(ttl),
                        selected: selectedTtl == ttl,
                        onTap: isSavingTtl ? null : () => applyTtl(ttl),
                      );
                    }),
                    if (isSavingTtl)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Updating…',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                        label: const Text('Close'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
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

class _DisappearingNoticeEntry {
  const _DisappearingNoticeEntry({
    required this.text,
    required this.timestamp,
    required this.sequence,
  });

  final String text;
  final DateTime timestamp;
  final int sequence;
}

class _TimelineEntry {
  _TimelineEntry.message({
    required ChatMessage this.message,
    required this.sequence,
  }) : notice = null,
       timestamp = message.timestamp;
  _TimelineEntry.notice({
    required _DisappearingNoticeEntry this.notice,
    required this.sequence,
  }) : message = null,
       timestamp = notice.timestamp;

  final ChatMessage? message;
  final _DisappearingNoticeEntry? notice;
  final DateTime timestamp;
  final int sequence;
}

class _TimelineNoticeRow extends StatelessWidget {
  const _TimelineNoticeRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpirationOptionTile extends StatelessWidget {
  const _ExpirationOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: selected
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}

class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.date});

  final DateTime date;

  static const _padding = EdgeInsets.symmetric(vertical: 16);
  static const _containerPadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 4,
  );
  static const _borderRadius = BorderRadius.all(Radius.circular(12));

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
      padding: _padding,
      child: Center(
        child: Container(
          padding: _containerPadding,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: _borderRadius,
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.copyable = false,
  });

  final String label;
  final String value;
  final bool copyable;

  static const _copyIcon = Icon(Icons.copy, size: 18);
  static const _labelWidth = 100.0;
  static const _copiedSnackBar = SnackBar(content: Text('Copied to clipboard'));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _labelWidth,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: copyable ? 'monospace' : null,
            ),
          ),
        ),
        if (copyable)
          IconButton(
            icon: _copyIcon,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(_copiedSnackBar);
              }
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
      ],
    );
  }
}
