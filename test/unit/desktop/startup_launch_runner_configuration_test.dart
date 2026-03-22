import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop startup launch runner configuration', () {
    test('Windows runner starts minimized for startup launches', () {
      final mainFile = File('windows/runner/main.cpp');
      final flutterWindowFile = File('windows/runner/flutter_window.cpp');

      expect(mainFile.existsSync(), isTrue);
      expect(flutterWindowFile.existsSync(), isTrue);

      final mainContent = mainFile.readAsStringSync();
      final flutterWindowContent = flutterWindowFile.readAsStringSync();

      expect(
        mainContent,
        contains('constexpr char kStartupLaunchArg[] = "--launch-at-startup";'),
      );
      expect(
        mainContent,
        contains(
          'const bool start_minimized = HasStartupLaunchArg(command_line_arguments);',
        ),
      );
      expect(
        mainContent,
        contains('FlutterWindow window(project, start_minimized);'),
      );
      expect(flutterWindowContent, contains('SW_SHOWMINIMIZED'));
    });

    test('Linux runner iconifies startup launches', () {
      final applicationFile = File('linux/runner/my_application.cc');
      expect(applicationFile.existsSync(), isTrue);

      final content = applicationFile.readAsStringSync();

      expect(
        content,
        contains('constexpr char kStartupLaunchArg[] = "--launch-at-startup";'),
      );
      expect(
        content,
        contains(
          'self->start_minimized = has_startup_launch_arg(*arguments + 1);',
        ),
      );
      expect(content, contains('gtk_window_iconify(window);'));
    });
  });
}
