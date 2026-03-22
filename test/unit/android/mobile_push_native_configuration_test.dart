import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android mobile push configuration', () {
    test('Gradle enables Firebase services for the Flutter app id', () {
      final appBuildFile = File('android/app/build.gradle');
      final settingsFile = File('android/settings.gradle');

      expect(appBuildFile.existsSync(), isTrue);
      expect(settingsFile.existsSync(), isTrue);

      final appBuildContent = appBuildFile.readAsStringSync();
      final settingsContent = settingsFile.readAsStringSync();

      expect(settingsContent, contains('id "com.google.gms.google-services"'));
      expect(appBuildContent, contains('id "com.google.gms.google-services"'));
      expect(appBuildContent, contains('applicationId = "to.iris.chat"'));
    });

    test(
      'main Android manifest keeps release networking and notification permissions',
      () {
        final manifestFile = File('android/app/src/main/AndroidManifest.xml');
        expect(manifestFile.existsSync(), isTrue);

        final content = manifestFile.readAsStringSync();
        expect(content, contains('android.permission.INTERNET'));
        expect(content, contains('android.permission.POST_NOTIFICATIONS'));
      },
    );

    test('google-services.json includes the Flutter Android client', () {
      final configFile = File('android/app/google-services.json');
      expect(configFile.existsSync(), isTrue);

      final decoded =
          jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
      final clients = (decoded['client'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      final matchingClient = clients.cast<Map<String, dynamic>?>().firstWhere(
        (client) =>
            client?['client_info']?['android_client_info']?['package_name'] ==
            'to.iris.chat',
        orElse: () => null,
      );

      expect(matchingClient, isNotNull);
    });
  });
}
