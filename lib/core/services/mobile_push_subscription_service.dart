import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/domain/repositories/auth_repository.dart';
import 'logger_service.dart';

const _notificationServerUrlOverride = String.fromEnvironment(
  'IRIS_NOTIFICATION_SERVER_URL',
);
const _productionNotificationServerUrl = 'https://notifications.iris.to';
const _sandboxNotificationServerUrl = 'https://notifications-sandbox.iris.to';

String resolveMobilePushServerUrl({
  required String platformKey,
  required bool isReleaseMode,
  String overrideValue = _notificationServerUrlOverride,
}) {
  final trimmedOverride = overrideValue.trim();
  if (trimmedOverride.isNotEmpty) {
    return trimmedOverride;
  }
  if (!isReleaseMode && (platformKey == 'ios' || platformKey == 'android')) {
    return _sandboxNotificationServerUrl;
  }
  return _productionNotificationServerUrl;
}

bool shouldUseProvisionalMobilePushAuthorization({
  required String platformKey,
  required bool isReleaseMode,
}) {
  return platformKey == 'ios' && !isReleaseMode;
}

class MobilePushToken {
  const MobilePushToken({this.fcmToken, this.apnsToken});

  final String? fcmToken;
  final String? apnsToken;

  bool get isEmpty =>
      (fcmToken == null || fcmToken!.isEmpty) &&
      (apnsToken == null || apnsToken!.isEmpty);
}

abstract class MobilePushTokenProvider {
  bool get supported;
  String get platformKey;
  Future<MobilePushToken?> requestToken();
}

class FirebaseMobilePushTokenProvider implements MobilePushTokenProvider {
  FirebaseMobilePushTokenProvider({FirebaseMessaging? messaging})
    : _messaging = messaging;

  final FirebaseMessaging? _messaging;
  bool _firebaseReady = false;

  @override
  bool get supported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  @override
  String get platformKey {
    if (kIsWeb) return 'unsupported';
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'unsupported';
  }

