import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iris_chat/config/providers/app_bootstrap_provider.dart';
import 'package:iris_chat/config/providers/auth_provider.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/config/providers/invite_provider.dart';
import 'package:iris_chat/config/providers/login_device_registration_provider.dart';
import 'package:iris_chat/config/providers/nostr_provider.dart';
import 'package:iris_chat/core/ffi/ndr_ffi.dart';
import 'package:iris_chat/core/services/database_service.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/services/secure_storage_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:iris_chat/core/utils/invite_url.dart';
import 'package:iris_chat/features/chat/presentation/screens/chat_screen.dart';
import 'package:mocktail/mocktail.dart';

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

ProviderContainer _makeContainer({
  required List<String> relayUrls,
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
        final service = NostrService(relayUrls: relayUrls);
        ref.onDispose(() {
          unawaited(service.dispose());
        });
        return service;
      }),
      sessionManagerServiceProvider.overrideWith((ref) {
        ref.watch(
          authStateProvider.select(
            (s) => (s.isAuthenticated, s.pubkeyHex, s.devicePubkeyHex),
          ),
        );

        final nostr = ref.watch(nostrServiceProvider);
        final auth = ref.watch(authRepositoryProvider);
        final messageDatasource = ref.watch(messageDatasourceProvider);

        final svc = SessionManagerService(
          nostr,
          auth,
          storagePathOverride: ndrPath,
          hasProcessedMessageEventId: messageDatasource.messageExists,
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

Future<void> _runAppBootstrap(ProviderContainer container) async {
  Future<void> bootstrapCurrentSessions() async {
    final sessionManager = container.read(sessionManagerServiceProvider);
    final bootstrapTargets = sessionBootstrapTargets(
      sessionRecipientPubkeysHex: container
          .read(sessionStateProvider)
          .sessions
          .map((session) => session.recipientPubkeyHex),
      ownerPubkeyHex: sessionManager.ownerPubkeyHex,
    );
    await sessionManager.setupUsers(bootstrapTargets);
    final relayBootstrapTargets = await sessionRelayBootstrapTargets(
      bootstrapTargets: bootstrapTargets,
      getActiveSessionState: sessionManager.getActiveSessionState,
    );
    if (relayBootstrapTargets.isNotEmpty) {
      await sessionManager.bootstrapUsersFromRelay(relayBootstrapTargets);
    }
  }

  await container.read(sessionStateProvider.notifier).loadSessions();
  await container.read(groupStateProvider.notifier).loadGroups();
  await bootstrapCurrentSessions();
  await container.read(inviteStateProvider.notifier).loadInvites();
  await container
      .read(inviteStateProvider.notifier)
      .bootstrapInviteResponsesFromRelay();
  await container.read(sessionStateProvider.notifier).loadSessions();
  await bootstrapCurrentSessions();
  final sessionManager = container.read(sessionManagerServiceProvider);
  final bootstrapTargets = sessionBootstrapTargets(
    sessionRecipientPubkeysHex: container
        .read(sessionStateProvider)
        .sessions
        .map((session) => session.recipientPubkeyHex),
    ownerPubkeyHex: sessionManager.ownerPubkeyHex,
  );
  await sessionManager.refreshSubscription();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  await sessionManager.repairRecentlyActiveLinkedDeviceRecords(
    bootstrapTargets,
  );
  container.read(messageSubscriptionProvider);
  await container
      .read(inviteStateProvider.notifier)
      .ensurePublishedPublicInvite();
  await container
      .read(sessionManagerServiceProvider)
      .bootstrapOwnerSelfSessionIfNeeded();
}

Map<String, dynamic> _payloadFor(Map<String, dynamic> command) {
  final payload = command['payload'];
  if (payload is Map<String, dynamic>) return payload;
  if (payload is Map) {
    return Map<String, dynamic>.from(payload);
  }
  return const <String, dynamic>{};
}

Future<void> _emitEvent(File eventsFile, Map<String, dynamic> event) async {
  final line = jsonEncode(event);
  await eventsFile.writeAsString('$line\n', mode: FileMode.append, flush: true);
  // Keep a mirrored stdout breadcrumb for easier local debugging.
  stdout.writeln('IRIS_FLUTTER_INTEROP_EVENT $line');
}

Future<String?> _readPersistedInteropDevicePrivkey(File stateFile) async {
  if (!stateFile.existsSync()) return null;
  try {
    final decoded = jsonDecode(await stateFile.readAsString());
    if (decoded is! Map<String, dynamic>) return null;
    final value = decoded['devicePrivkeyHex'];
    if (value is! String) return null;
    final normalized = value.trim().toLowerCase();
    if (normalized.length != 64) return null;
    return normalized;
  } catch (_) {
    return null;
  }
}

Future<void> _writePersistedInteropDevicePrivkey(
  File stateFile,
  String devicePrivkeyHex,
) async {
  final normalized = devicePrivkeyHex.trim().toLowerCase();
  if (normalized.length != 64) return;
  await stateFile.writeAsString(
    jsonEncode({'devicePrivkeyHex': normalized}),
    flush: true,
  );
}

class _PendingLinkInvite {
  const _PendingLinkInvite({
    required this.invite,
    required this.devicePrivkeyHex,
    required this.ephemeralPubkeyHex,
  });

  final InviteHandle invite;
  final String devicePrivkeyHex;
  final String ephemeralPubkeyHex;
}

_PendingLinkInvite? _pendingLinkInvite;

Future<void> _disposePendingLinkInvite() async {
  final pending = _pendingLinkInvite;
  _pendingLinkInvite = null;
  if (pending == null) return;
  try {
    await pending.invite.dispose();
  } catch (_) {}
}

class _MessageMatch {
  const _MessageMatch({
    required this.sessionId,
    required this.messageId,
    required this.text,
    this.rumorId,
    this.eventId,
  });

  final String sessionId;
  final String messageId;
  final String text;
  final String? rumorId;
  final String? eventId;
}

_MessageMatch? _findMessageByText(
  ProviderContainer container, {
  required String text,
  required bool incomingOnly,
}) {
  final messagesBySession = container.read(chatStateProvider).messages;
  for (final entry in messagesBySession.entries) {
    final sessionId = entry.key;
    for (final message in entry.value) {
      if (message.text != text) continue;
      if (incomingOnly && !message.isIncoming) continue;
      return _MessageMatch(
        sessionId: sessionId,
        messageId: message.id,
        text: message.text,
        rumorId: message.rumorId,
        eventId: message.eventId,
      );
    }
  }
  return null;
}

Map<String, dynamic> _debugStateForTimeout(ProviderContainer container) {
  final authState = container.read(authStateProvider);
  final sessionManager = container.read(sessionManagerServiceProvider);
  final sessions = container.read(sessionStateProvider).sessions;
  final messages = container.read(chatStateProvider).messages;

  return {
    'auth': {
      'isAuthenticated': authState.isAuthenticated,
      'ownerPubkeyHex': authState.pubkeyHex,
      'devicePubkeyHex': authState.devicePubkeyHex,
    },
    'sessions': [
      for (final session in sessions)
        {
          'id': session.id,
          'recipientPubkeyHex': session.recipientPubkeyHex,
          'createdAt': session.createdAt.toIso8601String(),
          'isInitiator': session.isInitiator,
        },
    ],
    'messages': {
      for (final entry in messages.entries)
        entry.key: [
          for (final message in entry.value)
            {
              'id': message.id,
              'text': message.text,
              'isIncoming': message.isIncoming,
              'eventId': message.eventId,
              'rumorId': message.rumorId,
            },
        ],
    },
    'sessionManager': sessionManager.debugSnapshot(),
    'nostr': container.read(nostrServiceProvider).debugSnapshot(),
  };
}

Future<String?> _findSessionIdByRecipient(
  ProviderContainer container,
  String recipientPubkeyHex,
) async {
  final normalized = recipientPubkeyHex.toLowerCase();

  final inMemory = container.read(sessionStateProvider).sessions;
  for (final session in inMemory) {
    if (session.recipientPubkeyHex.toLowerCase() == normalized ||
        session.id.toLowerCase() == normalized) {
      return session.id;
    }
  }

  final fromDb = await container
      .read(sessionDatasourceProvider)
      .getSessionByRecipient(normalized);
  if (fromDb != null) {
    unawaited(
      container.read(sessionStateProvider.notifier).refreshSession(fromDb.id),
    );
    return fromDb.id;
  }

  return null;
}

Future<bool> _waitForMessageText(
  ProviderContainer container, {
  required String text,
  required Duration timeout,
  required bool incomingOnly,
}) async {
  final end = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(end)) {
    final match = _findMessageByText(
      container,
      text: text,
      incomingOnly: incomingOnly,
    );
    if (match != null) {
      return true;
    }

    await Future.delayed(const Duration(milliseconds: 80));
  }

  return false;
}

Future<_MessageMatch?> _waitForMessageMatch(
  ProviderContainer container, {
  required String text,
  required Duration timeout,
  required bool incomingOnly,
}) async {
  final end = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(end)) {
    final match = _findMessageByText(
      container,
      text: text,
      incomingOnly: incomingOnly,
    );
    if (match != null) return match;
    await Future.delayed(const Duration(milliseconds: 80));
  }

  return null;
}

Future<Set<String>> _typingKeysForSession(
  ProviderContainer container,
  String sessionId,
) async {
  final normalizedSessionId = sessionId.toLowerCase();
  final keys = <String>{normalizedSessionId};

  String? recipientPubkeyHex;
  final inMemory = container.read(sessionStateProvider).sessions;
  for (final s in inMemory) {
    if (s.id.toLowerCase() == normalizedSessionId) {
      recipientPubkeyHex = s.recipientPubkeyHex;
      break;
    }
  }

  if (recipientPubkeyHex == null || recipientPubkeyHex.isEmpty) {
    final byId = await container
        .read(sessionDatasourceProvider)
        .getSession(sessionId);
    recipientPubkeyHex = byId?.recipientPubkeyHex;
  }

  if (recipientPubkeyHex == null || recipientPubkeyHex.isEmpty) {
    final byRecipient = await container
        .read(sessionDatasourceProvider)
        .getSessionByRecipient(sessionId);
    recipientPubkeyHex = byRecipient?.recipientPubkeyHex;
  }

  final recipient = recipientPubkeyHex?.toLowerCase().trim();
  if (recipient != null && recipient.isNotEmpty) {
    keys.add(recipient);
  }

  return keys;
}

Future<bool> _waitForTypingState(
  ProviderContainer container, {
  required String sessionId,
  required bool expectedTyping,
  required Duration timeout,
}) async {
  final end = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(end)) {
    final keys = await _typingKeysForSession(container, sessionId);
    final typing = container.read(chatStateProvider).typingStates;
    final isTyping = keys.any((key) => typing[key] ?? false);
    if (isTyping == expectedTyping) {
      return true;
    }
    await Future.delayed(const Duration(milliseconds: 80));
  }

  return false;
}

