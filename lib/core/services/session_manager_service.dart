import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../features/auth/domain/repositories/auth_repository.dart';
import '../ffi/ndr_ffi.dart';
import 'logger_service.dart';
import 'nostr_service.dart';

class DecryptedMessage {
  const DecryptedMessage({
    required this.senderPubkeyHex,
    required this.content,
    this.eventId,
    this.createdAt,
  });

  final String senderPubkeyHex;
  final String content;
  final String? eventId;
  final int? createdAt;
}

/// Bridges NDR SessionManager with the app's Nostr transport.
class SessionManagerService {
  SessionManagerService(
    this._nostrService,
    this._authRepository, {
    String? storagePathOverride,
  }) : _storagePathOverride = storagePathOverride;

  final NostrService _nostrService;
  final AuthRepository _authRepository;
  final String? _storagePathOverride;

  final StreamController<DecryptedMessage> _decryptedController =
      StreamController<DecryptedMessage>.broadcast();

  Stream<DecryptedMessage> get decryptedMessages => _decryptedController.stream;

  SessionManagerHandle? _manager;
  String? _ownerPubkeyHex;
  String? _devicePubkeyHex;
  StreamSubscription<NostrEvent>? _eventSubscription;
  Timer? _drainTimer;
  bool _draining = false;
  bool _started = false;
  bool _isDisposed = false;
  Future<void> _opQueue = Future.value();
  final Map<String, int> _eventTimestamps = {};
  static const String _groupOuterSubId = 'ndr-group-outer';
  List<String> _groupOuterSenderEventPubkeys = const [];

  /// Owner public key (hex) for this session manager (differs for linked devices).
  String? get ownerPubkeyHex => _ownerPubkeyHex;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    await _runExclusive(() async {
      await _initManager();
    });

    _eventSubscription = _nostrService.events.listen((event) {
      _runExclusiveDetached(() async {
        await _handleEvent(event);
      });
    });

