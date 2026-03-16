import 'dart:convert';

import '../../features/invite/data/datasources/invite_local_datasource.dart';
import '../ffi/ndr_ffi.dart';
import '../services/nostr_service.dart';
import 'invite_url.dart';

const appInviteResponsesSubId = 'app-invite-responses';

Future<String?> resolveInviteEphemeralPubkey(String serializedState) async {
  // Best-effort extract from stored JSON first.
  try {
    final decoded = jsonDecode(serializedState);
    if (decoded is Map<String, dynamic>) {
      final candidates = <Object?>[
        decoded['ephemeralKey'],
        decoded['inviterEphemeralPublicKey'],
        decoded['inviterEphemeralPublicKeyHex'],
        decoded['inviterEphemeralPubkeyHex'],
        decoded['inviter_ephemeral_public_key'],
        decoded['inviter_ephemeral_public_key_hex'],
        decoded['inviter_ephemeral_pubkey_hex'],
      ];
      for (final candidate in candidates) {
        if (candidate is String && candidate.isNotEmpty) return candidate;
      }
    }
  } catch (_) {}

  // Fallback: roundtrip through native invite -> URL and read fragment.
  InviteHandle? handle;
  try {
    handle = await NdrFfi.inviteDeserialize(serializedState);
    final url = await handle.toUrl('https://iris.to');
    final decoded = decodeInviteUrlData(url);
    final eph =
        decoded?['ephemeralKey'] ??
        decoded?['inviterEphemeralPublicKey'] ??
        decoded?['inviterEphemeralPublicKeyHex'] ??
        decoded?['inviterEphemeralPubkeyHex'] ??
        decoded?['inviter_ephemeral_public_key'] ??
        decoded?['inviter_ephemeral_public_key_hex'] ??
        decoded?['inviter_ephemeral_pubkey_hex'];
    if (eph is String && eph.isNotEmpty) return eph;
  } catch (_) {
    // Ignore; invite state may be malformed or native may be unavailable.
  } finally {
    try {
      await handle?.dispose();
    } catch (_) {}
  }

  return null;
}

Future<void> refreshInviteResponseSubscription({
  required NostrService nostrService,
  required InviteLocalDatasource inviteDatasource,
  String subscriptionId = appInviteResponsesSubId,
}) async {
  final invites = await inviteDatasource.getActiveInvites();
  final ephs = <String>{};

  for (final invite in invites) {
    final serialized = invite.serializedState;
    if (serialized == null || serialized.isEmpty) continue;
    final eph = await resolveInviteEphemeralPubkey(serialized);
    if (eph != null && eph.isNotEmpty) {
      ephs.add(eph);
    }
  }

  if (ephs.isEmpty) {
    nostrService.closeSubscription(subscriptionId);
    return;
  }

  final sorted = ephs.toList()..sort();
  nostrService.subscribeWithIdRaw(subscriptionId, <String, dynamic>{
    'kinds': const [1059],
    '#p': sorted,
  });
}