Future<bool> _waitForGroup(
  ProviderContainer container, {
  required String groupId,
  required Duration timeout,
}) async {
  final end = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(end)) {
    final groups = container.read(groupStateProvider).groups;
    if (groups.any((g) => g.id == groupId)) {
      return true;
    }
    await Future.delayed(const Duration(milliseconds: 80));
  }

  return false;
}

Future<String?> _waitForGroupNamed(
  ProviderContainer container, {
  required String name,
  required Duration timeout,
}) async {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;

  final end = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(end)) {
    final groups = container.read(groupStateProvider).groups;
    for (final group in groups) {
      if (group.name == trimmed) {
        return group.id;
      }
    }
    await Future.delayed(const Duration(milliseconds: 80));
  }

  return null;
}

Future<bool> _waitForGroupMessageText(
  ProviderContainer container, {
  required String groupId,
  required String text,
  required Duration timeout,
  required bool incomingOnly,
}) async {
  final end = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(end)) {
    final messagesByGroup = container.read(groupStateProvider).messages;
    final messages = messagesByGroup[groupId] ?? const <dynamic>[];

    for (final message in messages) {
      if (message.text != text) continue;
      if (incomingOnly && !message.isIncoming) continue;
      return true;
    }

    await Future.delayed(const Duration(milliseconds: 80));
  }

  return false;
}