  @override
  Future<MobilePushToken?> requestToken() async {
    if (!supported) return null;

    try {
      await _ensureFirebaseReady();
      final settings = await _messagingInstance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: shouldUseProvisionalMobilePushAuthorization(
          platformKey: platformKey,
          isReleaseMode: kReleaseMode,
        ),
      );
      final status = settings.authorizationStatus;
      if (status == AuthorizationStatus.denied ||
          status == AuthorizationStatus.notDetermined) {
        return null;
      }

      if (!kIsWeb && Platform.isIOS) {
        final apns = await _requestApnsToken();
        if (apns == null) return null;
        return MobilePushToken(apnsToken: apns);
      }

      final fcm = _cleanToken(await _messagingInstance.getToken());
      if (fcm == null) return null;
      return MobilePushToken(fcmToken: fcm);
    } catch (error, stackTrace) {
      Logger.warning(
        'Failed to fetch mobile push token',
        category: LogCategory.auth,
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> _ensureFirebaseReady() async {
    if (_firebaseReady) return;
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    _firebaseReady = true;
  }

  FirebaseMessaging get _messagingInstance {
    return _messaging ?? FirebaseMessaging.instance;
  }

  Future<String?> _requestApnsToken() async {
    // Trigger native APNS registration before polling the bridged token.
    await _messagingInstance.getToken();
    for (var attempt = 0; attempt < 5; attempt++) {
      final apns = _cleanToken(await _messagingInstance.getAPNSToken());
      if (apns != null) return apns;
      await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
    return null;
  }

  String? _cleanToken(String? token) {
    if (token == null) return null;
    final trimmed = token.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }
}

abstract class MobilePushSubscriptionService {
  bool get isSupported;

  Future<void> sync({
    required bool enabled,
    required String? ownerPubkeyHex,
    List<String> messageAuthorPubkeysHex = const <String>[],
  });
}

class MobilePushSubscriptionServiceImpl
    implements MobilePushSubscriptionService {
  MobilePushSubscriptionServiceImpl({
    required AuthRepository authRepository,
    required MobilePushTokenProvider tokenProvider,
    http.Client? httpClient,
    Future<SharedPreferences> Function()? preferencesFactory,
    Uri? serverBaseUri,
    int dmEventKind = 1060,
  }) : _authRepository = authRepository,
       _tokenProvider = tokenProvider,
       _httpClient = httpClient ?? http.Client(),
       _preferencesFactory =
           preferencesFactory ?? SharedPreferences.getInstance,
       _serverBaseUri =
           serverBaseUri ??
           Uri.parse(
             resolveMobilePushServerUrl(
               platformKey: tokenProvider.platformKey,
               isReleaseMode: kReleaseMode,
             ),
           ),
       _dmEventKind = dmEventKind;

  final AuthRepository _authRepository;
  final MobilePushTokenProvider _tokenProvider;
  final http.Client _httpClient;
  final Future<SharedPreferences> Function() _preferencesFactory;
  final Uri _serverBaseUri;
  final int _dmEventKind;

  @override
  bool get isSupported => _tokenProvider.supported;

  @override
  Future<void> sync({
    required bool enabled,
    required String? ownerPubkeyHex,
    List<String> messageAuthorPubkeysHex = const <String>[],
  }) async {
    if (!isSupported) return;

    final owner = _normalizeHex(ownerPubkeyHex);
    final messageAuthors = _normalizeHexList(messageAuthorPubkeysHex);
    final privkey = (await _authRepository.getPrivateKey())?.trim();

    if (!enabled ||
        owner == null ||
        privkey == null ||
        privkey.isEmpty ||
        messageAuthors.isEmpty) {
      await _disable(privkey: privkey);
      return;
    }

    final token = await _tokenProvider.requestToken();
    if (token == null || token.isEmpty) return;

    final privateKey = privkey;
    final subscriptions = await _fetchSubscriptions(privateKey);
    final existingId = await _resolveExistingSubscriptionId(
      subscriptions: subscriptions,
      token: token,
    );

    final payload = _buildPayload(
      messageAuthorPubkeysHex: messageAuthors,
      token: token,
    );
    final targetId = existingId;
    if (targetId != null) {
      final update = await _authedRequest(
        method: 'POST',
        path: '/subscriptions/$targetId',
        privkeyHex: privateKey,
        body: payload,
      );
      if (_isSuccess(update.statusCode)) {
        await _saveStoredSubscriptionId(targetId);
        return;
      }

      if (update.statusCode != 404) {
        Logger.warning(
          'Failed to update mobile push subscription',
          category: LogCategory.nostr,
          data: {'status': update.statusCode},
        );
        return;
      }
      await _clearStoredSubscriptionId();
    }

    final create = await _authedRequest(
      method: 'POST',
      path: '/subscriptions',
      privkeyHex: privateKey,
      body: payload,
    );
    if (!_isSuccess(create.statusCode)) {
      Logger.warning(
        'Failed to create mobile push subscription',
        category: LogCategory.nostr,
        data: {'status': create.statusCode},
      );
      return;
    }

    final createdId = _extractSubscriptionId(create.body);
    if (createdId != null) {
      await _saveStoredSubscriptionId(createdId);
    }
  }

  Future<void> _disable({required String? privkey}) async {
    final storedId = await _loadStoredSubscriptionId();
    if (storedId == null || storedId.isEmpty) return;

    if (privkey == null || privkey.isEmpty) {
      await _clearStoredSubscriptionId();
      return;
    }

    final response = await _authedRequest(
      method: 'DELETE',
      path: '/subscriptions/$storedId',
      privkeyHex: privkey,
    );
    if (_isSuccess(response.statusCode) || response.statusCode == 404) {
      await _clearStoredSubscriptionId();
      return;
    }

    Logger.warning(
      'Failed to delete mobile push subscription',
      category: LogCategory.nostr,
      data: {'status': response.statusCode},
    );
  }

  Future<Map<String, dynamic>> _fetchSubscriptions(String privkeyHex) async {
    final response = await _authedRequest(
      method: 'GET',
      path: '/subscriptions',
      privkeyHex: privkeyHex,
    );
    if (!_isSuccess(response.statusCode) || response.body.trim().isEmpty) {
      return <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<String?> _resolveExistingSubscriptionId({
    required Map<String, dynamic> subscriptions,
    required MobilePushToken token,
  }) async {
    final stored = await _loadStoredSubscriptionId();
    if (stored != null && subscriptions.containsKey(stored)) {
      return stored;
    }

    for (final entry in subscriptions.entries) {
      if (entry.value is! Map<String, dynamic>) continue;
      final subscription = entry.value as Map<String, dynamic>;
      if (_subscriptionContainsToken(subscription, token)) {
        return entry.key;
      }
    }
    return null;
  }

  bool _subscriptionContainsToken(
    Map<String, dynamic> subscription,
    MobilePushToken token,
  ) {
    bool containsToken(Object? rawList, String? value) {
      if (value == null || value.isEmpty || rawList is! List<dynamic>) {
        return false;
      }
      return rawList.any((v) => v is String && v.trim() == value);
    }

    return containsToken(subscription['fcm_tokens'], token.fcmToken) ||
        containsToken(subscription['apns_tokens'], token.apnsToken);
  }

  Map<String, dynamic> _buildPayload({
    required List<String> messageAuthorPubkeysHex,
    required MobilePushToken token,
  }) {
    final usesFcm = _tokenProvider.platformKey == 'android';
    final usesApns = _tokenProvider.platformKey == 'ios';
    final fcmToken = usesFcm ? token.fcmToken : null;
    final apnsToken = usesApns ? token.apnsToken : null;

    return <String, dynamic>{
      'webhooks': const <String>[],
      'web_push_subscriptions': const <Object>[],
      'fcm_tokens': fcmToken == null ? const <String>[] : <String>[fcmToken],
      'apns_tokens': apnsToken == null ? const <String>[] : <String>[apnsToken],
      'filter': <String, dynamic>{
        'kinds': <int>[_dmEventKind],
        'authors': messageAuthorPubkeysHex,
      },
    };
  }

  Future<http.Response> _authedRequest({
    required String method,
    required String path,
    required String privkeyHex,
    Map<String, dynamic>? body,
  }) async {
    final uri = _resolveUri(path);
    final headers = <String, String>{
      'accept': 'application/json',
      'authorization': _buildAuthHeader(
        privkeyHex: privkeyHex,
        method: method,
        uri: uri,
      ),
    };
    if (body != null) {
      headers['content-type'] = 'application/json';
    }

    final request = http.Request(method.toUpperCase(), uri);
    request.headers.addAll(headers);
    if (body != null) {
      request.body = jsonEncode(body);
    }

    final response = await _httpClient.send(request);
    return http.Response.fromStream(response);
  }

  String _buildAuthHeader({
    required String privkeyHex,
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
      privkey: privkeyHex,
      verify: false,
    );
    final encoded = base64Encode(utf8.encode(jsonEncode(event.toJson())));
    return 'Nostr $encoded';
  }

  Uri _resolveUri(String path) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    var basePath = _serverBaseUri.path;
    if (basePath.endsWith('/')) {
      basePath = basePath.substring(0, basePath.length - 1);
    }
    if (basePath == '/') basePath = '';
    return _serverBaseUri.replace(path: '$basePath$normalizedPath');
  }

  bool _isSuccess(int statusCode) => statusCode >= 200 && statusCode < 300;

  String? _extractSubscriptionId(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final id = decoded['id'];
        if (id is String && id.trim().isNotEmpty) {
          return id.trim();
        }
      }
    } catch (_) {}
    return null;
  }

  String? _normalizeHex(String? value) {
    if (value == null) return null;
    final normalized = value.trim().toLowerCase();
    if (normalized.length != 64) return null;
    final isHex = RegExp(r'^[0-9a-f]+$').hasMatch(normalized);
    if (!isHex) return null;
    return normalized;
  }

  List<String> _normalizeHexList(Iterable<String> values) {
    final normalized = <String>{};
    for (final value in values) {
      final hex = _normalizeHex(value);
      if (hex != null) {
        normalized.add(hex);
      }
    }
    return normalized.toList(growable: false);
  }

  String get _storedSubscriptionIdKey =>
      'settings.mobile_push_subscription_id.${_tokenProvider.platformKey}';

  Future<String?> _loadStoredSubscriptionId() async {
    final prefs = await _preferencesFactory();
    final id = prefs.getString(_storedSubscriptionIdKey);
    if (id == null || id.trim().isEmpty) return null;
    return id.trim();
  }

  Future<void> _saveStoredSubscriptionId(String id) async {
    final prefs = await _preferencesFactory();
    await prefs.setString(_storedSubscriptionIdKey, id);
  }

  Future<void> _clearStoredSubscriptionId() async {
    final prefs = await _preferencesFactory();
    await prefs.remove(_storedSubscriptionIdKey);
  }
}
