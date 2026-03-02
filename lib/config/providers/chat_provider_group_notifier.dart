part of 'chat_provider.dart';

class _PendingGroupEvent {
  const _PendingGroupEvent({
    required this.rumorId,
    required this.rumorJson,
    required this.receivedAtMs,
    this.eventId,
  });

  final String rumorId;
  final String rumorJson;
  final int receivedAtMs;
  final String? eventId;
}

/// Notifier for group chats and group messages.
class GroupNotifier extends StateNotifier<GroupState> {
  GroupNotifier(
    this._groupDatasource,
    this._groupMessageDatasource,
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
       super(const GroupState());

  final GroupLocalDatasource _groupDatasource;
  final GroupMessageLocalDatasource _groupMessageDatasource;
  final SessionManagerService _sessionManagerService;
  final DesktopNotificationService _desktopNotificationService;
  final InboundActivityPolicy _inboundActivityPolicy;

  static const int _kGroupMetadataKind = kGroupMetadataKind;
  static const int _kChatMessageKind = 14;
  static const int _kReactionKind = 7;
  static const int _kTypingKind = 25;

  static const Duration _kTypingExpiry = Duration(seconds: 10);
  static const Duration _kTypingThrottle = Duration(seconds: 3);
  static const Duration _kLoadTimeout = Duration(seconds: 3);
  static const Duration _kGroupUpsertTimeout = Duration(seconds: 2);

  // Queue events that arrive before the group's metadata.
  final Map<String, List<_PendingGroupEvent>> _pendingByGroupId = {};
  static const int _kMaxPendingPerGroup = 50;
  static const Duration _kPendingMaxAge = Duration(minutes: 5);

  // Dedupe inner rumor ids (bounded).
  final Map<String, int> _seenRumorAtMs = {};
  static const int _kMaxSeenRumors = 10000;

  final Map<String, Timer> _typingExpiryTimers = {};
  final Map<String, int> _lastTypingSentAtMs = {};
  final Map<String, int> _lastGroupMessageAtMs = {};
  bool _typingIndicatorsEnabled = true;
  bool _desktopNotificationsEnabled = true;

  set typingIndicatorsEnabled(bool value) {
    _typingIndicatorsEnabled = value;
  }

  set desktopNotificationsEnabled(bool value) {
    _desktopNotificationsEnabled = value;
  }

  @override
  void dispose() {
    for (final t in _typingExpiryTimers.values) {
      t.cancel();
    }
    _typingExpiryTimers.clear();
    _lastGroupMessageAtMs.clear();
    super.dispose();
  }

  String? _myPubkeyHex() => _sessionManagerService.ownerPubkeyHex;

  List<String> _normalizedHexList(List<String> input) {
    final values = <String>{};
    for (final raw in input) {
      final value = raw.toLowerCase().trim();
      if (value.isEmpty) continue;
      values.add(value);
    }
    final normalized = values.toList()..sort();
    return normalized;
  }

  Future<void> _upsertGroupInNativeManager(ChatGroup group) async {
    await _sessionManagerService.groupUpsert(
      id: group.id,
      name: group.name,
      description: group.description,
      picture: group.picture,
      members: _normalizedHexList(group.members),
      admins: _normalizedHexList(group.admins),
      createdAtMs: group.createdAt.millisecondsSinceEpoch,
      secret: group.secret,
      accepted: group.accepted,
    );
  }

  Future<void> loadGroups() async {
    if (!mounted) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final groups = await _groupDatasource.getAllGroups().timeout(
        _kLoadTimeout,
      );
      if (!mounted) return;
      state = state.copyWith(groups: groups, isLoading: false);
      for (final group in groups) {
        try {
          await _upsertGroupInNativeManager(
            group,
          ).timeout(_kGroupUpsertTimeout);
        } catch (_) {}
      }
    } catch (e, st) {
      if (!mounted) return;
      final appError = AppError.from(e, st);
      state = state.copyWith(isLoading: false, error: appError.message);
    }
  }