Future<void> _pumpChatUi(
  WidgetTester tester,
  ProviderContainer container,
  String sessionId,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatScreen(sessionId: sessionId)),
    ),
  );
  await tester.pump();
}

Future<bool> _waitForMessageInUi(
  WidgetTester tester,
  ProviderContainer container, {
  required String sessionId,
  required String text,
  required Duration timeout,
  required bool incomingOnly,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await _pumpChatUi(tester, container, sessionId);
    final match = _findMessageByText(
      container,
      text: text,
      incomingOnly: incomingOnly,
    );
    if (match != null &&
        match.sessionId.toLowerCase() == sessionId.toLowerCase() &&
        find.text(text).evaluate().isNotEmpty) {
      return true;
    }
    await tester.pump(const Duration(milliseconds: 80));
  }
  return false;
}

Future<void> _sendMessageInUi(
  WidgetTester tester,
  ProviderContainer container, {
  required String sessionId,
  required String text,
}) async {
  await _pumpChatUi(tester, container, sessionId);

  final input = find.byType(TextField).first;
  if (input.evaluate().isEmpty) {
    throw StateError('Chat composer TextField not found');
  }
  await tester.tap(input);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.showKeyboard(input);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.enterText(input, text);
  await tester.pump(const Duration(milliseconds: 50));
  final textField = tester.widget<TextField>(input);
  final composed = textField.controller?.text ?? '';
  if (composed.trim() != text.trim()) {
    throw StateError(
      'Failed to type message in composer. expected="$text" actual="$composed"',
    );
  }

  final sendButton = find.byIcon(Icons.send).first;
  if (sendButton.evaluate().isEmpty) {
    throw StateError('Send button not found in chat UI');
  }
  await tester.tap(sendButton);
  await tester.pump(const Duration(milliseconds: 120));

  final sent = await _waitForMessageText(
    container,
    text: text,
    timeout: const Duration(seconds: 8),
    incomingOnly: false,
  );
  if (!sent) {
    final messages =
        container.read(chatStateProvider).messages[sessionId] ?? [];
    final previews = messages.map((m) => m.text).toList(growable: false);
    throw StateError(
      'UI send did not produce local message text within timeout. '
      'sessionId=$sessionId knownMessages=${previews.join(" | ")}',
    );
  }
}

