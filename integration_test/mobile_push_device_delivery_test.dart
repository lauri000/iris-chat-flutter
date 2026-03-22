import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:iris_chat/config/providers/app_bootstrap_provider.dart';
import 'package:iris_chat/config/providers/auth_provider.dart';
import 'package:iris_chat/config/providers/chat_provider.dart';
import 'package:iris_chat/config/providers/invite_provider.dart';
import 'package:iris_chat/config/providers/login_device_registration_provider.dart';
import 'package:iris_chat/config/providers/mobile_push_provider.dart';
import 'package:iris_chat/config/providers/nostr_provider.dart';
import 'package:iris_chat/core/services/database_service.dart';
import 'package:iris_chat/core/services/mobile_push_runtime_service.dart';
import 'package:iris_chat/core/services/mobile_push_subscription_service.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/services/secure_storage_service.dart';
import 'package:iris_chat/core/services/session_manager_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nostr/nostr.dart' as nostr;

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

const _testRelayUrls = <String>['wss://temp.iris.to'];

void _debugLog(String message) {
  // ignore: avoid_print
  print('[mobile-push-test] $message');
}

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

  when(storage.deleteAll).thenAnswer((_) async => store.clear());

  return SecureStorageService(storage);
}

ProviderContainer _makeEphemeralContainer({
  required String dbPath,
  required String ndrPath,
  required SecureStorageService secureStorage,
  required List<String> relayUrls,
}) {
  return ProviderContainer(
    overrides: [
      secureStorageProvider.overrideWithValue(secureStorage),
      databaseServiceProvider.overrideWithValue(
        DatabaseService(dbPath: dbPath),
      ),
      nostrServiceProvider.overrideWith((ref) {
        final service = NostrService(relayUrls: relayUrls);
        unawaited(service.connect());
        ref.onDispose(() {
          unawaited(service.dispose());
        });
        return service;
      }),
      sessionManagerServiceProvider.overrideWith((ref) {
        final nostrService = ref.watch(nostrServiceProvider);
        final authRepository = ref.watch(authRepositoryProvider);
        final messageDatasource = ref.watch(messageDatasourceProvider);

        final service = SessionManagerService(
          nostrService,
          authRepository,
          storagePathOverride: ndrPath,
          hasProcessedMessageEventId: messageDatasource.messageExists,
        );
        unawaited(service.start());
        ref.onDispose(() {
          unawaited(service.dispose());
        });
        return service;
      }),
    ],
  );
}

Future<void> _waitForCondition(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  Duration delay = const Duration(milliseconds: 250),
  String? debugLabel,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) {
      return;
    }
    await Future<void>.delayed(delay);
  }
  throw StateError('Timed out waiting for ${debugLabel ?? 'condition'}');
}

Future<void> _publishCurrentDeviceForIdentity(
  ProviderContainer container,
) async {
  final authState = container.read(authStateProvider);
  final ownerPubkeyHex = authState.pubkeyHex;
  if (ownerPubkeyHex == null || ownerPubkeyHex.isEmpty) return;

  final ownerPrivkeyHex = await container
      .read(authRepositoryProvider)
      .getOwnerPrivateKey();
  if (ownerPrivkeyHex == null || ownerPrivkeyHex.isEmpty) return;

  await container
      .read(loginDeviceRegistrationServiceProvider)
      .publishSingleDevice(
        ownerPubkeyHex: ownerPubkeyHex,
        ownerPrivkeyHex: ownerPrivkeyHex,
        devicePubkeyHex: ownerPubkeyHex,
      );
}

Future<void> _waitForRelayConnection(ProviderContainer container) async {
  container.read(nostrServiceProvider);
  await _waitForCondition(
    () async {
      final snapshot = container.read(nostrServiceProvider).debugSnapshot();
      final connectedCount = snapshot['connectedCount'];
      return connectedCount is int && connectedCount > 0;
    },
    timeout: const Duration(seconds: 20),
    debugLabel: 'relay connection',
  );
}

Future<void> _bootstrapApp(ProviderContainer container) async {
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
  final repairTargets = sessionBootstrapTargets(
    sessionRecipientPubkeysHex: container
        .read(sessionStateProvider)
        .sessions
        .map((session) => session.recipientPubkeyHex),
    ownerPubkeyHex: sessionManager.ownerPubkeyHex,
  );
  await sessionManager.refreshSubscription();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  await sessionManager.repairRecentlyActiveLinkedDeviceRecords(repairTargets);
  container.read(messageSubscriptionProvider);
  await container
      .read(inviteStateProvider.notifier)
      .ensurePublishedPublicInvite();
}

String _mobilePlatformKey() {
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  throw UnsupportedError('Mobile push device test only supports Android/iOS');
}

