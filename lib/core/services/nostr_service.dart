import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'logger_service.dart';

typedef NostrChannelConnector = Future<WebSocketChannel> Function(Uri uri);

/// Service for communicating with Nostr relays.
class NostrService {
  NostrService({
    List<String>? relayUrls,
    Duration baseReconnectDelay = const Duration(seconds: 2),
    Duration maxReconnectDelay = const Duration(seconds: 30),
    NostrChannelConnector? connectChannel,
  }) : _relayUrls = relayUrls ?? defaultRelays,
       _baseReconnectDelay = baseReconnectDelay,
       _maxReconnectDelay = maxReconnectDelay,
       _connectChannel = connectChannel ?? _defaultConnectChannel;

  final List<String> _relayUrls;
  final Duration _baseReconnectDelay;
  final Duration _maxReconnectDelay;
  final NostrChannelConnector _connectChannel;
  final Map<String, WebSocketChannel> _connections = {};
  final Map<String, StreamSubscription<dynamic>> _relaySubscriptions = {};
  final Map<String, Set<String>> _activeSubscriptions = {};
  final Map<String, Timer> _reconnectTimers = {};
  final Set<String> _connectingRelays = <String>{};
  // Desired subscriptions keyed by subscription id. These are replayed on (re)connect so
  // the app keeps receiving events after reconnects, and so subscriptions issued before
  // the websocket is connected aren't lost.
  final Map<String, Map<String, dynamic>> _subscriptionFilters = {};

  // Best-effort queue for publishes attempted while disconnected.
  // This is intentionally small; events are content-addressed and can be re-sent.
  final List<String> _pendingPublishes = <String>[];
  static const int _maxPendingPublishes = 200;

  final _eventController = StreamController<NostrEvent>.broadcast();
  final _connectionController =
      StreamController<RelayConnectionEvent>.broadcast();

  bool _disposed = false;
  final Map<String, int> _reconnectAttempts = {};

  /// Stream of incoming events from all connected relays.
  Stream<NostrEvent> get events => _eventController.stream;

  /// Stream of connection status changes.
  Stream<RelayConnectionEvent> get connectionEvents =>
      _connectionController.stream;

  /// Default relay URLs.
  static const defaultRelays = [
    'wss://relay.primal.net',
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://temp.iris.to',
    'wss://offchain.pub',
  ];

  /// Connect to all configured relays.
  Future<void> connect() async {
    if (_disposed) {
      throw StateError('NostrService has been disposed');
    }

    Logger.info(
      'Connecting to relays',
      category: LogCategory.nostr,
      data: {'relayCount': _relayUrls.length},
    );

    await Future.wait(_relayUrls.map(_connectToRelay));
  }

  Future<void> _connectToRelay(String url) async {
    if (_disposed || _connections.containsKey(url) || _connectingRelays.contains(url)) {
      return;
    }

    _reconnectTimers.remove(url)?.cancel();
    _connectingRelays.add(url);

    try {
      Logger.debug(
        'Connecting to relay',
        category: LogCategory.nostr,
        data: {'url': url},
      );

      final channel = await _connectChannel(Uri.parse(url));

      _connections[url] = channel;
      _reconnectAttempts[url] = 0;
      _activeSubscriptions[url] = {};

      // ignore: cancel_subscriptions - stored in _relaySubscriptions and cancelled in disconnect()
      final subscription = channel.stream.listen(
        (data) => _handleMessage(url, data),
        onError: (Object error) => _handleError(url, error),
        onDone: () => _handleDisconnect(url),
      );

      _relaySubscriptions[url] = subscription;

      _connectionController.add(
        RelayConnectionEvent(url: url, status: RelayStatus.connected),
      );

      // Replay known subscriptions and queued publishes.
      _resubscribeRelay(url);
      await _flushPendingPublishes();

      Logger.info(
        'Connected to relay',
        category: LogCategory.nostr,
        data: {'url': url},
      );
    } catch (e, st) {
      Logger.error(
        'Failed to connect to relay',
        category: LogCategory.nostr,
        error: e,
        stackTrace: st,
        data: {'url': url},
      );

      _connectionController.add(
        RelayConnectionEvent(
          url: url,
          status: RelayStatus.error,
          error: e.toString(),
        ),
      );

      _scheduleReconnect(url);
    } finally {
      _connectingRelays.remove(url);
    }
  }