Future<void> _handleCommand({
  required WidgetTester tester,
  required ProviderContainer container,
  required File eventsFile,
  required Map<String, dynamic> command,
}) async {
  final id = command['id']?.toString() ?? '';
  final type = command['type']?.toString() ?? '';
  final payload = _payloadFor(command);

  Future<void> ok(Map<String, dynamic> data) {
    return _emitEvent(eventsFile, {
      'type': 'response',
      'id': id,
      'ok': true,
      'data': data,
    });
  }

  Future<void> fail(Object error) {
    return _emitEvent(eventsFile, {
      'type': 'response',
      'id': id,
      'ok': false,
      'error': error.toString(),
    });
  }

  try {
    switch (type) {
      case 'get_pubkey':
        final pubkeyHex = container.read(authStateProvider).pubkeyHex;
        if (pubkeyHex == null || pubkeyHex.isEmpty) {
          throw StateError('No authenticated pubkey');
        }
        await ok({'pubkeyHex': pubkeyHex});
        return;

      case 'create_invite':
        final maxUsesRaw = payload['maxUses'];
        final maxUses = maxUsesRaw is num ? maxUsesRaw.toInt() : 1;
        final invite = await container
            .read(inviteStateProvider.notifier)
            .createInvite(maxUses: maxUses);
        if (invite == null) {
          final err = container.read(inviteStateProvider).error;
          throw StateError(err ?? 'Failed to create invite');
        }

        final inviteUrl = await container
            .read(inviteStateProvider.notifier)
            .getInviteUrl(invite.id);
        if (inviteUrl == null || inviteUrl.isEmpty) {
          final err = container.read(inviteStateProvider).error;
          throw StateError(err ?? 'Failed to build invite url');
        }

        await ok({'inviteId': invite.id, 'inviteUrl': inviteUrl});
        return;

      case 'ensure_default_invite_published':
        await container
            .read(inviteStateProvider.notifier)
            .ensurePublishedPublicInvite();
        await ok({});
        return;

      case 'accept_invite':
        final inviteUrl = payload['inviteUrl']?.toString() ?? '';
        if (inviteUrl.isEmpty) {
          throw ArgumentError('accept_invite requires inviteUrl');
        }

        final sessionId = await container
            .read(inviteStateProvider.notifier)
            .acceptInviteFromUrl(inviteUrl);
        if (sessionId == null || sessionId.isEmpty) {
          final err = container.read(inviteStateProvider).error;
          throw StateError(err ?? 'Failed to accept invite');
        }

        await ok({'sessionId': sessionId});
        return;

      case 'create_link_invite':
        await _disposePendingLinkInvite();
        final nostrService = container.read(nostrServiceProvider);
        await nostrService.connect();

        final keypair = await NdrFfi.generateKeypair();
        final invite = await NdrFfi.createInvite(
          inviterPubkeyHex: keypair.publicKeyHex,
          deviceId: keypair.publicKeyHex,
          maxUses: 1,
        );
        await invite.setPurpose('link');
        final inviteUrl = await invite.toUrl('https://iris.to');

        final data = decodeInviteUrlData(inviteUrl);
        final eph =
            (data?['ephemeralKey'] ?? data?['inviterEphemeralPublicKey'])
                as String?;
        if (eph == null || eph.isEmpty) {
          await invite.dispose();
          throw StateError('Invite URL missing ephemeral key');
        }

        _pendingLinkInvite = _PendingLinkInvite(
          invite: invite,
          devicePrivkeyHex: keypair.privateKeyHex,
          ephemeralPubkeyHex: eph,
        );

        await ok({'inviteUrl': inviteUrl, 'ephemeralPubkeyHex': eph});
        return;

      case 'wait_for_linked_device':
        final pending = _pendingLinkInvite;
        if (pending == null) {
          throw StateError(
            'No pending link invite. Call create_link_invite first.',
          );
        }

        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final timeout = Duration(milliseconds: timeoutMs);

        final nostrService = container.read(nostrServiceProvider);
        final subid = 'interop-link-${DateTime.now().microsecondsSinceEpoch}';
        final completer = Completer<NostrEvent>();

        final sub = nostrService.events.listen((event) {
          if (completer.isCompleted) return;
          if (event.subscriptionId != subid) return;
          if (event.kind != 1059) return;
          completer.complete(event);
        });

        InviteResponseResult? response;
        try {
          nostrService.subscribeWithId(
            subid,
            NostrFilter(
              kinds: const [1059],
              pTags: [pending.ephemeralPubkeyHex],
            ),
          );

          final event = await completer.future.timeout(timeout);
          response = await pending.invite.processResponse(
            eventJson: jsonEncode(event.toJson()),
            inviterPrivkeyHex: pending.devicePrivkeyHex,
          );
          if (response == null) {
            throw StateError('Failed to process link invite response');
          }

          final ownerPubkeyHex =
              (response.ownerPubkeyHex ?? response.inviteePubkeyHex)
                  .toLowerCase();
          final sessionState = await response.session.stateJson();
          final remoteDeviceId = response.inviteePubkeyHex;

          await container
              .read(authStateProvider.notifier)
              .loginLinkedDevice(
                ownerPubkeyHex: ownerPubkeyHex,
                devicePrivkeyHex: pending.devicePrivkeyHex,
              );
          await container
              .read(sessionManagerServiceProvider)
              .importSessionState(
                peerPubkeyHex: ownerPubkeyHex,
                stateJson: sessionState,
                deviceId: remoteDeviceId,
              );

          await _runAppBootstrap(container);

          final authState = container.read(authStateProvider);
          if (!authState.isAuthenticated || authState.pubkeyHex == null) {
            throw StateError(authState.error ?? 'Linked-device login failed');
          }

          await ok({
            'ownerPubkeyHex': ownerPubkeyHex,
            'pubkeyHex': authState.pubkeyHex,
            'devicePubkeyHex': authState.devicePubkeyHex,
          });
          return;
        } finally {
          nostrService.closeSubscription(subid);
          await sub.cancel();
          try {
            await response?.session.dispose();
          } catch (_) {}
          await _disposePendingLinkInvite();
        }

      case 'accept_link_invite':
        final inviteUrl = payload['inviteUrl']?.toString() ?? '';
        if (inviteUrl.isEmpty) {
          throw ArgumentError('accept_link_invite requires inviteUrl');
        }
        final linked = await container
            .read(inviteStateProvider.notifier)
            .acceptLinkInviteFromUrl(inviteUrl);
        if (!linked) {
          final err = container.read(inviteStateProvider).error;
          throw StateError(err ?? 'Failed to accept link invite');
        }

        await ok({});
        return;

      case 'wait_for_session':
        final recipientPubkeyHex =
            payload['recipientPubkeyHex']?.toString() ?? '';
        if (recipientPubkeyHex.isEmpty) {
          throw ArgumentError('wait_for_session requires recipientPubkeyHex');
        }

        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final end = DateTime.now().add(Duration(milliseconds: timeoutMs));

        while (DateTime.now().isBefore(end)) {
          final sessionId = await _findSessionIdByRecipient(
            container,
            recipientPubkeyHex,
          );
          if (sessionId != null && sessionId.isNotEmpty) {
            await ok({'sessionId': sessionId});
            return;
          }
          await Future.delayed(const Duration(milliseconds: 80));
        }

        throw TimeoutException(
          'Timed out waiting for session',
          Duration(milliseconds: timeoutMs),
        );

      case 'ensure_session_for_recipient':
        final recipientPubkeyHex =
            payload['recipientPubkeyHex']?.toString() ?? '';
        if (recipientPubkeyHex.isEmpty) {
          throw ArgumentError(
            'ensure_session_for_recipient requires recipientPubkeyHex',
          );
        }

        final inviteSessionId = await container
            .read(inviteStateProvider.notifier)
            .acceptPublicInviteForPubkey(recipientPubkeyHex);
        if (inviteSessionId != null && inviteSessionId.isNotEmpty) {
          await ok({
            'sessionId': inviteSessionId,
            'acceptedViaPublicInvite': true,
          });
          return;
        }

        final session = await container
            .read(sessionStateProvider.notifier)
            .ensureSessionForRecipient(recipientPubkeyHex);
        await ok({'sessionId': session.id, 'acceptedViaPublicInvite': false});
        return;

      case 'get_connection_status':
        final nostrService = container.read(nostrServiceProvider);
        await ok({
          'connectedCount': nostrService.connectedCount,
          'connectionStatus': nostrService.connectionStatus,
        });
        return;

      case 'get_debug_state':
        final authState = container.read(authStateProvider);
        final sessions = container.read(sessionStateProvider).sessions;
        final messagesBySession = container.read(chatStateProvider).messages;
        final sessionManager = container.read(sessionManagerServiceProvider);
        final totalNativeSessions = await sessionManager.getTotalSessions();
        final nostrDebug = container.read(nostrServiceProvider).debugSnapshot();
        final sessionManagerDebug = sessionManager.debugSnapshot();

        await ok({
          'auth': {
            'isAuthenticated': authState.isAuthenticated,
            'ownerPubkeyHex': authState.pubkeyHex,
            'devicePubkeyHex': authState.devicePubkeyHex,
          },
          'totalNativeSessions': totalNativeSessions,
          'nostr': nostrDebug,
          'sessionManager': sessionManagerDebug,
          'sessions': [
            for (final session in sessions)
              {
                'id': session.id,
                'recipientPubkeyHex': session.recipientPubkeyHex,
                'createdAt': session.createdAt.toIso8601String(),
                'isInitiator': session.isInitiator,
              },
          ],
          'messages': {
            for (final entry in messagesBySession.entries)
              entry.key: [
                for (final message in entry.value)
                  {
                    'id': message.id,
                    'text': message.text,
                    'isIncoming': message.isIncoming,
                    'status': message.status.name,
                    'eventId': message.eventId,
                    'rumorId': message.rumorId,
                  },
              ],
          },
        });
        return;

      case 'wait_for_connected_relays':
        final minConnectedRaw = payload['minConnected'];
        final minConnected = minConnectedRaw is num
            ? minConnectedRaw.toInt()
            : 1;
        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final end = DateTime.now().add(Duration(milliseconds: timeoutMs));
        final nostrService = container.read(nostrServiceProvider);

        while (DateTime.now().isBefore(end)) {
          final connectedCount = nostrService.connectedCount;
          if (connectedCount >= minConnected) {
            await ok({
              'connectedCount': connectedCount,
              'connectionStatus': nostrService.connectionStatus,
            });
            return;
          }
          await Future.delayed(const Duration(milliseconds: 100));
        }

        throw TimeoutException(
          'Timed out waiting for connected relays >= $minConnected',
          Duration(milliseconds: timeoutMs),
        );

      case 'send_message':
        final sessionId = payload['sessionId']?.toString() ?? '';
        final text = payload['text']?.toString() ?? '';
        if (sessionId.isEmpty || text.isEmpty) {
          throw ArgumentError('send_message requires sessionId and text');
        }

        await container
            .read(chatStateProvider.notifier)
            .sendMessage(sessionId, text);
        await ok({});
        return;

      case 'send_message_ui':
        final sessionId = payload['sessionId']?.toString() ?? '';
        final text = payload['text']?.toString() ?? '';
        if (sessionId.isEmpty || text.isEmpty) {
          throw ArgumentError('send_message_ui requires sessionId and text');
        }
        await _sendMessageInUi(
          tester,
          container,
          sessionId: sessionId,
          text: text,
        );
        await ok({});
        return;

      case 'send_typing':
        final sessionId = payload['sessionId']?.toString() ?? '';
        if (sessionId.isEmpty) {
          throw ArgumentError('send_typing requires sessionId');
        }
        await container
            .read(chatStateProvider.notifier)
            .notifyTyping(sessionId);
        await ok({});
        return;

      case 'send_typing_stopped':
        final sessionId = payload['sessionId']?.toString() ?? '';
        if (sessionId.isEmpty) {
          throw ArgumentError('send_typing_stopped requires sessionId');
        }
        await container
            .read(chatStateProvider.notifier)
            .notifyTypingStopped(sessionId);
        await ok({});
        return;

      case 'wait_for_message':
        final text = payload['text']?.toString() ?? '';
        if (text.isEmpty) {
          throw ArgumentError('wait_for_message requires text');
        }

        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final incomingOnly = payload['incomingOnly'] == true;

        final received = await _waitForMessageText(
          container,
          text: text,
          timeout: Duration(milliseconds: timeoutMs),
          incomingOnly: incomingOnly,
        );

        if (!received) {
          throw TimeoutException(
            'Timed out waiting for message text\n${jsonEncode(_debugStateForTimeout(container))}',
            Duration(milliseconds: timeoutMs),
          );
        }

        await ok({'text': text});
        return;

      case 'wait_for_message_ui':
        final sessionId = payload['sessionId']?.toString() ?? '';
        final text = payload['text']?.toString() ?? '';
        if (sessionId.isEmpty || text.isEmpty) {
          throw ArgumentError(
            'wait_for_message_ui requires sessionId and text',
          );
        }

        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final incomingOnly = payload['incomingOnly'] == true;

        final visible = await _waitForMessageInUi(
          tester,
          container,
          sessionId: sessionId,
          text: text,
          timeout: Duration(milliseconds: timeoutMs),
          incomingOnly: incomingOnly,
        );
        if (!visible) {
          throw TimeoutException(
            'Timed out waiting for message in chat UI',
            Duration(milliseconds: timeoutMs),
          );
        }

        await ok({'sessionId': sessionId, 'text': text});
        return;

      case 'wait_for_message_meta':
        final text = payload['text']?.toString() ?? '';
        if (text.isEmpty) {
          throw ArgumentError('wait_for_message_meta requires text');
        }

        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final incomingOnly = payload['incomingOnly'] == true;

        final match = await _waitForMessageMatch(
          container,
          text: text,
          timeout: Duration(milliseconds: timeoutMs),
          incomingOnly: incomingOnly,
        );

        if (match == null) {
          throw TimeoutException(
            'Timed out waiting for message text\n${jsonEncode(_debugStateForTimeout(container))}',
            Duration(milliseconds: timeoutMs),
          );
        }

        await ok({
          'sessionId': match.sessionId,
          'messageId': match.messageId,
          'text': match.text,
          'rumorId': match.rumorId,
          'eventId': match.eventId,
        });
        return;

      case 'wait_for_typing':
        final sessionId = payload['sessionId']?.toString() ?? '';
        if (sessionId.isEmpty) {
          throw ArgumentError('wait_for_typing requires sessionId');
        }
        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final expectedTyping = payload['isTyping'] != false;

        final reached = await _waitForTypingState(
          container,
          sessionId: sessionId,
          expectedTyping: expectedTyping,
          timeout: Duration(milliseconds: timeoutMs),
        );

        if (!reached) {
          throw TimeoutException(
            'Timed out waiting for typing state',
            Duration(milliseconds: timeoutMs),
          );
        }

        await ok({'sessionId': sessionId, 'isTyping': expectedTyping});
        return;

      case 'send_reaction':
        final sessionId = payload['sessionId']?.toString() ?? '';
        final messageId = payload['messageId']?.toString() ?? '';
        final emoji = payload['emoji']?.toString() ?? '';
        if (sessionId.isEmpty || messageId.isEmpty || emoji.isEmpty) {
          throw ArgumentError(
            'send_reaction requires sessionId, messageId, and emoji',
          );
        }

        final myPubkey = container.read(authStateProvider).pubkeyHex;
        if (myPubkey == null || myPubkey.isEmpty) {
          throw StateError('No authenticated pubkey');
        }

        await container
            .read(chatStateProvider.notifier)
            .sendReaction(sessionId, messageId, emoji, myPubkey);
        await ok({});
        return;

      case 'create_group':
        final name = payload['name']?.toString().trim() ?? '';
        if (name.isEmpty) {
          throw ArgumentError('create_group requires name');
        }

        final memberPubkeysRaw = payload['memberPubkeysHex'];
        final memberPubkeys = <String>[];
        if (memberPubkeysRaw is List) {
          for (final value in memberPubkeysRaw) {
            final pubkey = value.toString().trim().toLowerCase();
            if (pubkey.isEmpty) continue;
            memberPubkeys.add(pubkey);
          }
        }

        final groupId = await container
            .read(groupStateProvider.notifier)
            .createGroup(name: name, memberPubkeysHex: memberPubkeys);

        if (groupId == null || groupId.isEmpty) {
          final err = container.read(groupStateProvider).error;
          throw StateError(err ?? 'Failed to create group');
        }

        await ok({'groupId': groupId});
        return;

      case 'wait_for_group':
        final groupId = payload['groupId']?.toString() ?? '';
        if (groupId.isEmpty) {
          throw ArgumentError('wait_for_group requires groupId');
        }

        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final found = await _waitForGroup(
          container,
          groupId: groupId,
          timeout: Duration(milliseconds: timeoutMs),
        );
        if (!found) {
          throw TimeoutException(
            'Timed out waiting for group',
            Duration(milliseconds: timeoutMs),
          );
        }
        await ok({'groupId': groupId});
        return;

      case 'wait_for_group_named':
        final name = payload['name']?.toString() ?? '';
        if (name.trim().isEmpty) {
          throw ArgumentError('wait_for_group_named requires name');
        }

        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final matchedGroupId = await _waitForGroupNamed(
          container,
          name: name,
          timeout: Duration(milliseconds: timeoutMs),
        );
        if (matchedGroupId == null || matchedGroupId.isEmpty) {
          throw TimeoutException(
            'Timed out waiting for group name',
            Duration(milliseconds: timeoutMs),
          );
        }
        await ok({'groupId': matchedGroupId, 'name': name});
        return;

      case 'accept_group':
        final groupId = payload['groupId']?.toString() ?? '';
        if (groupId.isEmpty) {
          throw ArgumentError('accept_group requires groupId');
        }
        await container
            .read(groupStateProvider.notifier)
            .acceptGroupInvitation(groupId);
        await ok({'groupId': groupId});
        return;

      case 'send_group_message':
        final groupId = payload['groupId']?.toString() ?? '';
        final text = payload['text']?.toString() ?? '';
        if (groupId.isEmpty || text.isEmpty) {
          throw ArgumentError('send_group_message requires groupId and text');
        }
        await container
            .read(groupStateProvider.notifier)
            .sendGroupMessage(groupId, text);
        await ok({'groupId': groupId});
        return;

      case 'wait_for_group_message':
        final groupId = payload['groupId']?.toString() ?? '';
        final text = payload['text']?.toString() ?? '';
        if (groupId.isEmpty || text.isEmpty) {
          throw ArgumentError(
            'wait_for_group_message requires groupId and text',
          );
        }

        final timeoutMsRaw = payload['timeoutMs'];
        final timeoutMs = timeoutMsRaw is num ? timeoutMsRaw.toInt() : 30000;
        final incomingOnly = payload['incomingOnly'] == true;

        final received = await _waitForGroupMessageText(
          container,
          groupId: groupId,
          text: text,
          timeout: Duration(milliseconds: timeoutMs),
          incomingOnly: incomingOnly,
        );
        if (!received) {
          throw TimeoutException(
            'Timed out waiting for group message text',
            Duration(milliseconds: timeoutMs),
          );
        }

        await ok({'groupId': groupId, 'text': text});
        return;

      case 'shutdown':
        await ok({});
        throw const _ShutdownSignal();

      default:
        throw ArgumentError('Unknown command type: $type');
    }
  } on _ShutdownSignal {
    rethrow;
  } catch (e) {
    await fail(e);
  }
}

