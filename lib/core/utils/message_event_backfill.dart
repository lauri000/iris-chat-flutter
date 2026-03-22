import 'dart:async';
import 'dart:convert';

import '../ffi/models/pubsub_event.dart';
import '../services/nostr_service.dart';

const messageEventKind = 1060;
const _directMessageSessionPrefixes = <String>[
  'session-current-',
  'session-next-',
];

void _debugNdrLog(String message) {}

Future<List<NostrEvent>> fetchRecentMessageEvents(
  NostrService nostrService, {
  required Iterable<String> senderPubkeysHex,
  required int sinceSeconds,
  int limit = 200,
  Duration timeout = const Duration(seconds: 2),
  Duration? connectionTimeout,
  String subscriptionLabel = 'message-bootstrap',
}) async {
  final orderedPubkeys = <String>[];
  final seenAuthors = <String>{};
  for (final pubkey in senderPubkeysHex) {
    final normalized = pubkey.trim().toLowerCase();
    if (normalized.isEmpty || !seenAuthors.add(normalized)) continue;
    orderedPubkeys.add(normalized);
  }

  if (orderedPubkeys.isEmpty) {
    return const <NostrEvent>[];
  }
  _debugNdrLog(
    'fetchRecentMessageEvents authors=${orderedPubkeys.join(",")} since=$sinceSeconds',
  );

  final subid = '$subscriptionLabel-${DateTime.now().microsecondsSinceEpoch}';
  final events = <NostrEvent>[];
  final seenEventIds = <String>{};
  var completed = false;
  Timer? settleTimer;
  Timer? connectionTimer;
  final connectionWaitTimeout = connectionTimeout ?? timeout;
  late final StreamSubscription<NostrEvent> sub;
  StreamSubscription<RelayConnectionEvent>? connectionSub;

  Future<List<NostrEvent>> finish() async {
    if (completed) return events;
    completed = true;
    settleTimer?.cancel();
    connectionTimer?.cancel();
    await sub.cancel();
    await connectionSub?.cancel();
    nostrService.closeSubscription(subid);
    events.sort((a, b) {
      final createdAt = a.createdAt.compareTo(b.createdAt);
      if (createdAt != 0) return createdAt;
      return a.id.compareTo(b.id);
    });
    _debugNdrLog('fetchRecentMessageEvents finish count=${events.length}');
    return events;
  }

  final completer = Completer<List<NostrEvent>>();
  void startResponseTimeout() {
    connectionTimer?.cancel();
    connectionTimer = Timer(connectionWaitTimeout, () async {
      if (completer.isCompleted) return;
      completer.complete(await finish());
    });
  }

  void scheduleFinish() {
    if (completed) return;
    settleTimer?.cancel();
    settleTimer = Timer(const Duration(milliseconds: 100), () async {
      if (completer.isCompleted) return;
      completer.complete(await finish());
    });
  }

  sub = nostrService.events.listen((event) {
    if (event.subscriptionId != subid) return;
    if (event.kind != messageEventKind) return;

    final author = event.pubkey.trim().toLowerCase();
    if (!seenAuthors.contains(author)) return;
    if (!seenEventIds.add(event.id)) return;

    events.add(event);
    scheduleFinish();
  });

  nostrService.subscribeWithId(
    subid,
    NostrFilter(
      kinds: const [messageEventKind],
      authors: orderedPubkeys,
      since: sinceSeconds,
      limit: limit,
    ),
  );

  if (nostrService.connectedCount > 0) {
    startResponseTimeout();
  } else {
    connectionSub = nostrService.connectionEvents.listen((event) {
      if (completed || event.status != RelayStatus.connected) return;
      connectionSub?.cancel();
      connectionSub = null;
      startResponseTimeout();
    });
    connectionTimer = Timer(timeout, () async {
      if (completer.isCompleted) return;
      completer.complete(await finish());
    });
  }

  return completer.future;
}

List<String> directMessageSubscriptionBackfillAuthors({
  required PubSubEvent event,
  required Map<String, int> existingAuthorRefCounts,
}) {
  final subid = event.subid?.trim();
  final filterJson = event.filterJson;
  if (subid == null || subid.isEmpty || filterJson == null) {
    return const <String>[];
  }

  if (!_directMessageSessionPrefixes.any(subid.startsWith)) {
    return const <String>[];
  }

  try {
    final decoded = jsonDecode(filterJson);
    if (decoded is! Map<String, dynamic>) return const <String>[];

    final kinds = decoded['kinds'];
    if (kinds is! List || !kinds.any((kind) => kind == messageEventKind)) {
      return const <String>[];
    }

    final authors = decoded['authors'];
    if (authors is! List) return const <String>[];

    final addedAuthors = <String>[];
    final seenAuthors = <String>{};
    for (final author in authors) {
      final normalized = author?.toString().trim().toLowerCase();
      if (normalized == null || normalized.length != 64) continue;
      if (!RegExp(r'^[0-9a-f]+$').hasMatch(normalized)) continue;
      if (!seenAuthors.add(normalized)) continue;
      if ((existingAuthorRefCounts[normalized] ?? 0) > 0) continue;
      addedAuthors.add(normalized);
    }

    return addedAuthors;
  } catch (_) {
    return const <String>[];
  }
}
