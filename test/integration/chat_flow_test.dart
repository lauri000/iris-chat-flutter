/// Integration tests for SessionManager-based chat flows.
///
/// These tests verify the end-to-end-ish flow for the Dart MethodChannel bindings,
/// using mocked native responses to simulate the ndr-ffi library.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iris_chat/core/ffi/ndr_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Test data
  const alicePubkey =
      'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
  const alicePrivkey =
      'a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2';
  const bobPubkey =
      'b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1';
  const bobPrivkey =
      'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2';

  late MethodChannel channel;

  // Per-manager state for the mock MethodChannel.
  final managers = <String, Map<String, Object?>>{};
  final outerToInnerRumor = <String, String>{};

  var nextId = 0;
  String makeId(String prefix) => '$prefix-${nextId++}';

  void enqueue(String managerId, Map<String, dynamic> event) {
    final mgr = managers[managerId];
    if (mgr == null) return;
    final q = (mgr['queue'] as List).cast<Map<String, dynamic>>();
    q.add(event);
  }

  List<Map<String, dynamic>> drainQueue(String managerId) {
    final mgr = managers[managerId];
    if (mgr == null) return const [];
    final q = (mgr['queue'] as List).cast<Map<String, dynamic>>();
    final out = List<Map<String, dynamic>>.from(q);
    q.clear();
    return out;
  }

  setUp(() {
    channel = const MethodChannel('to.iris.chat/ndr_ffi');
    managers.clear();
    outerToInnerRumor.clear();
    nextId = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'version':
              return '0.0.76';

            case 'derivePublicKey':
              final privkey = methodCall.arguments['privkeyHex'] as String;
              if (privkey == alicePrivkey) return alicePubkey;
              if (privkey == bobPrivkey) return bobPubkey;
              throw PlatformException(
                code: 'InvalidKey',
                message: 'Unknown key',
              );

            case 'sessionManagerNew':
            case 'sessionManagerNewWithStoragePath':
              final id = makeId('mgr');
              managers[id] = <String, Object?>{
                'queue': <Map<String, dynamic>>[],
                'ourPubkeyHex': methodCall.arguments['ourPubkeyHex'] as String,
              };
              return {'id': id};

            case 'sessionManagerInit':
              return null;

            case 'sessionManagerAcceptInviteFromUrl':
              {
                final id = methodCall.arguments['id'] as String;
                // Publish a signed invite response event (kind 1059) via pubsub.
                final responseEventJson = jsonEncode({
                  'id': makeId('invite-resp'),
                  'kind': 1059,
                  'pubkey': managers[id]?['ourPubkeyHex'],
                  'created_at': 1700000000,
                  'tags': [
                    ['p', 'invite-eph'],
                  ],
                  'content': 'mock-invite-response',
                  'sig': '00',
                });
                enqueue(id, {
                  'kind': 'publish_signed',
                  'eventJson': responseEventJson,
                });
                return {
                  'ownerPubkeyHex': alicePubkey,
                  'inviterDevicePubkeyHex': alicePubkey,
                  'deviceId': alicePubkey,
                  'createdNewSession': true,
                };
              }

            case 'sessionManagerSendTextWithInnerId':
              {
                final id = methodCall.arguments['id'] as String;
                final ourPubkeyHex = managers[id]?['ourPubkeyHex'] as String?;
                final text = methodCall.arguments['text'] as String;

                final innerId = makeId('inner');
                final outerId = makeId('outer');
                final innerRumorJson = jsonEncode({
                  'id': innerId,
                  'kind': 14,
                  'pubkey': ourPubkeyHex ?? '',
                  'created_at': 1700000000,
                  'tags': const [],
                  'content': text,
                });

                outerToInnerRumor[outerId] = innerRumorJson;

                final outerEventJson = jsonEncode({
                  'id': outerId,
                  'kind': 1060,
                  'pubkey': ourPubkeyHex ?? '',
                  'created_at': 1700000000,
                  'tags': const [],
                  'content': 'mock-encrypted',
                  'sig': '00',
                });

                enqueue(id, {
                  'kind': 'publish_signed',
                  'eventJson': outerEventJson,
                });

                return {
                  'innerId': innerId,
                  'outerEventIds': [outerId],
                };
              }

            case 'sessionManagerProcessEvent':
              {
                final id = methodCall.arguments['id'] as String;
                final eventJson = methodCall.arguments['eventJson'] as String;
                final m = jsonDecode(eventJson) as Map<String, dynamic>;
                final kind = m['kind'];
                final eventId = m['id'];
                if (kind == 1060 && eventId is String) {
                  final rumor = outerToInnerRumor[eventId];
                  if (rumor != null) {
                    final rumorMap = jsonDecode(rumor) as Map<String, dynamic>;
                    final sender = rumorMap['pubkey'] as String? ?? '';
                    enqueue(id, {
                      'kind': 'decrypted_message',
                      'senderPubkeyHex': sender,
                      'content': rumor,
                      'eventId': eventId,
                    });
                  }
                }
                return null;
              }

            case 'sessionManagerDrainEvents':
              {
                final id = methodCall.arguments['id'] as String;
                return drainQueue(id);
              }

            case 'sessionManagerDispose':
              {
                final id = methodCall.arguments['id'] as String;
                managers.remove(id);
                return null;
              }

            default:
              throw MissingPluginException('No mock for ${methodCall.method}');
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('SessionManager Chat Flow', () {
    test('Accepting an invite publishes a signed response event', () async {
      final bobMgr = await NdrFfi.createSessionManager(
        ourPubkeyHex: bobPubkey,
        ourIdentityPrivkeyHex: bobPrivkey,
        deviceId: bobPubkey,
      );
      await bobMgr.init();

      final accept = await bobMgr.acceptInviteFromUrl(
        inviteUrl: 'https://iris.to/#invite=whatever',
      );
      expect(accept.createdNewSession, isTrue);

      final events = await bobMgr.drainEvents();
      expect(events.any((e) => e.kind == 'publish_signed'), isTrue);

      final response = events.firstWhere((e) => e.kind == 'publish_signed');
      final responseJson = response.eventJson;
      expect(responseJson, isNotNull);
      final decoded = jsonDecode(responseJson!) as Map<String, dynamic>;
      expect(decoded['kind'], 1059);

      await bobMgr.dispose();
    });

    test('Send -> publish -> process -> decrypted_message', () async {
      final aliceMgr = await NdrFfi.createSessionManager(
        ourPubkeyHex: alicePubkey,
        ourIdentityPrivkeyHex: alicePrivkey,
        deviceId: alicePubkey,
      );
      final bobMgr = await NdrFfi.createSessionManager(
        ourPubkeyHex: bobPubkey,
        ourIdentityPrivkeyHex: bobPrivkey,
        deviceId: bobPubkey,
      );
      await aliceMgr.init();
      await bobMgr.init();

      final send = await aliceMgr.sendTextWithInnerId(
        recipientPubkeyHex: bobPubkey,
        text: 'hello bob',
      );
      expect(send.innerId, isNotEmpty);
      expect(send.outerEventIds, isNotEmpty);

      // Simulate relay delivery: deliver Alice's outer event to Bob's manager.
      final aliceOut = await aliceMgr.drainEvents();
      final publish = aliceOut.firstWhere((e) => e.kind == 'publish_signed');
      await bobMgr.processEvent(publish.eventJson!);

      final bobEvents = await bobMgr.drainEvents();
      final dec = bobEvents.firstWhere((e) => e.kind == 'decrypted_message');
      expect(dec.senderPubkeyHex, alicePubkey);

      final rumor = jsonDecode(dec.content!) as Map<String, dynamic>;
      expect(rumor['kind'], 14);
      expect(rumor['content'], 'hello bob');
      expect(rumor['id'], send.innerId);

      await aliceMgr.dispose();
      await bobMgr.dispose();
    });
  });
}