Future<void> _runBridgeLoop({
  required WidgetTester tester,
  required ProviderContainer container,
  required File commandsFile,
  required File eventsFile,
}) async {
  var offset = 0;

  while (true) {
    final content = await commandsFile.readAsString();
    if (content.length > offset) {
      final chunk = content.substring(offset);
      offset = content.length;
      final lines = const LineSplitter().convert(chunk);

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        Map<String, dynamic> command;
        try {
          command = jsonDecode(trimmed) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        try {
          await _handleCommand(
            tester: tester,
            container: container,
            eventsFile: eventsFile,
            command: command,
          );
        } on _ShutdownSignal {
          return;
        }
      }
    }

    await Future.delayed(const Duration(milliseconds: 50));
  }
}

class _ShutdownSignal implements Exception {
  const _ShutdownSignal();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('flutter interop bridge', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());

    if (!Platform.isMacOS) {
      return;
    }

    const relayUrl = String.fromEnvironment('IRIS_INTEROP_RELAY_URL');
    const relayUrlsRaw = String.fromEnvironment('IRIS_INTEROP_RELAY_URLS');
    const bridgeDirPath = String.fromEnvironment('IRIS_INTEROP_BRIDGE_DIR');
    const dataDirPath = String.fromEnvironment('IRIS_INTEROP_DATA_DIR');
    const privateKeyNsec = String.fromEnvironment(
      'IRIS_INTEROP_PRIVATE_KEY_NSEC',
    );
    const registerDeviceFlag = String.fromEnvironment(
      'IRIS_INTEROP_REGISTER_DEVICE',
    );
    const registerDeviceOnLogin = registerDeviceFlag == '1';

