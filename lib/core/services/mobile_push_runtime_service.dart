import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'logger_service.dart';

const _mobilePushDefaultTitle = 'Iris Chat';
const _mobilePushDefaultBody = 'New activity';
const _androidChannel = AndroidNotificationChannel(
  'iris_chat_messages',
  'Chat Messages',
  description: 'Incoming push notifications for Iris Chat conversations.',
  importance: Importance.high,
);

final FlutterLocalNotificationsPlugin _mobilePushNotificationsPlugin =
    FlutterLocalNotificationsPlugin();
const MethodChannel _iosMobilePushChannel = MethodChannel('to.iris/mobile_push');
final StreamController<MobilePushNotificationContent>
_mobilePushReceivedNotificationsController =
    StreamController<MobilePushNotificationContent>.broadcast();
bool _mobilePushNotificationsInitialized = false;
bool _mobilePushBackgroundHandlerRegistered = false;
bool _mobilePushForegroundMessageListenerRegistered = false;
bool _mobilePushIosBridgeRegistered = false;

Stream<MobilePushNotificationContent> get mobilePushReceivedNotifications =>
    _mobilePushReceivedNotificationsController.stream;

class MobilePushNotificationContent {
  const MobilePushNotificationContent({
    required this.title,
    required this.body,
    required this.payloadData,
  });

  final String title;
  final String body;
  final Map<String, String> payloadData;

  static MobilePushNotificationContent? fromData(Map<String, dynamic> data) {
    if (data.isEmpty) return null;

    final payloadData = <String, String>{};
    data.forEach((key, value) {
      if (value == null) return;
      payloadData[key] = value.toString();
    });
    if (payloadData.isEmpty) return null;

    final title =
        _normalizedValue(payloadData['title']) ?? _mobilePushDefaultTitle;
    final body =
        _normalizedValue(payloadData['body']) ?? _mobilePushDefaultBody;

    return MobilePushNotificationContent(
      title: title,
      body: body,
      payloadData: payloadData,
    );
  }

  static String? _normalizedValue(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }
}

void registerMobilePushBackgroundHandler() {
  if (_mobilePushBackgroundHandlerRegistered || kIsWeb) return;
  if (!Platform.isAndroid) return;
  FirebaseMessaging.onBackgroundMessage(mobilePushBackgroundMessageHandler);
  _mobilePushBackgroundHandlerRegistered = true;
}

Future<void> initializeMobilePushRuntime() async {
  if (kIsWeb) return;
  if (!Platform.isAndroid && !Platform.isIOS) return;

  await _ensureFirebaseReady();
  await _ensureLocalNotificationsReady();
  _ensureForegroundMessageListenerRegistered();
  await _ensureIosRemoteNotificationBridgeRegistered();

  if (Platform.isIOS) {
    try {
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
    } catch (error, stackTrace) {
      Logger.warning(
        'Failed to configure iOS foreground notification presentation',
        category: LogCategory.auth,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

Future<void> _ensureFirebaseReady() async {
  if (Firebase.apps.isNotEmpty) return;
  await Firebase.initializeApp();
}

Future<void> _ensureLocalNotificationsReady() async {
  if (_mobilePushNotificationsInitialized) return;

  const initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );

  await _mobilePushNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: _handleNotificationResponse,
    onDidReceiveBackgroundNotificationResponse:
        mobilePushBackgroundNotificationTapHandler,
  );

  await _mobilePushNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(_androidChannel);

  _mobilePushNotificationsInitialized = true;
}

void _ensureForegroundMessageListenerRegistered() {
  if (_mobilePushForegroundMessageListenerRegistered) return;

  FirebaseMessaging.onMessage.listen((message) async {
    final content = MobilePushNotificationContent.fromData(message.data);
    if (content != null && !Platform.isAndroid) {
      _mobilePushReceivedNotificationsController.add(content);
    }

    if (Platform.isAndroid) {
      await showLocalNotificationForRemoteMessage(message);
    }
  });

  _mobilePushForegroundMessageListenerRegistered = true;
}

Future<void> _ensureIosRemoteNotificationBridgeRegistered() async {
  if (kIsWeb || !Platform.isIOS || _mobilePushIosBridgeRegistered) return;

  _iosMobilePushChannel.setMethodCallHandler((call) async {
    if (call.method != 'remoteNotification') {
      return;
    }
    _emitIosRemoteNotificationPayload(call.arguments);
  });
  _mobilePushIosBridgeRegistered = true;

  try {
    final pendingNotifications =
        await _iosMobilePushChannel.invokeMethod<List<dynamic>>('setDartReady') ??
        const <dynamic>[];
    for (final notification in pendingNotifications) {
      _emitIosRemoteNotificationPayload(notification);
    }
  } catch (error, stackTrace) {
    Logger.warning(
      'Failed to initialize iOS remote notification bridge',
      category: LogCategory.message,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

void _emitIosRemoteNotificationPayload(Object? rawPayload) {
  if (rawPayload is! Map) return;

  final payload = <String, dynamic>{};
  rawPayload.forEach((key, value) {
    if (key == null) return;
    payload[key.toString()] = value;
  });

  final content = MobilePushNotificationContent.fromData(payload);
  if (content == null) return;
  _mobilePushReceivedNotificationsController.add(content);
}

void _handleNotificationResponse(NotificationResponse response) {}

@pragma('vm:entry-point')
void mobilePushBackgroundNotificationTapHandler(
  NotificationResponse response,
) {}

@pragma('vm:entry-point')
Future<void> mobilePushBackgroundMessageHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _ensureFirebaseReady();
  await _ensureLocalNotificationsReady();
  await showLocalNotificationForRemoteMessage(message);
}

Future<void> showLocalNotificationForRemoteMessage(
  RemoteMessage message,
) async {
  if (kIsWeb || !Platform.isAndroid) return;

  final content = MobilePushNotificationContent.fromData(message.data);
  if (content == null) return;
  _mobilePushReceivedNotificationsController.add(content);

  try {
    await _mobilePushNotificationsPlugin.show(
      _notificationIdForContent(content),
      content.title,
      content.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: jsonEncode(content.payloadData),
    );
  } catch (error, stackTrace) {
    Logger.warning(
      'Failed to show Android local notification for push payload',
      category: LogCategory.message,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

int _notificationIdForContent(MobilePushNotificationContent content) {
  final eventId = content.payloadData['event'];
  if (eventId != null && eventId.isNotEmpty) {
    return eventId.hashCode;
  }
  return jsonEncode(content.payloadData).hashCode;
}