  Future<void> loadGroupMessages(String groupId, {int limit = 200}) async {
    try {
      final messages = await _groupMessageDatasource.getMessagesForGroup(
        groupId,
        limit: limit,
      );
      state = state.copyWith(
        messages: {...state.messages, groupId: messages},
        error: null,
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<ChatGroup?> getGroup(String groupId) async {
    final inState = state.groups.cast<ChatGroup?>().firstWhere(
      (g) => g?.id == groupId,
      orElse: () => null,
    );
    if (inState != null) return inState;
    return _groupDatasource.getGroup(groupId);
  }

  /// Reload a group from storage and merge it into state.
  Future<void> refreshGroup(String groupId) async {
    try {
      final g = await _groupDatasource.getGroup(groupId);
      if (g == null) return;

      final idx = state.groups.indexWhere((e) => e.id == groupId);
      if (idx == -1) {
        state = state.copyWith(groups: [g, ...state.groups]);
        return;
      }

      final next = [...state.groups];
      next[idx] = g;
      state = state.copyWith(groups: next);
    } catch (_) {}
  }

  /// Remove expired group messages from in-memory state.
  ///
  /// Persistent storage cleanup is handled elsewhere; this only updates UI state.
  void purgeExpiredFromState(int nowSeconds) {
    if (state.messages.isEmpty) return;

    var changed = false;
    final updatedByGroup = <String, List<ChatMessage>>{};

    for (final entry in state.messages.entries) {
      final filtered = entry.value
          .where((m) => m.expiresAt == null || m.expiresAt! > nowSeconds)
          .toList();
      if (filtered.length != entry.value.length) changed = true;
      updatedByGroup[entry.key] = filtered;
    }

    if (!changed) return;
    state = state.copyWith(messages: updatedByGroup);
  }

  Future<String?> createGroup({
    required String name,
    required List<String> memberPubkeysHex,
  }) async {
    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) {
      state = state.copyWith(error: 'Not logged in');
      return null;
    }

    try {
      final created = await _sessionManagerService.groupCreate(
        name: name.trim(),
        memberOwnerPubkeys: _normalizedHexList(memberPubkeysHex),
        fanoutMetadata: true,
      );
      final group = ChatGroup(
        id: created.group.id,
        name: created.group.name,
        description: created.group.description,
        picture: created.group.picture,
        members: _normalizedHexList(created.group.members),
        admins: _normalizedHexList(created.group.admins),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          created.group.createdAtMs,
        ),
        secret: created.group.secret,
        accepted: created.group.accepted ?? true,
      );

      // Persist and update UI.
      await _groupDatasource.saveGroup(group);
      state = state.copyWith(
        groups: [group, ...state.groups.where((g) => g.id != group.id)],
        error: null,
      );

      // Fan out metadata back to the owner so other clients/devices logged into
      // the same account can materialize the group without requiring another member.
      try {
        await _sendGroupMetadataSenderCopyToOwner(
          ownerPubkeyHex: myPubkeyHex,
          metadataRumorJson: created.metadataRumorJson,
        );
      } catch (_) {}

      return group.id;
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
      return null;
    }
  }

  Future<void> acceptGroupInvitation(String groupId) async {
    try {
      final group = await getGroup(groupId);
      if (group == null) return;
      final updated = group.copyWith(accepted: true);
      await _groupDatasource.saveGroup(updated);
      state = state.copyWith(
        groups: state.groups.map((g) => g.id == groupId ? updated : g).toList(),
      );
      await _upsertGroupInNativeManager(updated);
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<void> renameGroup(String groupId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final group = await getGroup(groupId);
    if (group == null) return;

    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) {
      state = state.copyWith(error: 'Not logged in');
      return;
    }
    if (!isGroupAdmin(group, myPubkeyHex)) {
      state = state.copyWith(error: 'Only group admins can edit the group.');
      return;
    }

    if (group.name == trimmed) return;

    try {
      final updated = group.copyWith(name: trimmed);
      await _groupDatasource.saveGroup(updated);
      state = state.copyWith(
        groups: state.groups.map((g) => g.id == groupId ? updated : g).toList(),
        error: null,
      );

      await _sendGroupEventThroughManager(
        group: updated,
        kind: _kGroupMetadataKind,
        content: buildGroupMetadataContent(updated),
        tags: [
          [kGroupTagName, updated.id],
        ],
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<void> setGroupMessageTtlSeconds(
    String groupId,
    int? ttlSeconds,
  ) async {
    final group = await getGroup(groupId);
    if (group == null) return;

    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) {
      state = state.copyWith(error: 'Not logged in');
      return;
    }
    if (!isGroupAdmin(group, myPubkeyHex)) {
      state = state.copyWith(
        error: 'Only group admins can edit disappearing messages.',
      );
      return;
    }

    final normalized = (ttlSeconds != null && ttlSeconds > 0)
        ? ttlSeconds
        : null;
    if (group.messageTtlSeconds == normalized) return;

    try {
      final updated = group.copyWith(messageTtlSeconds: normalized);
      await _groupDatasource.saveGroup(updated);
      state = state.copyWith(
        groups: state.groups.map((g) => g.id == groupId ? updated : g).toList(),
        error: null,
      );

      await _sendGroupEventThroughManager(
        group: updated,
        kind: _kGroupMetadataKind,
        content: buildGroupMetadataContent(updated),
        tags: [
          [kGroupTagName, updated.id],
        ],
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<void> setGroupPicture(String groupId, String? picture) async {
    final group = await getGroup(groupId);
    if (group == null) return;

    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) {
      state = state.copyWith(error: 'Not logged in');
      return;
    }
    if (!isGroupAdmin(group, myPubkeyHex)) {
      state = state.copyWith(error: 'Only group admins can edit the group.');
      return;
    }

    final normalized = picture?.trim();
    final nextPicture = normalized == null || normalized.isEmpty
        ? null
        : normalized;
    if (group.picture == nextPicture) return;

    try {
      final updated = group.copyWith(picture: nextPicture);
      await _groupDatasource.saveGroup(updated);
      state = state.copyWith(
        groups: state.groups.map((g) => g.id == groupId ? updated : g).toList(),
        error: null,
      );

      await _sendGroupEventThroughManager(
        group: updated,
        kind: _kGroupMetadataKind,
        content: buildGroupMetadataContent(updated),
        tags: [
          [kGroupTagName, updated.id],
        ],
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<void> addGroupMembers(
    String groupId,
    List<String> memberPubkeysHex,
  ) async {
    if (memberPubkeysHex.isEmpty) return;

    final group = await getGroup(groupId);
    if (group == null) return;

    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) {
      state = state.copyWith(error: 'Not logged in');
      return;
    }
    if (!isGroupAdmin(group, myPubkeyHex)) {
      state = state.copyWith(error: 'Only group admins can edit the group.');
      return;
    }

    final toAdd = <String>[];
    final seen = <String>{};
    for (final raw in memberPubkeysHex) {
      final pk = raw.toLowerCase().trim();
      if (pk.isEmpty) continue;
      if (pk == myPubkeyHex) continue;
      if (group.members.contains(pk)) continue;
      if (!seen.add(pk)) continue;
      toAdd.add(pk);
    }
    if (toAdd.isEmpty) return;

    try {
      final updated = group.copyWith(members: [...group.members, ...toAdd]);
      await _groupDatasource.saveGroup(updated);
      state = state.copyWith(
        groups: state.groups.map((g) => g.id == groupId ? updated : g).toList(),
        error: null,
      );

      await _sendGroupEventThroughManager(
        group: updated,
        kind: _kGroupMetadataKind,
        content: buildGroupMetadataContent(updated),
        tags: [
          [kGroupTagName, updated.id],
        ],
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<void> removeGroupMember(String groupId, String memberPubkeyHex) async {
    final group = await getGroup(groupId);
    if (group == null) return;

    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) {
      state = state.copyWith(error: 'Not logged in');
      return;
    }
    if (!isGroupAdmin(group, myPubkeyHex)) {
      state = state.copyWith(error: 'Only group admins can edit the group.');
      return;
    }

    final member = memberPubkeyHex.toLowerCase().trim();
    if (member.isEmpty) return;
    if (!group.members.contains(member)) return;
    if (member == myPubkeyHex) {
      state = state.copyWith(
        error: 'You cannot remove yourself from the group.',
      );
      return;
    }

    final updatedMembers = group.members.where((m) => m != member).toList();
    if (updatedMembers.isEmpty) return;
    final updatedAdmins = group.admins.where((a) => a != member).toList();

    // Rotate the shared secret so removed members cannot decrypt future group messages
    // in clients that use SharedChannel (matches iris-chat semantics).
    final rotatedSecret = generateGroupSecretHex();

    final updated = group.copyWith(
      members: updatedMembers,
      admins: updatedAdmins.isNotEmpty ? updatedAdmins : [myPubkeyHex],
      secret: rotatedSecret,
    );

    try {
      await _groupDatasource.saveGroup(updated);
      state = state.copyWith(
        groups: state.groups.map((g) => g.id == groupId ? updated : g).toList(),
        error: null,
      );

      // Send updated metadata (with rotated secret) to remaining members.
      await _sendGroupEventThroughManager(
        group: updated,
        kind: _kGroupMetadataKind,
        content: buildGroupMetadataContent(updated),
        tags: [
          [kGroupTagName, updated.id],
        ],
      );

      // Notify the removed member; omit secret.
      await _sendGroupEventToRecipients(
        recipients: [member],
        kind: _kGroupMetadataKind,
        content: buildGroupMetadataContent(updated, excludeSecret: true),
        tags: [
          [kGroupTagName, updated.id],
        ],
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<void> deleteGroup(String groupId) async {
    try {
      await _groupDatasource.deleteGroup(groupId);
      await _groupMessageDatasource.deleteMessagesForGroup(groupId);
      await _sessionManagerService.groupRemove(groupId);

      final nextGroups = state.groups.where((g) => g.id != groupId).toList();
      final nextMessages = {...state.messages}..remove(groupId);
      state = state.copyWith(groups: nextGroups, messages: nextMessages);
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  /// Delete a group message locally (UI + local DB only).
  Future<void> deleteGroupMessageLocal(String groupId, String messageId) async {
    final current = state.messages[groupId] ?? const <ChatMessage>[];
    if (current.isEmpty) return;

    final updated = current.where((m) => m.id != messageId).toList();
    final nextMessages = {...state.messages};
    if (updated.isEmpty) {
      nextMessages.remove(groupId);
    } else {
      nextMessages[groupId] = updated;
    }
    state = state.copyWith(messages: nextMessages);

    try {
      await _groupMessageDatasource.deleteMessage(messageId);
      await _groupDatasource.recomputeDerivedFieldsFromMessages(groupId);
      await refreshGroup(groupId);
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<void> markGroupSeen(String groupId) async {
    if (!_inboundActivityPolicy.canMarkSeen()) return;

    final group = await getGroup(groupId);
    if (group == null) return;

    // Mark in-memory messages as seen (local only; no receipts for groups).
    final current = state.messages[groupId] ?? const <ChatMessage>[];
    final updated = current.map((m) {
      if (!m.isIncoming) return m;
      if (m.status == MessageStatus.seen) return m;
      return m.copyWith(status: MessageStatus.seen);
    }).toList();

    state = state.copyWith(messages: {...state.messages, groupId: updated});

    // Persist best-effort.
    unawaited(() async {
      try {
        for (final m in updated) {
          if (!m.isIncoming) continue;
          await _groupMessageDatasource.updateMessageStatus(
            m.id,
            MessageStatus.seen,
          );
        }
      } catch (_) {}
    }());

    // Clear unread counter.
    final updatedGroup = group.copyWith(unreadCount: 0);
    state = state.copyWith(
      groups: state.groups
          .map((g) => g.id == groupId ? updatedGroup : g)
          .toList(),
    );
    unawaited(() async {
      try {
        await _groupDatasource.updateMetadata(groupId, unreadCount: 0);
      } catch (_) {}
    }());
  }

  Future<void> sendGroupMessage(
    String groupId,
    String text, {
    String? replyToId,
  }) async {
    final group = await getGroup(groupId);
    if (group == null) return;
    if (!group.accepted) {
      state = state.copyWith(error: 'Accept the group invitation first.');
      return;
    }

    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) return;

    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final ttlSeconds = group.messageTtlSeconds;
      final expiresAtSeconds = (ttlSeconds != null && ttlSeconds > 0)
          ? (nowMs ~/ 1000 + ttlSeconds)
          : null;

      final tags = <List<String>>[
        [kGroupTagName, groupId],
        ['ms', nowMs.toString()],
        if (expiresAtSeconds != null)
          ['expiration', expiresAtSeconds.toString()],
        if (replyToId != null && replyToId.trim().isNotEmpty)
          ['e', replyToId.trim(), '', 'reply'],
      ];
      final tagsJson = jsonEncode(tags);
      final createdAtSeconds = nowMs ~/ 1000;

      final sendInnerId = await _sendGroupEventThroughManager(
        group: group,
        kind: _kChatMessageKind,
        content: trimmed,
        tags: tags,
        nowMs: nowMs,
      );

      // Best effort sender-copy to owner so other devices on the same account
      // can materialize messages in self-only groups.
      try {
        await _sessionManagerService.sendEventWithInnerId(
          recipientPubkeyHex: myPubkeyHex,
          kind: _kChatMessageKind,
          content: trimmed,
          tagsJson: tagsJson,
          createdAtSeconds: createdAtSeconds,
        );
      } catch (_) {}

      final rumorId =
          sendInnerId ?? DateTime.now().microsecondsSinceEpoch.toString();

      final message = ChatMessage(
        id: rumorId,
        sessionId: groupSessionId(groupId),
        text: trimmed,
        timestamp: DateTime.fromMillisecondsSinceEpoch(nowMs),
        direction: MessageDirection.outgoing,
        status: MessageStatus.sent,
        rumorId: rumorId,
        expiresAt: expiresAtSeconds,
        replyToId: (replyToId != null && replyToId.trim().isNotEmpty)
            ? replyToId.trim()
            : null,
        senderPubkeyHex: myPubkeyHex,
      );

      // Update UI state.
      final current = state.messages[groupId] ?? const <ChatMessage>[];
      state = state.copyWith(
        messages: {
          ...state.messages,
          groupId: [...current, message],
        },
      );

      // Persist best-effort.
      unawaited(() async {
        try {
          await _groupMessageDatasource.saveMessage(message);
          await _groupDatasource.updateMetadata(
            groupId,
            lastMessageAt: message.timestamp,
            lastMessagePreview: buildAttachmentAwarePreview(message.text),
            unreadCount: 0,
          );
        } catch (_) {}
      }());

      // Update group list state immediately.
      _updateGroupLastMessageInState(
        groupId,
        lastMessageAt: message.timestamp,
        lastMessagePreview: buildAttachmentAwarePreview(message.text),
        resetUnread: true,
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<void> sendGroupReaction({
    required String groupId,
    required String messageId,
    required String emoji,
  }) async {
    final group = await getGroup(groupId);
    if (group == null) return;
    if (!group.accepted) return;

    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) return;

    final trimmed = emoji.trim();
    if (trimmed.isEmpty) return;

    // Optimistic update.
    await _applyGroupReaction(groupId, messageId, trimmed, myPubkeyHex);

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final tags = <List<String>>[
      [kGroupTagName, groupId],
      ['ms', nowMs.toString()],
      ['e', messageId],
    ];

    try {
      await _sendGroupEventThroughManager(
        group: group,
        kind: _kReactionKind,
        content: trimmed,
        tags: tags,
        nowMs: nowMs,
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
    }
  }

  Future<void> sendGroupTyping(String groupId, {bool isTyping = true}) async {
    if (!_typingIndicatorsEnabled) return;

    final group = await getGroup(groupId);
    if (group == null) return;
    if (!group.accepted) return;

    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (isTyping) {
      final last = _lastTypingSentAtMs[groupId] ?? 0;
      if (nowMs - last < _kTypingThrottle.inMilliseconds) return;
      _lastTypingSentAtMs[groupId] = nowMs;
    } else {
      _lastTypingSentAtMs.remove(groupId);
    }

    final tags = <List<String>>[
      [kGroupTagName, groupId],
      ['ms', nowMs.toString()],
    ];
    if (!isTyping) {
      final nowSeconds = nowMs ~/ 1000;
      tags.add(['expiration', nowSeconds.toString()]);
    }

    try {
      await _sendGroupEventThroughManager(
        group: group,
        kind: _kTypingKind,
        content: 'typing',
        tags: tags,
        nowMs: nowMs,
      );
    } catch (_) {}
  }

  Future<void> handleIncomingGroupRumorJson(
    String rumorJson, {
    String? eventId,
  }) async {
    final rumor = NostrRumor.tryParse(rumorJson);
    if (rumor == null) return;
    await _handleGroupRumor(rumor, eventId: eventId);
  }

  Future<void> _handleGroupRumor(NostrRumor rumor, {String? eventId}) async {
    final groupTag = getFirstTagValue(rumor.tags, kGroupTagName);
    final groupId =
        groupTag ??
        (rumor.kind == _kGroupMetadataKind
            ? parseGroupMetadata(rumor.content)?.id
            : null);
    if (groupId == null || groupId.isEmpty) return;

    if (rumor.kind == _kGroupMetadataKind) {
      await _handleGroupMetadata(rumor, groupId);
      return;
    }

    final group = await getGroup(groupId);
    if (group == null) {
      // Queue until we get metadata.
      _queuePending(
        groupId,
        rumorId: rumor.id,
        rumorJson: jsonEncode(_rumorToMap(rumor)),
        eventId: eventId,
      );
      return;
    }

    // Dedupe by stable inner id (rumor.id) once the group exists.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final prevSeen = _seenRumorAtMs[rumor.id];
    if (prevSeen != null) return;
    _seenRumorAtMs[rumor.id] = nowMs;
    if (_seenRumorAtMs.length > _kMaxSeenRumors) {
      final keys = _seenRumorAtMs.keys.take(2000).toList();
      for (final k in keys) {
        _seenRumorAtMs.remove(k);
      }
    }

    if (rumor.kind == _kTypingKind) {
      _handleGroupTyping(rumor, groupId);
      return;
    }

    if (rumor.kind == _kReactionKind) {
      await _handleGroupReaction(rumor, groupId);
      return;
    }

    if (rumor.kind == _kChatMessageKind) {
      await _handleGroupMessage(rumor, groupId, group, eventId: eventId);
      return;
    }
  }

  Future<void> _handleGroupMetadata(NostrRumor rumor, String groupId) async {
    final metadata = parseGroupMetadata(rumor.content);
    if (metadata == null) return;

    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) return;

    final existing = await getGroup(metadata.id);
    if (existing != null) {
      final result = validateMetadataUpdate(
        existing: existing,
        metadata: metadata,
        senderPubkeyHex: rumor.pubkey,
        myPubkeyHex: myPubkeyHex,
      );
      if (result == MetadataValidation.reject) return;
      if (result == MetadataValidation.removed) {
        await deleteGroup(metadata.id);
        return;
      }

      final updated = applyMetadataUpdate(
        existing: existing,
        metadata: metadata,
      );
      await _groupDatasource.saveGroup(updated);
      state = state.copyWith(
        groups: state.groups
            .map((g) => g.id == updated.id ? updated : g)
            .toList(),
      );
      await _upsertGroupInNativeManager(updated);
      return;
    }

    if (!validateMetadataCreation(
      metadata: metadata,
      senderPubkeyHex: rumor.pubkey,
      myPubkeyHex: myPubkeyHex,
    )) {
      return;
    }

    final createdAt = rumorTimestamp(rumor);
    final group = ChatGroup(
      id: metadata.id,
      name: metadata.name,
      members: metadata.members,
      admins: metadata.admins,
      description: metadata.description,
      picture: metadata.picture,
      createdAt: createdAt,
      secret: metadata.secret,
      accepted: false,
      messageTtlSeconds: metadata.messageTtlSeconds,
    );

    await _groupDatasource.saveGroup(group);
    state = state.copyWith(
      groups: [group, ...state.groups.where((g) => g.id != group.id)],
    );
    await _upsertGroupInNativeManager(group);

    // Flush any pending events for this group.
    await _flushPending(group.id);
  }

  Future<void> _handleGroupMessage(
    NostrRumor rumor,
    String groupId,
    ChatGroup group, {
    String? eventId,
  }) async {
    final myPubkeyHex = _myPubkeyHex();
    final isMine = myPubkeyHex != null && rumor.pubkey == myPubkeyHex;

    // Persist first to avoid duplicates across UI rebuilds.
    if (await _groupMessageDatasource.messageExists(rumor.id)) return;

    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiresAtSeconds = getExpirationTimestampSeconds(rumor.tags);
    if (expiresAtSeconds != null && expiresAtSeconds <= nowSeconds) {
      return;
    }

    final replyToId = _resolveReplyToId(rumor.tags);

    final message = ChatMessage(
      id: rumor.id,
      sessionId: groupSessionId(groupId),
      text: rumor.content,
      timestamp: rumorTimestamp(rumor),
      expiresAt: expiresAtSeconds,
      direction: isMine ? MessageDirection.outgoing : MessageDirection.incoming,
      status: isMine ? MessageStatus.sent : MessageStatus.delivered,
      eventId: eventId,
      rumorId: rumor.id,
      replyToId: replyToId,
      senderPubkeyHex: rumor.pubkey,
    );

    if (!isMine) {
      _clearGroupTyping(
        groupId,
        messageTimestampMs: rumorTimestamp(rumor).millisecondsSinceEpoch,
      );
    }

    await _groupMessageDatasource.saveMessage(message);

    // Update in-memory list.
    final current = state.messages[groupId] ?? const <ChatMessage>[];
    if (current.any((m) => m.id == message.id)) return;
    final updated = [...current, message]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    state = state.copyWith(messages: {...state.messages, groupId: updated});

    final lastPreview = buildAttachmentAwarePreview(message.text);

    // Update group last message + unread.
    final incUnread = !isMine;
    _updateGroupLastMessageInState(
      groupId,
      lastMessageAt: message.timestamp,
      lastMessagePreview: buildAttachmentAwarePreview(message.text),
      incrementUnread: incUnread,
    );

    unawaited(() async {
      try {
        await _groupDatasource.updateMetadata(
          groupId,
          lastMessageAt: message.timestamp,
          lastMessagePreview: lastPreview,
          unreadCount: incUnread ? group.unreadCount + 1 : null,
        );
      } catch (_) {}
    }());

    if (!isMine &&
        _inboundActivityPolicy.shouldNotifyDesktopForTimestamp(
          message.timestamp,
        )) {
      unawaited(
        _desktopNotificationService.showIncomingMessage(
          enabled: _desktopNotificationsEnabled,
          conversationTitle: group.name,
          body: buildAttachmentAwarePreview(message.text),
        ),
      );
    }
  }

  Future<void> _handleGroupReaction(NostrRumor rumor, String groupId) async {
    final messageId = getFirstTagValue(rumor.tags, 'e');
    if (messageId == null || messageId.isEmpty) return;
    await _applyGroupReaction(
      groupId,
      messageId,
      rumor.content,
      rumor.pubkey,
      notifyIncoming: true,
      reactionTimestamp: rumorTimestamp(rumor),
    );
  }

  void _handleGroupTyping(NostrRumor rumor, String groupId) {
    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex != null && rumor.pubkey == myPubkeyHex) return;

    final expiresAtSeconds = getExpirationTimestampSeconds(rumor.tags);
    if (isTypingStopRumor(rumor, expiresAtSeconds: expiresAtSeconds)) {
      _clearGroupTyping(groupId);
      return;
    }

    final typingTimestampMs = rumorTimestamp(rumor).millisecondsSinceEpoch;
    final lastMessageTimestampMs = _lastGroupMessageAtMs[groupId];
    if (isTypingTimestampStale(
      typingTimestampMs: typingTimestampMs,
      lastMessageTimestampMs: lastMessageTimestampMs,
    )) {
      return;
    }

    _typingExpiryTimers[groupId]?.cancel();
    state = state.copyWith(
      typingStates: {...state.typingStates, groupId: true},
    );
    _typingExpiryTimers[groupId] = Timer(_kTypingExpiry, () {
      _clearGroupTyping(groupId);
    });
  }

  void _clearGroupTyping(String groupId, {int? messageTimestampMs}) {
    if (messageTimestampMs != null) {
      final existing = _lastGroupMessageAtMs[groupId] ?? 0;
      _lastGroupMessageAtMs[groupId] = messageTimestampMs > existing
          ? messageTimestampMs
          : existing;
    }
    _typingExpiryTimers[groupId]?.cancel();
    _typingExpiryTimers.remove(groupId);
    if (!state.typingStates.containsKey(groupId)) return;
    final next = {...state.typingStates}..remove(groupId);
    state = state.copyWith(typingStates: next);
  }

  Future<void> _applyGroupReaction(
    String groupId,
    String messageId,
    String emoji,
    String pubkeyHex, {
    bool notifyIncoming = false,
    DateTime? reactionTimestamp,
  }) async {
    final current = state.messages[groupId] ?? const <ChatMessage>[];
    var idx = current.indexWhere((m) => m.id == messageId);
    if (idx == -1) {
      idx = current.indexWhere((m) => m.rumorId == messageId);
    }
    if (idx == -1) return;

    final message = current[idx];
    final reactions = <String, List<String>>{};

    for (final entry in message.reactions.entries) {
      final filtered = entry.value.where((u) => u != pubkeyHex).toList();
      if (filtered.isNotEmpty) reactions[entry.key] = filtered;
    }
    reactions[emoji] = [...(reactions[emoji] ?? []), pubkeyHex];

    final updatedMessage = message.copyWith(reactions: reactions);
    final next = [...current];
    next[idx] = updatedMessage;
    state = state.copyWith(messages: {...state.messages, groupId: next});

    final myPubkeyHex = _myPubkeyHex();
    final shouldNotify =
        notifyIncoming &&
        (myPubkeyHex == null || myPubkeyHex.toLowerCase() != pubkeyHex) &&
        reactionTimestamp != null &&
        _inboundActivityPolicy.shouldNotifyDesktopForTimestamp(
          reactionTimestamp,
        );
    if (shouldNotify) {
      final groupName = state.groups
          .cast<ChatGroup?>()
          .firstWhere((g) => g?.id == groupId, orElse: () => null)
          ?.name;
      await _desktopNotificationService.showIncomingReaction(
        enabled: _desktopNotificationsEnabled,
        conversationTitle: groupName ?? 'Group chat',
        emoji: emoji,
        targetPreview: buildAttachmentAwarePreview(updatedMessage.text),
      );
    }

    unawaited(() async {
      try {
        await _groupMessageDatasource.saveMessage(updatedMessage);
      } catch (_) {}
    }());
  }

  void _queuePending(
    String groupId, {
    required String rumorId,
    required String rumorJson,
    String? eventId,
  }) {
    final list = _pendingByGroupId.putIfAbsent(
      groupId,
      () => <_PendingGroupEvent>[],
    );
    if (list.length >= _kMaxPendingPerGroup) return;
    if (list.any((p) => p.rumorId == rumorId)) return;
    list.add(
      _PendingGroupEvent(
        rumorId: rumorId,
        rumorJson: rumorJson,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch,
        eventId: eventId,
      ),
    );
  }

  Future<void> _flushPending(String groupId) async {
    final pending = _pendingByGroupId.remove(groupId);
    if (pending == null || pending.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final p in pending) {
      if (now - p.receivedAtMs > _kPendingMaxAge.inMilliseconds) continue;
      final rumor = NostrRumor.tryParse(p.rumorJson);
      if (rumor == null) continue;
      await _handleGroupRumor(rumor, eventId: p.eventId);
    }
  }

  /// Send a group-tagged rumor through native GroupManager.
  ///
  /// GroupManager is responsible for one-to-many outer transport and sender-key distribution.
  Future<String?> _sendGroupEventThroughManager({
    required ChatGroup group,
    required int kind,
    required String content,
    required List<List<String>> tags,
    int? nowMs,
  }) async {
    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) return null;

    await _upsertGroupInNativeManager(group);
    final sendResult = await _sessionManagerService.groupSendEvent(
      groupId: group.id,
      kind: kind,
      content: content,
      tagsJson: jsonEncode(tags),
      nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );
    return sendResult.innerEventId.isNotEmpty ? sendResult.innerEventId : null;
  }

  /// Send a rumor pairwise to specific recipients via SessionManager.
  ///
  /// This is only used for targeted migration/notification paths (e.g. removed member update).
  Future<String?> _sendGroupEventToRecipients({
    required List<String> recipients,
    required int kind,
    required String content,
    required List<List<String>> tags,
    int? createdAtSeconds,
  }) async {
    final myPubkeyHex = _myPubkeyHex();
    if (myPubkeyHex == null || myPubkeyHex.isEmpty) return null;

    if (recipients.isEmpty) return null;
    final tagsJson = jsonEncode(tags);

    String? innerId;
    for (final raw in recipients) {
      final member = raw.toLowerCase().trim();
      if (member.isEmpty) continue;
      if (member == myPubkeyHex) continue;

      final sendResult = await _sessionManagerService.sendEventWithInnerId(
        recipientPubkeyHex: member,
        kind: kind,
        content: content,
        tagsJson: tagsJson,
        createdAtSeconds: createdAtSeconds,
      );
      if (innerId == null && sendResult.innerId.isNotEmpty) {
        innerId = sendResult.innerId;
      }
    }
    return innerId;
  }

  Future<void> _sendGroupMetadataSenderCopyToOwner({
    required String ownerPubkeyHex,
    required String? metadataRumorJson,
  }) async {
    final rumorJson = metadataRumorJson?.trim();
    if (rumorJson == null || rumorJson.isEmpty) return;

    final rumor = NostrRumor.tryParse(rumorJson);
    if (rumor == null) return;

    final recipient = ownerPubkeyHex.toLowerCase().trim();
    if (recipient.isEmpty) return;

    await _sessionManagerService.sendEventWithInnerId(
      recipientPubkeyHex: recipient,
      kind: rumor.kind,
      content: rumor.content,
      tagsJson: jsonEncode(rumor.tags),
      createdAtSeconds: rumor.createdAt,
    );
  }

  void _updateGroupLastMessageInState(
    String groupId, {
    required DateTime lastMessageAt,
    required String lastMessagePreview,
    bool incrementUnread = false,
    bool resetUnread = false,
  }) {
    final nextGroups = state.groups.map((g) {
      if (g.id != groupId) return g;

      final nextUnread = resetUnread
          ? 0
          : incrementUnread
          ? (g.unreadCount + 1)
          : g.unreadCount;

      return g.copyWith(
        lastMessageAt: lastMessageAt,
        lastMessagePreview: lastMessagePreview.length > 50
            ? '${lastMessagePreview.substring(0, 50)}...'
            : lastMessagePreview,
        unreadCount: nextUnread,
      );
    }).toList();

    state = state.copyWith(groups: nextGroups);
  }

  static String? _resolveReplyToId(List<List<String>> tags) {
    for (final t in tags) {
      if (t.length < 2) continue;
      if (t[0] != 'e') continue;
      if (t.length >= 4 && t[3] == 'reply') return t[1];
    }
    // Fallback: first e tag.
    return getFirstTagValue(tags, 'e');
  }

  static Map<String, dynamic> _rumorToMap(NostrRumor rumor) {
    return {
      'id': rumor.id,
      'pubkey': rumor.pubkey,
      'created_at': rumor.createdAt,
      'kind': rumor.kind,
      'content': rumor.content,
      'tags': rumor.tags,
    };
  }
}