    final relayUrls = relayUrlsRaw
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList(growable: false);
    final effectiveRelayUrls = relayUrls.isNotEmpty
        ? relayUrls
        : (relayUrl.isNotEmpty ? <String>[relayUrl] : const <String>[]);

    expect(
      effectiveRelayUrls,
      isNotEmpty,
      reason: 'IRIS_INTEROP_RELAY_URL or IRIS_INTEROP_RELAY_URLS is required',
    );
    expect(
      bridgeDirPath,
      isNotEmpty,
      reason: 'IRIS_INTEROP_BRIDGE_DIR is required',
    );

    final bridgeDir = Directory(bridgeDirPath);
    await bridgeDir.create(recursive: true);

    final commandsFile = File('${bridgeDir.path}/commands.jsonl');
    final eventsFile = File('${bridgeDir.path}/events.jsonl');

    await commandsFile.create(recursive: true);
    await eventsFile.writeAsString('', flush: true);

    final hasDataDirOverride = dataDirPath.trim().isNotEmpty;
    final rootDir = hasDataDirOverride
        ? await Directory(dataDirPath).create(recursive: true)
        : await Directory.systemTemp.createTemp('iris-chat-interop-');
    final interopLoginStateFile = File(
      '${rootDir.path}/interop_login_state.json',
    );
    final secureStorage = _createInMemorySecureStorage();

