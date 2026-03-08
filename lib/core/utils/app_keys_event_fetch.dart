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
  final sub = nostrService.events.listen((event) {
    if (event.subscriptionId != subid) return;
    if (event.kind != _appKeysEventKind) return;
    if (event.pubkey.trim().toLowerCase() != normalizedOwnerPubkeyHex) return;
    if (event.getTagValue('d') != _appKeysDTagValue) return;

    // Replaceable events are second-granularity. Prefer the later-delivered
    // event when timestamps tie so rapid AppKeys updates do not drop devices.
    if (best == null || event.createdAt >= best!.createdAt) {
      best = event;
    }
  });

  try {
    nostrService.subscribeWithId(
      subid,
      NostrFilter(
        kinds: const [_appKeysEventKind],
        authors: [normalizedOwnerPubkeyHex],
        limit: 50,
      ),
    );
    await Future.delayed(timeout);
    return best;
  } finally {
    await sub.cancel();
    nostrService.closeSubscription(subid);
  }
}