  static Future<WebSocketChannel> _defaultConnectChannel(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;
    return channel;
  }

  void _handleMessage(String relay, dynamic data) {
    try {
      final message = jsonDecode(data as String) as List<dynamic>;
      if (message.isEmpty) return;

      final type = message[0] as String;

      switch (type) {
        case 'EVENT':
          if (message.length >= 3) {
            final subscriptionId = message[1] as String;
            final eventData = message[2] as Map<String, dynamic>;
            final event = NostrEvent.fromJson(
              eventData,
              subscriptionId: subscriptionId,
            );

            _eventController.add(event);
          }
          break;
        case 'OK':
          if (message.length >= 3) {
            final eventId = message[1] as String;
            final accepted = message[2] as bool;
            final reason = message.length > 3 ? message[3] as String? : null;

            Logger.debug(
              'Event ${accepted ? "accepted" : "rejected"}',
              category: LogCategory.nostr,
              data: {
                'relay': relay,
                'eventId': eventId.substring(0, 8),
                'reason': ?reason,
              },
            );
          }
          break;
        case 'EOSE':
          if (message.length >= 2) {
            final subscriptionId = message[1] as String;
            Logger.debug(
              'End of stored events',
              category: LogCategory.nostr,
              data: {'relay': relay, 'subscriptionId': subscriptionId},
            );
          }
          break;
        case 'NOTICE':
          if (message.length >= 2) {
            final notice = message[1] as String;
            Logger.warning(
              'Relay notice',
              category: LogCategory.nostr,
              data: {'relay': relay, 'notice': notice},
            );
          }
          break;
        case 'CLOSED':
          if (message.length >= 2) {
            final subscriptionId = message[1] as String;
            _activeSubscriptions[relay]?.remove(subscriptionId);
            Logger.debug(
              'Subscription closed by relay',
              category: LogCategory.nostr,
              data: {'relay': relay, 'subscriptionId': subscriptionId},
            );
          }
          break;
      }
    } catch (e, st) {
      Logger.error(
        'Failed to parse relay message',
        category: LogCategory.nostr,
        error: e,
        stackTrace: st,
        data: {'relay': relay},
      );
    }
  }

  void _handleError(String relay, Object error) {
    Logger.error(
      'Relay connection error',
      category: LogCategory.nostr,
      error: error,
      data: {'relay': relay},
    );

    _cleanupRelay(relay);

    _connectionController.add(
      RelayConnectionEvent(
        url: relay,
        status: RelayStatus.error,
        error: error.toString(),
      ),
    );

    _scheduleReconnect(relay);
  }

  void _handleDisconnect(String relay) {
    Logger.info(
      'Disconnected from relay',
      category: LogCategory.nostr,
      data: {'relay': relay},
    );

    _cleanupRelay(relay);

    _connectionController.add(
      RelayConnectionEvent(url: relay, status: RelayStatus.disconnected),
    );

    _scheduleReconnect(relay);
  }

  void _cleanupRelay(String relay) {
    _connections.remove(relay);
    _relaySubscriptions.remove(relay)?.cancel();
    _activeSubscriptions.remove(relay);
  }