    final container = _makeContainer(
      relayUrls: effectiveRelayUrls,
      dbPath: '${rootDir.path}/db.sqlite',
      ndrPath: '${rootDir.path}/ndr',
      secureStorage: secureStorage,
    );

    try {
      await container.read(nostrServiceProvider).connect();

      if (privateKeyNsec.trim().isNotEmpty) {
        if (registerDeviceOnLogin) {
          final persistedDevicePrivkeyHex =
              await _readPersistedInteropDevicePrivkey(interopLoginStateFile);
          if (persistedDevicePrivkeyHex != null) {
            await container
                .read(authStateProvider.notifier)
                .login(
                  privateKeyNsec,
                  devicePrivkeyHex: persistedDevicePrivkeyHex,
                );
          } else {
            final registrationService = container.read(
              loginDeviceRegistrationServiceProvider,
            );
            final preview = await registrationService
                .buildPreviewFromPrivateKeyNsec(privateKeyNsec);

            await container
                .read(authStateProvider.notifier)
                .login(
                  privateKeyNsec,
                  devicePrivkeyHex: preview.currentDevicePrivkeyHex,
                );

            await registrationService.publishDeviceList(
              ownerPubkeyHex: preview.ownerPubkeyHex,
              ownerPrivkeyHex: preview.ownerPrivkeyHex,
              devices: preview.devicesIfRegistered,
            );
            await _writePersistedInteropDevicePrivkey(
              interopLoginStateFile,
              preview.currentDevicePrivkeyHex,
            );
          }
        } else {
          await container
              .read(authStateProvider.notifier)
              .login(privateKeyNsec);
        }
      } else {
        await container.read(authStateProvider.notifier).createIdentity();
      }

      final authState = container.read(authStateProvider);
      expect(
        authState.isAuthenticated,
        isTrue,
        reason: authState.error ?? 'Bridge auth failed',
      );
      await _runAppBootstrap(container);

      final authStateSnapshot = container.read(authStateProvider);
      final pubkeyHex = authStateSnapshot.pubkeyHex;
      final devicePubkeyHex = authStateSnapshot.devicePubkeyHex;
      await _emitEvent(eventsFile, {
        'type': 'ready',
        'data': {
          'pubkeyHex': pubkeyHex,
          'devicePubkeyHex': devicePubkeyHex,
          'relayUrl': effectiveRelayUrls.first,
          'relayUrls': effectiveRelayUrls,
        },
      });

      await _runBridgeLoop(
        tester: tester,
        container: container,
        commandsFile: commandsFile,
        eventsFile: eventsFile,
      );
    } finally {
      await _disposePendingLinkInvite();
      try {
        await container.read(sessionManagerServiceProvider).dispose();
      } catch (_) {}
      try {
        await container.read(nostrServiceProvider).dispose();
      } catch (_) {}
      try {
        await container.read(databaseServiceProvider).close();
      } catch (_) {}
      container.dispose();

      if (!hasDataDirOverride) {
        try {
          await rootDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
