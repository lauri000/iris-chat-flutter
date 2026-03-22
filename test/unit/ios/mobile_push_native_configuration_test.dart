import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS mobile push configuration', () {
    test('bundle id and Firebase config align with the live APNS topic', () {
      final projectFile = File('ios/Runner.xcodeproj/project.pbxproj');
      final plistFile = File('ios/Runner/GoogleService-Info.plist');

      expect(projectFile.existsSync(), isTrue);
      expect(plistFile.existsSync(), isTrue);

      final projectContent = projectFile.readAsStringSync();
      final plistContent = plistFile.readAsStringSync();

      expect(projectContent, contains('PRODUCT_BUNDLE_IDENTIFIER = to.iris;'));
      expect(plistContent, contains('<key>BUNDLE_ID</key>'));
      expect(plistContent, contains('<string>to.iris</string>'));
      expect(projectContent, contains('GoogleService-Info.plist'));
    });

    test('app target enables push entitlements and remote registration', () {
      final entitlementsFile = File('ios/Runner/Runner.entitlements');
      final appDelegateFile = File('ios/Runner/AppDelegate.swift');
      final sceneDelegateFile = File('ios/Runner/SceneDelegate.swift');
      final infoPlistFile = File('ios/Runner/Info.plist');
      final projectFile = File('ios/Runner.xcodeproj/project.pbxproj');

      expect(entitlementsFile.existsSync(), isTrue);
      expect(appDelegateFile.existsSync(), isTrue);
      expect(sceneDelegateFile.existsSync(), isTrue);
      expect(infoPlistFile.existsSync(), isTrue);
      expect(projectFile.existsSync(), isTrue);

      final entitlementsContent = entitlementsFile.readAsStringSync();
      final appDelegateContent = appDelegateFile.readAsStringSync();
      final sceneDelegateContent = sceneDelegateFile.readAsStringSync();
      final infoPlistContent = infoPlistFile.readAsStringSync();
      final projectContent = projectFile.readAsStringSync();

      expect(entitlementsContent, contains('<key>aps-environment</key>'));
      expect(
        projectContent,
        contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'),
      );
      expect(
        appDelegateContent,
        contains('UNUserNotificationCenter.current().delegate = self'),
      );
      expect(
        appDelegateContent,
        contains('application.registerForRemoteNotifications()'),
      );
      expect(sceneDelegateContent, contains('class SceneDelegate'));
      expect(projectContent, contains('SceneDelegate.swift in Sources'));
      expect(
        infoPlistContent,
        contains('<key>UIApplicationSceneManifest</key>'),
      );
      expect(
        infoPlistContent,
        contains(r'<string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>'),
      );
      expect(infoPlistContent, contains('<key>UIBackgroundModes</key>'));
      expect(
        infoPlistContent,
        contains('<string>remote-notification</string>'),
      );
    });
  });
}