  void _scheduleReconnect(String relay) {
    if (_disposed ||
        _connections.containsKey(relay) ||
        _reconnectTimers.containsKey(relay)) {
      return;
    }

    final attempts = (_reconnectAttempts[relay] ?? 0) + 1;
    _reconnectAttempts[relay] = attempts;

    // Keep retrying indefinitely, but cap the backoff so long-lived sessions
    // eventually recover without user intervention after transient relay churn.
    var delay = _baseReconnectDelay * (1 << (attempts - 1));
    if (delay > _maxReconnectDelay) {
      delay = _maxReconnectDelay;
    }

    Logger.debug(
      'Scheduling reconnect',
      category: LogCategory.nostr,
      data: {
        'relay': relay,
        'attempt': attempts,
        'delaySeconds': delay.inSeconds,
      },
    );

    _reconnectTimers[relay] = Timer(delay, () {
      _reconnectTimers.remove(relay);
      if (!_disposed) {
        _connectToRelay(relay);
      }
    });
  }

  /// Publish an event to all connected relays.
  Future<void> publishEvent(String eventJson) async {
    if (_disposed) {
      throw StateError('NostrService has been disposed');
    }

    if (_connections.isEmpty) {
      _enqueuePendingPublish(eventJson);
      Logger.warning(
        'No relay connections; queued event for later publish',
        category: LogCategory.nostr,
        data: {'queuedCount': _pendingPublishes.length},
      );
      return;
    }

    final message = jsonEncode(['EVENT', jsonDecode(eventJson)]);
    var successCount = 0;
    var failCount = 0;

    for (final entry in _connections.entries) {
      try {
        entry.value.sink.add(message);
        successCount++;
      } catch (e) {
        failCount++;
        Logger.error(
          'Failed to publish event to relay',
          category: LogCategory.nostr,
          error: e,
          data: {'relay': entry.key},
        );
      }
    }

    Logger.info(
      'Event published',
      category: LogCategory.nostr,
      data: {'successCount': successCount, 'failCount': failCount},
    );

    if (successCount == 0 && _connections.isNotEmpty) {
      _enqueuePendingPublish(eventJson);
      throw const NostrException('Failed to publish event to any relay');
    }
  }

  /// Subscribe to events matching a filter.
  String subscribe(NostrFilter filter) {
    if (_disposed) {
      throw StateError('NostrService has been disposed');
    }

    final subscriptionId = _generateSubscriptionId();
    subscribeWithIdRaw(subscriptionId, filter.toJson());
    return subscriptionId;
  }

  /// Subscribe to events using a provided subscription id.
  String subscribeWithId(String subscriptionId, NostrFilter filter) {
    if (_disposed) {
      throw StateError('NostrService has been disposed');
    }

    return subscribeWithIdRaw(subscriptionId, filter.toJson());
  }

  /// Subscribe using a raw filter JSON map. Unknown keys/tags are preserved.
  String subscribeWithIdRaw(
    String subscriptionId,
    Map<String, dynamic> filterJson,
  ) {
    if (_disposed) {
      throw StateError('NostrService has been disposed');
    }

    final hadExisting = _subscriptionFilters.containsKey(subscriptionId);
    _subscriptionFilters[subscriptionId] = filterJson;

    // Some relays don't apply a second REQ with the same subscription id. Treat this as
    // an "update": CLOSE then REQ so key-rotation / filter changes actually take effect.
    if (hadExisting) {
      final closeMessage = jsonEncode(['CLOSE', subscriptionId]);
      for (final entry in _connections.entries) {
        try {
          entry.value.sink.add(closeMessage);
          _activeSubscriptions[entry.key]?.remove(subscriptionId);
        } catch (e) {
          Logger.error(
            'Failed to close subscription on relay (resubscribe)',
            category: LogCategory.nostr,
            error: e,
            data: {'relay': entry.key, 'subscriptionId': subscriptionId},
          );
        }
      }
    }

    final message = jsonEncode(['REQ', subscriptionId, filterJson]);
    var successCount = 0;

    for (final entry in _connections.entries) {
      try {
        entry.value.sink.add(message);
        _activeSubscriptions[entry.key]?.add(subscriptionId);
        successCount++;
      } catch (e) {
        Logger.error(
          'Failed to subscribe on relay',
          category: LogCategory.nostr,
          error: e,
          data: {'relay': entry.key},
        );
      }
    }

    Logger.info(
      hadExisting
          ? 'Subscription updated (custom id)'
          : 'Subscription created (custom id)',
      category: LogCategory.nostr,
      data: {
        'subscriptionId': subscriptionId,
        'relayCount': successCount,
        // Avoid logging full filter JSON (can be very large, e.g. big `#p` lists),
        // which can flood debug consoles and inflate memory usage in debug builds.
        'kinds': filterJson['kinds'],
        'authorsCount': (filterJson['authors'] as List<dynamic>?)?.length,
        'idsCount': (filterJson['ids'] as List<dynamic>?)?.length,
        '#pCount': (filterJson['#p'] as List<dynamic>?)?.length,
        '#eCount': (filterJson['#e'] as List<dynamic>?)?.length,
        '#dCount': (filterJson['#d'] as List<dynamic>?)?.length,
      },
    );

    return subscriptionId;
  }

