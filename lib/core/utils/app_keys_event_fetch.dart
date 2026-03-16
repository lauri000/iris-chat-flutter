import 'dart:async';

import '../services/nostr_service.dart';

const _appKeysEventKind = 30078;
const _appKeysDTagValue = 'double-ratchet/app-keys';

Future<NostrEvent?> fetchLatestAppKeysEvent(
  NostrService nostrService, {
  required String ownerPubkeyHex,
  Duration timeout = const Duration(seconds: 2),
  String subscriptionLabel = 'appkeys-fetch',
}) async {
  final normalizedOwnerPubkeyHex = ownerPubkeyHex.trim().toLowerCase();
  if (normalizedOwnerPubkeyHex.isEmpty) {
    return null;
  }

  final subid = '$subscriptionLabel-${DateTime.now().microsecondsSinceEpoch}';

  NostrEvent? best;
  var completed = false;
  Timer? settleTimer;
  late final StreamSubscription<NostrEvent> sub;

  Future<NostrEvent?> finish() async {
    if (completed) return best;
    completed = true;
    settleTimer?.cancel();
    await sub.cancel();
    nostrService.closeSubscription(subid);
    return best;
  }

  final completer = Completer<NostrEvent?>();
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
    if (event.kind != _appKeysEventKind) return;
    if (event.pubkey.trim().toLowerCase() != normalizedOwnerPubkeyHex) return;
    if (event.getTagValue('d') != _appKeysDTagValue) return;

    // Replaceable events are second-granularity. Prefer the later-delivered
    // event when timestamps tie so rapid AppKeys updates do not drop devices.
    if (best == null || event.createdAt >= best!.createdAt) {
      best = event;
    }
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

  Timer(timeout, () async {
    if (completer.isCompleted) return;
    completer.complete(await finish());
  });

  return completer.future;
}
