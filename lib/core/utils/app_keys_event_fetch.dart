import 'dart:async';
import 'dart:convert';

import '../ffi/ndr_ffi.dart';
import '../services/nostr_service.dart';

const _appKeysEventKind = 30078;
const _appKeysDTagValue = 'double-ratchet/app-keys';

bool isAppKeysEvent(NostrEvent event) {
  return event.kind == _appKeysEventKind &&
      event.getTagValue('d') == _appKeysDTagValue;
}

Future<List<NostrEvent>> fetchAppKeysEvents(
  NostrService nostrService, {
  required String ownerPubkeyHex,
  Duration timeout = const Duration(seconds: 2),
  Duration? connectionTimeout,
  String subscriptionLabel = 'appkeys-fetch',
}) async {
  final normalizedOwnerPubkeyHex = ownerPubkeyHex.trim().toLowerCase();
  if (normalizedOwnerPubkeyHex.isEmpty) {
    return const <NostrEvent>[];
  }

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
    if (!isAppKeysEvent(event)) return;
    if (event.pubkey.trim().toLowerCase() != normalizedOwnerPubkeyHex) return;
    if (!seenEventIds.add(event.id)) return;

    events.add(event);
    scheduleFinish();
  });

  nostrService.subscribeWithId(
    subid,
    NostrFilter(
      kinds: const [_appKeysEventKind],
      authors: [normalizedOwnerPubkeyHex],
      limit: 50,
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

Future<List<FfiDeviceEntry>> resolveLatestAppKeysDevicesFromEvents(
  List<NostrEvent> events, {
  String? ownerPrivkeyHex,
}) async {
  if (events.isEmpty) return const <FfiDeviceEntry>[];
  return NdrFfi.resolveLatestAppKeysDevices(
    events.map((event) => jsonEncode(event.toJson())).toList(),
    ownerPrivkeyHex: ownerPrivkeyHex,
  );
}

Future<List<FfiDeviceEntry>> fetchLatestAppKeysDevices(
  NostrService nostrService, {
  required String ownerPubkeyHex,
  String? ownerPrivkeyHex,
  Duration timeout = const Duration(seconds: 2),
  Duration? connectionTimeout,
  String subscriptionLabel = 'appkeys-fetch',
}) async {
  final events = await fetchAppKeysEvents(
    nostrService,
    ownerPubkeyHex: ownerPubkeyHex,
    timeout: timeout,
    connectionTimeout: connectionTimeout,
    subscriptionLabel: subscriptionLabel,
  );
  return resolveLatestAppKeysDevicesFromEvents(
    events,
    ownerPrivkeyHex: ownerPrivkeyHex,
  );
}
