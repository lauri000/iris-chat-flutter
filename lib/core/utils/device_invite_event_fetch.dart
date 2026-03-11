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

  final sub = nostrService.events.listen((event) {
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
  });

  try {
    nostrService.subscribeWithId(
      subid,
      NostrFilter(
        kinds: const [_inviteEventKind],
        authors: orderedPubkeys,
        limit: 100,
      ),
    );
    await Future.delayed(timeout);
    return orderedPubkeys
        .map((pubkey) => bestByAuthor[pubkey])
        .whereType<NostrEvent>()
        .toList(growable: false);
  } finally {
    await sub.cancel();
    nostrService.closeSubscription(subid);
  }
}
