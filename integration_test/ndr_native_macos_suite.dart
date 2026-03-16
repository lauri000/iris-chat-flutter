import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:iris_chat/core/ffi/ndr_ffi.dart';

class _PumpLog {
  final List<PubSubEvent> a = <PubSubEvent>[];
  final List<PubSubEvent> b = <PubSubEvent>[];
}

bool _isPublish(PubSubEvent e) =>
    (e.kind == 'publish' || e.kind == 'publish_signed') && e.eventJson != null;

Map<String, dynamic> _jsonMap(String s) =>
    jsonDecode(s) as Map<String, dynamic>;

String _describeDecryptedEvents(List<PubSubEvent> events) {
  final lines = <String>[];
  for (final e in events) {
    if (e.kind != 'decrypted_message') continue;
    final sender = e.senderPubkeyHex ?? 'null';
    final eventId = e.eventId ?? 'null';

    var innerKind = 'unknown';
    var innerContent = '';
    final c = e.content;
    if (c == null) {
      innerKind = 'null-content';
    } else {
      try {
        final decoded = jsonDecode(c);
        if (decoded is Map<String, dynamic>) {
          final k = decoded['kind'];
          innerKind = k?.toString() ?? 'null';
          innerContent = (decoded['content'] ?? '').toString();
        } else {
          innerKind = 'non-map-json';
          innerContent = decoded.toString();
        }
      } catch (_) {
        innerKind = 'non-json';
        innerContent = c;
      }
    }

    final contentPreview = innerContent.length > 80
        ? '${innerContent.substring(0, 80)}…'
        : innerContent;
    final senderPreview = sender.length >= 8 ? sender.substring(0, 8) : sender;
    final eventIdPreview = eventId.length >= 8
        ? eventId.substring(0, 8)
        : eventId;

    lines.add(
      'sender=$senderPreview eventId=$eventIdPreview innerKind=$innerKind content="$contentPreview"',
    );
  }
  if (lines.isEmpty) return '(none)';
  return lines.join('\n');
}

String _describeKindCounts(List<PubSubEvent> events) {
  final counts = <String, int>{};
  for (final e in events) {
    counts[e.kind] = (counts[e.kind] ?? 0) + 1;
  }
  if (counts.isEmpty) return '(none)';
  return counts.entries.map((e) => '${e.key}:${e.value}').join(', ');
}

String _describePublishEvents(List<PubSubEvent> events) {
  final lines = <String>[];
  for (final e in events) {
    if (e.kind != 'publish' && e.kind != 'publish_signed') continue;
    final ej = e.eventJson;
    if (ej == null) {
      lines.add('${e.kind} eventJson=null');
      continue;
    }
    try {
      final m = _jsonMap(ej);
      final k = m['kind'];
      final id = m['id'];
      final pubkey = m['pubkey'];
      lines.add(
        '${e.kind} kind=$k id=${(id is String && id.length >= 8) ? id.substring(0, 8) : id} pubkey=${(pubkey is String && pubkey.length >= 8) ? pubkey.substring(0, 8) : pubkey}',
      );
    } catch (_) {
      lines.add('${e.kind} eventJson=non-json length=${ej.length}');
    }
  }
  if (lines.isEmpty) return '(none)';
  return lines.join('\n');
}

Future<_PumpLog> _pumpUntilSettled({
  required SessionManagerHandle a,
  required SessionManagerHandle b,
  int maxRounds = 50,
}) async {
  final log = _PumpLog();
  for (var i = 0; i < maxRounds; i++) {
    final aEvents = await a.drainEvents();
    final bEvents = await b.drainEvents();
    log.a.addAll(aEvents);
    log.b.addAll(bEvents);

    final aPublishes = aEvents.where(_isPublish).toList();
    final bPublishes = bEvents.where(_isPublish).toList();

    // Deliver outgoing publishes directly to the other manager, and also
    // echo back to the sender to mimic relay fan-out of our own publishes.
    for (final e in aPublishes) {
      await a.processEvent(e.eventJson!);
      await b.processEvent(e.eventJson!);
    }
    for (final e in bPublishes) {
      await a.processEvent(e.eventJson!);
      await b.processEvent(e.eventJson!);
    }

    if (aPublishes.isEmpty && bPublishes.isEmpty) {
      break;
    }
  }
  return log;
}

PubSubEvent? _findDecrypted(
  List<PubSubEvent> events, {
  required String senderPubkeyHex,
  required int kind,
}) {
  for (final e in events) {
    if (e.kind != 'decrypted_message') continue;
    if (e.senderPubkeyHex != senderPubkeyHex) continue;
    final content = e.content;
    if (content == null) continue;
    final m = _jsonMap(content);
    if (m['kind'] == kind) {
      return e;
    }
  }
  return null;
}

