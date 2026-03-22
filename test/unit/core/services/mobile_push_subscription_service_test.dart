import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iris_chat/core/services/mobile_push_subscription_service.dart';
import 'package:iris_chat/features/auth/domain/models/identity.dart';
import 'package:iris_chat/features/auth/domain/repositories/auth_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this.privateKeyHex);

  final String? privateKeyHex;

  @override
  Future<Identity> createIdentity() {
    throw UnimplementedError();
  }

  @override
  Future<String?> getDevicePubkeyHex() {
    throw UnimplementedError();
  }

  @override
  Future<Identity?> getCurrentIdentity() {
    throw UnimplementedError();
  }

  @override
  Future<String?> getPrivateKey() async => privateKeyHex;

  @override
  Future<String?> getOwnerPrivateKey() async => null;

  @override
  Future<bool> hasIdentity() {
    throw UnimplementedError();
  }

  @override
  Future<Identity> login(String privkeyHex, {String? devicePrivkeyHex}) {
    throw UnimplementedError();
  }

  @override
  Future<Identity> loginLinkedDevice({
    required String ownerPubkeyHex,
    required String devicePrivkeyHex,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> logout() {
    throw UnimplementedError();
  }
}

class _FakeMobilePushTokenProvider implements MobilePushTokenProvider {
  _FakeMobilePushTokenProvider({
    required this.supported,
    required this.platformKey,
    this.token,
  });

  @override
  final bool supported;

  @override
  final String platformKey;

  final MobilePushToken? token;

  @override
  Future<MobilePushToken?> requestToken() async => token;
}

void main() {
  const privateKey =
      '1111111111111111111111111111111111111111111111111111111111111111';
  const ownerPubkey =
      '2222222222222222222222222222222222222222222222222222222222222222';
  const messageAuthorPubkey =
      '3333333333333333333333333333333333333333333333333333333333333333';
  const fcmToken = 'fcm-token-123';
  const apnsToken = 'apns-token-123';
  const apiBase = 'https://notifications.iris.to';

  TestWidgetsFlutterBinding.ensureInitialized();

  group('MobilePushSubscriptionServiceImpl', () {
    test('uses sandbox notification server for non-release mobile builds', () {
      expect(
        resolveMobilePushServerUrl(platformKey: 'ios', isReleaseMode: false),
        'https://notifications-sandbox.iris.to',
      );
      expect(
        resolveMobilePushServerUrl(
          platformKey: 'android',
          isReleaseMode: false,
        ),
        'https://notifications-sandbox.iris.to',
      );
      expect(
        resolveMobilePushServerUrl(platformKey: 'ios', isReleaseMode: true),
        apiBase,
      );
    });

    test('uses provisional notification authorization on debug iOS only', () {
      expect(
        shouldUseProvisionalMobilePushAuthorization(
          platformKey: 'ios',
          isReleaseMode: false,
        ),
        isTrue,
      );
      expect(
        shouldUseProvisionalMobilePushAuthorization(
          platformKey: 'ios',
          isReleaseMode: true,
        ),
        isFalse,
      );
      expect(
        shouldUseProvisionalMobilePushAuthorization(
          platformKey: 'android',
          isReleaseMode: false,
        ),
        isFalse,
      );
    });

    test(
      'creates subscription with NIP-98 auth when enabling on Android',
      () async {
        SharedPreferences.setMockInitialValues({});
        late Map<String, dynamic> postedBody;
        late String postAuthHeader;
        var getCalls = 0;
        var postCalls = 0;

        final client = MockClient((request) async {
          if (request.method == 'GET' && request.url.path == '/subscriptions') {
            getCalls += 1;
            return http.Response('{}', 200);
          }
          if (request.method == 'POST' &&
              request.url.path == '/subscriptions') {
            postCalls += 1;
            postedBody = jsonDecode(request.body) as Map<String, dynamic>;
            postAuthHeader = request.headers['authorization'] ?? '';
            return http.Response('{"id":"sub-1"}', 201);
          }
          return http.Response('not found', 404);
        });

        final service = MobilePushSubscriptionServiceImpl(
          authRepository: _FakeAuthRepository(privateKey),
          tokenProvider: _FakeMobilePushTokenProvider(
            supported: true,
            platformKey: 'android',
            token: const MobilePushToken(fcmToken: fcmToken),
          ),
          httpClient: client,
          preferencesFactory: SharedPreferences.getInstance,
          serverBaseUri: Uri.parse(apiBase),
        );

        await service.sync(
          enabled: true,
          ownerPubkeyHex: ownerPubkey,
          messageAuthorPubkeysHex: const [messageAuthorPubkey],
        );

        expect(getCalls, 1);
        expect(postCalls, 1);
        expect(postedBody['webhooks'], isEmpty);
        expect(postedBody['web_push_subscriptions'], isEmpty);
        expect(postedBody['fcm_tokens'], [fcmToken]);
        expect(postedBody['apns_tokens'], isEmpty);
        expect(postedBody['filter']['kinds'], [1060]);
        expect(postedBody['filter']['authors'], [messageAuthorPubkey]);

        expect(postAuthHeader.startsWith('Nostr '), isTrue);
        final authEventJson = utf8.decode(
          base64Decode(postAuthHeader.substring('Nostr '.length)),
        );
        final authEvent = jsonDecode(authEventJson) as Map<String, dynamic>;
        expect(authEvent['kind'], 27235);
        expect(authEvent['content'], '');
        final tags = (authEvent['tags'] as List<dynamic>)
            .map((e) => (e as List<dynamic>).cast<String>())
            .toList();
        expect(
          tags.any(
            (tag) => tag.length == 2 && tag[0] == 'method' && tag[1] == 'POST',
          ),
          isTrue,
        );
        expect(
          tags.any(
            (tag) =>
                tag.length == 2 &&
                tag[0] == 'u' &&
                tag[1] == '$apiBase/subscriptions',
          ),
          isTrue,
        );

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('settings.mobile_push_subscription_id.android'),
          'sub-1',
        );
      },
    );

    test('updates existing stored subscription on enable', () async {
      SharedPreferences.setMockInitialValues({
        'settings.mobile_push_subscription_id.android': 'sub-1',
      });

      var updateCalls = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/subscriptions') {
          return http.Response(
            '{"sub-1":{"filter":{"kinds":[1060],"authors":["$messageAuthorPubkey"]},"fcm_tokens":["$fcmToken"],"apns_tokens":[]}}',
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/subscriptions/sub-1') {
          updateCalls += 1;
          return http.Response('{"status":"Updated"}', 200);
        }
        return http.Response('not found', 404);
      });

      final service = MobilePushSubscriptionServiceImpl(
        authRepository: _FakeAuthRepository(privateKey),
        tokenProvider: _FakeMobilePushTokenProvider(
          supported: true,
          platformKey: 'android',
          token: const MobilePushToken(fcmToken: fcmToken),
        ),
        httpClient: client,
        preferencesFactory: SharedPreferences.getInstance,
        serverBaseUri: Uri.parse(apiBase),
      );

      await service.sync(
        enabled: true,
        ownerPubkeyHex: ownerPubkey,
        messageAuthorPubkeysHex: const [messageAuthorPubkey],
      );
      expect(updateCalls, 1);
    });

    test('deletes stored subscription when disabling', () async {
      SharedPreferences.setMockInitialValues({
        'settings.mobile_push_subscription_id.android': 'sub-1',
      });

      var deleteCalls = 0;
      final client = MockClient((request) async {
        if (request.method == 'DELETE' &&
            request.url.path == '/subscriptions/sub-1') {
          deleteCalls += 1;
          return http.Response('', 204);
        }
        return http.Response('not found', 404);
      });

      final service = MobilePushSubscriptionServiceImpl(
        authRepository: _FakeAuthRepository(privateKey),
        tokenProvider: _FakeMobilePushTokenProvider(
          supported: true,
          platformKey: 'android',
        ),
        httpClient: client,
        preferencesFactory: SharedPreferences.getInstance,
        serverBaseUri: Uri.parse(apiBase),
      );

      await service.sync(enabled: false, ownerPubkeyHex: ownerPubkey);
      expect(deleteCalls, 1);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('settings.mobile_push_subscription_id.android'),
        isNull,
      );
    });

    test('does not call API when token is unavailable', () async {
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      final client = MockClient((request) async {
        calls += 1;
        return http.Response('unexpected', 500);
      });

      final service = MobilePushSubscriptionServiceImpl(
        authRepository: _FakeAuthRepository(privateKey),
        tokenProvider: _FakeMobilePushTokenProvider(
          supported: true,
          platformKey: 'android',
          token: null,
        ),
        httpClient: client,
        preferencesFactory: SharedPreferences.getInstance,
        serverBaseUri: Uri.parse(apiBase),
      );

      await service.sync(
        enabled: true,
        ownerPubkeyHex: ownerPubkey,
        messageAuthorPubkeysHex: const [messageAuthorPubkey],
      );
      expect(calls, 0);
    });

    test('creates subscription with APNS token only on iOS', () async {
      SharedPreferences.setMockInitialValues({});
      late Map<String, dynamic> postedBody;

      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/subscriptions') {
          return http.Response('{}', 200);
        }
        if (request.method == 'POST' && request.url.path == '/subscriptions') {
          postedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{"id":"sub-ios"}', 201);
        }
        return http.Response('not found', 404);
      });

      final service = MobilePushSubscriptionServiceImpl(
        authRepository: _FakeAuthRepository(privateKey),
        tokenProvider: _FakeMobilePushTokenProvider(
          supported: true,
          platformKey: 'ios',
          token: const MobilePushToken(
            fcmToken: fcmToken,
            apnsToken: apnsToken,
          ),
        ),
        httpClient: client,
        preferencesFactory: SharedPreferences.getInstance,
        serverBaseUri: Uri.parse(apiBase),
      );

      await service.sync(
        enabled: true,
        ownerPubkeyHex: ownerPubkey,
        messageAuthorPubkeysHex: const [messageAuthorPubkey],
      );

      expect(postedBody['fcm_tokens'], isEmpty);
      expect(postedBody['apns_tokens'], [apnsToken]);
      expect(postedBody['filter']['authors'], [messageAuthorPubkey]);
    });
  });
}
