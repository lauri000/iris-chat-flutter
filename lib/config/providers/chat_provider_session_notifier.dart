part of 'chat_provider.dart';

class SessionNotifier extends StateNotifier<SessionState> {
  SessionNotifier(
    this._sessionDatasource,
    this._profileService,
    this._sessionManagerService,
  ) : super(const SessionState());

  final SessionLocalDatasource _sessionDatasource;
  final ProfileService _profileService;
  final SessionManagerService _sessionManagerService;
  static const Duration _kLoadTimeout = Duration(seconds: 3);

  void _armPeerSession(String recipientPubkeyHex) {
    final normalized = recipientPubkeyHex.trim().toLowerCase();
    if (normalized.isEmpty) return;
    unawaited(
      _sessionManagerService
          .setupUser(normalized)
          .catchError((error, stackTrace) {}),
    );
  }

  void _upsertSessionInState(ChatSession session) {
    // Avoid duplicate sessions in memory when the same session is "added" twice
    // (e.g., relay replays, reconnects, or overlapping flows).
    final existingIndex = state.sessions.indexWhere((s) => s.id == session.id);
    if (existingIndex == -1) {
      state = state.copyWith(sessions: [session, ...state.sessions]);
      return;
    }

    final updated = [...state.sessions];
    updated[existingIndex] = session;
    // Keep most-recent sessions at the top.
    if (existingIndex != 0) {
      updated.removeAt(existingIndex);
      updated.insert(0, session);
    }
    state = state.copyWith(sessions: updated);
  }