Future<Directory> _tempDir(String prefix) async {
  return Directory.systemTemp.createTemp(prefix);
}

Future<void> _drainAllEvents(SessionManagerHandle mgr) async {
  while (true) {
    final events = await mgr.drainEvents();
    if (events.isEmpty) return;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('ndr-ffi native (macOS)', () {
    testWidgets('smoke: version + keypair', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());

      final v = await NdrFfi.version();
      expect(v, isNotEmpty);
      expect(v, isNot('unknown'));
      expect(v, matches(RegExp(r'^\d+\.\d+\.\d+$')));

      final kp = await NdrFfi.generateKeypair();
      expect(kp.publicKeyHex, hasLength(64));
      expect(kp.privateKeyHex, hasLength(64));
    }, skip: !Platform.isMacOS);

    testWidgets(
      'invite -> accept (SessionManager) -> processResponse -> send/decrypt (SessionManager)',
      (tester) async {
        await tester.pumpWidget(const SizedBox.shrink());

        final alice = await NdrFfi.generateKeypair();
        final bob = await NdrFfi.generateKeypair();

        final aliceDir = await _tempDir('ndr-macos-invite-alice-');
        final bobDir = await _tempDir('ndr-macos-invite-bob-');

        final aliceMgr = await NdrFfi.createSessionManager(
          ourPubkeyHex: alice.publicKeyHex,
          ourIdentityPrivkeyHex: alice.privateKeyHex,
          deviceId: alice.publicKeyHex,
          storagePath: aliceDir.path,
        );
        final bobMgr = await NdrFfi.createSessionManager(
          ourPubkeyHex: bob.publicKeyHex,
          ourIdentityPrivkeyHex: bob.privateKeyHex,
          deviceId: bob.publicKeyHex,
          storagePath: bobDir.path,
        );
        await aliceMgr.init();
        await bobMgr.init();

        // Drain and drop init-time pubsub events so we don't auto-accept each other's device invites.
        await _drainAllEvents(aliceMgr);
        await _drainAllEvents(bobMgr);

        final invite = await NdrFfi.createInvite(
          inviterPubkeyHex: alice.publicKeyHex,
          deviceId: alice.publicKeyHex,
          maxUses: 1,
        );
        final url = await invite.toUrl('https://iris.to');

        // Bob accepts via SessionManager; response is published via pubsub events.
        await bobMgr.acceptInviteFromUrl(inviteUrl: url);
        final bobAcceptEvents = await bobMgr.drainEvents();
        final responseEvent = bobAcceptEvents.firstWhere(
          (e) {
            if (e.kind != 'publish_signed' || e.eventJson == null) return false;
            try {
              final m = _jsonMap(e.eventJson!);
              return m['kind'] == 1059;
            } catch (_) {
              return false;
            }
          },
          orElse: () => throw StateError(
            'No publish_signed invite response found. Bob kinds: ${_describeKindCounts(bobAcceptEvents)}\n'
            'Bob publish events:\n${_describePublishEvents(bobAcceptEvents)}',
          ),
        );

        final aliceResp = await invite.processResponse(
          eventJson: responseEvent.eventJson!,
          inviterPrivkeyHex: alice.privateKeyHex,
        );
        expect(aliceResp, isNotNull);

        // Import inviter-side session state into Alice's manager so it can decrypt.
        final aliceState = await aliceResp!.session.stateJson();
        await aliceMgr.importSessionState(
          peerPubkeyHex: bob.publicKeyHex,
          stateJson: aliceState,
          deviceId: bob.publicKeyHex,
        );

        // Bob sends a message; Alice decrypts it via SessionManager.
        await bobMgr.sendTextWithInnerId(
          recipientPubkeyHex: alice.publicKeyHex,
          text: 'hello alice',
        );

        final log = await _pumpUntilSettled(a: aliceMgr, b: bobMgr);
        final aliceChat = _findDecrypted(
          log.a,
          senderPubkeyHex: bob.publicKeyHex,
          kind: 14,
        );
        expect(
          aliceChat,
          isNotNull,
          reason:
              'Alice kind counts: ${_describeKindCounts(log.a)}\n'
              'Bob kind counts: ${_describeKindCounts(log.b)}\n'
              'Alice decrypted events:\n${_describeDecryptedEvents(log.a)}\n'
              'Alice publish events:\n${_describePublishEvents(log.a)}\n'
              'Bob publish events:\n${_describePublishEvents(log.b)}',
        );
        final aliceRumor = _jsonMap(aliceChat!.content!);
        expect(aliceRumor['content'], 'hello alice');

        await aliceResp.session.dispose();
        await invite.dispose();
        await aliceMgr.dispose();
        await bobMgr.dispose();

        // Best-effort cleanup.
        try {
          await aliceDir.delete(recursive: true);
        } catch (_) {}
        try {
          await bobDir.delete(recursive: true);
        } catch (_) {}
      },
      skip: !Platform.isMacOS,
    );

    testWidgets('session manager: inner ids + receipts + typing', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());

      final alice = await NdrFfi.generateKeypair();
      final bob = await NdrFfi.generateKeypair();

      final aliceDir = await _tempDir('ndr-macos-alice-');
      final bobDir = await _tempDir('ndr-macos-bob-');

      final aliceMgr = await NdrFfi.createSessionManager(
        ourPubkeyHex: alice.publicKeyHex,
        ourIdentityPrivkeyHex: alice.privateKeyHex,
        deviceId: alice.publicKeyHex,
        storagePath: aliceDir.path,
      );
      final bobMgr = await NdrFfi.createSessionManager(
        ourPubkeyHex: bob.publicKeyHex,
        ourIdentityPrivkeyHex: bob.privateKeyHex,
        deviceId: bob.publicKeyHex,
        storagePath: bobDir.path,
      );
      await aliceMgr.init();
      await bobMgr.init();

      // Drain and drop init-time pubsub events so we don't auto-accept each other's device invites.
      await _drainAllEvents(aliceMgr);
      await _drainAllEvents(bobMgr);

      // Establish a session: Bob accepts via SessionManager, Alice processes the response and imports state.
      final invite = await NdrFfi.createInvite(
        inviterPubkeyHex: alice.publicKeyHex,
        deviceId: alice.publicKeyHex,
        maxUses: 1,
      );
      final url = await invite.toUrl('https://iris.to');

      await bobMgr.acceptInviteFromUrl(inviteUrl: url);
      final bobAcceptEvents = await bobMgr.drainEvents();
      final responseEvent = bobAcceptEvents.firstWhere(
        (e) {
          if (e.kind != 'publish_signed' || e.eventJson == null) return false;
          try {
            final m = _jsonMap(e.eventJson!);
            return m['kind'] == 1059;
          } catch (_) {
            return false;
          }
        },
        orElse: () => throw StateError(
          'No publish_signed invite response found. Bob kinds: ${_describeKindCounts(bobAcceptEvents)}\n'
          'Bob publish events:\n${_describePublishEvents(bobAcceptEvents)}',
        ),
      );

      final aliceResp = await invite.processResponse(
        eventJson: responseEvent.eventJson!,
        inviterPrivkeyHex: alice.privateKeyHex,
      );
      expect(aliceResp, isNotNull);

      final aliceState = await aliceResp!.session.stateJson();
      await aliceMgr.importSessionState(
        peerPubkeyHex: bob.publicKeyHex,
        stateJson: aliceState,
        deviceId: bob.publicKeyHex,
      );

      // Send a text with a stable inner id.
      final send = await bobMgr.sendTextWithInnerId(
        recipientPubkeyHex: alice.publicKeyHex,
        text: 'hi alice',
      );
      expect(send.innerId, isNotEmpty);

      // Deliver published events and wait for Alice to decrypt the rumor.
      final log1 = await _pumpUntilSettled(a: aliceMgr, b: bobMgr);
      final aliceChat = _findDecrypted(
        log1.a,
        senderPubkeyHex: bob.publicKeyHex,
        kind: 14,
      );
      expect(
        aliceChat,
        isNotNull,
        reason:
            'Alice kind counts: ${_describeKindCounts(log1.a)}\n'
            'Bob kind counts: ${_describeKindCounts(log1.b)}\n'
            'Alice publish events:\n${_describePublishEvents(log1.a)}\n'
            'Bob publish events:\n${_describePublishEvents(log1.b)}\n'
            'Alice decrypted events:\n${_describeDecryptedEvents(log1.a)}',
      );
      final aliceRumor = _jsonMap(aliceChat!.content!);
      expect(aliceRumor['content'], 'hi alice');

      // Stable inner id comes from the rumor id; PubSubEvent.eventId is the outer event id.
      final rumorId = aliceRumor['id'] as String;
      expect(rumorId, send.innerId);

      // Alice sends delivered + seen receipts, and typing.
      await aliceMgr.sendReceipt(
        recipientPubkeyHex: bob.publicKeyHex,
        receiptType: 'delivered',
        messageIds: [rumorId],
      );
      await aliceMgr.sendReceipt(
        recipientPubkeyHex: bob.publicKeyHex,
        receiptType: 'seen',
        messageIds: [rumorId],
      );
      await aliceMgr.sendTyping(recipientPubkeyHex: bob.publicKeyHex);

      final log2 = await _pumpUntilSettled(a: aliceMgr, b: bobMgr);

      final bobDelivered = _findDecrypted(
        log2.b,
        senderPubkeyHex: alice.publicKeyHex,
        kind: 15,
      );
      expect(bobDelivered, isNotNull);
      final deliveredRumor = _jsonMap(bobDelivered!.content!);
      expect(deliveredRumor['content'], 'delivered');
      expect(
        (deliveredRumor['tags'] as List).any((t) {
          final tag = (t as List).map((e) => e.toString()).toList();
          return tag.length >= 2 && tag[0] == 'e' && tag[1] == rumorId;
        }),
        isTrue,
      );

      final bobTyping = _findDecrypted(
        log2.b,
        senderPubkeyHex: alice.publicKeyHex,
        kind: 25,
      );
      expect(bobTyping, isNotNull);

      await aliceResp.session.dispose();
      await invite.dispose();
      await aliceMgr.dispose();
      await bobMgr.dispose();

      // Best-effort cleanup.
      try {
        await aliceDir.delete(recursive: true);
      } catch (_) {}
      try {
        await bobDir.delete(recursive: true);
      } catch (_) {}
    }, skip: !Platform.isMacOS);

    testWidgets(
      'link invite: accept (SessionManager) + appkeys create/parse',
      (tester) async {
        await tester.pumpWidget(const SizedBox.shrink());

        final owner = await NdrFfi.generateKeypair();
        final device = await NdrFfi.generateKeypair();

        final ownerDir = await _tempDir('ndr-macos-owner-');
        final ownerMgr = await NdrFfi.createSessionManager(
          ourPubkeyHex: owner.publicKeyHex,
          ourIdentityPrivkeyHex: owner.privateKeyHex,
          deviceId: owner.publicKeyHex,
          storagePath: ownerDir.path,
        );
        await ownerMgr.init();

        final deviceInvite = await NdrFfi.createInvite(
          inviterPubkeyHex: device.publicKeyHex,
          deviceId: device.publicKeyHex,
          maxUses: 1,
        );
        await deviceInvite.setPurpose('link');
        final url = await deviceInvite.toUrl('https://iris.to');

        // Owner accepts the device's link invite.
        await ownerMgr.acceptInviteFromUrl(
          inviteUrl: url,
          ownerPubkeyHintHex: owner.publicKeyHex,
        );
        final ownerEvents = await ownerMgr.drainEvents();
        final responseEvent = ownerEvents.firstWhere(
          (e) {
            if (e.kind != 'publish_signed' || e.eventJson == null) return false;
            try {
              final m = _jsonMap(e.eventJson!);
              return m['kind'] == 1059;
            } catch (_) {
              return false;
            }
          },
          orElse: () => throw StateError(
            'No publish_signed invite response found. Owner kinds: ${_describeKindCounts(ownerEvents)}\n'
            'Owner publish events:\n${_describePublishEvents(ownerEvents)}',
          ),
        );

        // Device processes the response and learns the owner pubkey.
        final resp = await deviceInvite.processResponse(
          eventJson: responseEvent.eventJson!,
          inviterPrivkeyHex: device.privateKeyHex,
        );
        expect(resp, isNotNull);
        expect(resp!.ownerPubkeyHex, owner.publicKeyHex);

        // AppKeys: include both devices.
        final appKeysEvent = await NdrFfi.createSignedAppKeysEvent(
          ownerPubkeyHex: owner.publicKeyHex,
          ownerPrivkeyHex: owner.privateKeyHex,
          devices: [
            FfiDeviceEntry(
              identityPubkeyHex: owner.publicKeyHex,
              createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            ),
            FfiDeviceEntry(
              identityPubkeyHex: device.publicKeyHex,
              createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            ),
          ],
        );
        final parsed = await NdrFfi.parseAppKeysEvent(appKeysEvent);
        final parsedKeys = parsed.map((d) => d.identityPubkeyHex).toSet();
        expect(parsedKeys, contains(owner.publicKeyHex));
        expect(parsedKeys, contains(device.publicKeyHex));

        await resp.session.dispose();
        await deviceInvite.dispose();
        await ownerMgr.dispose();

        // Best-effort cleanup.
        try {
          await ownerDir.delete(recursive: true);
        } catch (_) {}
      },
      skip: !Platform.isMacOS,
    );
  });
}
