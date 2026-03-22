import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/services/mobile_push_runtime_service.dart';

void main() {
  group('MobilePushNotificationContent', () {
    test('builds notification content from push data payload', () {
      final content = MobilePushNotificationContent.fromData(const {
        'title': 'DM by Alice',
        'body': 'New message',
        'event': '{"id":"abc"}',
        'url': 'https://iris.to/abc',
      });

      expect(content, isNotNull);
      expect(content!.title, 'DM by Alice');
      expect(content.body, 'New message');
      expect(content.payloadData['event'], '{"id":"abc"}');
      expect(content.payloadData['url'], 'https://iris.to/abc');
    });

    test('falls back to app defaults when push data omits title and body', () {
      final content = MobilePushNotificationContent.fromData(const {
        'event': '{"id":"abc"}',
      });

      expect(content, isNotNull);
      expect(content!.title, 'Iris Chat');
      expect(content.body, 'New activity');
    });

    test('returns null for an empty payload', () {
      expect(MobilePushNotificationContent.fromData(const {}), isNull);
    });
  });
}
