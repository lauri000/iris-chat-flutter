import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('macOS startup launch configuration', () {
    test('MainFlutterWindow wires launch_at_startup method channel', () {
      final mainWindowFile = File('macos/Runner/MainFlutterWindow.swift');
      expect(mainWindowFile.existsSync(), isTrue);

      final content = mainWindowFile.readAsStringSync();
      expect(content, contains('import LaunchAtLogin'));
      expect(content, contains('name: "launch_at_startup"'));
      expect(content, contains('launchAtStartupIsEnabled'));
      expect(content, contains('launchAtStartupSetEnabled'));
    });

    test('Xcode project includes LaunchAtLogin package and helper script', () {
      final projectFile = File('macos/Runner.xcodeproj/project.pbxproj');
      expect(projectFile.existsSync(), isTrue);

      final content = projectFile.readAsStringSync();
      expect(
        content,
        contains('https://github.com/sindresorhus/LaunchAtLogin'),
      );
      expect(content, contains('LaunchAtLogin in Frameworks'));
      expect(content, contains('Copy "Launch at Login Helper"'));
      expect(content, contains('copy-helper-swiftpm.sh'));
    });

    test('AppDelegate minimizes login-item launches', () {
      final appDelegateFile = File('macos/Runner/AppDelegate.swift');
      expect(appDelegateFile.existsSync(), isTrue);

      final content = appDelegateFile.readAsStringSync();
      expect(content, contains('import LaunchAtLogin'));
      expect(content, contains('static var wasLaunchedAtLogin'));
      expect(content, contains('keyAELaunchedAsLogInItem'));
      expect(
        content,
        contains('let launchedAtLogin = LaunchAtLogin.wasLaunchedAtLogin'),
      );
      expect(content, contains('miniaturize(nil)'));
      expect(content, contains('activateExistingInstanceIfNeeded'));
      expect(
        content,
        contains('runningApplications(withBundleIdentifier: bundleIdentifier)'),
      );
      expect(
        content,
        contains(
          'activate(options: [.activateAllWindows, .activateIgnoringOtherApps])',
        ),
      );
      expect(content, contains('NSApp.terminate(nil)'));
      expect(
        content,
        isNot(contains('super.applicationDidFinishLaunching(notification)')),
        reason:
            'FlutterAppDelegate on macOS does not implement '
            'applicationDidFinishLaunching:, so calling super crashes on app '
            'startup before Flutter bootstrap can run.',
      );
    });

    test('Info.plist prohibits multiple macOS instances', () {
      final infoPlistFile = File('macos/Runner/Info.plist');
      expect(infoPlistFile.existsSync(), isTrue);

      final content = infoPlistFile.readAsStringSync();
      expect(content, contains('<key>LSMultipleInstancesProhibited</key>'));
      expect(content, contains('<true/>'));
    });
  });
}