String _buildNostrAuthHeader({
  required String privateKeyHex,
  required String method,
  required Uri uri,
}) {
  final event = nostr.Event.from(
    kind: 27235,
    tags: <List<String>>[
      <String>['u', uri.toString()],
      <String>['method', method.toUpperCase()],
    ],
    content: '',
    privkey: privateKeyHex,
    verify: false,
  );
  final encoded = base64Encode(utf8.encode(jsonEncode(event.toJson())));
  return 'Nostr $encoded';
}

Future<Map<String, dynamic>> _fetchSubscriptions({
  required String privateKeyHex,
  required Uri serverBaseUri,
}) async {
  final uri = serverBaseUri.replace(path: '/subscriptions');
  final response = await http.get(
    uri,
    headers: <String, String>{
      'accept': 'application/json',
      'authorization': _buildNostrAuthHeader(
        privateKeyHex: privateKeyHex,
        method: 'GET',
        uri: uri,
      ),
    },
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError(
      'Failed to fetch subscriptions: ${response.statusCode} ${response.body}',
    );
  }
  if (response.body.trim().isEmpty) {
    return <String, dynamic>{};
  }
  final decoded = jsonDecode(response.body);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  throw StateError('Unexpected subscriptions payload: ${response.body}');
}

String? _findMatchingSubscriptionId({
  required Map<String, dynamic> subscriptions,
  required List<String> expectedMessageAuthorPubkeysHex,
  required String platformKey,
}) {
  final tokenField = platformKey == 'android' ? 'fcm_tokens' : 'apns_tokens';
  for (final entry in subscriptions.entries) {
    if (entry.value is! Map<String, dynamic>) continue;
    final subscription = entry.value as Map<String, dynamic>;
    final filter = subscription['filter'];
    final tokens = subscription[tokenField];
    if (filter is! Map<String, dynamic> || tokens is! List<dynamic>) continue;
    final authors = filter['authors'];
    final kinds = filter['kinds'];
    final hasExpectedAuthor =
        authors is List<dynamic> &&
        expectedMessageAuthorPubkeysHex.any(authors.contains);
    final hasDmKind =
        kinds is List<dynamic> && kinds.any((kind) => kind == 1060);
    final hasToken = tokens.any((token) => token is String && token.isNotEmpty);
    if (hasExpectedAuthor && hasDmKind && hasToken) {
      return entry.key;
    }
  }
  return null;
}

Future<List<String>> _messageAuthorPubkeysForContainer(
  ProviderContainer container,
) async {
  final authors = <String>{};
  final sessionManager = container.read(sessionManagerServiceProvider);
  for (final session in container.read(sessionStateProvider).sessions) {
    authors.addAll(
      await sessionManager.getMessagePushAuthorPubkeys(
        session.recipientPubkeyHex,
      ),
    );
  }
  return authors.toList(growable: false);
}

