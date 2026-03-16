import 'dart:async';

import '../services/nostr_service.dart';

const _inviteEventKind = 30078;
const _inviteLTagValue = 'double-ratchet/invites';
const _inviteDTagPrefix = 'double-ratchet/invites/';

Future<List<NostrEvent>> fetchLatestDeviceInviteEvents(
  NostrService nostrService, {
  required Iterable<String> devicePubkeysHex,
  Duration timeout = const Duration(seconds: 2),
  String subscriptionLabel = 'device-invite-fetch',
}) async {
  final orderedPubkeys = <String>[];
  final seen = <String>{};
  for (final pubkey in devicePubkeysHex) {
    final normalized = pubkey.trim().toLowerCase();
    if (normalized.isEmpty || !seen.add(normalized)) continue;
    orderedPubkeys.add(normalized);
  }

  if (orderedPubkeys.isEmpty) {
    return const <NostrEvent>[];
  }

  final subid = '$subscriptionLabel-${DateTime.now().microsecondsSinceEpoch}';
  final bestByAuthor = <String, NostrEvent>{};
  var completed = false;
  Timer? settleTimer;
  late final StreamSubscription<NostrEvent> sub;

  Future<List<NostrEvent>> finish() async {
    if (completed) {
      return orderedPubkeys
          .map((pubkey) => bestByAuthor[pubkey])
          .whereType<NostrEvent>()
          .toList(growable: false);
    }

    completed = true;
    settleTimer?.cancel();
    await sub.cancel();
    nostrService.closeSubscription(subid);
    return orderedPubkeys
        .map((pubkey) => bestByAuthor[pubkey])
        .whereType<NostrEvent>()
        .toList(growable: false);
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
    if (event.subscriptionId != subid) return;
    if (event.kind != _inviteEventKind) return;

    final author = event.pubkey.trim().toLowerCase();
    if (!seen.contains(author)) return;
    if (event.getTagValue('l') != _inviteLTagValue) return;

    final dTag = event.getTagValue('d');
    if (dTag == null || !dTag.startsWith(_inviteDTagPrefix)) return;

    final existing = bestByAuthor[author];
    if (existing == null || event.createdAt >= existing.createdAt) {
      bestByAuthor[author] = event;
    }
    scheduleFinish();
  });

  nostrService.subscribeWithId(
    subid,
    NostrFilter(
      kinds: const [_inviteEventKind],
      authors: orderedPubkeys,
      limit: 100,
    ),
  );

  Timer(timeout, () async {
    if (completer.isCompleted) return;
    completer.complete(await finish());
  });

  return completer.future;
}