  /// Load all sessions from storage.
  Future<void> loadSessions() async {
    if (!mounted) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final sessions = await _sessionDatasource.getAllSessions().timeout(
        _kLoadTimeout,
      );
      if (!mounted) return;
      state = state.copyWith(sessions: sessions, isLoading: false);

      // Fetch profile metadata (names + avatars) for all recipients.
      unawaited(
        _fetchRecipientProfiles(sessions).catchError((error, stackTrace) {}),
      );
    } catch (e, st) {
      if (!mounted) return;
      final appError = AppError.from(e, st);
      state = state.copyWith(isLoading: false, error: appError.message);
    }
  }

  /// Fetch profiles for session recipients.
  Future<void> _fetchRecipientProfiles(List<ChatSession> sessions) async {
    try {
      final recipientPubkeys = sessions
          .map((s) => s.recipientPubkeyHex)
          .where((pubkey) => pubkey.trim().isNotEmpty)
          .toSet()
          .toList();

      if (recipientPubkeys.isEmpty) return;

      // Fetch profiles in background
      await _profileService.fetchProfiles(recipientPubkeys);

      // Update sessions with profile names
      for (final pubkey in recipientPubkeys) {
        final profile =
            _profileService.getCachedProfile(pubkey) ??
            await _profileService.getProfile(pubkey);
        if (profile?.bestName != null) {
          await updateRecipientName(pubkey, profile!.bestName!);
        }
      }
    } catch (_) {
      // Best-effort background task; ignore errors to avoid noisy unhandled futures.
    }
  }

  /// Update recipient name for sessions with a given pubkey.
  Future<void> updateRecipientName(String pubkey, String name) async {
    final updatedSessions = <ChatSession>[];

    for (final session in state.sessions) {
      if (session.recipientPubkeyHex == pubkey &&
          session.recipientName != name) {
        final updated = session.copyWith(recipientName: name);
        unawaited(() async {
          try {
            await _sessionDatasource.saveSession(updated);
          } catch (_) {}
        }());
        updatedSessions.add(updated);
      } else {
        updatedSessions.add(session);
      }
    }

    if (updatedSessions != state.sessions) {
      state = state.copyWith(sessions: updatedSessions);
    }
  }

  /// Add a new session.
  Future<void> addSession(ChatSession session) async {
    _upsertSessionInState(session);
    _armPeerSession(session.recipientPubkeyHex);
    unawaited(
      _profileService
          .fetchProfiles([session.recipientPubkeyHex])
          .catchError((error, stackTrace) {}),
    );
    unawaited(() async {
      try {
        await _sessionDatasource.saveSession(session);
      } catch (_) {}
    }());
  }

  /// Ensure a session exists for [recipientPubkeyHex] and return it.
  ///
  /// This is used for "public chat links" that only contain a Nostr identity
  /// (npub/nprofile) rather than an Iris invite payload.
  Future<ChatSession> ensureSessionForRecipient(
    String recipientPubkeyHex,
  ) async {
    final normalized = recipientPubkeyHex.toLowerCase().trim();

    // Fast-path: if already in memory, don't touch the DB (avoids UI stalls on locked DB).
    for (final s in state.sessions) {
      if (s.id == normalized || s.recipientPubkeyHex == normalized) {
        return s;
      }
    }

    // Create a placeholder session immediately so the UI can navigate.
    // Persist with INSERT-IF-ABSENT to avoid overwriting an existing session's
    // ratchet state/metadata if the DB already contains it.
    final session = ChatSession(
      id: normalized,
      recipientPubkeyHex: normalized,
      createdAt: DateTime.now(),
    );

    _upsertSessionInState(session);
    _armPeerSession(normalized);
    unawaited(() async {
      try {
        await _profileService.fetchProfiles([normalized]);
      } catch (_) {}
    }());
    unawaited(() async {
      try {
        await _sessionDatasource.insertSessionIfAbsent(session);
      } catch (_) {}
    }());

    return session;
  }

  /// Update a session.
  Future<void> updateSession(ChatSession session) async {
    state = state.copyWith(
      sessions: state.sessions
          .map((s) => s.id == session.id ? session : s)
          .toList(),
    );
    unawaited(() async {
      try {
        await _sessionDatasource.saveSession(session);
      } catch (_) {}
    }());
  }

  /// Update per-chat disappearing messages timer (in seconds).
  Future<void> setMessageTtlSeconds(
    String sessionId,
    int? messageTtlSeconds,
  ) async {
    final normalized = (messageTtlSeconds != null && messageTtlSeconds > 0)
        ? messageTtlSeconds
        : null;

    // Fast-path: update in-memory session if present.
    final index = state.sessions.indexWhere((s) => s.id == sessionId);
    if (index != -1) {
      final current = state.sessions[index];
      if (current.messageTtlSeconds == normalized) return;
      final updated = current.copyWith(messageTtlSeconds: normalized);
      _upsertSessionInState(updated);
      unawaited(() async {
        try {
          await _sessionDatasource.saveSession(updated);
        } catch (_) {}
      }());
      return;
    }

    // Fallback: load from DB and upsert.
    final existing = await _sessionDatasource.getSession(sessionId);
    if (existing == null) return;
    final updated = existing.copyWith(messageTtlSeconds: normalized);
    _upsertSessionInState(updated);
    unawaited(() async {
      try {
        await _sessionDatasource.saveSession(updated);
      } catch (_) {}
    }());
  }

  /// Reload a session from DB and upsert into state.
  Future<void> refreshSession(String sessionId) async {
    try {
      final s = await _sessionDatasource.getSession(sessionId);
      if (s == null) return;
      _upsertSessionInState(s);
    } catch (_) {}
  }

  /// Delete a session.
  Future<void> deleteSession(String id) async {
    await _sessionDatasource.deleteSession(id);
    state = state.copyWith(
      sessions: state.sessions.where((s) => s.id != id).toList(),
    );
  }

  /// Update session with new message info.
  Future<void> updateSessionWithMessage(
    String sessionId,
    ChatMessage message,
  ) async {
    final index = state.sessions.indexWhere((s) => s.id == sessionId);
    if (index == -1) return;

    final current = state.sessions[index];
    final updatedSession = current.copyWith(
      lastMessageAt: message.timestamp,
      lastMessagePreview: buildAttachmentAwarePreview(message.text),
    );

    final next = [...state.sessions];
    next[index] = updatedSession;
    if (index != 0) {
      next.removeAt(index);
      next.insert(0, updatedSession);
    }

    state = state.copyWith(sessions: next);

    unawaited(() async {
      try {
        await _sessionDatasource.updateMetadata(
          sessionId,
          lastMessageAt: message.timestamp,
          lastMessagePreview: buildAttachmentAwarePreview(message.text),
        );
      } catch (_) {}
    }());
  }

  /// Increment unread count for a session.
  Future<void> incrementUnread(String sessionId) async {
    final session = state.sessions.firstWhere(
      (s) => s.id == sessionId,
      orElse: () => throw Exception('Session not found'),
    );

    state = state.copyWith(
      sessions: state.sessions.map((s) {
        if (s.id == sessionId) {
          return s.copyWith(unreadCount: s.unreadCount + 1);
        }
        return s;
      }).toList(),
    );

    unawaited(() async {
      try {
        await _sessionDatasource.updateMetadata(
          sessionId,
          unreadCount: session.unreadCount + 1,
        );
      } catch (_) {}
    }());
  }

  /// Clear unread count for a session.
  Future<void> clearUnread(String sessionId) async {
    state = state.copyWith(
      sessions: state.sessions.map((s) {
        if (s.id == sessionId) {
          return s.copyWith(unreadCount: 0);
        }
        return s;
      }).toList(),
    );

    unawaited(() async {
      try {
        await _sessionDatasource.updateMetadata(sessionId, unreadCount: 0);
      } catch (_) {}
    }());
  }
}
