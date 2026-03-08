import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:uuid/uuid.dart';

import '../../core/ffi/ndr_ffi.dart';
import '../../core/services/error_service.dart';
import '../../core/services/logger_service.dart';
import '../../core/services/nostr_service.dart';
import '../../core/utils/app_keys_event_fetch.dart';
import '../../core/utils/invite_url.dart';
import '../../features/chat/domain/models/session.dart';
import '../../features/invite/data/datasources/invite_local_datasource.dart';
import '../../features/invite/domain/models/invite.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'device_manager_provider.dart';
import 'nostr_provider.dart';

part 'invite_provider.freezed.dart';

/// State for invites.
@freezed
abstract class InviteState with _$InviteState {
  const factory InviteState({
    @Default([]) List<Invite> invites,
    @Default(false) bool isLoading,
    @Default(false) bool isCreating,
    @Default(false) bool isAccepting,
    String? error,
  }) = _InviteState;
}

/// Notifier for invite state.
class InviteNotifier extends StateNotifier<InviteState> {
  InviteNotifier(this._datasource, this._ref) : super(const InviteState());

  final InviteLocalDatasource _datasource;
  final Ref _ref;
  static const Duration _kLoadTimeout = Duration(seconds: 3);

  /// Load all invites from storage.
  Future<void> loadInvites() async {
    if (!mounted) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final invites = await _datasource.getActiveInvites().timeout(
        _kLoadTimeout,
      );
      if (!mounted) return;
      state = state.copyWith(invites: invites, isLoading: false);
    } catch (e, st) {
      if (!mounted) return;
      final appError = AppError.from(e, st);
      state = state.copyWith(isLoading: false, error: appError.message);
    }
  }

  /// Create a new invite.
  Future<Invite?> createInvite({
    String? label,
    int? maxUses,
    bool publishToRelays = false,
  }) async {
    state = state.copyWith(isCreating: true, error: null);
    InviteHandle? inviteHandle;
    try {
      final authState = _ref.read(authStateProvider);
      if (!authState.isAuthenticated || authState.pubkeyHex == null) {
        throw Exception('Not authenticated');
      }

      // Use the device identity key to create invites so linked devices can participate.
      final authRepo = _ref.read(authRepositoryProvider);
      final devicePrivkeyHex = await authRepo.getPrivateKey();
      if (devicePrivkeyHex == null) {
        throw Exception('Private key not found');
      }
      final devicePubkeyHex = await NdrFfi.derivePublicKey(devicePrivkeyHex);

      // Default to single-use chat invites to avoid replay/duplicate session creation.
      final effectiveMaxUses = maxUses ?? 1;

      // Create invite using ndr-ffi
      inviteHandle = await NdrFfi.createInvite(
        inviterPubkeyHex: devicePubkeyHex,
        deviceId: devicePubkeyHex,
        maxUses: effectiveMaxUses,
      );

      // Make purpose explicit for cross-client compatibility.
      await inviteHandle.setPurpose('chat');

      // Embed owner pubkey in invite URLs for multi-device mapping.
      await inviteHandle.setOwnerPubkeyHex(authState.pubkeyHex);

      // Serialize for storage
      final serializedState = await inviteHandle.serialize();
      final inviterPubkey = await inviteHandle.getInviterPubkeyHex();

      final invite = Invite(
        id: const Uuid().v4(),
        inviterPubkeyHex: inviterPubkey,
        label: label,
        createdAt: DateTime.now(),
        maxUses: effectiveMaxUses,
        serializedState: serializedState,
      );

      await _datasource.saveInvite(invite);

      state = state.copyWith(
        invites: [invite, ...state.invites],
        isCreating: false,
      );

      if (publishToRelays) {
        await _publishInviteToRelays(
          serializedState: serializedState,
          signerPrivkeyHex: devicePrivkeyHex,
        );
      }

      return invite;
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(isCreating: false, error: appError.message);
      return null;
    } finally {
      try {
        await inviteHandle?.dispose();
      } catch (_) {}
    }
  }

  /// Ensure a regular chat invite exists and is published for npub bootstrap.
  Future<void> ensurePublishedPublicInvite() async {
    final authState = _ref.read(authStateProvider);
    if (!authState.isAuthenticated || authState.pubkeyHex == null) return;

    final authRepo = _ref.read(authRepositoryProvider);
    final devicePrivkeyHex = await authRepo.getPrivateKey();
    if (devicePrivkeyHex == null || devicePrivkeyHex.isEmpty) return;

    if (!authState.isLinkedDevice) {
      final ownerPubkeyHex = authState.pubkeyHex!;
      final devicePubkeyHex = await NdrFfi.derivePublicKey(devicePrivkeyHex);
      await _publishMergedAppKeys(
        ownerPubkeyHex: ownerPubkeyHex,
        ownerPrivkeyHex: devicePrivkeyHex,
        devicePubkeysToEnsure: {devicePubkeyHex},
      );
    }

    Invite? inviteToPublish;
    final existingInvites = await _datasource.getActiveInvites();
    for (final invite in existingInvites) {
      if (invite.serializedState == null || invite.serializedState!.isEmpty) {
        continue;
      }
      inviteToPublish = invite;
      break;
    }

    inviteToPublish ??= await createInvite();

    final serializedState = inviteToPublish?.serializedState;
    if (serializedState != null && serializedState.isNotEmpty) {
      await _publishInviteToRelays(
        serializedState: serializedState,
        signerPrivkeyHex: devicePrivkeyHex,
      );
    }
  }

  Future<void> _publishInviteToRelays({
    required String serializedState,
    required String signerPrivkeyHex,
  }) async {
    InviteHandle? inviteHandle;
    try {
      inviteHandle = await NdrFfi.inviteDeserialize(serializedState);
      final unsignedEventJson = await inviteHandle.toEventJson();
      final decoded = jsonDecode(unsignedEventJson);
      if (decoded is! Map<String, dynamic>) return;

      final kind = (decoded['kind'] as num?)?.toInt();
      if (kind == null) return;

      final content = decoded['content'] as String? ?? '';
      final rawTags = decoded['tags'];
      final tags = <List<String>>[];
      if (rawTags is List) {
        for (final entry in rawTags) {
          if (entry is! List) continue;
          tags.add(entry.map((e) => e.toString()).toList());
        }
      }

      final signed = nostr.Event.from(
        kind: kind,
        tags: tags,
        content: content,
        privkey: signerPrivkeyHex,
        verify: false,
      );

      await _ref
          .read(nostrServiceProvider)
          .publishEvent(jsonEncode(signed.toJson()));
    } catch (e, st) {
      Logger.warning(
        'Failed to publish invite event',
        category: LogCategory.invite,
        data: {'error': e.toString()},
      );
      Logger.debug(
        'Publish invite stack',
        category: LogCategory.invite,
        data: {'stack': st.toString()},
      );
    } finally {
      try {
        await inviteHandle?.dispose();
      } catch (_) {}
    }
  }

  /// Accept an invite from a URL.
  Future<String?> acceptInviteFromUrl(String url) async {
    state = state.copyWith(isAccepting: true, error: null);
    try {
      final authState = _ref.read(authStateProvider);
      if (!authState.isAuthenticated || authState.pubkeyHex == null) {
        throw Exception('Not authenticated');
      }

      final ownerHintPubkeyHex = extractInviteOwnerPubkeyHex(url);
      final sessionManager = _ref.read(sessionManagerServiceProvider);
      final acceptResult = await sessionManager.acceptInviteFromUrl(
        inviteUrl: url,
        ownerPubkeyHintHex: ownerHintPubkeyHex,
      );
      final inviterOwnerPubkey = acceptResult.ownerPubkeyHex;

      // Store sessions keyed by peer owner pubkey for stable routing/deduping.
      final sessionDatasource = _ref.read(sessionDatasourceProvider);
      final existing = await sessionDatasource.getSessionByRecipient(
        inviterOwnerPubkey,
      );
      final sessionId = existing?.id ?? inviterOwnerPubkey;

      // Create session in chat provider
      final sessionNotifier = _ref.read(sessionStateProvider.notifier);
      final session = ChatSession(
        id: sessionId,
        recipientPubkeyHex: inviterOwnerPubkey,
        recipientName: existing?.recipientName,
        createdAt: existing?.createdAt ?? DateTime.now(),
        lastMessageAt: existing?.lastMessageAt,
        lastMessagePreview: existing?.lastMessagePreview,
        unreadCount: existing?.unreadCount ?? 0,
        inviteId: existing?.inviteId,
        isInitiator: existing?.isInitiator ?? false,
      );

      await sessionNotifier.addSession(session);

      // Refresh subscription to listen for messages from the new session
      await sessionManager.refreshSubscription();

      state = state.copyWith(isAccepting: false);
      return sessionId;
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(isAccepting: false, error: appError.message);
      return null;
    }
  }

  /// Accept a private link invite as the owner and register the new device in AppKeys.
  ///
  /// Returns true on success.
  Future<bool> acceptLinkInviteFromUrl(String url) async {
    state = state.copyWith(isAccepting: true, error: null);
    try {
      final authState = _ref.read(authStateProvider);
      if (!authState.isAuthenticated || authState.pubkeyHex == null) {
        throw Exception('Not authenticated');
      }
      if (authState.isLinkedDevice) {
        throw Exception('Linked devices cannot accept link invites');
      }

      final authRepo = _ref.read(authRepositoryProvider);
      final ownerPrivkeyHex = await authRepo.getPrivateKey();
      if (ownerPrivkeyHex == null) {
        throw Exception('Private key not found');
      }

      final ownerPubkeyHex = authState.pubkeyHex!;
      final devicePubkeyHex = await NdrFfi.derivePublicKey(ownerPrivkeyHex);

      final sessionManager = _ref.read(sessionManagerServiceProvider);
      final acceptResult = await sessionManager.acceptInviteFromUrl(
        inviteUrl: url,
        ownerPubkeyHintHex: ownerPubkeyHex,
      );
      final linkedDevicePubkeyHex = acceptResult.inviterDevicePubkeyHex;

      // Publish updated AppKeys authorizing the new device.
      await _publishMergedAppKeys(
        ownerPubkeyHex: ownerPubkeyHex,
        ownerPrivkeyHex: ownerPrivkeyHex,
        devicePubkeysToEnsure: {devicePubkeyHex, linkedDevicePubkeyHex},
      );

      // Best-effort refresh so the local SessionManager can learn about the new device quickly.
      await _ref.read(sessionManagerServiceProvider).refreshSubscription();

      state = state.copyWith(isAccepting: false);
      return true;
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(isAccepting: false, error: appError.message);
      return false;
    }
  }

  /// Get the URL for an invite.
  Future<String?> getInviteUrl(
    String inviteId, {
    String root = 'https://chat.iris.to',
  }) async {
    InviteHandle? inviteHandle;
    Invite? invite;
    try {
      invite = await _datasource.getInvite(inviteId);
      if (invite?.serializedState == null) return null;

      inviteHandle = await NdrFfi.inviteDeserialize(invite!.serializedState!);
      return await inviteHandle.toUrl(root);
    } catch (e, st) {
      // Self-heal corrupted invite state (observed as `CryptoFailure("invalid HMAC")`).
      if (_looksLikeInvalidHmacError(e)) {
        try {
          await deleteInvite(inviteId);
        } catch (_) {}

        // Best-effort: create a replacement invite so the user can copy/share immediately.
        try {
          final replacement = await createInvite(
            label: invite?.label,
            maxUses: invite?.maxUses,
          );
          if (replacement?.serializedState == null) return null;

          inviteHandle = await NdrFfi.inviteDeserialize(
            replacement!.serializedState!,
          );
          return await inviteHandle.toUrl(root);
        } catch (_) {
          // If regeneration fails, fall through to a generic error.
        }
      }

      final appError = AppError.from(e, st);
      state = state.copyWith(error: appError.message);
      return null;
    } finally {
      try {
        await inviteHandle?.dispose();
      } catch (_) {}
    }
  }

  /// Delete an invite.
  Future<void> deleteInvite(String id) async {
    await _datasource.deleteInvite(id);
    state = state.copyWith(
      invites: state.invites.where((i) => i.id != id).toList(),
    );
  }

  /// Update invite label.
  Future<void> updateLabel(String id, String label) async {
    final invite = state.invites.firstWhere((i) => i.id == id);
    final updated = invite.copyWith(label: label);
    await _datasource.updateInvite(updated);

    state = state.copyWith(
      invites: state.invites.map((i) => i.id == id ? updated : i).toList(),
    );
  }

  /// Handle an invite response event from Nostr.
  Future<void> handleInviteResponse(String inviteId, String eventJson) async {
    Logger.info(
      'Processing invite response',
      category: LogCategory.nostr,
      data: {'inviteId': inviteId},
    );

    InviteHandle? inviteHandle;
    InviteResponseResult? result;
    try {
      final invite = await _datasource.getInvite(inviteId);
      if (invite == null || invite.serializedState == null) {
        Logger.warning(
          'Invite not found for response',
          category: LogCategory.nostr,
          data: {'inviteId': inviteId},
        );
        return;
      }

      final authState = _ref.read(authStateProvider);
      if (!authState.isAuthenticated || authState.pubkeyHex == null) {
        throw Exception('Not authenticated');
      }

      // Get private key from storage
      final authRepo = _ref.read(authRepositoryProvider);
      final devicePrivkeyHex = await authRepo.getPrivateKey();
      if (devicePrivkeyHex == null) {
        throw Exception('Private key not found');
      }

      final sessionManager = _ref.read(sessionManagerServiceProvider);
      inviteHandle = await NdrFfi.inviteDeserialize(invite.serializedState!);
      result = await inviteHandle.processResponse(
        eventJson: eventJson,
        inviterPrivkeyHex: devicePrivkeyHex,
      );

      if (result == null) {
        return;
      }

      final recipientOwnerPubkey =
          result.ownerPubkeyHex ?? result.inviteePubkeyHex;
      final sessionState = await result.session.stateJson();

      // If we already have a session with this peer, treat this as a replay/duplicate.
      // (Relays can replay stored events on reconnect; multiple relays can send duplicates.)
      final sessionDatasource = _ref.read(sessionDatasourceProvider);
      final existingSession = await sessionDatasource.getSessionByRecipient(
        recipientOwnerPubkey,
      );

      if (existingSession == null) {
        // Store sessions keyed by peer owner pubkey for stable routing/deduping.
        final sessionId = recipientOwnerPubkey;

        // Create session in chat provider
        final sessionNotifier = _ref.read(sessionStateProvider.notifier);
        final session = ChatSession(
          id: sessionId,
          recipientPubkeyHex: recipientOwnerPubkey,
          createdAt: DateTime.now(),
          inviteId: inviteId,
          isInitiator: true,
        );

        await sessionNotifier.addSession(session);
      }

      // SessionManager has no inviter-side "process response" API yet, so
      // import the freshly derived session state on each accepted response.
      //
      // This keeps sender subscriptions fresh when a peer rotates/refreshes sessions,
      // including self-chat interop where a session row may already exist.
      //
      // Interop note: invite responses from some clients omit/repurpose `deviceId`.
      // `inviteePubkeyHex` is the sender identity used for session event authors.
      final remoteDeviceId = result.inviteePubkeyHex;
      await sessionManager.importSessionState(
        peerPubkeyHex: recipientOwnerPubkey,
        stateJson: sessionState,
        deviceId: remoteDeviceId,
      );

      // Mark invite as used
      await _datasource.markUsed(inviteId, recipientOwnerPubkey);

      // Update local state (only if this is a new acceptance for this invite).
      if (!invite.acceptedBy.contains(recipientOwnerPubkey)) {
        final updatedInvite = invite.copyWith(
          useCount: invite.useCount + 1,
          acceptedBy: [...invite.acceptedBy, recipientOwnerPubkey],
        );
        state = state.copyWith(
          invites: state.invites
              .map((i) => i.id == inviteId ? updatedInvite : i)
              .where((i) => i.canBeUsed)
              .toList(),
        );
      }

      // Refresh message subscription to include new session
      await sessionManager.refreshSubscription();

      Logger.info(
        'Invite response processed, session ready',
        category: LogCategory.nostr,
        data: {
          'inviteId': inviteId,
          'invitee': recipientOwnerPubkey.substring(0, 8),
        },
      );
    } catch (e) {
      Logger.error(
        'Failed to process invite response',
        category: LogCategory.nostr,
        error: e,
        data: {'inviteId': inviteId},
      );
      state = state.copyWith(error: AppError.from(e).message);
    } finally {
      try {
        await result?.session.dispose();
      } catch (_) {}
      try {
        await inviteHandle?.dispose();
      } catch (_) {}
    }
  }

  /// Clear error state.
  void clearError() {
    state = state.copyWith(error: null);
  }

  static bool _looksLikeInvalidHmacError(Object error) {
    final s = error.toString().toLowerCase();
    return s.contains('invalid hmac') ||
        s.contains('cryptofailure("invalid hmac")');
  }

  static String? _normalizeDevicePubkeyHex(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    return normalized;
  }

  static void _upsertDeviceCreatedAt(
    Map<String, int> devices, {
    required String identityPubkeyHex,
    required int createdAt,
    required int nowSeconds,
  }) {
    final normalized = _normalizeDevicePubkeyHex(identityPubkeyHex);
    if (normalized == null) return;
    final timestamp = createdAt > 0 ? createdAt : nowSeconds;
    final existing = devices[normalized];
    if (existing == null || timestamp < existing) {
      devices[normalized] = timestamp;
    }
  }

  /// Build the device map that will be published in an AppKeys update.
  ///
  /// This intentionally keeps both locally known and relay-discovered devices
  /// so link acceptance cannot accidentally collapse the set to only a subset.
  static Map<String, int> buildMergedDeviceMap({
    required List<FfiDeviceEntry> localDevices,
    required List<FfiDeviceEntry> relayDevices,
    required Set<String> ensurePubkeys,
    required int nowSeconds,
  }) {
    final devices = <String, int>{};

    for (final device in localDevices) {
      _upsertDeviceCreatedAt(
        devices,
        identityPubkeyHex: device.identityPubkeyHex,
        createdAt: device.createdAt,
        nowSeconds: nowSeconds,
      );
    }

    for (final device in relayDevices) {
      _upsertDeviceCreatedAt(
        devices,
        identityPubkeyHex: device.identityPubkeyHex,
        createdAt: device.createdAt,
        nowSeconds: nowSeconds,
      );
    }

    for (final pubkey in ensurePubkeys) {
      final normalized = _normalizeDevicePubkeyHex(pubkey);
      if (normalized == null) continue;
      devices.putIfAbsent(normalized, () => nowSeconds);
    }

    return devices;
  }

  Future<void> _publishMergedAppKeys({
    required String ownerPubkeyHex,
    required String ownerPrivkeyHex,
    required Set<String> devicePubkeysToEnsure,
  }) async {
    final nostrService = _ref.read(nostrServiceProvider);

    final existing = await _fetchLatestAppKeysEvent(
      nostrService,
      ownerPubkeyHex: ownerPubkeyHex,
    );

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final localDevices = _ref.read(deviceManagerProvider).devices;
    final relayDevices = <FfiDeviceEntry>[];
    if (existing != null) {
      relayDevices.addAll(
        await NdrFfi.parseAppKeysEvent(jsonEncode(existing.toJson())),
      );
    }
    final devices = buildMergedDeviceMap(
      localDevices: localDevices,
      relayDevices: relayDevices,
      ensurePubkeys: devicePubkeysToEnsure,
      nowSeconds: now,
    );

    final eventJson = await NdrFfi.createSignedAppKeysEvent(
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      devices: devices.entries
          .map(
            (e) => FfiDeviceEntry(identityPubkeyHex: e.key, createdAt: e.value),
          )
          .toList(),
    );

    await nostrService.publishEvent(eventJson);
  }

  Future<NostrEvent?> _fetchLatestAppKeysEvent(
    NostrService nostrService, {
    required String ownerPubkeyHex,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    return fetchLatestAppKeysEvent(
      nostrService,
      ownerPubkeyHex: ownerPubkeyHex,
      timeout: timeout,
      subscriptionLabel: 'appkeys-fetch',
    );
  }
}

// Provider

final inviteDatasourceProvider = Provider<InviteLocalDatasource>((ref) {
  final db = ref.watch(databaseServiceProvider);
  return InviteLocalDatasource(db);
});

final inviteStateProvider = StateNotifierProvider<InviteNotifier, InviteState>((
  ref,
) {
  final datasource = ref.watch(inviteDatasourceProvider);
  return InviteNotifier(datasource, ref);
});