  /// Close a subscription.
  void closeSubscription(String subscriptionId) {
    if (_disposed) return;

    _subscriptionFilters.remove(subscriptionId);
    final message = jsonEncode(['CLOSE', subscriptionId]);

    for (final entry in _connections.entries) {
      try {
        entry.value.sink.add(message);
        _activeSubscriptions[entry.key]?.remove(subscriptionId);
      } catch (e) {
        Logger.error(
          'Failed to close subscription on relay',
          category: LogCategory.nostr,
          error: e,
          data: {'relay': entry.key, 'subscriptionId': subscriptionId},
        );
      }
    }

    Logger.debug(
      'Subscription closed',
      category: LogCategory.nostr,
      data: {'subscriptionId': subscriptionId},
    );
  }

  /// Disconnect from all relays and release resources.
  Future<void> disconnect() async {
    Logger.info('Disconnecting from all relays', category: LogCategory.nostr);

    for (final timer in _reconnectTimers.values) {
      timer.cancel();
    }
    _reconnectTimers.clear();
    _connectingRelays.clear();

    // Cancel all relay stream subscriptions
    for (final sub in _relaySubscriptions.values) {
      await sub.cancel();
    }
    _relaySubscriptions.clear();
    _activeSubscriptions.clear();

    // Close all WebSocket connections
    for (final channel in _connections.values) {
      await channel.sink.close();
    }
    _connections.clear();
    _reconnectAttempts.clear();
  }

  /// Dispose of the service and release all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    Logger.info('Disposing NostrService', category: LogCategory.nostr);

    await disconnect();
    _subscriptionFilters.clear();
    _pendingPublishes.clear();
    await _eventController.close();
    await _connectionController.close();
  }

  void _resubscribeRelay(String relay) {
    final channel = _connections[relay];
    if (channel == null) return;

    // Snapshot; callers may add/remove subscriptions while we iterate.
    final filters = Map<String, Map<String, dynamic>>.from(
      _subscriptionFilters,
    );
    for (final entry in filters.entries) {
      try {
        channel.sink.add(jsonEncode(['REQ', entry.key, entry.value]));
        _activeSubscriptions[relay]?.add(entry.key);
      } catch (e) {
        Logger.error(
          'Failed to replay subscription on relay',
          category: LogCategory.nostr,
          error: e,
          data: {'relay': relay, 'subscriptionId': entry.key},
        );
      }
    }
  }

  void _enqueuePendingPublish(String eventJson) {
    if (_pendingPublishes.length >= _maxPendingPublishes) {
      _pendingPublishes.removeAt(0);
    }
    _pendingPublishes.add(eventJson);
  }

  Future<void> _flushPendingPublishes() async {
    if (_pendingPublishes.isEmpty || _connections.isEmpty) return;

    final pending = List<String>.from(_pendingPublishes);
    _pendingPublishes.clear();

    for (final eventJson in pending) {
      try {
        await publishEvent(eventJson);
      } catch (_) {
        // publishEvent re-queues on transport failure. We ignore here.
      }
    }
  }

  String _generateSubscriptionId() {
    return DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  }

  /// Get connection status.
  Map<String, bool> get connectionStatus {
    return {for (final url in _relayUrls) url: _connections.containsKey(url)};
  }

  /// Number of connected relays.
  int get connectedCount => _connections.length;

  /// Whether service is disposed.
  bool get isDisposed => _disposed;

  Map<String, dynamic> debugSnapshot() {
    return {
      'connectedCount': connectedCount,
      'connectionStatus': connectionStatus,
      'subscriptionFilters': _subscriptionFilters.map(
        (key, value) => MapEntry(key, Map<String, dynamic>.from(value)),
      ),
      'activeSubscriptions': _activeSubscriptions.map(
        (key, value) => MapEntry(key, value.toList()..sort()),
      ),
    };
  }
}

