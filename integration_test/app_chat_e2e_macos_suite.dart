import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iris_chat/config/providers/auth_provider.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/config/providers/invite_provider.dart';
import 'package:iris_chat/config/providers/nostr_provider.dart';
import 'package:iris_chat/core/ffi/ndr_ffi.dart';
import 'package:iris_chat/core/services/database_service.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/services/secure_storage_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/core/utils/invite_url.dart';
import 'package:iris_chat/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:iris_chat/features/chat/presentation/screens/chat_screen.dart';
import 'package:iris_chat/features/chat/presentation/widgets/typing_dots.dart';
import 'package:mocktail/mocktail.dart';

import 'test_relay.dart';

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

SecureStorageService _createInMemorySecureStorage() {
  final store = <String, String?>{};
  final storage = _MockFlutterSecureStorage();

  when(
    () => storage.write(
      key: any(named: 'key'),
      value: any(named: 'value'),
    ),
  ).thenAnswer((invocation) async {
    final key = invocation.namedArguments[#key] as String;
    final value = invocation.namedArguments[#value] as String?;
    store[key] = value;
  });

  when(() => storage.read(key: any(named: 'key'))).thenAnswer((
    invocation,
  ) async {
    final key = invocation.namedArguments[#key] as String;
    return store[key];
  });

  when(() => storage.containsKey(key: any(named: 'key'))).thenAnswer((
    invocation,
  ) async {
    final key = invocation.namedArguments[#key] as String;
    return store.containsKey(key);
  });

  when(() => storage.delete(key: any(named: 'key'))).thenAnswer((
    invocation,
  ) async {
    final key = invocation.namedArguments[#key] as String;
    store.remove(key);
  });

  Future<void> clearAll(Invocation _) async => store.clear();
  when(storage.deleteAll).thenAnswer(clearAll);

  return SecureStorageService(storage);
}

class _AppInstance {
  _AppInstance({
    required this.name,
    required this.container,
    required this.rootDir,
    required this.secureStorage,
    required this.deleteRootOnDispose,
  });

  final String name;
  final ProviderContainer container;
  final Directory rootDir;
  final SecureStorageService secureStorage;
  final bool deleteRootOnDispose;

  String get dbPath => '${rootDir.path}/db.sqlite';
  String get ndrPath => '${rootDir.path}/ndr';

  Future<void> dispose() async {
    final sessionManager = container.read(sessionManagerServiceProvider);
    final nostrService = container.read(nostrServiceProvider);
    final database = container.read(databaseServiceProvider);
    container.dispose();

    // Best-effort cleanup; test failures should still unwind.
    try {
      await sessionManager.dispose();
    } catch (_) {}
    try {
      await nostrService.dispose();
    } catch (_) {}
    try {
      await database.close();
    } catch (_) {}
    if (deleteRootOnDispose) {
      try {
        await rootDir.delete(recursive: true);
      } catch (_) {}
    }
  }
}

ProviderContainer _makeContainer({
  required String relayUrl,
  required String dbPath,
  required String ndrPath,
  required SecureStorageService secureStorage,
}) {
  return ProviderContainer(
    overrides: [
      secureStorageProvider.overrideWithValue(secureStorage),
      databaseServiceProvider.overrideWithValue(
        DatabaseService(dbPath: dbPath),
      ),
      nostrServiceProvider.overrideWith((ref) {
        final service = NostrService(relayUrls: [relayUrl]);
        ref.onDispose(() {
          // onDispose doesn't await; keep it best-effort.
          unawaited(service.dispose());
        });
        return service;
      }),
      sessionManagerServiceProvider.overrideWith((ref) {
        final nostr = ref.watch(nostrServiceProvider);
        final auth = ref.watch(authRepositoryProvider);

        final svc = SessionManagerService(
          nostr,
          auth,
          storagePathOverride: ndrPath,
        );
        unawaited(svc.start());
        ref.onDispose(() {
          unawaited(svc.dispose());
        });
        return svc;
      }),
    ],
  );
}

Future<_AppInstance> _startInstance({
  required String name,
  required String relayUrl,
  Directory? rootDirOverride,
  SecureStorageService? secureStorageOverride,
  bool createIdentity = true,
  bool restoreIdentity = false,
  bool deleteRootOnDispose = true,
}) async {
  final rootDir =
      rootDirOverride ??
      await Directory.systemTemp.createTemp('iris-chat-$name-');
  final secureStorage = secureStorageOverride ?? _createInMemorySecureStorage();

  final container = _makeContainer(
    relayUrl: relayUrl,
    dbPath: '${rootDir.path}/db.sqlite',
    ndrPath: '${rootDir.path}/ndr',
    secureStorage: secureStorage,
  );

  // Create or restore identity before starting the session manager.
  final authNotifier = container.read(authStateProvider.notifier);
  if (restoreIdentity) {
    await authNotifier.checkAuth();
  } else if (createIdentity) {
    await authNotifier.createIdentity();
  }
  final authState = container.read(authStateProvider);
  if (!authState.isAuthenticated) {
    throw StateError('Failed to initialize auth for instance $name');
  }

  // Bring transport online.
  await container.read(nostrServiceProvider).connect();

  // Start message + invite subscription bridge.
  container.read(messageSubscriptionProvider);

  await container
      .read(inviteStateProvider.notifier)
      .ensurePublishedPublicInvite();

  return _AppInstance(
    name: name,
    container: container,
    rootDir: rootDir,
    secureStorage: secureStorage,
    deleteRootOnDispose: deleteRootOnDispose,
  );
}

Future<void> _pumpUntil({
  required bool Function() condition,
  Duration timeout = const Duration(seconds: 12),
  Duration delay = const Duration(milliseconds: 25),
  String Function()? debugOnTimeout,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (condition()) return;
    await Future.delayed(delay);
  }
  final extra = debugOnTimeout != null ? '\n${debugOnTimeout()}' : '';
  throw StateError(
    'pumpUntil: condition not met after ${timeout.inSeconds}s$extra',
  );
}

bool _eventHasTag(Map<String, dynamic> event, String name, String value) {
  final tags = event['tags'];
  if (tags is! List) return false;
  for (final t in tags) {
    if (t is! List || t.length < 2) continue;
    if (t[0] == name && t[1] == value) return true;
  }
  return false;
}

String _describeChatState(ProviderContainer c) {
  final sb = StringBuffer();

  final sessions = c.read(sessionStateProvider).sessions;
  sb.writeln('sessions(${sessions.length}):');
  for (final s in sessions) {
    final pk = s.recipientPubkeyHex;
    final pk8 = pk.length >= 8 ? pk.substring(0, 8) : pk;
    sb.writeln(
      '  id=${s.id} recipient=$pk8 initiator=${s.isInitiator} unread=${s.unreadCount} lastPreview="${s.lastMessagePreview ?? ""}"',
    );
  }

  final chat = c.read(chatStateProvider);
  sb.writeln('chat messages keys(${chat.messages.length}):');
  for (final entry in chat.messages.entries) {
    final sid = entry.key;
    final msgs = entry.value;
    sb.writeln('  sessionId=$sid msgs=${msgs.length}');
    for (final m in msgs) {
      sb.writeln(
        '    ${m.isIncoming ? "in " : "out"} ${m.status.name} text="${m.text}"',
      );
    }
  }

  return sb.toString();
}

String _describeRelayDrEvents(TestRelay relay) {
  final sb = StringBuffer();
  final dr = relay.events.where((e) {
    final k = e['kind'];
    return k is num && k.toInt() == 1060;
  }).toList();

  sb.writeln('relay kind=1060 events(${dr.length}):');
  for (final e in dr) {
    final id = e['id']?.toString() ?? 'null';
    final id8 = id.length >= 8 ? id.substring(0, 8) : id;
    final pubkey = e['pubkey']?.toString() ?? 'null';
    final pk8 = pubkey.length >= 8 ? pubkey.substring(0, 8) : pubkey;
    final tags = e['tags'];
    String? p;
    if (tags is List) {
      for (final t in tags) {
        if (t is! List || t.length < 2) continue;
        if (t[0] == 'p') {
          p = t[1]?.toString();
          break;
        }
      }
    }
    final p8 = p == null ? 'null' : (p.length >= 8 ? p.substring(0, 8) : p);
    sb.writeln('  id=$id8 pubkey=$pk8 p=$p8');
  }
  return sb.toString();
}

bool _hasChatMessage(
  ProviderContainer container,
  String text, {
  bool? isIncoming,
}) {
  final allMessages = container.read(chatStateProvider).messages.values;
  for (final messages in allMessages) {
    for (final message in messages) {
      if (message.text != text) continue;
      if (isIncoming != null && message.isIncoming != isIncoming) continue;
      return true;
    }
  }
  return false;
}

String _describeInstances(Iterable<_AppInstance?> instances) {
  final sb = StringBuffer();
  for (final instance in instances) {
    if (instance == null) continue;
    sb.writeln('--- ${instance.name} ---');
    sb.writeln(_describeChatState(instance.container));
  }
  return sb.toString();
}

Future<_AppInstance> _startLinkedInstance({
  required String name,
  required String relayUrl,
  required TestRelay relay,
  required _AppInstance owner,
}) async {
  final ownerContainer = owner.container;
  final ownerPubkeyHex = ownerContainer.read(authStateProvider).pubkeyHex;
  if (ownerPubkeyHex == null || ownerPubkeyHex.isEmpty) {
    throw StateError('Owner pubkey missing for linked device $name');
  }

  final deviceNostr = NostrService(relayUrls: [relayUrl]);
  final deviceStorage = _createInMemorySecureStorage();
  final deviceRepo = AuthRepositoryImpl(deviceStorage);

  StreamSubscription<NostrEvent>? deviceSub;
  String? subid;
  InviteHandle? deviceInvite;
  InviteResponseResult? response;

  try {
    await deviceNostr.connect();

    final deviceKeypair = await NdrFfi.generateKeypair();
    deviceInvite = await NdrFfi.createInvite(
      inviterPubkeyHex: deviceKeypair.publicKeyHex,
      deviceId: deviceKeypair.publicKeyHex,
      maxUses: 1,
    );
    await deviceInvite.setPurpose('link');
    final inviteUrl = await deviceInvite.toUrl('https://iris.to');

    final data = decodeInviteUrlData(inviteUrl);
    final eph =
        data?['ephemeralKey'] ??
        data?['inviterEphemeralPublicKey'] ??
        data?['inviterEphemeralPublicKeyHex'];
    final inviteEph = eph is String ? eph : eph?.toString();
    if (inviteEph == null || inviteEph.isEmpty) {
      throw StateError('Invite URL missing ephemeral key for linked device');
    }

    final responseCompleter = Completer<NostrEvent>();
    subid = 'link-device-$name-${DateTime.now().microsecondsSinceEpoch}';
    deviceSub = deviceNostr.events.listen((event) {
      if (responseCompleter.isCompleted) return;
      if (event.subscriptionId != subid) return;
      if (event.kind != 1059) return;
      responseCompleter.complete(event);
    });
    deviceNostr.subscribeWithId(
      subid,
      NostrFilter(kinds: const [1059], pTags: [inviteEph]),
    );

    await _pumpUntil(
      condition: () =>
          relay.hasKindAndPTagSubscription(kind: 1059, pTagValue: inviteEph),
      timeout: const Duration(seconds: 6),
    );

    final accepted = await ownerContainer
        .read(inviteStateProvider.notifier)
        .acceptLinkInviteFromUrl(inviteUrl);
    if (!accepted) {
      final error = ownerContainer.read(inviteStateProvider).error;
      throw StateError(
        'Owner failed to accept link invite for $name${error == null ? "" : ": $error"}',
      );
    }

    final responseEvent = await responseCompleter.future.timeout(
      const Duration(seconds: 10),
    );
    response = await deviceInvite.processResponse(
      eventJson: jsonEncode(responseEvent.toJson()),
      inviterPrivkeyHex: deviceKeypair.privateKeyHex,
    );

    final resolvedOwnerPubkeyHex =
        response!.ownerPubkeyHex ?? response.inviteePubkeyHex;
    final sessionState = await response.session.stateJson();
    final remoteDeviceId = response.inviteePubkeyHex;
    if (resolvedOwnerPubkeyHex.isEmpty) {
      throw StateError('Invite response missing owner pubkey for $name');
    }
    if (resolvedOwnerPubkeyHex.toLowerCase() != ownerPubkeyHex.toLowerCase()) {
      throw StateError(
        'Linked device owner mismatch for $name: '
        '$resolvedOwnerPubkeyHex != $ownerPubkeyHex',
      );
    }

    await deviceRepo.loginLinkedDevice(
      ownerPubkeyHex: resolvedOwnerPubkeyHex,
      devicePrivkeyHex: deviceKeypair.privateKeyHex,
    );

    final instance = await _startInstance(
      name: name,
      relayUrl: relayUrl,
      secureStorageOverride: deviceStorage,
      createIdentity: false,
      restoreIdentity: true,
    );

    await instance.container
        .read(sessionManagerServiceProvider)
        .importSessionState(
          peerPubkeyHex: resolvedOwnerPubkeyHex,
          stateJson: sessionState,
          deviceId: remoteDeviceId,
        );

    return instance;
  } finally {
    if (subid != null) {
      deviceNostr.closeSubscription(subid);
    }
    await deviceSub?.cancel();
    try {
      await response?.session.dispose();
    } catch (_) {}
    try {
      await deviceInvite?.dispose();
    } catch (_) {}
    await deviceNostr.dispose();
  }
}

String _describeDecryptedMessage(DecryptedMessage m) {
  var innerKind = 'non-json';
  var innerContent = '';

  try {
    final decoded = jsonDecode(m.content);
    if (decoded is Map<String, dynamic>) {
      innerKind = decoded['kind']?.toString() ?? 'null';
      innerContent = (decoded['content'] ?? '').toString();
    } else {
      innerKind = 'non-map-json';
      innerContent = decoded.toString();
    }
  } catch (_) {
    innerKind = 'non-json';
    innerContent = m.content;
  }

  final sender = m.senderPubkeyHex;
  final sender8 = sender.length >= 8 ? sender.substring(0, 8) : sender;
  final eventId = m.eventId ?? '';
  final event8 = eventId.length >= 8 ? eventId.substring(0, 8) : eventId;
  final contentPreview = innerContent.length > 80
      ? '${innerContent.substring(0, 80)}...'
      : innerContent;
  return 'from=$sender8 eventId=$event8 kind=$innerKind content="$contentPreview"';
}

Future<String> _capturePngFromFinder(
  WidgetTester tester, {
  required Finder finder,
  required String fileName,
}) async {
  final renderObject = tester.firstRenderObject(finder);
  if (renderObject is! RenderRepaintBoundary) {
    throw StateError('Finder must resolve to a RepaintBoundary');
  }

  final image = await renderObject.toImage(pixelRatio: 2.0);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) {
    throw StateError('Failed to encode screenshot PNG');
  }
  final bytes = byteData.buffer.asUint8List();
  final dir = Directory('integration_test/artifacts');
  await dir.create(recursive: true);
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.absolute.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two app instances can exchange messages over a relay', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());

    if (!Platform.isMacOS) {
      return;
    }

    final relay = await TestRelay.start();
    final relayUrl = 'ws://127.0.0.1:${relay.port}';

    _AppInstance? alice;
    _AppInstance? bob;

    final aliceDec = <String>[];
    final bobDec = <String>[];
    StreamSubscription<DecryptedMessage>? aliceDecSub;
    StreamSubscription<DecryptedMessage>? bobDecSub;
    final aliceNostr1060 = <String>[];
    final bobNostr1060 = <String>[];
    StreamSubscription? aliceNostrSub;
    StreamSubscription? bobNostrSub;

    try {
      alice = await _startInstance(name: 'alice', relayUrl: relayUrl);
      bob = await _startInstance(name: 'bob', relayUrl: relayUrl);

      final aliceC = alice.container;
      final bobC = bob.container;

      aliceDecSub = aliceC
          .read(sessionManagerServiceProvider)
          .decryptedMessages
          .listen((m) {
            aliceDec.add(_describeDecryptedMessage(m));
            if (aliceDec.length > 50) {
              aliceDec.removeAt(0);
            }
          });
      bobDecSub = bobC
          .read(sessionManagerServiceProvider)
          .decryptedMessages
          .listen((m) {
            bobDec.add(_describeDecryptedMessage(m));
            if (bobDec.length > 50) {
              bobDec.removeAt(0);
            }
          });

      aliceNostrSub = aliceC.read(nostrServiceProvider).events.listen((e) {
        if (e.kind != 1060) return;
        final id8 = e.id.length >= 8 ? e.id.substring(0, 8) : e.id;
        aliceNostr1060.add('id=$id8 sub=${e.subscriptionId ?? ""}');
        if (aliceNostr1060.length > 50) {
          aliceNostr1060.removeAt(0);
        }
      });
      bobNostrSub = bobC.read(nostrServiceProvider).events.listen((e) {
        if (e.kind != 1060) return;
        final id8 = e.id.length >= 8 ? e.id.substring(0, 8) : e.id;
        bobNostr1060.add('id=$id8 sub=${e.subscriptionId ?? ""}');
        if (bobNostr1060.length > 50) {
          bobNostr1060.removeAt(0);
        }
      });

      // Alice creates invite.
      final invite = await aliceC
          .read(inviteStateProvider.notifier)
          .createInvite(maxUses: 1);
      expect(invite, isNotNull);

      final inviteUrl = await aliceC
          .read(inviteStateProvider.notifier)
          .getInviteUrl(invite!.id);
      expect(inviteUrl, isNotNull);

      final data = decodeInviteUrlData(inviteUrl!);
      final eph =
          data?['ephemeralKey'] ??
          data?['inviterEphemeralPublicKey'] ??
          data?['inviterEphemeralPublicKeyHex'];
      final inviteEph = eph is String ? eph : eph?.toString();
      expect(inviteEph, isNotNull, reason: 'Invite URL missing ephemeral key');

      // Ensure at least one client is subscribed for the invite response before Bob publishes it.
      await _pumpUntil(
        condition: () =>
            relay.hasKindAndPTagSubscription(kind: 1059, pTagValue: inviteEph!),
        timeout: const Duration(seconds: 6),
      );

      // Bob accepts.
      final bobSessionId = await bobC
          .read(inviteStateProvider.notifier)
          .acceptInviteFromUrl(inviteUrl);
      expect(bobSessionId, isNotNull);

      final taggedInviteResponses = relay.events.where((e) {
        final k = e['kind'];
        return k is num &&
            k.toInt() == 1059 &&
            _eventHasTag(e, 'p', inviteEph!);
      });
      expect(
        taggedInviteResponses,
        isNotEmpty,
        reason: 'Relay did not receive invite response for invite eph',
      );

      final bobOwnerPubkey = bobC.read(authStateProvider).pubkeyHex;
      expect(bobOwnerPubkey, isNotNull);

      // Wait for Alice to process the invite response and create a session.
      await _pumpUntil(
        condition: () {
          final sessions = aliceC.read(sessionStateProvider).sessions;
          return sessions.any((s) => s.recipientPubkeyHex == bobOwnerPubkey);
        },
      );

      final aliceSession = aliceC
          .read(sessionStateProvider)
          .sessions
          .firstWhere((s) => s.recipientPubkeyHex == bobOwnerPubkey);

      // Bob -> Alice
      await bobC
          .read(chatStateProvider.notifier)
          .sendMessage(bobSessionId!, 'hello alice');

      await _pumpUntil(
        condition: () {
          final msgs =
              aliceC.read(chatStateProvider).messages[aliceSession.id] ??
              const [];
          return msgs.any((m) => m.text == 'hello alice' && m.isIncoming);
        },
      );

      // Alice -> Bob
      await aliceC
          .read(chatStateProvider.notifier)
          .sendMessage(aliceSession.id, 'hi bob');

      await _pumpUntil(
        condition: () {
          final msgs =
              bobC.read(chatStateProvider).messages[bobSessionId] ?? const [];
          return msgs.any((m) => m.text == 'hi bob' && m.isIncoming);
        },
        debugOnTimeout: () {
          return '--- bob state ---\n${_describeChatState(bobC)}\n'
              '--- alice state ---\n${_describeChatState(aliceC)}\n'
              '--- bob decrypted (${bobDec.length}) ---\n${bobDec.join("\n")}\n'
              '--- alice decrypted (${aliceDec.length}) ---\n${aliceDec.join("\n")}\n'
              '--- bob nostr 1060 (${bobNostr1060.length}) ---\n${bobNostr1060.join("\n")}\n'
              '--- alice nostr 1060 (${aliceNostr1060.length}) ---\n${aliceNostr1060.join("\n")}\n'
              '--- relay ---\n${_describeRelayDrEvents(relay)}';
        },
      );
    } finally {
      // Cancel local decrypted-message taps (best effort).
      try {
        await aliceDecSub?.cancel();
      } catch (_) {}
      try {
        await bobDecSub?.cancel();
      } catch (_) {}
      try {
        await aliceNostrSub?.cancel();
      } catch (_) {}
      try {
        await bobNostrSub?.cancel();
      } catch (_) {}
      await alice?.dispose();
      await bob?.dispose();
      await relay.stop();
    }
  });

  testWidgets('burst incoming messages are all received in order', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());

    if (!Platform.isMacOS) {
      return;
    }

    final relay = await TestRelay.start();
    final relayUrl = 'ws://127.0.0.1:${relay.port}';

    _AppInstance? alice;
    _AppInstance? bob;

    try {
      alice = await _startInstance(name: 'alice-burst', relayUrl: relayUrl);
      bob = await _startInstance(name: 'bob-burst', relayUrl: relayUrl);

      final aliceC = alice.container;
      final bobC = bob.container;

      final invite = await aliceC
          .read(inviteStateProvider.notifier)
          .createInvite(maxUses: 1);
      expect(invite, isNotNull);

      final inviteUrl = await aliceC
          .read(inviteStateProvider.notifier)
          .getInviteUrl(invite!.id);
      expect(inviteUrl, isNotNull);

      final data = decodeInviteUrlData(inviteUrl!);
      final eph =
          data?['ephemeralKey'] ??
          data?['inviterEphemeralPublicKey'] ??
          data?['inviterEphemeralPublicKeyHex'];
      final inviteEph = eph is String ? eph : eph?.toString();
      expect(inviteEph, isNotNull, reason: 'Invite URL missing ephemeral key');

      await _pumpUntil(
        condition: () =>
            relay.hasKindAndPTagSubscription(kind: 1059, pTagValue: inviteEph!),
        timeout: const Duration(seconds: 6),
      );

      final bobSessionId = await bobC
          .read(inviteStateProvider.notifier)
          .acceptInviteFromUrl(inviteUrl);
      expect(bobSessionId, isNotNull);

      final bobOwnerPubkey = bobC.read(authStateProvider).pubkeyHex;
      expect(bobOwnerPubkey, isNotNull);

      await _pumpUntil(
        condition: () {
          final sessions = aliceC.read(sessionStateProvider).sessions;
          return sessions.any((s) => s.recipientPubkeyHex == bobOwnerPubkey);
        },
      );

      final aliceSessionId = aliceC
          .read(sessionStateProvider)
          .sessions
          .firstWhere((s) => s.recipientPubkeyHex == bobOwnerPubkey)
          .id;

      final base = DateTime.now().millisecondsSinceEpoch;
      final burstTexts = List<String>.generate(
        6,
        (i) => 'burst bob->alice #$i @$base',
      );

      await Future.wait(
        burstTexts.map(
          (text) => bobC
              .read(chatStateProvider.notifier)
              .sendMessage(bobSessionId!, text),
        ),
      );

      await _pumpUntil(
        condition: () {
          final msgs =
              aliceC.read(chatStateProvider).messages[aliceSessionId] ?? [];
          final incomingTexts = msgs
              .where((m) => m.isIncoming)
              .map((m) => m.text)
              .toSet();
          return burstTexts.every(incomingTexts.contains);
        },
        timeout: const Duration(seconds: 30),
        debugOnTimeout: () {
          return '--- alice state ---\n${_describeChatState(aliceC)}\n'
              '--- bob state ---\n${_describeChatState(bobC)}\n'
              '--- relay ---\n${_describeRelayDrEvents(relay)}';
        },
      );
    } finally {
      // Dispose ChatScreen from widget tree before disposing providers to avoid
      // late seen-sync callbacks touching disposed notifiers.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await alice?.dispose();
      await bob?.dispose();
      await relay.stop();
    }
  });

  testWidgets(
    'reopen app keeps receiving messages and handles multiple ratchet rounds',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());

      if (!Platform.isMacOS) {
        return;
      }

      final relay = await TestRelay.start();
      final relayUrl = 'ws://127.0.0.1:${relay.port}';
      final aliceRootDir = await Directory.systemTemp.createTemp(
        'iris-chat-alice-reopen-',
      );
      final aliceStorage = _createInMemorySecureStorage();

      _AppInstance? alice;
      _AppInstance? bob;

      try {
        alice = await _startInstance(
          name: 'alice-reopen',
          relayUrl: relayUrl,
          rootDirOverride: aliceRootDir,
          secureStorageOverride: aliceStorage,
          deleteRootOnDispose: false,
        );
        bob = await _startInstance(name: 'bob-reopen', relayUrl: relayUrl);

        final aliceC = alice.container;
        final bobC = bob.container;

        final invite = await aliceC
            .read(inviteStateProvider.notifier)
            .createInvite(maxUses: 1);
        expect(invite, isNotNull);

        final inviteUrl = await aliceC
            .read(inviteStateProvider.notifier)
            .getInviteUrl(invite!.id);
        expect(inviteUrl, isNotNull);

        final data = decodeInviteUrlData(inviteUrl!);
        final eph =
            data?['ephemeralKey'] ??
            data?['inviterEphemeralPublicKey'] ??
            data?['inviterEphemeralPublicKeyHex'];
        final inviteEph = eph is String ? eph : eph?.toString();
        expect(
          inviteEph,
          isNotNull,
          reason: 'Invite URL missing ephemeral key',
        );

        await _pumpUntil(
          condition: () => relay.hasKindAndPTagSubscription(
            kind: 1059,
            pTagValue: inviteEph!,
          ),
          timeout: const Duration(seconds: 6),
        );

        final bobSessionId = await bobC
            .read(inviteStateProvider.notifier)
            .acceptInviteFromUrl(inviteUrl);
        expect(bobSessionId, isNotNull);

        final bobOwnerPubkey = bobC.read(authStateProvider).pubkeyHex;
        expect(bobOwnerPubkey, isNotNull);

        await _pumpUntil(
          condition: () {
            final sessions = aliceC.read(sessionStateProvider).sessions;
            return sessions.any((s) => s.recipientPubkeyHex == bobOwnerPubkey);
          },
        );

        var aliceSessionId = aliceC
            .read(sessionStateProvider)
            .sessions
            .firstWhere((s) => s.recipientPubkeyHex == bobOwnerPubkey)
            .id;

        final beforeReopenText =
            'pre-reopen bob->alice ${DateTime.now().millisecondsSinceEpoch}';
        await bobC
            .read(chatStateProvider.notifier)
            .sendMessage(bobSessionId!, beforeReopenText);

        await _pumpUntil(
          condition: () {
            final msgs =
                aliceC.read(chatStateProvider).messages[aliceSessionId] ??
                const [];
            return msgs.any((m) => m.text == beforeReopenText && m.isIncoming);
          },
        );

        await alice.dispose();
        alice = await _startInstance(
          name: 'alice-reopen',
          relayUrl: relayUrl,
          rootDirOverride: aliceRootDir,
          secureStorageOverride: aliceStorage,
          createIdentity: false,
          restoreIdentity: true,
          deleteRootOnDispose: false,
        );

        final reopenedAliceC = alice.container;
        await reopenedAliceC.read(sessionStateProvider.notifier).loadSessions();

        await _pumpUntil(
          condition: () {
            final sessions = reopenedAliceC.read(sessionStateProvider).sessions;
            return sessions.any((s) => s.recipientPubkeyHex == bobOwnerPubkey);
          },
        );

        aliceSessionId = reopenedAliceC
            .read(sessionStateProvider)
            .sessions
            .firstWhere((s) => s.recipientPubkeyHex == bobOwnerPubkey)
            .id;

        for (var i = 1; i <= 3; i++) {
          final bobToAlice =
              'post-reopen bob->alice #$i ${DateTime.now().millisecondsSinceEpoch}';
          await bobC
              .read(chatStateProvider.notifier)
              .sendMessage(bobSessionId, bobToAlice);

          await _pumpUntil(
            condition: () {
              final msgs =
                  reopenedAliceC
                      .read(chatStateProvider)
                      .messages[aliceSessionId] ??
                  const [];
              return msgs.any((m) => m.text == bobToAlice && m.isIncoming);
            },
            timeout: const Duration(seconds: 20),
            debugOnTimeout: () {
              return '--- reopened alice state ---\n${_describeChatState(reopenedAliceC)}\n'
                  '--- bob state ---\n${_describeChatState(bobC)}\n'
                  '--- relay ---\n${_describeRelayDrEvents(relay)}';
            },
          );

          final aliceToBob =
              'post-reopen alice->bob #$i ${DateTime.now().millisecondsSinceEpoch}';
          await reopenedAliceC
              .read(chatStateProvider.notifier)
              .sendMessage(aliceSessionId, aliceToBob);

          await _pumpUntil(
            condition: () {
              final msgs =
                  bobC.read(chatStateProvider).messages[bobSessionId] ??
                  const [];
              return msgs.any((m) => m.text == aliceToBob && m.isIncoming);
            },
            timeout: const Duration(seconds: 20),
            debugOnTimeout: () {
              return '--- reopened alice state ---\n${_describeChatState(reopenedAliceC)}\n'
                  '--- bob state ---\n${_describeChatState(bobC)}\n'
                  '--- relay ---\n${_describeRelayDrEvents(relay)}';
            },
          );
        }
      } finally {
        await alice?.dispose();
        await bob?.dispose();
        try {
          await aliceRootDir.delete(recursive: true);
        } catch (_) {}
        await relay.stop();
      }
    },
  );

  testWidgets('typing indicator appears in UI and hides on stop rumor', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());

    if (!Platform.isMacOS) {
      return;
    }

    await tester.binding.setSurfaceSize(const Size(1280, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final relay = await TestRelay.start();
    final relayUrl = 'ws://127.0.0.1:${relay.port}';

    _AppInstance? alice;
    _AppInstance? bob;

    try {
      alice = await _startInstance(name: 'alice-typing', relayUrl: relayUrl);
      bob = await _startInstance(name: 'bob-typing', relayUrl: relayUrl);

      final aliceC = alice.container;
      final bobC = bob.container;

      final invite = await aliceC
          .read(inviteStateProvider.notifier)
          .createInvite(maxUses: 1);
      expect(invite, isNotNull);

      final inviteUrl = await aliceC
          .read(inviteStateProvider.notifier)
          .getInviteUrl(invite!.id);
      expect(inviteUrl, isNotNull);

      final data = decodeInviteUrlData(inviteUrl!);
      final eph =
          data?['ephemeralKey'] ??
          data?['inviterEphemeralPublicKey'] ??
          data?['inviterEphemeralPublicKeyHex'];
      final inviteEph = eph is String ? eph : eph?.toString();
      expect(inviteEph, isNotNull);

      await _pumpUntil(
        condition: () =>
            relay.hasKindAndPTagSubscription(kind: 1059, pTagValue: inviteEph!),
        timeout: const Duration(seconds: 6),
      );

      final bobSessionId = await bobC
          .read(inviteStateProvider.notifier)
          .acceptInviteFromUrl(inviteUrl);
      expect(bobSessionId, isNotNull);

      final bobOwnerPubkey = bobC.read(authStateProvider).pubkeyHex;
      expect(bobOwnerPubkey, isNotNull);

      await _pumpUntil(
        condition: () {
          final sessions = aliceC.read(sessionStateProvider).sessions;
          return sessions.any((s) => s.recipientPubkeyHex == bobOwnerPubkey);
        },
      );

      final aliceSession = aliceC
          .read(sessionStateProvider)
          .sessions
          .firstWhere((s) => s.recipientPubkeyHex == bobOwnerPubkey);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: aliceC,
          child: MaterialApp(
            home: RepaintBoundary(
              key: const Key('typing_indicator_capture'),
              child: ChatScreen(sessionId: aliceSession.id),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(TypingDots), findsNothing);

      await bobC.read(chatStateProvider.notifier).notifyTyping(bobSessionId!);
      await _pumpUntil(
        condition: () {
          final typing = aliceC.read(chatStateProvider).typingStates;
          return (typing[aliceSession.id] ?? false) ||
              (typing[aliceSession.recipientPubkeyHex] ?? false);
        },
        timeout: const Duration(seconds: 8),
      );

      final showDeadline = DateTime.now().add(const Duration(seconds: 4));
      while (DateTime.now().isBefore(showDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(TypingDots).evaluate().isNotEmpty) break;
      }
      expect(find.byType(TypingDots), findsOneWidget);
      final screenshotPath = await _capturePngFromFinder(
        tester,
        finder: find.byKey(const Key('typing_indicator_capture')),
        fileName: 'typing_indicator_e2e.png',
      );
      expect(File(screenshotPath).existsSync(), isTrue);

      await bobC
          .read(chatStateProvider.notifier)
          .notifyTypingStopped(bobSessionId);
      await _pumpUntil(
        condition: () {
          final typing = aliceC.read(chatStateProvider).typingStates;
          return !(typing[aliceSession.id] ?? false) &&
              !(typing[aliceSession.recipientPubkeyHex] ?? false);
        },
        timeout: const Duration(seconds: 8),
      );

      final hideDeadline = DateTime.now().add(const Duration(seconds: 4));
      while (DateTime.now().isBefore(hideDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(TypingDots).evaluate().isEmpty) break;
      }
      expect(find.byType(TypingDots), findsNothing);
    } finally {
      await alice?.dispose();
      await bob?.dispose();
      await relay.stop();
    }
  });

  testWidgets('incoming burst keeps latest message visible when chat is open', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());

    if (!Platform.isMacOS) {
      return;
    }

    await tester.binding.setSurfaceSize(const Size(1280, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final relay = await TestRelay.start();
    final relayUrl = 'ws://127.0.0.1:${relay.port}';

    _AppInstance? alice;
    _AppInstance? bob;

    try {
      alice = await _startInstance(name: 'alice-ui-burst', relayUrl: relayUrl);
      bob = await _startInstance(name: 'bob-ui-burst', relayUrl: relayUrl);

      final aliceC = alice.container;
      final bobC = bob.container;

      final invite = await aliceC
          .read(inviteStateProvider.notifier)
          .createInvite(maxUses: 1);
      expect(invite, isNotNull);

      final inviteUrl = await aliceC
          .read(inviteStateProvider.notifier)
          .getInviteUrl(invite!.id);
      expect(inviteUrl, isNotNull);

      final data = decodeInviteUrlData(inviteUrl!);
      final eph =
          data?['ephemeralKey'] ??
          data?['inviterEphemeralPublicKey'] ??
          data?['inviterEphemeralPublicKeyHex'];
      final inviteEph = eph is String ? eph : eph?.toString();
      expect(inviteEph, isNotNull);

      await _pumpUntil(
        condition: () =>
            relay.hasKindAndPTagSubscription(kind: 1059, pTagValue: inviteEph!),
        timeout: const Duration(seconds: 6),
      );

      final bobSessionId = await bobC
          .read(inviteStateProvider.notifier)
          .acceptInviteFromUrl(inviteUrl);
      expect(bobSessionId, isNotNull);

      final bobOwnerPubkey = bobC.read(authStateProvider).pubkeyHex;
      expect(bobOwnerPubkey, isNotNull);

      await _pumpUntil(
        condition: () {
          final sessions = aliceC.read(sessionStateProvider).sessions;
          return sessions.any((s) => s.recipientPubkeyHex == bobOwnerPubkey);
        },
      );

      final aliceSession = aliceC
          .read(sessionStateProvider)
          .sessions
          .firstWhere((s) => s.recipientPubkeyHex == bobOwnerPubkey);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: aliceC,
          child: MaterialApp(home: ChatScreen(sessionId: aliceSession.id)),
        ),
      );
      await tester.pump();

      final burst = List<String>.generate(
        8,
        (i) =>
            'ui burst bob->alice #$i ${DateTime.now().millisecondsSinceEpoch}',
      );

      await Future.wait(
        burst.map(
          (text) => bobC
              .read(chatStateProvider.notifier)
              .sendMessage(bobSessionId!, text),
        ),
      );

      await _pumpUntil(
        condition: () {
          final msgs =
              aliceC.read(chatStateProvider).messages[aliceSession.id] ??
              const <dynamic>[];
          final incomingTexts = msgs
              .where((m) => m.isIncoming)
              .map((m) => m.text)
              .toSet();
          return burst.every(incomingTexts.contains);
        },
        timeout: const Duration(seconds: 30),
      );

      final last = burst.last;
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 120));
        if (find.text(last).evaluate().isNotEmpty) break;
      }

      expect(
        find.text(last),
        findsOneWidget,
        reason: 'Latest incoming message should stay visible when chat is open',
      );
    } finally {
      await alice?.dispose();
      await bob?.dispose();
      await relay.stop();
    }
  });

  testWidgets(
    'public npub chat link path can bootstrap first incoming message',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());

      if (!Platform.isMacOS) {
        return;
      }

      final relay = await TestRelay.start();
      final relayUrl = 'ws://127.0.0.1:${relay.port}';

      _AppInstance? alice;
      _AppInstance? bob;

      try {
        alice = await _startInstance(name: 'alice-npub', relayUrl: relayUrl);
        bob = await _startInstance(name: 'bob-npub', relayUrl: relayUrl);

        final aliceC = alice.container;
        final bobC = bob.container;

        final bobPubkey = bobC.read(authStateProvider).pubkeyHex;
        expect(bobPubkey, isNotNull);

        final aliceSession = await aliceC
            .read(sessionStateProvider.notifier)
            .ensureSessionForRecipient(bobPubkey!);

        await aliceC
            .read(chatStateProvider.notifier)
            .sendMessage(aliceSession.id, 'hello bob via npub path');

        await _pumpUntil(
          condition: () {
            final allMessages = bobC.read(chatStateProvider).messages.values;
            for (final messages in allMessages) {
              if (messages.any((m) => m.text == 'hello bob via npub path')) {
                return true;
              }
            }
            return false;
          },
          timeout: const Duration(seconds: 20),
          debugOnTimeout: () {
            return '--- bob state ---\n${_describeChatState(bobC)}\n'
                '--- alice state ---\n${_describeChatState(aliceC)}\n'
                '--- relay ---\n${_describeRelayDrEvents(relay)}';
          },
        );
      } finally {
        await alice?.dispose();
        await bob?.dispose();
        await relay.stop();
      }
    },
  );

  testWidgets('two users with linked devices sync messages across all devices', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());

    if (!Platform.isMacOS) {
      return;
    }

    final relay = await TestRelay.start();
    final relayUrl = 'ws://127.0.0.1:${relay.port}';

    _AppInstance? aliceOwner;
    _AppInstance? aliceLinked;
    _AppInstance? bobOwner;
    _AppInstance? bobLinked;

    String debugState() {
      return '${_describeInstances([aliceOwner, aliceLinked, bobOwner, bobLinked])}\n'
          '--- relay ---\n${_describeRelayDrEvents(relay)}';
    }

    try {
      aliceOwner = await _startInstance(
        name: 'alice-owner-multi-device',
        relayUrl: relayUrl,
      );
      bobOwner = await _startInstance(
        name: 'bob-owner-multi-device',
        relayUrl: relayUrl,
      );

      final aliceOwnerC = aliceOwner.container;
      final bobOwnerC = bobOwner.container;
      final alicePubkey = aliceOwnerC.read(authStateProvider).pubkeyHex;
      final bobPubkey = bobOwnerC.read(authStateProvider).pubkeyHex;
      expect(alicePubkey, isNotNull);
      expect(bobPubkey, isNotNull);
      final alicePubkeyHex = alicePubkey!;
      final bobPubkeyHex = bobPubkey!;

      final baseAliceSession = await aliceOwnerC
          .read(sessionStateProvider.notifier)
          .ensureSessionForRecipient(bobPubkeyHex);
      final bootstrapText =
          'owner bootstrap ${DateTime.now().millisecondsSinceEpoch}';
      await aliceOwnerC
          .read(chatStateProvider.notifier)
          .sendMessage(baseAliceSession.id, bootstrapText);

      await _pumpUntil(
        condition: () =>
            _hasChatMessage(bobOwnerC, bootstrapText, isIncoming: true),
        timeout: const Duration(seconds: 20),
        debugOnTimeout: debugState,
      );

      await aliceOwnerC
          .read(sessionManagerServiceProvider)
          .setupUser(bobPubkeyHex);
      await bobOwnerC
          .read(sessionManagerServiceProvider)
          .setupUser(alicePubkeyHex);

      aliceLinked = await _startLinkedInstance(
        name: 'alice-linked-multi-device',
        relayUrl: relayUrl,
        relay: relay,
        owner: aliceOwner,
      );
      await bobOwnerC
          .read(sessionManagerServiceProvider)
          .setupUser(alicePubkeyHex);

      bobLinked = await _startLinkedInstance(
        name: 'bob-linked-multi-device',
        relayUrl: relayUrl,
        relay: relay,
        owner: bobOwner,
      );
      await aliceOwnerC
          .read(sessionManagerServiceProvider)
          .setupUser(bobPubkeyHex);

      final aliceOwnerSessionId = aliceOwnerC
          .read(sessionStateProvider)
          .sessions
          .firstWhere((s) => s.recipientPubkeyHex == bobPubkeyHex)
          .id;

      final ownerToBobText =
          'alice owner -> bob all devices ${DateTime.now().millisecondsSinceEpoch}';
      await aliceOwnerC
          .read(chatStateProvider.notifier)
          .sendMessage(aliceOwnerSessionId, ownerToBobText);

      await _pumpUntil(
        condition: () =>
            _hasChatMessage(
              aliceLinked!.container,
              ownerToBobText,
              isIncoming: false,
            ) &&
            _hasChatMessage(bobOwnerC, ownerToBobText, isIncoming: true) &&
            _hasChatMessage(
              bobLinked!.container,
              ownerToBobText,
              isIncoming: true,
            ),
        timeout: const Duration(seconds: 25),
        debugOnTimeout: debugState,
      );

      await _pumpUntil(
        condition: () {
          final sessions = bobLinked!.container.read(sessionStateProvider);
          return sessions.sessions.any(
            (s) => s.recipientPubkeyHex == alicePubkeyHex,
          );
        },
        timeout: const Duration(seconds: 20),
        debugOnTimeout: debugState,
      );

      final bobLinkedSessionId = bobLinked.container
          .read(sessionStateProvider)
          .sessions
          .firstWhere((s) => s.recipientPubkeyHex == alicePubkeyHex)
          .id;

      await bobLinked.container
          .read(sessionManagerServiceProvider)
          .setupUser(alicePubkeyHex);
      await bobLinked.container
          .read(sessionManagerServiceProvider)
          .setupUser(bobPubkeyHex);

      final linkedToAliceText =
          'bob linked -> alice all devices ${DateTime.now().millisecondsSinceEpoch}';
      await bobLinked.container
          .read(chatStateProvider.notifier)
          .sendMessage(bobLinkedSessionId, linkedToAliceText);

      await _pumpUntil(
        condition: () =>
            _hasChatMessage(bobOwnerC, linkedToAliceText, isIncoming: false) &&
            _hasChatMessage(aliceOwnerC, linkedToAliceText, isIncoming: true) &&
            _hasChatMessage(
              aliceLinked!.container,
              linkedToAliceText,
              isIncoming: true,
            ),
        timeout: const Duration(seconds: 25),
        debugOnTimeout: debugState,
      );
    } finally {
      await aliceOwner?.dispose();
      await aliceLinked?.dispose();
      await bobOwner?.dispose();
      await bobLinked?.dispose();
      await relay.stop();
    }
  });
}
