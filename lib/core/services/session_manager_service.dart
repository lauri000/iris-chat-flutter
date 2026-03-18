import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../features/auth/domain/repositories/auth_repository.dart';
import '../ffi/ndr_ffi.dart';
import '../utils/app_keys_event_fetch.dart';
import '../utils/device_invite_event_fetch.dart';
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

String? _jsonStringValue(
  Map<String, dynamic> map,
  String snakeKey,
  String camelKey,
) {
  final value = map[snakeKey] ?? map[camelKey];
  if (value is String && value.isNotEmpty) return value;
  return null;
}

bool sessionStateHasReceivingCapabilityJson(String stateJson) {
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

bool sessionStateTracksSenderPubkeyJson(
  String stateJson,
  String senderPubkeyHex,
) {
  try {
    final decoded = jsonDecode(stateJson);
    if (decoded is! Map<String, dynamic>) return false;

    final normalizedSender = senderPubkeyHex.trim().toLowerCase();
    if (normalizedSender.isEmpty) return false;

    final current = _jsonStringValue(
      decoded,
      'their_current_nostr_public_key',
      'theirCurrentNostrPublicKey',
    );
    final next = _jsonStringValue(
      decoded,
      'their_next_nostr_public_key',
      'theirNextNostrPublicKey',
    );

    return current?.trim().toLowerCase() == normalizedSender ||
        next?.trim().toLowerCase() == normalizedSender;
  } catch (_) {
    return false;
  }
}

List<String> storedDeviceIdsMissingReceivingStateForSender({
  required String userRecordJson,
  required String senderPubkeyHex,
}) {
  try {
    final decoded = jsonDecode(userRecordJson);
    if (decoded is! Map<String, dynamic>) return const <String>[];

    final devices = decoded['devices'];
    if (devices is! List) return const <String>[];

    final normalizedSender = senderPubkeyHex.trim().toLowerCase();
    if (normalizedSender.isEmpty) return const <String>[];

    final matchingDeviceIds = <String>[];
    for (final rawDevice in devices) {
      if (rawDevice is! Map) continue;
      final device = Map<String, dynamic>.from(rawDevice);
      final deviceId = _jsonStringValue(
        device,
        'device_id',
        'deviceId',
      )?.trim();
      if (deviceId == null || deviceId.isEmpty) continue;

      final sessionMaps = <Map<String, dynamic>>[];
      final active = device['active_session'] ?? device['activeSession'];
      if (active is Map) {
        sessionMaps.add(Map<String, dynamic>.from(active));
      }

      final inactive =
          device['inactive_sessions'] ?? device['inactiveSessions'];
      if (inactive is List) {
        for (final rawSession in inactive) {
          if (rawSession is Map) {
            sessionMaps.add(Map<String, dynamic>.from(rawSession));
          }
        }
      }

      var tracksSender = false;
      var hasReceivingSession = false;
      for (final sessionMap in sessionMaps) {
        final current = _jsonStringValue(
          sessionMap,
          'their_current_nostr_public_key',
          'theirCurrentNostrPublicKey',
        );
        final next = _jsonStringValue(
          sessionMap,
          'their_next_nostr_public_key',
          'theirNextNostrPublicKey',
        );
        final tracksThisSender =
            current?.trim().toLowerCase() == normalizedSender ||
            next?.trim().toLowerCase() == normalizedSender;
        if (!tracksThisSender) continue;

        tracksSender = true;
        final sessionJson = jsonEncode(sessionMap);
        if (sessionStateHasReceivingCapabilityJson(sessionJson)) {
          hasReceivingSession = true;
          break;
        }
      }

      if (tracksSender && !hasReceivingSession) {
        matchingDeviceIds.add(deviceId);
      }
    }

    return matchingDeviceIds;
  } catch (_) {
    return const <String>[];
  }
}

List<Map<String, dynamic>> _deviceSessionMaps(Map<String, dynamic> device) {
  final sessionMaps = <Map<String, dynamic>>[];

  final active = device['active_session'] ?? device['activeSession'];
  if (active is Map) {
    sessionMaps.add(Map<String, dynamic>.from(active));
  }

  final inactive = device['inactive_sessions'] ?? device['inactiveSessions'];
  if (inactive is List) {
    for (final rawSession in inactive) {
      if (rawSession is Map) {
        sessionMaps.add(Map<String, dynamic>.from(rawSession));
      }
    }
  }

  return sessionMaps;
}

List<String> storedKnownDeviceIdsMissingRecords(String userRecordJson) {
  try {
    final decoded = jsonDecode(userRecordJson);
    if (decoded is! Map<String, dynamic>) return const <String>[];

    final knownDeviceIdentities = decoded['known_device_identities'];
    if (knownDeviceIdentities is! List) return const <String>[];

    final knownDeviceIds = <String>{};
    for (final value in knownDeviceIdentities) {
      final deviceId = value?.toString().trim();
      if (deviceId != null && deviceId.isNotEmpty) {
        knownDeviceIds.add(deviceId);
      }
    }
    if (knownDeviceIds.isEmpty) return const <String>[];

    final devices = decoded['devices'];
    if (devices is! List) {
      return knownDeviceIds.toList(growable: false);
    }

    final presentDeviceIds = <String>{};
    for (final rawDevice in devices) {
      if (rawDevice is! Map) continue;
      final device = Map<String, dynamic>.from(rawDevice);
      final deviceId = _jsonStringValue(
        device,
        'device_id',
        'deviceId',
      )?.trim();
      if (deviceId != null && deviceId.isNotEmpty) {
        presentDeviceIds.add(deviceId);
      }
    }

    return knownDeviceIds
        .where((deviceId) => !presentDeviceIds.contains(deviceId))
        .toList(growable: false);
  } catch (_) {
    return const <String>[];
  }
}

String? storedReceivingSessionStateForDevice({
  required String userRecordJson,
  required String deviceId,
  String? senderPubkeyHex,
}) {
  try {
    final decoded = jsonDecode(userRecordJson);
    if (decoded is! Map<String, dynamic>) return null;

    final devices = decoded['devices'];
    if (devices is! List) return null;

    final normalizedDeviceId = deviceId.trim();
    if (normalizedDeviceId.isEmpty) return null;
    final normalizedSender = senderPubkeyHex?.trim().toLowerCase();

    for (final rawDevice in devices) {
      if (rawDevice is! Map) continue;
      final device = Map<String, dynamic>.from(rawDevice);
      final currentDeviceId = _jsonStringValue(
        device,
        'device_id',
        'deviceId',
      )?.trim();
      if (currentDeviceId != normalizedDeviceId) continue;

      Map<String, dynamic>? firstReceivingFallback;
      for (final sessionMap in _deviceSessionMaps(device)) {
        final sessionJson = jsonEncode(sessionMap);
        if (!sessionStateHasReceivingCapabilityJson(sessionJson)) {
          continue;
        }

        firstReceivingFallback ??= sessionMap;
        if (normalizedSender == null || normalizedSender.isEmpty) {
          return sessionJson;
        }
        if (sessionStateTracksSenderPubkeyJson(sessionJson, normalizedSender)) {
          return sessionJson;
        }
      }

      if (firstReceivingFallback != null) {
        return jsonEncode(firstReceivingFallback);
      }
      return null;
    }
  } catch (_) {
    return null;
  }

  return null;
}

List<String> storedDeviceIdsMissingReceiveStateComparedToSnapshot({
  required String currentUserRecordJson,
  required String snapshotUserRecordJson,
}) {
  try {
    final currentDecoded = jsonDecode(currentUserRecordJson);
    final snapshotDecoded = jsonDecode(snapshotUserRecordJson);
    if (currentDecoded is! Map<String, dynamic> ||
        snapshotDecoded is! Map<String, dynamic>) {
      return const <String>[];
    }

    final currentDevices = currentDecoded['devices'];
    final snapshotDevices = snapshotDecoded['devices'];
    if (snapshotDevices is! List) return const <String>[];

    final currentReceiveByDeviceId = <String, bool>{};
    if (currentDevices is List) {
      for (final rawDevice in currentDevices) {
        if (rawDevice is! Map) continue;
        final device = Map<String, dynamic>.from(rawDevice);
        final deviceId = _jsonStringValue(
          device,
          'device_id',
          'deviceId',
        )?.trim();
        if (deviceId == null || deviceId.isEmpty) continue;

        currentReceiveByDeviceId[deviceId] = _deviceSessionMaps(device).any(
          (sessionMap) =>
              sessionStateHasReceivingCapabilityJson(jsonEncode(sessionMap)),
        );
      }
    }

    final missingDeviceIds = <String>[];
    for (final rawDevice in snapshotDevices) {
      if (rawDevice is! Map) continue;
      final device = Map<String, dynamic>.from(rawDevice);
      final deviceId = _jsonStringValue(
        device,
        'device_id',
        'deviceId',
      )?.trim();
      if (deviceId == null || deviceId.isEmpty) continue;

      final snapshotHasReceiveState = _deviceSessionMaps(device).any(
        (sessionMap) =>
            sessionStateHasReceivingCapabilityJson(jsonEncode(sessionMap)),
      );
      if (!snapshotHasReceiveState) continue;

      if (currentReceiveByDeviceId[deviceId] != true) {
        missingDeviceIds.add(deviceId);
      }
    }

    return missingDeviceIds;
  } catch (_) {
    return const <String>[];
  }
}

/// Bridges NDR SessionManager with the app's Nostr transport.
class SessionManagerService {
  SessionManagerService(
    this._nostrService,
    this._authRepository, {
    String? storagePathOverride,
    Future<bool> Function(String eventId)? hasProcessedMessageEventId,
  }) : _storagePathOverride = storagePathOverride,
       _hasProcessedMessageEventId = hasProcessedMessageEventId;

  final NostrService _nostrService;
  final AuthRepository _authRepository;
  final String? _storagePathOverride;
  final Future<bool> Function(String eventId)? _hasProcessedMessageEventId;

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
  final Map<String, String> _eventSenderPubkeys = <String, String>{};
  final List<Map<String, dynamic>> _debugRecentRelayEvents =
      <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _debugRecentDecryptedEvents =
      <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _debugRecentBootstrapInviteDecisions =
      <Map<String, dynamic>>[];
  Map<String, dynamic>? _debugLastOwnerSelfSessionBootstrap;
  final Map<String, String> _recentLinkedDeviceSenderByPeerOwner =
      <String, String>{};
  final Map<String, String> _preInitUserRecordJsonByOwner = <String, String>{};
  final Map<String, int> _processedMessageEventIds = <String, int>{};
  final Map<String, Timer> _relayBackfillTimersByOwner = <String, Timer>{};
  static const String _groupOuterSubId = 'ndr-group-outer';
  static const String _processedMessageEventIdsFileName =
      'processed_message_event_ids.json';
  static const int _kMaxProcessedMessageEventIds = 4000;
  List<String> _groupOuterSenderEventPubkeys = const [];
  static Future<void> _storageCriticalQueue = Future.value();
  String? _processedMessageEventIdsPath;
  Future<void> _processedIdsPersistQueue = Future.value();

  /// Owner public key (hex) for this session manager (differs for linked devices).
  String? get ownerPubkeyHex => _ownerPubkeyHex;
  String? get devicePubkeyHex => _devicePubkeyHex;

  Map<String, dynamic> debugSnapshot() {
    return {
      'ownerPubkeyHex': _ownerPubkeyHex,
      'devicePubkeyHex': _devicePubkeyHex,
      'recentLinkedDeviceSenderByPeerOwner': Map<String, String>.from(
        _recentLinkedDeviceSenderByPeerOwner,
      ),
      'pendingRelayBackfillOwners': _relayBackfillTimersByOwner.keys.toList()
        ..sort(),
      'recentRelayEvents': List<Map<String, dynamic>>.from(
        _debugRecentRelayEvents,
      ),
      'recentBootstrapInviteDecisions': List<Map<String, dynamic>>.from(
        _debugRecentBootstrapInviteDecisions,
      ),
      'recentDecryptedEvents': List<Map<String, dynamic>>.from(
        _debugRecentDecryptedEvents,
      ),
      'lastOwnerSelfSessionBootstrap':
          _debugLastOwnerSelfSessionBootstrap == null
          ? null
          : Map<String, dynamic>.from(_debugLastOwnerSelfSessionBootstrap!),
    };
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _eventSubscription = _nostrService.events.listen((event) {
      _runExclusiveDetached(() async {
        await _handleEvent(event);
      });
    });

    try {
      await _runExclusive(() async {
        await _initManager();
      });
    } catch (_) {
      await _eventSubscription?.cancel();
      _eventSubscription = null;
      _started = false;
      rethrow;
    }

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
    for (final timer in _relayBackfillTimersByOwner.values) {
      timer.cancel();
    }
    _relayBackfillTimersByOwner.clear();
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
    await _runExclusiveIgnoringDisposed(() async {
      await _drainEventsUnlocked();
    });
  }

  Future<void> setupUser(String userPubkeyHex) async {
    await _runExclusiveIgnoringDisposed(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      await manager.setupUser(userPubkeyHex);
      await _drainEventsUnlocked();
    });
  }

  Future<void> setupUsers(Iterable<String> userPubkeysHex) async {
    final ordered = <String>[];
    final seen = <String>{};
    for (final raw in userPubkeysHex) {
      final normalized = raw.trim().toLowerCase();
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      ordered.add(normalized);
    }
    if (ordered.isEmpty) return;

    await _runExclusiveIgnoringDisposed(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      for (final pubkeyHex in ordered) {
        await manager.setupUser(pubkeyHex);
      }
      await _drainEventsUnlocked();
    });
  }

  Future<void> bootstrapUsersFromRelay(Iterable<String> userPubkeysHex) async {
    final orderedOwners = <String>[];
    final seenOwners = <String>{};
    for (final raw in userPubkeysHex) {
      final normalized = raw.trim().toLowerCase();
      if (normalized.isEmpty || !seenOwners.add(normalized)) continue;
      orderedOwners.add(normalized);
    }
    if (orderedOwners.isEmpty) return;

    final appKeysEvents = <NostrEvent>[];
    final inviteEvents = <MapEntry<String, NostrEvent>>[];
    final seenEventIds = <String>{};

    for (final ownerPubkeyHex in orderedOwners) {
      final appKeysEventsForOwner = await fetchAppKeysEvents(
        _nostrService,
        ownerPubkeyHex: ownerPubkeyHex,
        timeout: const Duration(seconds: 1),
        subscriptionLabel: 'appkeys-bootstrap',
      );
      final devicePubkeys = <String>{ownerPubkeyHex};

      for (final appKeysEvent in appKeysEventsForOwner) {
        if (seenEventIds.add(appKeysEvent.id)) {
          appKeysEvents.add(appKeysEvent);
        }
      }
      try {
        final parsed = await resolveLatestAppKeysDevicesFromEvents(
          appKeysEventsForOwner,
        );
        for (final device in parsed) {
          final normalized = device.identityPubkeyHex.trim().toLowerCase();
          if (normalized.isNotEmpty) {
            devicePubkeys.add(normalized);
          }
        }
      } catch (_) {}

      final latestInvites = await fetchLatestDeviceInviteEvents(
        _nostrService,
        devicePubkeysHex: devicePubkeys,
        timeout: const Duration(seconds: 1),
        subscriptionLabel: 'device-invite-bootstrap',
      );
      for (final inviteEvent in latestInvites) {
        if (seenEventIds.add(inviteEvent.id)) {
          inviteEvents.add(MapEntry(ownerPubkeyHex, inviteEvent));
        }
      }
    }

    if (appKeysEvents.isEmpty && inviteEvents.isEmpty) return;

    await _runExclusiveIgnoringDisposed(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }

      for (final event in appKeysEvents) {
        await manager.processEvent(jsonEncode(event.toJson()));
      }
      for (final inviteEntry in inviteEvents) {
        try {
          final acceptResult = await manager.acceptInviteFromEventJson(
            eventJson: jsonEncode(inviteEntry.value.toJson()),
            ownerPubkeyHintHex: inviteEntry.key,
          );
          _pushDebugEntry(_debugRecentBootstrapInviteDecisions, {
            'ownerPubkeyHex': inviteEntry.key,
            'inviteEventId': inviteEntry.value.id,
            'inviteAuthorPubkeyHex': inviteEntry.value.pubkey,
            'decision': 'accept_invite_from_event_json',
            'createdNewSession': acceptResult.createdNewSession,
            'resolvedOwnerPubkeyHex': acceptResult.ownerPubkeyHex,
            'inviterDevicePubkeyHex': acceptResult.inviterDevicePubkeyHex,
            'deviceId': acceptResult.deviceId,
          });
        } catch (_) {
          try {
            await manager.processEvent(jsonEncode(inviteEntry.value.toJson()));
            _pushDebugEntry(_debugRecentBootstrapInviteDecisions, {
              'ownerPubkeyHex': inviteEntry.key,
              'inviteEventId': inviteEntry.value.id,
              'inviteAuthorPubkeyHex': inviteEntry.value.pubkey,
              'decision': 'process_event_fallback',
            });
          } catch (error) {
            _pushDebugEntry(_debugRecentBootstrapInviteDecisions, {
              'ownerPubkeyHex': inviteEntry.key,
              'inviteEventId': inviteEntry.value.id,
              'inviteAuthorPubkeyHex': inviteEntry.value.pubkey,
              'decision': 'error',
              'error': error.toString(),
            });
          }
        }
      }
      await _drainEventsUnlocked();
    });
  }

  Future<bool> bootstrapOwnerSelfSessionIfNeeded() async {
    return _runExclusiveIgnoringDisposed(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }

      final ownerPubkeyHex = _ownerPubkeyHex?.trim().toLowerCase();
      final devicePubkeyHex = _devicePubkeyHex?.trim().toLowerCase();
      _debugLastOwnerSelfSessionBootstrap = {
        'ownerPubkeyHex': ownerPubkeyHex,
        'devicePubkeyHex': devicePubkeyHex,
        'step': 'precheck',
      };
      if (ownerPubkeyHex == null ||
          ownerPubkeyHex.isEmpty ||
          devicePubkeyHex == null ||
          devicePubkeyHex.isEmpty ||
          ownerPubkeyHex == devicePubkeyHex) {
        _debugLastOwnerSelfSessionBootstrap = {
          ...?_debugLastOwnerSelfSessionBootstrap,
          'step': 'skipped',
          'reason': 'not_linked_device_or_missing_keys',
        };
        return;
      }

      final activeSessionState = await manager.getActiveSessionState(
        ownerPubkeyHex,
      );
      if (activeSessionState != null && activeSessionState.isNotEmpty) {
        _debugLastOwnerSelfSessionBootstrap = {
          ...?_debugLastOwnerSelfSessionBootstrap,
          'step': 'skipped',
          'reason': 'active_session_exists',
        };
        return;
      }

      final ownerPrivkeyHex = await _authRepository.getOwnerPrivateKey();
      final devicePrivkeyHex = await _authRepository.getPrivateKey();
      if (ownerPrivkeyHex == null ||
          ownerPrivkeyHex.isEmpty ||
          devicePrivkeyHex == null ||
          devicePrivkeyHex.isEmpty) {
        _debugLastOwnerSelfSessionBootstrap = {
          ...?_debugLastOwnerSelfSessionBootstrap,
          'step': 'skipped',
          'reason': 'missing_private_keys',
        };
        return;
      }

      InviteHandle? inviteHandle;
      InviteAcceptResult? acceptResult;
      InviteResponseResult? responseResult;

      try {
        _debugLastOwnerSelfSessionBootstrap = {
          ...?_debugLastOwnerSelfSessionBootstrap,
          'step': 'create_invite',
        };
        inviteHandle = await NdrFfi.createInvite(
          inviterPubkeyHex: devicePubkeyHex,
          deviceId: devicePubkeyHex,
          maxUses: 1,
        );
        await inviteHandle.setPurpose('chat');
        await inviteHandle.setOwnerPubkeyHex(ownerPubkeyHex);

        _debugLastOwnerSelfSessionBootstrap = {
          ...?_debugLastOwnerSelfSessionBootstrap,
          'step': 'accept_with_owner',
        };
        acceptResult = await inviteHandle.acceptWithOwner(
          inviteePubkeyHex: ownerPubkeyHex,
          inviteePrivkeyHex: ownerPrivkeyHex,
          deviceId: ownerPubkeyHex,
          ownerPubkeyHex: ownerPubkeyHex,
        );

        _debugLastOwnerSelfSessionBootstrap = {
          ...?_debugLastOwnerSelfSessionBootstrap,
          'step': 'process_response',
        };
        responseResult = await inviteHandle.processResponse(
          eventJson: acceptResult.responseEventJson,
          inviterPrivkeyHex: devicePrivkeyHex,
        );
        if (responseResult == null) {
          _debugLastOwnerSelfSessionBootstrap = {
            ...?_debugLastOwnerSelfSessionBootstrap,
            'step': 'process_response',
            'reason': 'response_result_null',
          };
          return;
        }

        final inviterSessionStateJson = await responseResult.session
            .stateJson();
        _debugLastOwnerSelfSessionBootstrap = {
          ...?_debugLastOwnerSelfSessionBootstrap,
          'step': 'import_session_state',
          'sessionStateLength': inviterSessionStateJson.length,
          'remoteDeviceId': responseResult.remoteDeviceId,
        };
        await manager.importSessionState(
          peerPubkeyHex: ownerPubkeyHex,
          stateJson: inviterSessionStateJson,
          deviceId: responseResult.remoteDeviceId,
        );
        await _drainEventsUnlocked();
        final importedSessionState = await manager.getActiveSessionState(
          ownerPubkeyHex,
        );
        _debugLastOwnerSelfSessionBootstrap = {
          ...?_debugLastOwnerSelfSessionBootstrap,
          'step': 'done',
          'activeSessionLength': importedSessionState?.length ?? 0,
        };
      } catch (error) {
        _debugLastOwnerSelfSessionBootstrap = {
          ...?_debugLastOwnerSelfSessionBootstrap,
          'step': 'error',
          'error': error.toString(),
        };
        rethrow;
      } finally {
        try {
          await responseResult?.session.dispose();
        } catch (_) {}
        try {
          await acceptResult?.session.dispose();
        } catch (_) {}
        try {
          await inviteHandle?.dispose();
        } catch (_) {}
      }
    }).then((_) => true).catchError((_) => false);
  }

  Future<void> repairRecentlyActiveLinkedDeviceRecords(
    Iterable<String> peerOwnerPubkeysHex,
  ) async {
    final orderedOwners = <String>[];
    final seenOwners = <String>{};
    for (final raw in peerOwnerPubkeysHex) {
      final normalized = raw.trim().toLowerCase();
      if (normalized.isEmpty || !seenOwners.add(normalized)) continue;
      orderedOwners.add(normalized);
    }
    if (orderedOwners.isEmpty) return;

    final storagePath = _processedMessageEventIdsPath == null
        ? await _resolveStoragePath()
        : File(_processedMessageEventIdsPath!).parent.path;

    for (final peerOwnerPubkeyHex in orderedOwners) {
      final senderPubkeyHex =
          _recentLinkedDeviceSenderByPeerOwner[peerOwnerPubkeyHex];

      final userRecordFile = File(
        '$storagePath/user_${peerOwnerPubkeyHex.trim().toLowerCase()}.json',
      );
      if (!userRecordFile.existsSync()) continue;

      final userRecordJson = userRecordFile.readAsStringSync();
      var targetDeviceIds = senderPubkeyHex == null || senderPubkeyHex.isEmpty
          ? const <String>[]
          : storedDeviceIdsMissingReceivingStateForSender(
              userRecordJson: userRecordJson,
              senderPubkeyHex: senderPubkeyHex,
            );
      if (targetDeviceIds.isEmpty) {
        final missingKnownDeviceIds = storedKnownDeviceIdsMissingRecords(
          userRecordJson,
        );
        if (missingKnownDeviceIds.length == 1) {
          targetDeviceIds = missingKnownDeviceIds;
        }
      }
      final backupUserRecordJson =
          _preInitUserRecordJsonByOwner[peerOwnerPubkeyHex];
      if (targetDeviceIds.isEmpty && backupUserRecordJson != null) {
        targetDeviceIds = storedDeviceIdsMissingReceiveStateComparedToSnapshot(
          currentUserRecordJson: userRecordJson,
          snapshotUserRecordJson: backupUserRecordJson,
        );
      }
      if (targetDeviceIds.isEmpty) continue;

      final activeSessionState = await getActiveSessionState(
        peerOwnerPubkeyHex,
      );

      for (final deviceId in targetDeviceIds) {
        final snapshotState = backupUserRecordJson == null
            ? null
            : storedReceivingSessionStateForDevice(
                userRecordJson: backupUserRecordJson,
                deviceId: deviceId,
                senderPubkeyHex: senderPubkeyHex,
              );

        var stateToImport = snapshotState;
        if (senderPubkeyHex != null && senderPubkeyHex.isNotEmpty) {
          if (activeSessionState != null &&
              activeSessionState.isNotEmpty &&
              sessionStateTracksSenderPubkeyJson(
                activeSessionState,
                senderPubkeyHex,
              )) {
            stateToImport = activeSessionState;
          }
        } else if ((stateToImport == null || stateToImport.isEmpty) &&
            activeSessionState != null &&
            activeSessionState.isNotEmpty) {
          stateToImport = activeSessionState;
        }
        if (stateToImport == null || stateToImport.isEmpty) {
          continue;
        }
        await importSessionState(
          peerPubkeyHex: peerOwnerPubkeyHex,
          stateJson: stateToImport,
          deviceId: deviceId,
        );
      }
    }
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
    await _runExclusiveIgnoringDisposed(() async {
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
    await _runExclusiveIgnoringDisposed(() async {
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
    await _runExclusiveIgnoringDisposed(() async {
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
    await _runExclusiveIgnoringDisposed(() async {
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
    await _runExclusiveIgnoringDisposed(() async {
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
    await _runExclusiveIgnoringDisposed(() async {
      await _ensureManagerInitializedUnlocked();
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      await manager.importSessionState(
        peerPubkeyHex: peerPubkeyHex,
        stateJson: stateJson,
        deviceId: deviceId,
      );
      await _drainEventsUnlocked();
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

  Future<void> processEventJson(String eventJson) async {
    await _runExclusiveIgnoringDisposed(() async {
      final manager = _manager;
      if (manager == null) {
        throw const NostrException('Session manager not initialized');
      }
      await manager.processEvent(eventJson);
      await _drainEventsUnlocked();
    });
  }

  Future<void> _initManager() async {
    await _runStorageCritical(
      action: () async {
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
        _processedMessageEventIdsPath =
            '$storagePath/$_processedMessageEventIdsFileName';
        await _snapshotExistingUserRecords(storagePath);
        await _loadProcessedMessageEventIds();

        _manager = await NdrFfi.createSessionManager(
          ourPubkeyHex: devicePubkeyHex,
          ourIdentityPrivkeyHex: devicePrivkeyHex,
          deviceId: devicePubkeyHex,
          storagePath: storagePath,
          ownerPubkeyHex: ownerPubkeyHex == devicePubkeyHex
              ? null
              : ownerPubkeyHex,
        );

        await _manager!.init();
        _ownerPubkeyHex = await _manager!.getOwnerPubkeyHex();
        _devicePubkeyHex = devicePubkeyHex;

        await _drainEventsUnlocked();
        await _refreshGroupOuterSubscription();
      },
    );
  }

  Future<void> _ensureManagerInitializedUnlocked() async {
    if (_manager != null || _isDisposed) return;
    await _initManager();
  }

  Future<String> _resolveStoragePath() async {
    return resolveStoragePath(storagePathOverride: _storagePathOverride);
  }

  /// Resolve the on-disk storage directory used by ndr-ffi SessionManager.
  static Future<String> resolveStoragePath({
    String? storagePathOverride,
  }) async {
    final override = storagePathOverride;
    if (override != null && override.isNotEmpty) return override;

    final supportDir = await getApplicationSupportDirectory();
    return '${supportDir.path}/ndr';
  }

  /// Delete all persisted ndr-ffi SessionManager storage from disk.
  static Future<void> clearPersistentStorage({
    String? storagePathOverride,
  }) async {
    await _runStorageCritical(
      action: () async {
        final storagePath = await resolveStoragePath(
          storagePathOverride: storagePathOverride,
        );
        final dir = Directory(storagePath);
        if (!dir.existsSync()) return;
        dir.deleteSync(recursive: true);
      },
    );
  }

  Future<void> _handleEvent(NostrEvent event) async {
    _pushDebugEntry(_debugRecentRelayEvents, {
      'id': event.id,
      'kind': event.kind,
      'pubkey': event.pubkey,
      'subscriptionId': event.subscriptionId,
      'createdAt': event.createdAt,
    });

    // Only handle NDR-related kinds to reduce overhead.
    if (event.kind != 1060 &&
        event.kind != 1058 &&
        event.kind != 1059 &&
        event.kind != 30078) {
      return;
    }

    if (event.kind == 1060) {
      if (_processedMessageEventIds.containsKey(event.id)) {
        _eventTimestamps[event.id] = event.createdAt;
        return;
      }
      final hasProcessedMessageEventId = _hasProcessedMessageEventId;
      if (hasProcessedMessageEventId != null) {
        try {
          if (await hasProcessedMessageEventId(event.id)) {
            _eventTimestamps[event.id] = event.createdAt;
            return;
          }
        } catch (_) {}
      }
    }

    // De-dupe by id for non-message kinds. For direct 1060 messages we still
    // allow replays by default, but if the outer event id is already present in
    // local message storage we can safely skip it to avoid replaying old relay
    // history on app reopen.
    if (event.kind != 1060 && _eventTimestamps.containsKey(event.id)) return;
    _eventTimestamps[event.id] = event.createdAt;
    if (event.kind == 1060) {
      _eventSenderPubkeys[event.id] = event.pubkey.trim().toLowerCase();
    }
    // Prevent unbounded growth in long-running sessions.
    if (_eventTimestamps.length > 10000) {
      // Map preserves insertion order; drop oldest.
      final keys = _eventTimestamps.keys.take(2000).toList();
      for (final k in keys) {
        _eventTimestamps.remove(k);
        _eventSenderPubkeys.remove(k);
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
          _markProcessedMessageEventId(
            decrypted.outerEventId,
            createdAt: decrypted.outerCreatedAt,
          );
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
    if (_shouldScheduleOwnerRelayBackfill(event)) {
      _scheduleOwnerRelayBackfill(event.pubkey);
    }
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

  bool _shouldScheduleOwnerRelayBackfill(NostrEvent event) {
    if (!isAppKeysEvent(event)) return false;

    final ownerPubkeyHex = event.pubkey.trim().toLowerCase();
    if (ownerPubkeyHex.isEmpty) return false;

    final subscriptionId = event.subscriptionId?.trim().toLowerCase() ?? '';
    if (subscriptionId.startsWith('appkeys-fetch-') ||
        subscriptionId.startsWith('appkeys-bootstrap-')) {
      return false;
    }

    return true;
  }

  void _scheduleOwnerRelayBackfill(String ownerPubkeyHex) {
    final normalizedOwnerPubkeyHex = ownerPubkeyHex.trim().toLowerCase();
    if (normalizedOwnerPubkeyHex.isEmpty || _isDisposed) return;

    _relayBackfillTimersByOwner.remove(normalizedOwnerPubkeyHex)?.cancel();
    _relayBackfillTimersByOwner[normalizedOwnerPubkeyHex] = Timer(
      const Duration(milliseconds: 300),
      () {
        _relayBackfillTimersByOwner.remove(normalizedOwnerPubkeyHex);
        unawaited(_runOwnerRelayBackfill(normalizedOwnerPubkeyHex));
      },
    );
  }

  Future<void> _runOwnerRelayBackfill(String ownerPubkeyHex) async {
    if (_isDisposed) return;

    try {
      await setupUser(ownerPubkeyHex);
      await bootstrapUsersFromRelay([ownerPubkeyHex]);
      await refreshSubscription();

      if (_ownerPubkeyHex?.trim().toLowerCase() == ownerPubkeyHex) {
        await bootstrapOwnerSelfSessionIfNeeded();
      }
    } catch (_) {}
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
          if (event.eventId != null && event.eventId!.isNotEmpty) {
            _markProcessedMessageEventId(event.eventId!, createdAt: createdAt);
          }
          String innerKind = 'non-json';
          String innerContentPreview = event.content!;
          try {
            final decoded = jsonDecode(event.content!);
            if (decoded is Map<String, dynamic>) {
              innerKind = decoded['kind']?.toString() ?? 'null';
              final innerContent = (decoded['content'] ?? '').toString();
              innerContentPreview = innerContent.length > 160
                  ? innerContent.substring(0, 160)
                  : innerContent;
            }
          } catch (_) {}
          _pushDebugEntry(_debugRecentDecryptedEvents, {
            'senderPubkeyHex': event.senderPubkeyHex,
            'eventId': event.eventId,
            'createdAt': createdAt,
            'innerKind': innerKind,
            'innerContentPreview': innerContentPreview,
            'contentPreview': event.content!.length > 160
                ? event.content!.substring(0, 160)
                : event.content!,
          });
          final outerSenderPubkeyHex = event.eventId == null
              ? null
              : _eventSenderPubkeys[event.eventId!];
          if (outerSenderPubkeyHex != null &&
              outerSenderPubkeyHex.isNotEmpty &&
              outerSenderPubkeyHex !=
                  event.senderPubkeyHex!.trim().toLowerCase()) {
            _recentLinkedDeviceSenderByPeerOwner[event.senderPubkeyHex!
                    .trim()
                    .toLowerCase()] =
                outerSenderPubkeyHex;
            await _repairLinkedDeviceReceiveState(
              peerOwnerPubkeyHex: event.senderPubkeyHex!,
              senderPubkeyHex: outerSenderPubkeyHex,
            );
          }
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

  Future<void> _runExclusiveIgnoringDisposed(
    Future<void> Function() action,
  ) async {
    if (_isDisposed) return;
    try {
      await _runExclusive(action);
    } catch (error) {
      if (_isDisposed && _isDisposedError(error)) {
        return;
      }
      rethrow;
    }
  }

  void _runExclusiveDetached(Future<void> Function() action) {
    _opQueue = _opQueue
        .then((_) async {
          if (_isDisposed) return;
          await action();
        })
        .catchError((error, stackTrace) {});
  }

  static Future<T> _runStorageCritical<T>({
    required Future<T> Function() action,
  }) {
    final completer = Completer<T>();

    _storageCriticalQueue = _storageCriticalQueue.catchError((_) {}).then((
      _,
    ) async {
      try {
        final result = await action();
        if (!completer.isCompleted) completer.complete(result);
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });

    return completer.future;
  }

  bool _isDisposedError(Object error) {
    return error is NostrException &&
        error.message == 'Session manager disposed';
  }

  Future<void> _repairLinkedDeviceReceiveState({
    required String peerOwnerPubkeyHex,
    required String senderPubkeyHex,
  }) async {
    final manager = _manager;
    if (manager == null) return;

    final activeSessionState = await manager.getActiveSessionState(
      peerOwnerPubkeyHex,
    );

    final storagePath = _processedMessageEventIdsPath == null
        ? await _resolveStoragePath()
        : File(_processedMessageEventIdsPath!).parent.path;
    final userRecordFile = File(
      '$storagePath/user_${peerOwnerPubkeyHex.trim().toLowerCase()}.json',
    );
    if (!userRecordFile.existsSync()) return;

    final userRecordJson = userRecordFile.readAsStringSync();
    var targetDeviceIds = storedDeviceIdsMissingReceivingStateForSender(
      userRecordJson: userRecordJson,
      senderPubkeyHex: senderPubkeyHex,
    );
    if (targetDeviceIds.isEmpty) {
      final missingKnownDeviceIds = storedKnownDeviceIdsMissingRecords(
        userRecordJson,
      );
      if (missingKnownDeviceIds.length == 1) {
        targetDeviceIds = missingKnownDeviceIds;
      }
    }
    final backupUserRecordJson =
        _preInitUserRecordJsonByOwner[peerOwnerPubkeyHex.trim().toLowerCase()];
    if (targetDeviceIds.isEmpty && backupUserRecordJson != null) {
      targetDeviceIds = storedDeviceIdsMissingReceiveStateComparedToSnapshot(
        currentUserRecordJson: userRecordJson,
        snapshotUserRecordJson: backupUserRecordJson,
      );
    }
    if (targetDeviceIds.isEmpty) return;

    for (final deviceId in targetDeviceIds) {
      final snapshotState = backupUserRecordJson == null
          ? null
          : storedReceivingSessionStateForDevice(
              userRecordJson: backupUserRecordJson,
              deviceId: deviceId,
              senderPubkeyHex: senderPubkeyHex,
            );
      var stateToImport = snapshotState;
      if (activeSessionState != null &&
          activeSessionState.isNotEmpty &&
          sessionStateTracksSenderPubkeyJson(
            activeSessionState,
            senderPubkeyHex,
          )) {
        stateToImport = activeSessionState;
      }
      if (stateToImport == null || stateToImport.isEmpty) {
        continue;
      }
      await manager.importSessionState(
        peerPubkeyHex: peerOwnerPubkeyHex,
        stateJson: stateToImport,
        deviceId: deviceId,
      );
    }
    await _drainEventsUnlocked();
  }

  void _pushDebugEntry(
    List<Map<String, dynamic>> target,
    Map<String, dynamic> entry,
  ) {
    target.add(entry);
    if (target.length > 20) {
      target.removeRange(0, target.length - 20);
    }
  }

  Future<void> _loadProcessedMessageEventIds() async {
    final path = _processedMessageEventIdsPath;
    if (path == null || path.isEmpty) return;

    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final raw = file.readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;

      _processedMessageEventIds.clear();
      for (final value in decoded) {
        if (value is String && value.isNotEmpty) {
          _processedMessageEventIds[value] = 0;
        }
      }
      _trimProcessedMessageEventIds();
    } catch (_) {}
  }

  Future<void> _snapshotExistingUserRecords(String storagePath) async {
    _preInitUserRecordJsonByOwner.clear();
    try {
      final dir = Directory(storagePath);
      if (!dir.existsSync()) return;

      for (final entry in dir.listSync()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.isEmpty
            ? entry.path
            : entry.uri.pathSegments.last;
        if (!name.startsWith('user_') || !name.endsWith('.json')) continue;

        final ownerPubkeyHex = name
            .substring('user_'.length, name.length - '.json'.length)
            .trim()
            .toLowerCase();
        if (ownerPubkeyHex.isEmpty) continue;
        _preInitUserRecordJsonByOwner[ownerPubkeyHex] = entry
            .readAsStringSync();
      }
    } catch (_) {}
  }

  void _markProcessedMessageEventId(String eventId, {int? createdAt}) {
    if (eventId.isEmpty) return;
    _processedMessageEventIds.remove(eventId);
    _processedMessageEventIds[eventId] = createdAt ?? 0;
    _trimProcessedMessageEventIds();
    _scheduleProcessedMessageEventIdsPersist();
  }

  void _trimProcessedMessageEventIds() {
    while (_processedMessageEventIds.length > _kMaxProcessedMessageEventIds) {
      final oldestKey = _processedMessageEventIds.keys.first;
      _processedMessageEventIds.remove(oldestKey);
    }
  }

  void _scheduleProcessedMessageEventIdsPersist() {
    final path = _processedMessageEventIdsPath;
    if (path == null || path.isEmpty) return;

    final payload = jsonEncode(_processedMessageEventIds.keys.toList());
    _processedIdsPersistQueue = _processedIdsPersistQueue
        .then((_) async {
          try {
            File(path).writeAsStringSync(payload, flush: true);
          } catch (_) {}
        })
        .catchError((error, stackTrace) {});
  }
}