/// Connection event for relay status changes.
class RelayConnectionEvent {
  const RelayConnectionEvent({
    required this.url,
    required this.status,
    this.error,
  });

  final String url;
  final RelayStatus status;
  final String? error;
}

/// Relay connection status.
enum RelayStatus { connected, disconnected, error }

/// A Nostr event.
class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
    this.subscriptionId,
  });

  factory NostrEvent.fromJson(
    Map<String, dynamic> json, {
    String? subscriptionId,
  }) {
    return NostrEvent(
      id: json['id'] as String,
      pubkey: json['pubkey'] as String,
      createdAt: json['created_at'] as int,
      kind: json['kind'] as int,
      tags: (json['tags'] as List<dynamic>)
          .map((t) => (t as List<dynamic>).map((e) => e.toString()).toList())
          .toList(),
      content: json['content'] as String,
      sig: json['sig'] as String,
      subscriptionId: subscriptionId,
    );
  }

  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;
  final String? subscriptionId;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'pubkey': pubkey,
      'created_at': createdAt,
      'kind': kind,
      'tags': tags,
      'content': content,
      'sig': sig,
    };
  }

  /// Get tag value by name.
  String? getTagValue(String name) {
    for (final tag in tags) {
      if (tag.isNotEmpty && tag[0] == name && tag.length > 1) {
        return tag[1];
      }
    }
    return null;
  }

  /// Get the 'p' tag (recipient pubkey).
  String? get recipientPubkey => getTagValue('p');
}

/// Filter for Nostr subscriptions.
class NostrFilter {
  const NostrFilter({
    this.ids,
    this.authors,
    this.kinds,
    this.eTags,
    this.pTags,
    this.since,
    this.until,
    this.limit,
  });

  factory NostrFilter.fromJson(Map<String, dynamic> json) {
    return NostrFilter(
      ids: (json['ids'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
      authors: (json['authors'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      kinds: (json['kinds'] as List<dynamic>?)?.map((e) => e as int).toList(),
      eTags: (json['#e'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
      pTags: (json['#p'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
      since: json['since'] as int?,
      until: json['until'] as int?,
      limit: json['limit'] as int?,
    );
  }

  final List<String>? ids;
  final List<String>? authors;
  final List<int>? kinds;
  final List<String>? eTags;
  final List<String>? pTags;
  final int? since;
  final int? until;
  final int? limit;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (ids != null) json['ids'] = ids;
    if (authors != null) json['authors'] = authors;
    if (kinds != null) json['kinds'] = kinds;
    if (eTags != null) json['#e'] = eTags;
    if (pTags != null) json['#p'] = pTags;
    if (since != null) json['since'] = since;
    if (until != null) json['until'] = until;
    if (limit != null) json['limit'] = limit;
    return json;
  }
}

/// Exception for Nostr-related errors.
class NostrException implements Exception {
  const NostrException(this.message);

  final String message;

  @override
  String toString() => 'NostrException: $message';
}