String? _extractEventIdFromPayloadJson(String payload) {
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      final id = decoded['id'];
      if (id is String && id.isNotEmpty) {
        return id;
      }
    }
  } catch (_) {}
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('receives a real mobile push notification for a live DM send', (
    tester,
  ) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }

    await initializeMobilePushRuntime();

    final recipientRootDir = await Directory.systemTemp.createTemp(
      'iris-chat-push-recipient-',
    );
    final recipientContainer = _makeEphemeralContainer(
      dbPath: '${recipientRootDir.path}/db.sqlite',
      ndrPath: '${recipientRootDir.path}/ndr',
      secureStorage: _createInMemorySecureStorage(),
      relayUrls: _testRelayUrls,
    );
    addTearDown(() async {
      recipientContainer.dispose();
      if (recipientRootDir.existsSync()) {
        recipientRootDir.deleteSync(recursive: true);
      }
    });

    final authNotifier = recipientContainer.read(authStateProvider.notifier);
    await authNotifier.createIdentity();
    await _waitForRelayConnection(recipientContainer);
    await _publishCurrentDeviceForIdentity(recipientContainer);
    await _bootstrapApp(recipientContainer);

    final recipientPubkeyHex = recipientContainer
        .read(authStateProvider)
        .pubkeyHex;
    expect(recipientPubkeyHex, isNotNull);
    final recipientPrivateKeyHex = await recipientContainer
        .read(authRepositoryProvider)
        .getPrivateKey();
    expect(recipientPrivateKeyHex, isNotNull);

    final senderRootDir = await Directory.systemTemp.createTemp(
      'iris-chat-push-sender-',
    );
    final senderContainer = _makeEphemeralContainer(
      dbPath: '${senderRootDir.path}/db.sqlite',
      ndrPath: '${senderRootDir.path}/ndr',
      secureStorage: _createInMemorySecureStorage(),
      relayUrls: _testRelayUrls,
    );
    addTearDown(() async {
      senderContainer.dispose();
      if (senderRootDir.existsSync()) {
        senderRootDir.deleteSync(recursive: true);
      }
    });

    await senderContainer.read(authStateProvider.notifier).createIdentity();
    await _waitForRelayConnection(senderContainer);
    await _publishCurrentDeviceForIdentity(senderContainer);
    await _bootstrapApp(senderContainer);

    final invite = await recipientContainer
        .read(inviteStateProvider.notifier)
        .createInvite(maxUses: 1);
    expect(invite, isNotNull);

    final inviteUrl = await recipientContainer
        .read(inviteStateProvider.notifier)
        .getInviteUrl(invite!.id);
    expect(inviteUrl, isNotNull);
    final resolvedInviteUrl = inviteUrl!;
    _debugLog('created invite ${invite.id}');

    final senderSessionId = await senderContainer
        .read(inviteStateProvider.notifier)
        .acceptInviteFromUrl(resolvedInviteUrl);
    expect(senderSessionId, isNotNull);
    _debugLog('sender accepted invite into session $senderSessionId');

    await _bootstrapApp(senderContainer);
    await _bootstrapApp(recipientContainer);
    await Future<void>.delayed(const Duration(seconds: 4));

    final recipientMessageAuthors = await _messageAuthorPubkeysForContainer(
      recipientContainer,
    );
    expect(recipientMessageAuthors, isNotEmpty);

    final subscriptionService = recipientContainer.read(
      mobilePushSubscriptionServiceProvider,
    );
    await subscriptionService.sync(
      enabled: true,
      ownerPubkeyHex: recipientPubkeyHex,
      messageAuthorPubkeysHex: recipientMessageAuthors,
    );
    _debugLog(
      'synced mobile push subscription for ${recipientPubkeyHex!} authors=${jsonEncode(recipientMessageAuthors)}',
    );

    final serverBaseUri = Uri.parse(
      resolveMobilePushServerUrl(
        platformKey: _mobilePlatformKey(),
        isReleaseMode: false,
      ),
    );
    _debugLog('using notification server $serverBaseUri');

    String? subscriptionId;
    Map<String, dynamic>? matchedSubscription;
    await _waitForCondition(
      () async {
        final subscriptions = await _fetchSubscriptions(
          privateKeyHex: recipientPrivateKeyHex!,
          serverBaseUri: serverBaseUri,
        );
        subscriptionId = _findMatchingSubscriptionId(
          subscriptions: subscriptions,
          expectedMessageAuthorPubkeysHex: recipientMessageAuthors,
          platformKey: _mobilePlatformKey(),
        );
        if (subscriptionId != null) {
          matchedSubscription =
              subscriptions[subscriptionId] as Map<String, dynamic>?;
        }
        return subscriptionId != null;
      },
      timeout: const Duration(seconds: 45),
      debugLabel: 'mobile push sync',
    );
    _debugLog(
      'subscription $subscriptionId ${jsonEncode(matchedSubscription ?? <String, dynamic>{})}',
    );

    final pushReceived = Completer<MobilePushNotificationContent>();
    var expectedOuterEventIds = const <String>[];
    final receivedByEventId = <String, MobilePushNotificationContent>{};
    final pushSub = mobilePushReceivedNotifications.listen((content) {
      _debugLog(
        'received push title=${content.title} body=${content.body} payload=${jsonEncode(content.payloadData)}',
      );
      final payload = content.payloadData['event'];
      final eventId = payload == null
          ? null
          : _extractEventIdFromPayloadJson(payload);
      if (eventId == null) return;
      receivedByEventId[eventId] = content;
      if (!expectedOuterEventIds.contains(eventId)) return;
      if (!pushReceived.isCompleted) {
        pushReceived.complete(content);
      }
    });
    addTearDown(pushSub.cancel);

    final messageText =
        'push-device-e2e-${DateTime.now().millisecondsSinceEpoch}';
    final sendResult = await senderContainer
        .read(sessionManagerServiceProvider)
        .sendTextWithInnerId(
          recipientPubkeyHex: recipientPubkeyHex,
          text: messageText,
        );
    expectedOuterEventIds = List<String>.from(sendResult.outerEventIds);
    _debugLog(
      'sent message "$messageText" outerEventIds=${jsonEncode(expectedOuterEventIds)}',
    );
    for (final eventId in expectedOuterEventIds) {
      final content = receivedByEventId[eventId];
      if (content != null && !pushReceived.isCompleted) {
        pushReceived.complete(content);
      }
    }

    final receivedNotification = await pushReceived.future.timeout(
      const Duration(seconds: 90),
    );

    final payload = receivedNotification.payloadData['event'];
    expect(payload, isNotNull);
    final eventId = _extractEventIdFromPayloadJson(payload!);
    expect(sendResult.outerEventIds, contains(eventId));
    expect(receivedNotification.body, 'New message');
  });
}
