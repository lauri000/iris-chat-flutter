part of 'chat_provider.dart';

class _AlwaysFocusedAppFocusState implements AppFocusState {
  const _AlwaysFocusedAppFocusState();

  @override
  bool get isAppFocused => true;
}

/// Notifier for chat messages.
class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier(
    this._messageDatasource,
    this._sessionDatasource,
    this._sessionManagerService, {
    DesktopNotificationService? desktopNotificationService,
    InboundActivityPolicy? inboundActivityPolicy,
  }) : _desktopNotificationService =
           desktopNotificationService ?? const NoopDesktopNotificationService(),
       _inboundActivityPolicy =
           inboundActivityPolicy ??
           InboundActivityPolicy(
             appFocusState: const _AlwaysFocusedAppFocusState(),
             appOpenedAt: DateTime.now(),
           ),
       super(const ChatState());

  final MessageLocalDatasource _messageDatasource;
  final SessionLocalDatasource _sessionDatasource;
  final SessionManagerService _sessionManagerService;
  final DesktopNotificationService _desktopNotificationService;
  final InboundActivityPolicy _inboundActivityPolicy;

  static const int _kReactionKind = 7;
  static const int _kChatMessageKind = 14;
  static const int _kReceiptKind = 15;
  static const int _kTypingKind = 25;

  static const Duration _kTypingExpiry = Duration(seconds: 10);
  static const Duration _kTypingThrottle = Duration(seconds: 3);

  final Map<String, Timer> _typingExpiryTimers = {};
  final Map<String, int> _lastTypingSentAtMs = {};
  final Map<String, int> _lastRemoteMessageAtMs = {};
  bool _typingIndicatorsEnabled = true;
  bool _deliveryReceiptsEnabled = true;
  bool _readReceiptsEnabled = true;
  bool _desktopNotificationsEnabled = true;

  Future<void> _armPeerSession(String recipientPubkeyHex) async {
    final normalized = recipientPubkeyHex.trim().toLowerCase();
    if (normalized.isEmpty) return;
    try {
      await _sessionManagerService.setupUser(normalized);
    } catch (_) {}
  }

  void setOutboundSignalSettings({
    required bool typingIndicatorsEnabled,
    required bool deliveryReceiptsEnabled,
    required bool readReceiptsEnabled,
    required bool desktopNotificationsEnabled,
  }) {
    _typingIndicatorsEnabled = typingIndicatorsEnabled;
    _deliveryReceiptsEnabled = deliveryReceiptsEnabled;
    _readReceiptsEnabled = readReceiptsEnabled;
    _desktopNotificationsEnabled = desktopNotificationsEnabled;
  }

  @override
  void dispose() {
    for (final t in _typingExpiryTimers.values) {
      t.cancel();
    }
    _typingExpiryTimers.clear();
    _lastRemoteMessageAtMs.clear();
    super.dispose();
  }

  /// Load messages for a session.
  Future<void> loadMessages(String sessionId, {int limit = 50}) async {
    try {
      final messages = await _messageDatasource.getMessagesForSession(
        sessionId,
        limit: limit,
      );
      state = state.copyWith(
        messages: {...state.messages, sessionId: messages},
        error: null,
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  /// Load more messages (pagination).
  Future<void> loadMoreMessages(String sessionId, {int limit = 50}) async {
    final currentMessages = state.messages[sessionId] ?? [];
    if (currentMessages.isEmpty) {
      return loadMessages(sessionId, limit: limit);
    }

    try {
      final oldestMessage = currentMessages.first;
      final olderMessages = await _messageDatasource.getMessagesForSession(
        sessionId,
        limit: limit,
        beforeId: oldestMessage.id,
      );

      state = state.copyWith(
        messages: {
          ...state.messages,
          sessionId: [...olderMessages, ...currentMessages],
        },
        error: null,
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  /// Remove expired messages from in-memory state.
  ///
  /// Persistent storage cleanup is handled elsewhere; this only updates UI state.
  void purgeExpiredFromState(int nowSeconds) {
    if (state.messages.isEmpty) return;

    var changed = false;
    final updatedBySession = <String, List<ChatMessage>>{};

    for (final entry in state.messages.entries) {
      final filtered = entry.value
          .where((m) => m.expiresAt == null || m.expiresAt! > nowSeconds)
          .toList();
      if (filtered.length != entry.value.length) changed = true;
      updatedBySession[entry.key] = filtered;
    }

    if (!changed) return;
    state = state.copyWith(messages: updatedBySession);
  }

  /// Add a message optimistically.
  void addMessageOptimistic(ChatMessage message) {
    final sessionId = message.sessionId;
    final currentMessages = state.messages[sessionId] ?? [];

    state = state.copyWith(
      messages: {
        ...state.messages,
        sessionId: [...currentMessages, message],
      },
      sendingStates: {...state.sendingStates, message.id: true},
    );
  }

  /// Send a message.
  Future<void> sendMessage(
    String sessionId,
    String text, {
    String? replyToId,
  }) async {
    // Create optimistic message
    final normalizedReplyTo = (replyToId != null && replyToId.trim().isNotEmpty)
        ? replyToId.trim()
        : null;
    final message = ChatMessage.outgoing(
      sessionId: sessionId,
      text: text,
      replyToId: normalizedReplyTo,
    );

    // Add to UI immediately
    addMessageOptimistic(message);

    await _sendMessageInternal(message);
  }

  /// Delete a message locally (UI + local DB only).
  Future<void> deleteMessageLocal(String sessionId, String messageId) async {
    final current = state.messages[sessionId] ?? const <ChatMessage>[];
    if (current.isEmpty) return;

    final updated = current.where((m) => m.id != messageId).toList();
    final nextMessages = {...state.messages};
    if (updated.isEmpty) {
      nextMessages.remove(sessionId);
    } else {
      nextMessages[sessionId] = updated;
    }

    final nextSending = {...state.sendingStates}..remove(messageId);
    state = state.copyWith(messages: nextMessages, sendingStates: nextSending);

    try {
      await _messageDatasource.deleteMessage(messageId);
      // Keep session list consistent if the last message was deleted.
      await _sessionDatasource.recomputeDerivedFieldsFromMessages(sessionId);
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  /// Remove all in-memory state for a deleted session.
  void removeSessionState(String sessionId, {String? recipientPubkeyHex}) {
    final removedMessages = state.messages[sessionId] ?? const <ChatMessage>[];

    final nextMessages = {...state.messages}..remove(sessionId);
    final nextSending = {...state.sendingStates};
    for (final message in removedMessages) {
      nextSending.remove(message.id);
    }

    final keys = _typingKeysForSession(
      sessionId,
      recipientPubkeyHex: recipientPubkeyHex,
    );
    final nextTyping = {...state.typingStates};
    for (final key in keys) {
      _typingExpiryTimers[key]?.cancel();
      _typingExpiryTimers.remove(key);
      _lastRemoteMessageAtMs.remove(key);
      nextTyping.remove(key);
    }
    _lastTypingSentAtMs.remove(sessionId);

    state = state.copyWith(
      messages: nextMessages,
      sendingStates: nextSending,
      typingStates: nextTyping,
    );
  }

  /// Send a queued message (called by OfflineQueueService).
  Future<void> sendQueuedMessage(
    String sessionId,
    String text,
    String messageId,
  ) async {
    // Find existing message or create placeholder
    final existingMessages = state.messages[sessionId] ?? [];
    final existingMessage = existingMessages.cast<ChatMessage?>().firstWhere(
      (m) => m?.id == messageId,
      orElse: () => null,
    );

    if (existingMessage != null) {
      // Update to pending and send
      final pendingMessage = existingMessage.copyWith(
        status: MessageStatus.pending,
      );
      await _sendMessageInternal(pendingMessage);
    } else {
      // Message not in state, create it
      final message = ChatMessage(
        id: messageId,
        sessionId: sessionId,
        text: text,
        timestamp: DateTime.now(),
        direction: MessageDirection.outgoing,
        status: MessageStatus.pending,
      );
      addMessageOptimistic(message);
      await _sendMessageInternal(message);
    }
  }

  Future<void> _sendMessageInternal(ChatMessage message) async {
    int? expiresAtSeconds;
    try {
      final session = await _sessionDatasource.getSession(message.sessionId);
      if (session == null) {
        throw const AppError(
          type: AppErrorType.sessionExpired,
          message: 'Session not found. Please start a new conversation.',
          isRetryable: false,
        );
      }

      final ttlSeconds = session.messageTtlSeconds;
      expiresAtSeconds = (ttlSeconds != null && ttlSeconds > 0)
          ? (DateTime.now().millisecondsSinceEpoch ~/ 1000 + ttlSeconds)
          : null;

      final normalizedReplyTo =
          (message.replyToId != null && message.replyToId!.trim().isNotEmpty)
          ? message.replyToId!.trim()
          : null;

      final sendResult = normalizedReplyTo == null
          // Fast path for normal messages.
          ? await _sessionManagerService.sendTextWithInnerId(
              recipientPubkeyHex: session.recipientPubkeyHex,
              text: message.text,
              expiresAtSeconds: expiresAtSeconds,
            )
          // Replies are sent with explicit tags, aligned with iris-chat / iris-client.
          : await _sessionManagerService.sendEventWithInnerId(
              recipientPubkeyHex: session.recipientPubkeyHex,
              kind: _kChatMessageKind,
              content: message.text,
              tagsJson: jsonEncode([
                ['p', session.recipientPubkeyHex],
                ['e', normalizedReplyTo, '', 'reply'],
                if (expiresAtSeconds != null)
                  ['expiration', expiresAtSeconds.toString()],
              ]),
              createdAtSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            );

      final outerEventIds = sendResult.outerEventIds;
      final eventId = outerEventIds.isNotEmpty ? outerEventIds.first : null;
      final rumorId = sendResult.innerId.isNotEmpty ? sendResult.innerId : null;

      // Update message with success
      final sentMessage = message.copyWith(
        // `outerEventIds` can be empty even when the send succeeded (queued/offline
        // publishes, relays without ACKs, etc). Treat a successful send call as
        // "sent" and rely on receipts / self-echo backfill to advance further.
        status: MessageStatus.sent,
        eventId: eventId,
        rumorId: rumorId,
        expiresAt: expiresAtSeconds,
      );
      await updateMessage(sentMessage);
    } catch (e, st) {
      // Map to user-friendly error
      final appError = e is AppError ? e : AppError.from(e, st);

      // Update message with failure
      final failedMessage = message.copyWith(
        status: MessageStatus.failed,
        expiresAt: expiresAtSeconds ?? message.expiresAt,
      );
      await updateMessage(failedMessage);
      state = state.copyWith(error: appError.message);

      // Re-throw so queue service knows to retry
      rethrow;
    }
  }

  /// Receive a decrypted message from the session manager.
  Future<ChatMessage?> receiveDecryptedMessage(
    String senderPubkeyHex,
    String content, {
    String? eventId,
    int? createdAt,
  }) async {
    try {
      if (!mounted) return null;
      final hasDuplicateOuterEvent =
          eventId != null && await _messageDatasource.messageExists(eventId);
      if (!mounted) return null;

      final rumor = NostrRumor.tryParse(content);

      // Legacy fallback: treat decrypted plaintext as a chat message.
      if (rumor == null) {
        if (hasDuplicateOuterEvent) return null;
        if (!mounted) return null;
        final existingSession = await _sessionDatasource.getSessionByRecipient(
          senderPubkeyHex,
        );
        if (!mounted) return null;
        final sessionId = existingSession?.id ?? senderPubkeyHex;

        if (existingSession == null) {
          final session = ChatSession(
            id: sessionId,
            recipientPubkeyHex: senderPubkeyHex,
            createdAt: DateTime.now(),
            isInitiator: false,
          );
          await _sessionDatasource.saveSession(session);
        }
        await _armPeerSession(senderPubkeyHex);

        final timestamp = createdAt != null
            ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000)
            : DateTime.now();

        final reactionPayload = parseReactionPayload(content);
        if (reactionPayload != null) {
          await handleIncomingReaction(
            sessionId,
            reactionPayload['messageId'] as String,
            reactionPayload['emoji'] as String,
            senderPubkeyHex,
            timestamp: timestamp,
          );
          return null;
        }

        final resolvedEventId =
            eventId ?? DateTime.now().microsecondsSinceEpoch.toString();
        final message = ChatMessage.incoming(
          sessionId: sessionId,
          text: content,
          eventId: resolvedEventId,
          rumorId: resolvedEventId,
          timestamp: timestamp,
        );

        await addReceivedMessage(message);
        return message;
      }

      if (hasDuplicateOuterEvent && rumor.kind != _kChatMessageKind) {
        return null;
      }

      final ownerPubkeyHex = _sessionManagerService.ownerPubkeyHex;
      _debugChatLog(
        'receiveDecryptedMessage sender=$senderPubkeyHex rumorPubkey=${rumor.pubkey} kind=${rumor.kind} p=${getFirstTagValue(rumor.tags, 'p') ?? ""} owner=${ownerPubkeyHex ?? ""}',
      );
      final peerPubkeyHex = await _resolveConversationPeerPubkey(
        senderPubkeyHex: senderPubkeyHex,
        rumor: rumor,
        ownerPubkeyHex: ownerPubkeyHex,
      );
      if (!mounted) return null;

      if (peerPubkeyHex == null || peerPubkeyHex.isEmpty) {
        _debugChatLog(
          'receiveDecryptedMessage unresolved sender=$senderPubkeyHex rumorPubkey=${rumor.pubkey} rumorId=${rumor.id}',
        );
        return null;
      }
      await _armPeerSession(peerPubkeyHex);

      // Find or create session by recipient pubkey (peer pubkey).
      if (!mounted) return null;
      final existingSession = await _sessionDatasource.getSessionByRecipient(
        peerPubkeyHex,
      );
      if (!mounted) return null;
      final sessionId = existingSession?.id ?? peerPubkeyHex;
      _debugChatLog(
        'receiveDecryptedMessage resolvedPeer=$peerPubkeyHex sessionId=$sessionId existing=${existingSession != null}',
      );

      if (existingSession == null) {
        final session = ChatSession(
          id: sessionId,
          recipientPubkeyHex: peerPubkeyHex,
          createdAt: DateTime.now(),
          isInitiator: false,
        );
        await _sessionDatasource.saveSession(session);
      }

      // Receipt (kind 15): update outgoing message status by stable rumor ids.
      if (rumor.kind == _kReceiptKind) {
        final receiptType = rumor.content;
        final messageIds = getTagValues(rumor.tags, 'e');
        if (messageIds.isEmpty) return null;

        final nextStatus = switch (receiptType) {
          'delivered' => MessageStatus.delivered,
          'seen' => MessageStatus.seen,
          _ => null,
        };
        if (nextStatus == null) return null;

        final ownerPubkeyHex = _sessionManagerService.ownerPubkeyHex
            ?.toLowerCase()
            .trim();
        final rumorPubkeyHex = rumor.pubkey.toLowerCase().trim();
        final senderPubkey = senderPubkeyHex.toLowerCase().trim();
        final recipientPubkey = peerPubkeyHex.toLowerCase().trim();
        final pTagPubkey = getFirstTagValue(
          rumor.tags,
          'p',
        )?.toLowerCase().trim();

        final isDirectSelfReceipt =
            ownerPubkeyHex != null &&
            ownerPubkeyHex.isNotEmpty &&
            (rumorPubkeyHex == ownerPubkeyHex ||
                senderPubkey == ownerPubkeyHex);

        // Sender-copy receipts from another own device can be surfaced through
        // the peer chat stream. When p-tag points to this chat peer (not us),
        // treat the receipt as self for cross-device seen sync.
        final isSenderCopySelfReceipt =
            ownerPubkeyHex != null &&
            ownerPubkeyHex.isNotEmpty &&
            pTagPubkey != null &&
            pTagPubkey.isNotEmpty &&
            pTagPubkey != ownerPubkeyHex &&
            pTagPubkey == recipientPubkey;

        final targetDirection = (isDirectSelfReceipt || isSenderCopySelfReceipt)
            ? MessageDirection.incoming
            : MessageDirection.outgoing;

        for (final id in messageIds.toSet()) {
          await _applyMessageStatusByRumorId(
            id,
            nextStatus,
            direction: targetDirection,
          );
        }

        if (targetDirection == MessageDirection.incoming &&
            nextStatus == MessageStatus.seen) {
          try {
            await _sessionDatasource.recomputeDerivedFieldsFromMessages(
              sessionId,
            );
          } catch (_) {}
        }
        return null;
      }

      // Typing indicator (kind 25)
      if (rumor.kind == _kTypingKind) {
        if (ownerPubkeyHex != null && rumor.pubkey == ownerPubkeyHex) {
          // Ignore self typing events (multi-device sync).
          return null;
        }
        final expiresAtSeconds = getExpirationTimestampSeconds(rumor.tags);
        final isStopEvent = isTypingStopRumor(
          rumor,
          expiresAtSeconds: expiresAtSeconds,
        );

        if (isStopEvent) {
          _clearRemoteTyping(sessionId, recipientPubkeyHex: peerPubkeyHex);
        } else {
          _setRemoteTyping(
            sessionId,
            recipientPubkeyHex: peerPubkeyHex,
            typingTimestampMs: rumorTimestamp(rumor).millisecondsSinceEpoch,
          );
        }
        return null;
      }

      // Reaction (kind 7) or legacy reaction payload inside kind 14.
      if (rumor.kind == _kReactionKind) {
        final messageId = getFirstTagValue(rumor.tags, 'e');
        if (messageId == null || messageId.isEmpty) return null;
        await handleIncomingReaction(
          sessionId,
          messageId,
          rumor.content,
          rumor.pubkey,
          timestamp: rumorTimestamp(rumor),
        );
        return null;
      }

      if (rumor.kind != _kChatMessageKind) {
        return null;
      }

      final ownerPubkey = ownerPubkeyHex?.toLowerCase().trim();
      final rumorPubkey = rumor.pubkey.toLowerCase().trim();
      final senderPubkey = senderPubkeyHex.toLowerCase().trim();
      final recipientPubkey = peerPubkeyHex.toLowerCase().trim();
      final pTagPubkey = getFirstTagValue(
        rumor.tags,
        'p',
      )?.toLowerCase().trim();

      final isDirectSelfMessage =
          ownerPubkey != null &&
          ownerPubkey.isNotEmpty &&
          (rumorPubkey == ownerPubkey || senderPubkey == ownerPubkey);

      // Match iris-chat behavior: sender-copy messages from another own client
      // can be surfaced through the peer chat stream instead of our owner stream.
      final isSenderCopySelfMessage =
          ownerPubkey != null &&
          ownerPubkey.isNotEmpty &&
          pTagPubkey != null &&
          pTagPubkey.isNotEmpty &&
          pTagPubkey != ownerPubkey &&
          pTagPubkey == recipientPubkey;

      final isMine = isDirectSelfMessage || isSenderCopySelfMessage;
      final messageTimestamp = rumorTimestamp(rumor);
      final messageTimestampMs = messageTimestamp.millisecondsSinceEpoch;

      if (hasDuplicateOuterEvent) {
        if (!isMine) {
          _clearRemoteTyping(
            sessionId,
            recipientPubkeyHex: peerPubkeyHex,
            messageTimestampMs: messageTimestampMs,
          );
        }
        return null;
      }

      // De-dup using stable inner id.
      if (await _messageDatasource.messageExists(rumor.id)) {
        if (!mounted) return null;
        if (!isMine) {
          _clearRemoteTyping(
            sessionId,
            recipientPubkeyHex: peerPubkeyHex,
            messageTimestampMs: messageTimestampMs,
          );
        }
        // When we receive a relay echo / self-copy of our own outgoing message,
        // use it to backfill the outer event id so reactions can reference it.
        if (isMine && eventId != null && eventId.isNotEmpty) {
          _backfillOutgoingEventId(rumor.id, eventId);
        }
        return null;
      }

      // Some clients send reactions as JSON content in kind 14; keep compatibility.
      final reactionPayload = parseReactionPayload(rumor.content);
      if (reactionPayload != null) {
        await handleIncomingReaction(
          sessionId,
          reactionPayload['messageId'] as String,
          reactionPayload['emoji'] as String,
          rumor.pubkey,
          timestamp: rumorTimestamp(rumor),
        );
        return null;
      }

      final expiresAtSeconds = getExpirationTimestampSeconds(rumor.tags);
      if (isExpirationElapsed(expiresAtSeconds)) {
        // Ignore already-expired messages; they may still be delivered by relays,
        // but clients should not surface them.
        return null;
      }
      if (!mounted) return null;

      final message = ChatMessage(
        id: rumor.id,
        sessionId: sessionId,
        text: rumor.content,
        timestamp: messageTimestamp,
        expiresAt: expiresAtSeconds,
        direction: isMine
            ? MessageDirection.outgoing
            : MessageDirection.incoming,
        status: isMine ? MessageStatus.sent : MessageStatus.delivered,
        eventId: eventId,
        rumorId: rumor.id,
        replyToId: resolveReplyToId(rumor.tags),
      );

      if (!isMine) {
        _clearRemoteTyping(
          sessionId,
          recipientPubkeyHex: peerPubkeyHex,
          messageTimestampMs: messageTimestampMs,
        );
      }

      await addReceivedMessage(message);
      _debugChatLog(
        'receiveDecryptedMessage saved rumorId=${rumor.id} sessionId=$sessionId direction=${message.direction.name}',
      );
      if (!mounted) return null;

      // Auto-send delivery receipt for incoming messages.
      if (!isMine && _deliveryReceiptsEnabled) {
        await _sessionManagerService.sendReceipt(
          recipientPubkeyHex: peerPubkeyHex,
          receiptType: 'delivered',
          messageIds: [rumor.id],
        );
      }

      if (!isMine) {
        await _notifyIncomingMessage(message);
      }

      return message;
    } catch (e, st) {
      if (!mounted) return null;
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
      return null;
    }
  }

  Future<String?> _resolveConversationPeerPubkey({
    required String senderPubkeyHex,
    required NostrRumor rumor,
    required String? ownerPubkeyHex,
  }) async {
    if (!mounted) return null;
    final owner = ownerPubkeyHex?.toLowerCase().trim();
    final sender = senderPubkeyHex.toLowerCase().trim();
    if (sender.isEmpty) return null;
    final rumorAuthor = rumor.pubkey.toLowerCase().trim();
    final pTagPubkey = getFirstTagValue(rumor.tags, 'p')?.toLowerCase().trim();

    final isSelfTargetedRumor =
        owner != null &&
        owner.isNotEmpty &&
        (rumorAuthor == owner || sender == owner) &&
        (pTagPubkey == null || pTagPubkey.isEmpty || pTagPubkey == owner);

    final candidates = owner == null
        ? <String>[sender]
        : await NdrFfi.resolveConversationCandidatePubkeys(
            ownerPubkeyHex: owner,
            rumorPubkeyHex: rumor.pubkey,
            rumorTags: rumor.tags,
            senderPubkeyHex: sender,
          );
    _debugChatLog(
      'resolveConversationPeer sender=$sender rumorPubkey=$rumorAuthor owner=${owner ?? ""} p=${pTagPubkey ?? ""} candidates=${candidates.join(",")}',
    );

    // Self-targeted rumors should stay in the owner/self conversation even if
    // there happens to be a direct session stored for one of our own devices.
    if (isSelfTargetedRumor) {
      _debugChatLog(
        'resolveConversationPeer selfTargeted owner=$owner',
      );
      return owner;
    }

    if (owner != null &&
        sender.isNotEmpty &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(sender) &&
        sender != owner &&
        sender != rumorAuthor) {
      final senderSession = await _sessionDatasource.getSessionByRecipient(
        sender,
      );
      if (!mounted) return null;
      if (senderSession != null) {
        _debugChatLog(
          'resolveConversationPeer preferSender=$sender sessionId=${senderSession.id}',
        );
        return sender;
      }
    }

    for (final candidate in candidates) {
      if (!mounted) return null;
      if (owner != null && candidate == owner) continue;
      final existing = await _sessionDatasource.getSessionByRecipient(
        candidate,
      );
      if (!mounted) return null;
      _debugChatLog(
        'resolveConversationPeer candidate=$candidate existing=${existing != null} sessionId=${existing?.id ?? ""}',
      );
      if (existing != null) return candidate;
    }

    for (final candidate in candidates) {
      if (owner != null && candidate == owner) continue;
      if (candidate.isNotEmpty) {
        _debugChatLog('resolveConversationPeer fallback=$candidate');
        return candidate;
      }
    }

    if (owner != null && candidates.isNotEmpty && candidates.last == owner) {
      _debugChatLog('resolveConversationPeer ownerFallback=$owner');
      return owner;
    }

    return null;
  }

  Future<void> markSessionSeen(String sessionId) async {
    if (!_inboundActivityPolicy.canMarkSeen()) return;

    final session = await _sessionDatasource.getSession(sessionId);
    if (session == null) return;

    final inState = state.messages[sessionId];
    final messages = (inState == null || inState.isEmpty)
        ? await _messageDatasource.getMessagesForSession(sessionId, limit: 200)
        : inState;

    final toMark = messages
        .where((m) => m.isIncoming && m.status != MessageStatus.seen)
        .toList();
    if (toMark.isEmpty) return;

    final rumorIds = toMark
        .map((m) => m.rumorId ?? m.id)
        .where((id) => id.isNotEmpty)
        .toSet();

    if (rumorIds.isNotEmpty && _readReceiptsEnabled) {
      await _sessionManagerService.sendReceipt(
        recipientPubkeyHex: session.recipientPubkeyHex,
        receiptType: 'seen',
        messageIds: rumorIds.toList(),
      );
    }

    for (final id in rumorIds) {
      await _messageDatasource.updateIncomingStatusByRumorId(
        id,
        MessageStatus.seen,
      );
    }

    // Update in-memory state (only for messages currently loaded into state).
    final current = state.messages[sessionId];
    if (current == null) return;

    final updated = current.map((m) {
      if (!m.isIncoming) return m;
      final id = m.rumorId ?? m.id;
      if (!rumorIds.contains(id)) return m;
      if (!shouldAdvanceStatus(m.status, MessageStatus.seen)) return m;
      return m.copyWith(status: MessageStatus.seen);
    }).toList();

    state = state.copyWith(messages: {...state.messages, sessionId: updated});
  }

  Future<void> notifyTyping(String sessionId) async {
    if (!_typingIndicatorsEnabled) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final last = _lastTypingSentAtMs[sessionId] ?? 0;
    if (nowMs - last < _kTypingThrottle.inMilliseconds) return;

    _lastTypingSentAtMs[sessionId] = nowMs;

    final session = await _sessionDatasource.getSession(sessionId);
    if (session == null) return;

    await _sessionManagerService.sendTyping(
      recipientPubkeyHex: session.recipientPubkeyHex,
      expiresAtSeconds: null,
    );
  }

  Future<void> notifyTypingStopped(String sessionId) async {
    _lastTypingSentAtMs.remove(sessionId);
    if (!_typingIndicatorsEnabled) return;

    final session = await _sessionDatasource.getSession(sessionId);
    if (session == null) return;
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _sessionManagerService.sendTyping(
      recipientPubkeyHex: session.recipientPubkeyHex,
      expiresAtSeconds: nowSeconds,
    );
  }

  Set<String> _typingKeysForSession(
    String sessionId, {
    String? recipientPubkeyHex,
  }) {
    final keys = <String>{sessionId};
    final normalizedRecipient = recipientPubkeyHex?.toLowerCase().trim();
    if (normalizedRecipient != null && normalizedRecipient.isNotEmpty) {
      keys.add(normalizedRecipient);
    }
    return keys;
  }

  void _setRemoteTyping(
    String sessionId, {
    String? recipientPubkeyHex,
    int? typingTimestampMs,
  }) {
    final keys = _typingKeysForSession(
      sessionId,
      recipientPubkeyHex: recipientPubkeyHex,
    );
    final resolvedTypingTimestampMs =
        typingTimestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final applicableKeys = <String>{};
    for (final key in keys) {
      final lastMessageTimestampMs = _lastRemoteMessageAtMs[key];
      if (isTypingTimestampStale(
        typingTimestampMs: resolvedTypingTimestampMs,
        lastMessageTimestampMs: lastMessageTimestampMs,
      )) {
        continue;
      }
      applicableKeys.add(key);
    }
    if (applicableKeys.isEmpty) return;

    for (final key in applicableKeys) {
      _typingExpiryTimers[key]?.cancel();
    }

    final nextStates = {...state.typingStates};
    for (final key in applicableKeys) {
      nextStates[key] = true;
    }
    state = state.copyWith(typingStates: nextStates);

    final timer = Timer(_kTypingExpiry, () {
      final next = {...state.typingStates};
      for (final key in applicableKeys) {
        _typingExpiryTimers.remove(key);
        next.remove(key);
      }
      state = state.copyWith(typingStates: next);
    });
    for (final key in applicableKeys) {
      _typingExpiryTimers[key] = timer;
    }
  }

  void _clearRemoteTyping(
    String sessionId, {
    String? recipientPubkeyHex,
    int? messageTimestampMs,
  }) {
    final keys = _typingKeysForSession(
      sessionId,
      recipientPubkeyHex: recipientPubkeyHex,
    );

    if (messageTimestampMs != null) {
      for (final key in keys) {
        final existing = _lastRemoteMessageAtMs[key] ?? 0;
        _lastRemoteMessageAtMs[key] = messageTimestampMs > existing
            ? messageTimestampMs
            : existing;
      }
    }

    final next = {...state.typingStates};
    var changed = false;
    for (final key in keys) {
      _typingExpiryTimers[key]?.cancel();
      _typingExpiryTimers.remove(key);
      changed = next.remove(key) != null || changed;
    }
    if (!changed) return;
    state = state.copyWith(typingStates: next);
  }

  Future<void> _applyMessageStatusByRumorId(
    String rumorId,
    MessageStatus nextStatus, {
    required MessageDirection direction,
  }) async {
    if (!mounted) return;
    if (direction == MessageDirection.outgoing) {
      await _messageDatasource.updateOutgoingStatusByRumorId(
        rumorId,
        nextStatus,
      );
    } else {
      await _messageDatasource.updateIncomingStatusByRumorId(
        rumorId,
        nextStatus,
      );
    }
    if (!mounted) return;

    var changed = false;
    final updatedBySession = <String, List<ChatMessage>>{};

    for (final entry in state.messages.entries) {
      final sessionId = entry.key;
      final updated = entry.value.map((m) {
        if (m.direction != direction) return m;
        if (m.rumorId != rumorId && m.id != rumorId) return m;
        if (!shouldAdvanceStatus(m.status, nextStatus)) return m;
        changed = true;
        return m.copyWith(status: nextStatus);
      }).toList();
      updatedBySession[sessionId] = updated;
    }

    if (!changed) return;
    state = state.copyWith(messages: updatedBySession);
  }

  void _backfillOutgoingEventId(String rumorId, String eventId) {
    if (!mounted) return;
    // Update UI state immediately; persist in background.
    var changed = false;
    final updatedBySession = <String, List<ChatMessage>>{};

    for (final entry in state.messages.entries) {
      final sessionId = entry.key;
      final updated = entry.value.map((m) {
        if (!m.isOutgoing) return m;
        if (m.rumorId != rumorId && m.id != rumorId) return m;

        final nextEventId = (m.eventId == null || m.eventId!.isEmpty)
            ? eventId
            : m.eventId;
        final nextStatus = shouldAdvanceStatus(m.status, MessageStatus.sent)
            ? MessageStatus.sent
            : m.status;

        if (nextEventId == m.eventId && nextStatus == m.status) return m;
        changed = true;
        return m.copyWith(eventId: nextEventId, status: nextStatus);
      }).toList();
      updatedBySession[sessionId] = updated;
    }

    if (changed) {
      state = state.copyWith(messages: updatedBySession);
    }

    unawaited(() async {
      try {
        await _messageDatasource.updateOutgoingEventIdByRumorId(
          rumorId,
          eventId,
        );
      } catch (_) {}
    }());
  }

  Future<String> _notificationTitleForSession(String sessionId) async {
    final byId = await _sessionDatasource.getSession(sessionId);
    if (byId != null) return byId.displayName;
    final byRecipient = await _sessionDatasource.getSessionByRecipient(
      sessionId,
    );
    if (byRecipient != null) return byRecipient.displayName;
    return formatPubkeyForDisplay(sessionId);
  }

  Future<void> _notifyIncomingMessage(ChatMessage message) async {
    if (!_inboundActivityPolicy.shouldNotifyDesktopForTimestamp(
      message.timestamp,
    )) {
      return;
    }

    try {
      final title = await _notificationTitleForSession(message.sessionId);
      await _desktopNotificationService.showIncomingMessage(
        enabled: _desktopNotificationsEnabled,
        conversationTitle: title,
        body: buildAttachmentAwarePreview(message.text),
      );
    } catch (_) {}
  }

  Future<void> _notifyIncomingReaction({
    required String sessionId,
    required ChatMessage targetMessage,
    required String emoji,
  }) async {
    try {
      final title = await _notificationTitleForSession(sessionId);
      await _desktopNotificationService.showIncomingReaction(
        enabled: _desktopNotificationsEnabled,
        conversationTitle: title,
        emoji: emoji,
        targetPreview: buildAttachmentAwarePreview(targetMessage.text),
      );
    } catch (_) {}
  }

  /// Update a message (e.g., after sending succeeds).
  Future<void> updateMessage(ChatMessage message) async {
    final sessionId = message.sessionId;
    final currentMessages = state.messages[sessionId] ?? [];

    state = state.copyWith(
      messages: {
        ...state.messages,
        sessionId: currentMessages
            .map((m) => m.id == message.id ? message : m)
            .toList(),
      },
      sendingStates: {...state.sendingStates}..remove(message.id),
    );

    // Persist in background so UI doesn't stall on a locked DB.
    unawaited(() async {
      try {
        await _messageDatasource.saveMessage(message);
      } catch (_) {}
    }());
  }

  /// Add a received message.
  Future<void> addReceivedMessage(ChatMessage message) async {
    if (!mounted) return;
    // Check if message already exists
    final dedupeKey = message.rumorId ?? message.eventId ?? message.id;
    if (await _messageDatasource.messageExists(dedupeKey)) return;
    if (!mounted) return;

    await _messageDatasource.saveMessage(message);
    if (!mounted) return;

    final sessionId = message.sessionId;
    final currentMessages = state.messages[sessionId] ?? [];

    state = state.copyWith(
      messages: {
        ...state.messages,
        sessionId: [...currentMessages, message],
      },
    );
  }

  /// Send a reaction to a message.
  /// Prefer stable inner rumor ids for cross-client compatibility.
  Future<void> sendReaction(
    String sessionId,
    String messageId,
    String emoji,
    String myPubkey,
  ) async {
    try {
      // Find the message to get its eventId (Nostr event ID)
      final messages = state.messages[sessionId] ?? [];
      final message = messages.firstWhere(
        (m) => m.id == messageId,
        orElse: () => throw const AppError(
          type: AppErrorType.unknown,
          message: 'Message not found',
          isRetryable: false,
        ),
      );

      // Use stable inner ids first; many clients index reactions by inner rumor id.
      // Fall back to outer id for older locally-stored messages.
      final reactionMessageId =
          (message.rumorId != null && message.rumorId!.isNotEmpty)
          ? message.rumorId!
          : (message.eventId != null && message.eventId!.isNotEmpty)
          ? message.eventId!
          : null;
      if (reactionMessageId == null) {
        throw const AppError(
          type: AppErrorType.unknown,
          message:
              'Message not yet ready for reactions. Try again in a moment.',
          isRetryable: true,
        );
      }

      final session = await _sessionDatasource.getSession(sessionId);
      if (session == null) {
        throw const AppError(
          type: AppErrorType.sessionExpired,
          message: 'Session not found. Please start a new conversation.',
          isRetryable: false,
        );
      }

      await _sessionManagerService.sendReaction(
        recipientPubkeyHex: session.recipientPubkeyHex,
        messageId: reactionMessageId,
        emoji: emoji,
      );

      // Update reaction optimistically (use internal ID for state management)
      await _applyReaction(sessionId, messageId, emoji, myPubkey);
    } catch (e, st) {
      final appError = e is AppError ? e : AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  /// Send a 1:1 "chat-settings" rumor (kind 10448) to coordinate disappearing messages.
  ///
  /// This does not update local state; callers should persist `messageTtlSeconds`
  /// on the session separately (so sending can apply the setting immediately).
  Future<void> sendChatSettingsSignal(
    String sessionId,
    int? messageTtlSeconds,
  ) async {
    try {
      final session = await _sessionDatasource.getSession(sessionId);
      if (session == null) {
        throw const AppError(
          type: AppErrorType.sessionExpired,
          message: 'Session not found. Please start a new conversation.',
          isRetryable: false,
        );
      }

      final normalized = (messageTtlSeconds != null && messageTtlSeconds > 0)
          ? messageTtlSeconds
          : null;
      final content = buildChatSettingsContent(messageTtlSeconds: normalized);

      // Required for self-sync/outgoing copies so we can resolve the peer from the rumor.
      final tagsJson = jsonEncode([
        ['p', session.recipientPubkeyHex],
      ]);

      await _sessionManagerService.sendEventWithInnerId(
        recipientPubkeyHex: session.recipientPubkeyHex,
        kind: kChatSettingsKind,
        content: content,
        tagsJson: tagsJson,
        createdAtSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    } catch (e, st) {
      final appError = e is AppError ? e : AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  /// Handle incoming reaction.
  Future<void> handleIncomingReaction(
    String sessionId,
    String messageId,
    String emoji,
    String fromPubkey, {
    DateTime? timestamp,
  }) async {
    await _applyReaction(
      sessionId,
      messageId,
      emoji,
      fromPubkey,
      notifyIncoming: true,
      reactionTimestamp: timestamp,
    );
  }

  /// Apply a reaction to a message (used for both sent and received reactions).
  /// messageId can be either internal id or eventId (Nostr event ID)
  Future<void> _applyReaction(
    String sessionId,
    String messageId,
    String emoji,
    String pubkey, {
    bool notifyIncoming = false,
    DateTime? reactionTimestamp,
  }) async {
    final currentMessages = state.messages[sessionId] ?? [];
    final applied = applyReactionToMessages(
      currentMessages,
      messageId: messageId,
      emoji: emoji,
      actorPubkeyHex: pubkey,
      matchEventId: true,
    );
    if (applied == null) return;
    final updatedMessage = applied.updatedMessage;

    state = state.copyWith(
      messages: {...state.messages, sessionId: applied.updatedMessages},
    );

    final ownerPubkey = _sessionManagerService.ownerPubkeyHex;
    final shouldNotify =
        notifyIncoming &&
        (ownerPubkey == null || ownerPubkey.toLowerCase() != pubkey) &&
        reactionTimestamp != null &&
        _inboundActivityPolicy.shouldNotifyDesktopForTimestamp(
          reactionTimestamp,
        );
    if (shouldNotify) {
      await _notifyIncomingReaction(
        sessionId: sessionId,
        targetMessage: updatedMessage,
        emoji: emoji,
      );
    }

    // Save to database in background (DB can be locked; don't crash/log-spam).
    unawaited(() async {
      try {
        await _messageDatasource.saveMessage(updatedMessage);
      } catch (_) {}
    }());
  }

  /// Check if content is a reaction payload and return parsed data.
  static Map<String, dynamic>? parseReactionPayload(String content) {
    try {
      final parsed = jsonDecode(content) as Map<String, dynamic>;
      if (parsed['type'] == 'reaction' &&
          parsed['messageId'] != null &&
          parsed['emoji'] != null) {
        return parsed;
      }
    } catch (_) {}
    return null;
  }

  /// Update message status.
  Future<void> updateMessageStatus(
    String messageId,
    MessageStatus status,
  ) async {
    await _messageDatasource.updateMessageStatus(messageId, status);

    state = state.copyWith(
      messages: state.messages.map((sessionId, messages) {
        return MapEntry(
          sessionId,
          messages.map((m) {
            if (m.id == messageId) {
              return m.copyWith(status: status);
            }
            return m;
          }).toList(),
        );
      }),
    );
  }

  /// Clear error state.
  void clearError() {
    state = state.copyWith(error: null);
  }
}
