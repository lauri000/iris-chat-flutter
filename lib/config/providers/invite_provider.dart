import 'dart:async';
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
import '../../core/utils/device_labels.dart';
import '../../core/utils/invite_response_subscription.dart';
import '../../core/utils/invite_url.dart';
import '../../features/chat/domain/models/session.dart';
import '../../features/invite/data/datasources/invite_local_datasource.dart';
import '../../features/invite/domain/models/invite.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'device_manager_provider.dart';
import 'nostr_provider.dart';

part 'invite_provider.freezed.dart';

const String canonicalPublicInviteDeviceId = 'public';

int? effectiveInviteMaxUses({
  required int? requestedMaxUses,
  bool defaultToSingleUse = true,
}) {
  return requestedMaxUses ?? (defaultToSingleUse ? 1 : null);
}

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

  static String? serializedInviteDeviceId(String serializedState) {
    try {
      final decoded = jsonDecode(serializedState);
      if (decoded is Map<String, dynamic>) {
        final deviceId = decoded['deviceId'];
        if (deviceId is String && deviceId.isNotEmpty) {
          return deviceId;
        }
      }
    } catch (_) {}
    return null;
  }

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
    bool defaultToSingleUse = true,
    String? deviceIdOverride,
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

      // Most chat invites should stay single-use, but the app's long-lived
      // public invite must explicitly keep `maxUses` unlimited across restarts.
      final effectiveMaxUses = effectiveInviteMaxUses(
        requestedMaxUses: maxUses,
        defaultToSingleUse: defaultToSingleUse,
      );

      final inviteDeviceId =
          deviceIdOverride != null && deviceIdOverride.trim().isNotEmpty
          ? deviceIdOverride.trim()
          : devicePubkeyHex;

      // Create invite using ndr-ffi
      inviteHandle = await NdrFfi.createInvite(
        inviterPubkeyHex: devicePubkeyHex,
        deviceId: inviteDeviceId,
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

      await _refreshInviteResponseSubscription();

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

    Invite? inviteToPublish;
    final existingInvites = await _datasource.getActiveInvites();
    for (final invite in existingInvites) {
      if (invite.maxUses != null) continue;
      if (invite.serializedState == null || invite.serializedState!.isEmpty) {
        continue;
      }
      final deviceId = serializedInviteDeviceId(invite.serializedState!);
      if (deviceId != canonicalPublicInviteDeviceId) continue;
      inviteToPublish = invite;
      break;
    }

    inviteToPublish ??= await createInvite(
      maxUses: null,
      defaultToSingleUse: false,
      deviceIdOverride: canonicalPublicInviteDeviceId,
    );

    final serializedState = inviteToPublish?.serializedState;
    if (serializedState != null && serializedState.isNotEmpty) {
      await _refreshInviteResponseSubscription();
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

  Future<void> _refreshInviteResponseSubscription() async {
    try {
      await refreshInviteResponseSubscription(
        nostrService: _ref.read(nostrServiceProvider),
        inviteDatasource: _datasource,
        subscriptionId: appInviteResponsesSubId,
      );
    } catch (_) {}
  }

  Future<void> bootstrapInviteResponsesFromRelay({
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final inviteIdsByEphemeralPubkey = <String, String>{};
    final activeInvites = await _datasource.getActiveInvites();
    for (final invite in activeInvites) {
      final serialized = invite.serializedState;
      if (serialized == null || serialized.isEmpty) continue;
      final eph = await resolveInviteEphemeralPubkey(serialized);
      if (eph == null || eph.isEmpty) continue;
      inviteIdsByEphemeralPubkey[eph] = invite.id;
    }

    if (inviteIdsByEphemeralPubkey.isEmpty) return;

    final nostrService = _ref.read(nostrServiceProvider);
    final subscriptionId =
        'invite-response-bootstrap-${DateTime.now().microsecondsSinceEpoch}';
    final seenEventIds = <String>{};
    final matchingEvents = <NostrEvent>[];
    var completed = false;
    Timer? settleTimer;
    late final StreamSubscription<NostrEvent> sub;

    Future<List<NostrEvent>> finish() async {
      if (!completed) {
        completed = true;
        settleTimer?.cancel();
        await sub.cancel();
        nostrService.closeSubscription(subscriptionId);
      }

      matchingEvents.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return matchingEvents;
    }

    final completer = Completer<List<NostrEvent>>();
    void scheduleFinish() {
      if (completed) return;
      settleTimer?.cancel();
      settleTimer = Timer(const Duration(milliseconds: 100), () async {
        if (completer.isCompleted) return;
        completer.complete(await finish());
      });
    }

    sub = nostrService.events.listen((event) {
      if (event.subscriptionId != subscriptionId) return;
      if (event.kind != 1059) return;

      final matchesKnownInvite = event.tags.any(
        (tag) =>
            tag.length >= 2 &&
            tag[0] == 'p' &&
            inviteIdsByEphemeralPubkey.containsKey(tag[1]),
      );
      if (!matchesKnownInvite || !seenEventIds.add(event.id)) return;

      matchingEvents.add(event);
      scheduleFinish();
    });

    nostrService.subscribeWithIdRaw(subscriptionId, <String, dynamic>{
      'kinds': const [1059],
      '#p': inviteIdsByEphemeralPubkey.keys.toList()..sort(),
      'limit': 200,
    });

    Timer(timeout, () async {
      if (completer.isCompleted) return;
      completer.complete(await finish());
    });

    final replayedEvents = await completer.future;
    for (final event in replayedEvents) {
      for (final tag in event.tags) {
        if (tag.length < 2 || tag[0] != 'p') continue;
        final inviteId = inviteIdsByEphemeralPubkey[tag[1]];
        if (inviteId == null) continue;
        await handleInviteResponse(inviteId, jsonEncode(event.toJson()));
        break;
      }
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
      final sessionId = await _upsertAcceptedSession(
        acceptResult.ownerPubkeyHex,
      );

      state = state.copyWith(isAccepting: false);
      return sessionId;
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(isAccepting: false, error: appError.message);
      return null;
    }
  }

  /// Accept a published device invite for a bare owner pubkey / npub link.
  ///
  /// Returns the established session id when a public invite exists and can be
  /// accepted, otherwise `null` so callers can fall back to a placeholder row.
  Future<String?> acceptPublicInviteForPubkey(String ownerPubkeyHex) async {
    state = state.copyWith(isAccepting: true, error: null);
    try {
      final authState = _ref.read(authStateProvider);
      if (!authState.isAuthenticated || authState.pubkeyHex == null) {
        throw Exception('Not authenticated');
      }

      final normalizedOwnerPubkeyHex = _normalizeDevicePubkeyHex(
        ownerPubkeyHex,
      );
      if (normalizedOwnerPubkeyHex == null) {
        throw Exception('Invalid public key');
      }

      final sessionManager = _ref.read(sessionManagerServiceProvider);
      await sessionManager.setupUser(normalizedOwnerPubkeyHex);

      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(deadline)) {
        final activeSessionState = await sessionManager.getActiveSessionState(
          normalizedOwnerPubkeyHex,
        );
        if (activeSessionState != null && activeSessionState.isNotEmpty) {
          final sessionId = await _upsertAcceptedSession(
            normalizedOwnerPubkeyHex,
          );
          state = state.copyWith(isAccepting: false);
          return sessionId;
        }

        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      state = state.copyWith(isAccepting: false, error: null);
      return null;
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
      if (!authState.hasOwnerKey) {
        throw Exception('Linked devices cannot accept link invites');
      }

      final authRepo = _ref.read(authRepositoryProvider);
      final ownerPrivkeyHex = await authRepo.getOwnerPrivateKey();
      if (ownerPrivkeyHex == null) {
        throw Exception('Private key not found');
      }

      final ownerPubkeyHex = authState.pubkeyHex!;
      final devicePrivkeyHex = await authRepo.getPrivateKey();
      if (devicePrivkeyHex == null) {
        throw Exception('Device key not found');
      }
      final devicePubkeyHex = await NdrFfi.derivePublicKey(devicePrivkeyHex);

      final sessionManager = _ref.read(sessionManagerServiceProvider);
      final acceptResult = await sessionManager.acceptInviteFromUrl(
        inviteUrl: url,
        ownerPubkeyHintHex: ownerPubkeyHex,
      );
      final linkedDevicePubkeyHex = acceptResult.inviterDevicePubkeyHex;

      // Publish updated AppKeys authorizing the new device.
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _publishMergedAppKeys(
        ownerPubkeyHex: ownerPubkeyHex,
        ownerPrivkeyHex: ownerPrivkeyHex,
        deviceEntriesToEnsure: [
          buildCurrentDeviceEntry(
            identityPubkeyHex: devicePubkeyHex,
            createdAt: now,
          ),
          buildLinkedDeviceEntry(
            identityPubkeyHex: linkedDevicePubkeyHex,
            createdAt: now,
          ),
        ],
      );

      // Re-bootstrap the owner's own device graph now that AppKeys includes the
      // newly linked device, so current invite/session subscriptions cover it
      // across later restarts.
      await sessionManager.setupUser(ownerPubkeyHex);
      await sessionManager.bootstrapUsersFromRelay([ownerPubkeyHex]);

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
            defaultToSingleUse: invite?.maxUses != null,
            deviceIdOverride:
                invite?.serializedState != null &&
                    serializedInviteDeviceId(invite!.serializedState!) ==
                        canonicalPublicInviteDeviceId
                ? canonicalPublicInviteDeviceId
                : null,
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

      final remoteDeviceId = result.remoteDeviceId;
      final normalizedRecipientOwnerPubkey = _normalizeDevicePubkeyHex(
        recipientOwnerPubkey,
      );
      final normalizedRemoteDeviceId = _normalizeDevicePubkeyHex(
        remoteDeviceId,
      );

      // Owner-level active-session checks are only safe for owner-device responses.
      // Linked-device responses must still be imported so the native manager can
      // attach state to that specific remote device record.
      final isOwnerDeviceResponse =
          normalizedRecipientOwnerPubkey != null &&
          normalizedRecipientOwnerPubkey == normalizedRemoteDeviceId;
      var shouldImportSessionState = !isOwnerDeviceResponse;
      if (!shouldImportSessionState) {
        final activeSessionState = await sessionManager.getActiveSessionState(
          recipientOwnerPubkey,
        );
        shouldImportSessionState =
            activeSessionState == null ||
            activeSessionState.isEmpty ||
            !_sessionStateHasReceivingCapability(activeSessionState);
      }

      if (shouldImportSessionState) {
        await sessionManager.importSessionState(
          peerPubkeyHex: recipientOwnerPubkey,
          stateJson: sessionState,
          deviceId: remoteDeviceId,
        );
      }

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

  static bool _sessionStateHasReceivingCapability(String stateJson) {
    try {
      final decoded = jsonDecode(stateJson);
      if (decoded is! Map<String, dynamic>) return false;

      final receivingChainKey =
          decoded['receiving_chain_key'] ?? decoded['receivingChainKey'];
      final theirCurrent =
          decoded['their_current_nostr_public_key'] ??
          decoded['theirCurrentNostrPublicKey'];
      final receivingNumber =
          decoded['receiving_chain_message_number'] ??
          decoded['receivingChainMessageNumber'];

      return receivingChainKey != null ||
          theirCurrent != null ||
          (receivingNumber is num && receivingNumber.toInt() > 0);
    } catch (_) {
      return false;
    }
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
    required List<FfiDeviceEntry> deviceEntriesToEnsure,
  }) async {
    final nostrService = _ref.read(nostrServiceProvider);
    final localDevices = _ref.read(deviceManagerProvider).devices;

    final relayDevices = await _fetchLatestAppKeysDevicesWithRetry(
      nostrService,
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      retry: localDevices.isEmpty,
    );

    final devices = mergeDeviceEntries(
      existingDevices: [...localDevices, ...relayDevices],
      ensuredDevices: deviceEntriesToEnsure,
    );

    final eventJson = await NdrFfi.createSignedAppKeysEvent(
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      devices: devices,
    );

    await nostrService.publishEvent(eventJson);
  }

  Future<List<FfiDeviceEntry>> _fetchLatestAppKeysDevices(
    NostrService nostrService, {
    required String ownerPubkeyHex,
    String? ownerPrivkeyHex,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    return fetchLatestAppKeysDevices(
      nostrService,
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      timeout: timeout,
      subscriptionLabel: 'appkeys-fetch',
    );
  }

  Future<List<FfiDeviceEntry>> _fetchLatestAppKeysDevicesWithRetry(
    NostrService nostrService, {
    required String ownerPubkeyHex,
    String? ownerPrivkeyHex,
    required bool retry,
  }) async {
    final first = await _fetchLatestAppKeysDevices(
      nostrService,
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      timeout: retry ? const Duration(seconds: 1) : const Duration(seconds: 2),
    );
    if (first.isNotEmpty || !retry) return first;

    await Future<void>.delayed(const Duration(milliseconds: 400));
    return _fetchLatestAppKeysDevices(
      nostrService,
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      timeout: const Duration(seconds: 1),
    );
  }

  Future<String> _upsertAcceptedSession(String recipientOwnerPubkeyHex) async {
    final normalizedRecipient = _normalizeDevicePubkeyHex(
      recipientOwnerPubkeyHex,
    );
    if (normalizedRecipient == null) {
      throw Exception('Invalid public key');
    }

    final sessionDatasource = _ref.read(sessionDatasourceProvider);
    final existing = await sessionDatasource.getSessionByRecipient(
      normalizedRecipient,
    );
    final sessionId = existing?.id ?? normalizedRecipient;

    final sessionNotifier = _ref.read(sessionStateProvider.notifier);
    final session = ChatSession(
      id: sessionId,
      recipientPubkeyHex: normalizedRecipient,
      recipientName: existing?.recipientName,
      createdAt: existing?.createdAt ?? DateTime.now(),
      lastMessageAt: existing?.lastMessageAt,
      lastMessagePreview: existing?.lastMessagePreview,
      unreadCount: existing?.unreadCount ?? 0,
      inviteId: existing?.inviteId,
      isInitiator: existing?.isInitiator ?? false,
    );

    await sessionNotifier.addSession(session);
    await _ref.read(sessionManagerServiceProvider).refreshSubscription();
    return sessionId;
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