    // Periodically drain events to avoid missing publishes/subscriptions.
    _drainTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _runExclusiveDetached(() async {
        await _drainEventsUnlocked();
      });
    });
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    _nostrService.closeSubscription(_groupOuterSubId);
    _groupOuterSenderEventPubkeys = const [];
    _drainTimer?.cancel();
    _drainTimer = null;
    try {
      await _opQueue;
    } catch (_) {}
    final manager = _manager;
    _manager = null;
    try {
      await manager?.dispose();
    } catch (_) {}
    await _decryptedController.close();
  }

  Future<void> refreshSubscription() async {
    await _runExclusive(() async {
      await _drainEventsUnlocked();
    });
  }

  Future<List<String>> sendText({
    required String recipientPubkeyHex,
    required String text,
    int? expiresAtSeconds,
  }) async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      final eventIds = await manager.sendText(
        recipientPubkeyHex: recipientPubkeyHex,
        text: text,
        expiresAtSeconds: expiresAtSeconds,
      );
      await _drainEventsUnlocked();
      return eventIds;
    });
  }

  Future<SendTextWithInnerIdResult> sendTextWithInnerId({
    required String recipientPubkeyHex,
    required String text,
    int? expiresAtSeconds,
  }) async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      final sendResult = await manager.sendTextWithInnerId(
        recipientPubkeyHex: recipientPubkeyHex,
        text: text,
        expiresAtSeconds: expiresAtSeconds,
      );
      await _drainEventsUnlocked();
      return sendResult;
    });
  }

  Future<SendTextWithInnerIdResult> sendEventWithInnerId({
    required String recipientPubkeyHex,
    required int kind,
    required String content,
    required String tagsJson,
    int? createdAtSeconds,
  }) async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      final sendResult = await manager.sendEventWithInnerId(
        recipientPubkeyHex: recipientPubkeyHex,
        kind: kind,
        content: content,
        tagsJson: tagsJson,
        createdAtSeconds: createdAtSeconds,
      );
      await _drainEventsUnlocked();
      return sendResult;
    });
  }

  Future<void> groupUpsert({
    required String id,
    required String name,
    String? description,
    String? picture,
    required List<String> members,
    required List<String> admins,
    required int createdAtMs,
    String? secret,
    bool? accepted,
  }) async {
    await _runExclusive(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      await manager.groupUpsert(
        FfiGroupData(
          id: id,
          name: name,
          description: description,
          picture: picture,
          members: members,
          admins: admins,
          createdAtMs: createdAtMs,
          secret: secret,
          accepted: accepted,
        ),
      );
      await _refreshGroupOuterSubscription();
    });
  }

  Future<GroupCreateResult> groupCreate({
    required String name,
    required List<String> memberOwnerPubkeys,
    bool fanoutMetadata = true,
    int? nowMs,
  }) async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      final created = await manager.groupCreate(
        name: name,
        memberOwnerPubkeys: memberOwnerPubkeys,
        fanoutMetadata: fanoutMetadata,
        nowMs: nowMs,
      );
      await _drainEventsUnlocked();
      await _refreshGroupOuterSubscription();
      return created;
    });
  }

  Future<void> groupRemove(String groupId) async {
    await _runExclusive(() async {
      final manager = _manager;
      if (manager == null) return;
      await manager.groupRemove(groupId);
      await _refreshGroupOuterSubscription();
    });
  }

  Future<GroupSendResult> groupSendEvent({
    required String groupId,
    required int kind,
    required String content,
    required String tagsJson,
    int? nowMs,
  }) async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      final sendResult = await manager.groupSendEvent(
        groupId: groupId,
        kind: kind,
        content: content,
        tagsJson: tagsJson,
        nowMs: nowMs,
      );
      await _drainEventsUnlocked();
      await _refreshGroupOuterSubscription();
      return sendResult;
    });
  }

  Future<List<GroupDecryptedResult>> groupHandleIncomingSessionEvent({
    required String eventJson,
    required String fromOwnerPubkeyHex,
    String? fromSenderDevicePubkeyHex,
  }) async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) return const <GroupDecryptedResult>[];
      final events = await manager.groupHandleIncomingSessionEvent(
        eventJson: eventJson,
        fromOwnerPubkeyHex: fromOwnerPubkeyHex,
        fromSenderDevicePubkeyHex: fromSenderDevicePubkeyHex,
      );
      await _refreshGroupOuterSubscription();
      return events;
    });
  }

  Future<void> sendReceipt({
    required String recipientPubkeyHex,
    required String receiptType,
    required List<String> messageIds,
  }) async {
    await _runExclusive(() async {
      final manager = _manager;
      if (manager == null) return;
      await manager.sendReceipt(
        recipientPubkeyHex: recipientPubkeyHex,
        receiptType: receiptType,
        messageIds: messageIds,
      );
      await _drainEventsUnlocked();
    });
  }

  Future<void> sendTyping({
    required String recipientPubkeyHex,
    int? expiresAtSeconds,
  }) async {
    await _runExclusive(() async {
      final manager = _manager;
      if (manager == null) return;
      await manager.sendTyping(
        recipientPubkeyHex: recipientPubkeyHex,
        expiresAtSeconds: expiresAtSeconds,
      );
      await _drainEventsUnlocked();
    });
  }

  Future<void> sendReaction({
    required String recipientPubkeyHex,
    required String messageId,
    required String emoji,
  }) async {
    await _runExclusive(() async {
      final manager = _manager;
      if (manager == null) return;
      await manager.sendReaction(
        recipientPubkeyHex: recipientPubkeyHex,
        messageId: messageId,
        emoji: emoji,
      );
      await _drainEventsUnlocked();
    });
  }

  Future<void> importSessionState({
    required String peerPubkeyHex,
    required String stateJson,
    String? deviceId,
  }) async {
    await _runExclusive(() async {
      final manager = _manager;
      if (manager == null) return;
      await manager.importSessionState(
        peerPubkeyHex: peerPubkeyHex,
        stateJson: stateJson,
        deviceId: deviceId,
      );
    });
  }

  Future<String?> getActiveSessionState(String peerPubkeyHex) async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) return null;
      return manager.getActiveSessionState(peerPubkeyHex);
    });
  }

  Future<int> getTotalSessions() async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) return 0;
      return manager.getTotalSessions();
    });
  }

  Future<SessionManagerAcceptInviteResult> acceptInviteFromUrl({
    required String inviteUrl,
    String? ownerPubkeyHintHex,
  }) async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      final result = await manager.acceptInviteFromUrl(
        inviteUrl: inviteUrl,
        ownerPubkeyHintHex: ownerPubkeyHintHex,
      );
      await _drainEventsUnlocked();
      return result;
    });
  }

  Future<SessionManagerAcceptInviteResult> acceptInviteFromEventJson({
    required String eventJson,
    String? ownerPubkeyHintHex,
  }) async {
    return _runExclusive(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      final result = await manager.acceptInviteFromEventJson(
        eventJson: eventJson,
        ownerPubkeyHintHex: ownerPubkeyHintHex,
      );
      await _drainEventsUnlocked();
      return result;
    });
  }

  Future<void> _initManager() async {
    final identity = await _authRepository.getCurrentIdentity();
    final devicePrivkeyHex = await _authRepository.getPrivateKey();
    if (identity?.pubkeyHex == null || devicePrivkeyHex == null) {
      Logger.warning(
        'Session manager not initialized: missing identity',
        category: LogCategory.session,
      );
      return;
    }

    final ownerPubkeyHex = identity!.pubkeyHex;
    final devicePubkeyHex = await NdrFfi.derivePublicKey(devicePrivkeyHex);

    final storagePath = await _resolveStoragePath();
    // ndr-ffi expects the directory to exist.
    await Directory(storagePath).create(recursive: true);

    _manager = await NdrFfi.createSessionManager(
      ourPubkeyHex: devicePubkeyHex,
      ourIdentityPrivkeyHex: devicePrivkeyHex,
      deviceId: devicePubkeyHex,
      storagePath: storagePath,
      ownerPubkeyHex: ownerPubkeyHex == devicePubkeyHex ? null : ownerPubkeyHex,
    );

    await _manager!.init();
    _ownerPubkeyHex = await _manager!.getOwnerPubkeyHex();
    _devicePubkeyHex = devicePubkeyHex;

    await _drainEventsUnlocked();
    await _refreshGroupOuterSubscription();
  }

  Future<String> _resolveStoragePath() async {
    final override = _storagePathOverride;
    if (override != null && override.isNotEmpty) return override;

    final supportDir = await getApplicationSupportDirectory();
    return '${supportDir.path}/ndr';
  }

  Future<void> _handleEvent(NostrEvent event) async {
    // Only handle NDR-related kinds to reduce overhead.
    if (event.kind != 1060 &&
        event.kind != 1058 &&
        event.kind != 1059 &&
        event.kind != 30078) {
      return;
    }

    // De-dupe by id. It's normal to receive the same event multiple times
    // (multiple relays, overlapping subscriptions, reconnect replays).
    if (_eventTimestamps.containsKey(event.id)) return;
    _eventTimestamps[event.id] = event.createdAt;
    // Prevent unbounded growth in long-running sessions.
    if (_eventTimestamps.length > 10000) {
      // Map preserves insertion order; drop oldest.
      final keys = _eventTimestamps.keys.take(2000).toList();
      for (final k in keys) {
        _eventTimestamps.remove(k);
      }
    }

    final manager = _manager;
    if (manager == null) return;
    final eventJson = jsonEncode(event.toJson());
    await manager.processEvent(eventJson);
    if (event.kind == 1060) {
      try {
        final decrypted = await manager.groupHandleOuterEvent(eventJson);
        if (decrypted != null) {
          _decryptedController.add(
            DecryptedMessage(
              senderPubkeyHex: _resolveGroupSenderPubkeyHex(decrypted),
              content: decrypted.innerEventJson,
              eventId: decrypted.outerEventId,
              createdAt: decrypted.outerCreatedAt,
            ),
          );
        }
      } catch (_) {}
    }
    await _drainEventsUnlocked();
  }

  String _resolveGroupSenderPubkeyHex(GroupDecryptedResult decrypted) {
    final owner = _ownerPubkeyHex?.trim().toLowerCase();
    final device = _devicePubkeyHex?.trim().toLowerCase();
    final senderOwner = decrypted.senderOwnerPubkeyHex?.trim().toLowerCase();
    final senderDevice = decrypted.senderDevicePubkeyHex.trim().toLowerCase();

    if (senderOwner != null && senderOwner.isNotEmpty) {
      return senderOwner;
    }

    if (owner != null &&
        owner.isNotEmpty &&
        device != null &&
        device.isNotEmpty &&
        senderDevice == device) {
      return owner;
    }

    return senderDevice;
  }

  Future<void> _refreshGroupOuterSubscription() async {
    final manager = _manager;
    if (manager == null) return;

    final next = await manager.groupKnownSenderEventPubkeys();
    next.sort();
    final deduped = <String>[];
    for (final pk in next) {
      if (pk.isEmpty) continue;
      if (deduped.isNotEmpty && deduped.last == pk) continue;
      deduped.add(pk);
    }

    if (_stringListsEqual(_groupOuterSenderEventPubkeys, deduped)) {
      return;
    }

    _groupOuterSenderEventPubkeys = deduped;
    _nostrService.closeSubscription(_groupOuterSubId);
    if (deduped.isEmpty) return;

    _nostrService.subscribeWithIdRaw(_groupOuterSubId, <String, dynamic>{
      'kinds': const [1060],
      'authors': deduped,
    });
  }

  bool _stringListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _drainEventsUnlocked() async {
    final manager = _manager;
    if (manager == null || _draining || _isDisposed) return;
    _draining = true;
    try {
      while (true) {
        final events = await manager.drainEvents();
        if (events.isEmpty) break;
        for (final event in events) {
          await _handlePubSubEvent(event);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _handlePubSubEvent(PubSubEvent event) async {
    final manager = _manager;
    switch (event.kind) {
      case 'publish':
      case 'publish_signed':
        if (event.eventJson != null) {
          try {
            await _nostrService.publishEvent(event.eventJson!);
          } catch (_) {}
          // Loop back our own publishes so the native manager can advance state and
          // update subscriptions without relying on a relay echo + subscription.
          //
          // This is important for back-to-back sends (e.g., auto receipts + user reply).
          if (manager != null) {
            try {
              final decoded =
                  jsonDecode(event.eventJson!) as Map<String, dynamic>;
              final id = decoded['id'];
              final createdAt = decoded['created_at'];
              if (id is String && createdAt is num) {
                _eventTimestamps[id] = createdAt.toInt();
                if (_eventTimestamps.length > 10000) {
                  final keys = _eventTimestamps.keys.take(2000).toList();
                  for (final k in keys) {
                    _eventTimestamps.remove(k);
                  }
                }
              }
            } catch (_) {}
            try {
              await manager.processEvent(event.eventJson!);
            } catch (_) {}
          }
        }
        break;
      case 'subscribe':
        if (event.subid != null && event.filterJson != null) {
          final filterMap =
              jsonDecode(event.filterJson!) as Map<String, dynamic>;
          // Preserve unknown tag filters like `#d` and `#l`.
          _nostrService.subscribeWithIdRaw(event.subid!, filterMap);
        }
        break;
      case 'unsubscribe':
        if (event.subid != null) {
          _nostrService.closeSubscription(event.subid!);
        }
        break;
      case 'decrypted_message':
        if (event.senderPubkeyHex != null && event.content != null) {
          final createdAt = event.eventId != null
              ? _eventTimestamps[event.eventId!]
              : null;
          _decryptedController.add(
            DecryptedMessage(
              senderPubkeyHex: event.senderPubkeyHex!,
              content: event.content!,
              eventId: event.eventId,
              createdAt: createdAt,
            ),
          );
        }
        break;
      case 'received_event':
        // Optional: forward to app if needed.
        break;
    }
  }

  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();

    _opQueue = _opQueue
        .then((_) async {
          if (_isDisposed) {
            throw const NostrException('Session manager disposed');
          }
          final result = await action();
          if (!completer.isCompleted) {
            completer.complete(result);
          }
        })
        .catchError((error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        });

    return completer.future;
  }

  void _runExclusiveDetached(Future<void> Function() action) {
    _opQueue = _opQueue
        .then((_) async {
          if (_isDisposed) return;
          await action();
        })
        .catchError((error, stackTrace) {});
  }
}
