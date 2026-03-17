import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/services/nostr_service.dart';
import 'package:iris_chat/core/utils/app_keys_event_fetch.dart';
import 'package:mocktail/mocktail.dart';

class MockNostrService extends Mock implements NostrService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockNostrService mockNostrService;
  late StreamController<NostrEvent> controller;
  late List<String> resolvedEventJsons;
  const channel = MethodChannel('to.iris.chat/ndr_ffi');

  setUpAll(() {
    registerFallbackValue(const NostrFilter());
  });

  setUp(() {
    mockNostrService = MockNostrService();
    controller = StreamController<NostrEvent>.broadcast();
    resolvedEventJsons = <String>[];

    when(() => mockNostrService.events).thenAnswer((_) => controller.stream);
    when(() => mockNostrService.closeSubscription(any())).thenAnswer((_) {});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method != 'resolveLatestAppKeysDevices') {
            return null;
          }

          final args = Map<dynamic, dynamic>.from(
            methodCall.arguments as Map<dynamic, dynamic>,
          );
          resolvedEventJsons = (args['eventJsons'] as List<dynamic>)
              .map((entry) => entry.toString())
              .toList();

          return <Map<String, Object?>>[
            {
              'identityPubkeyHex':
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'createdAt': 1700000000,
            },
            {
              'identityPubkeyHex':
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              'createdAt': 1700000001,
            },
          ];
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await controller.close();
  });

  test('fetchAppKeysEvents collects matching AppKeys events only', () async {
    when(() => mockNostrService.subscribeWithId(any(), any())).thenAnswer((
      invocation,
    ) {
      final subid = invocation.positionalArguments[0] as String;

      Future<void>.microtask(() {
        controller.add(
          _appKeysEvent(
            id: 'wrong-owner',
            pubkey:
                'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
            createdAt: 1700000001,
            subscriptionId: subid,
          ),
        );
        controller.add(
          _plainEvent(
            id: 'wrong-kind',
            pubkey:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            createdAt: 1700000002,
            kind: 1,
            subscriptionId: subid,
          ),
        );
        controller.add(
          _appKeysEvent(
            id: 'first-event',
            pubkey:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            createdAt: 1700000003,
            subscriptionId: subid,
          ),
        );
        controller.add(
          _appKeysEvent(
            id: 'second-event',
            pubkey:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            createdAt: 1700000004,
            subscriptionId: subid,
            devicePubkeys: const [
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ],
          ),
        );
      });

      return subid;
    });

    final events = await fetchAppKeysEvents(
      mockNostrService,
      ownerPubkeyHex:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      timeout: const Duration(milliseconds: 20),
      subscriptionLabel: 'test-appkeys',
    );

    expect(events.map((event) => event.id), ['first-event', 'second-event']);
  });

  test('fetchLatestAppKeysDevices delegates event convergence to FFI', () async {
    when(() => mockNostrService.subscribeWithId(any(), any())).thenAnswer((
      invocation,
    ) {
      final subid = invocation.positionalArguments[0] as String;

      Future<void>.microtask(() {
        controller.add(
          _appKeysEvent(
            id: 'first-event',
            pubkey:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            createdAt: 1700000000,
            subscriptionId: subid,
          ),
        );
        controller.add(
          _appKeysEvent(
            id: 'second-event',
            pubkey:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            createdAt: 1700000001,
            subscriptionId: subid,
            devicePubkeys: const [
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ],
          ),
        );
      });

      return subid;
    });

    final devices = await fetchLatestAppKeysDevices(
      mockNostrService,
      ownerPubkeyHex:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      timeout: const Duration(milliseconds: 20),
      subscriptionLabel: 'test-appkeys',
    );

    expect(devices, hasLength(2));
    expect(resolvedEventJsons, hasLength(2));
    expect(
      (jsonDecode(resolvedEventJsons.first) as Map<String, dynamic>)['id'],
      'first-event',
    );
    expect(
      (jsonDecode(resolvedEventJsons.last) as Map<String, dynamic>)['id'],
      'second-event',
    );
  });
}

NostrEvent _appKeysEvent({
  required String id,
  required String pubkey,
  required int createdAt,
  required String subscriptionId,
  List<String> devicePubkeys = const [
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ],
}) {
  return _plainEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: 30078,
    tags: [
      const ['d', 'double-ratchet/app-keys'],
      const ['version', '1'],
      ...devicePubkeys.map((pubkey) => ['device', pubkey, '$createdAt']),
    ],
    subscriptionId: subscriptionId,
  );
}

NostrEvent _plainEvent({
  required String id,
  required String pubkey,
  required int createdAt,
  required int kind,
  required String subscriptionId,
  List<List<String>> tags = const [],
}) {
  return NostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: kind,
    tags: tags,
    content: '',
    sig: 'sig',
    subscriptionId: subscriptionId,
  );
}
