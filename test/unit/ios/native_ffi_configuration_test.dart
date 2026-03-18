import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS native FFI configuration', () {
    test('generated Swift bindings stay behind the native FFI compile flag', () {
      for (final path in [
        'ios/Runner/ndr_ffi.swift',
        'ios/Runner/hashtree_ffi.swift',
      ]) {
        final bindingFile = File(path);
        expect(bindingFile.existsSync(), isTrue, reason: 'Missing $path');

        final content = bindingFile.readAsStringSync();
        expect(
          content,
          startsWith('#if NATIVE_RUST_FFI_ENABLED'),
          reason:
              '$path must stay compile-guarded so Flutter can still build if native '
              'Apple artifacts are temporarily unavailable.',
        );
        expect(
          content.trimRight(),
          endsWith('#endif'),
          reason:
              '$path should close the compile guard at the end of the file.',
        );
      }
    });

    test(
      'Xcode project enables native Rust FFI for iOS build configurations',
      () {
        final projectFile = File('ios/Runner.xcodeproj/project.pbxproj');
        expect(projectFile.existsSync(), isTrue);

        final content = projectFile.readAsStringSync();
        expect(
          content,
          contains(
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG NATIVE_RUST_FFI_ENABLED";',
          ),
        );
        expect(
          RegExp(
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS = NATIVE_RUST_FFI_ENABLED;',
          ).allMatches(content).length,
          greaterThanOrEqualTo(2),
          reason: 'Release and Profile should both enable native Rust FFI.',
        );
        expect(content, contains('OTHER_LDFLAGS[sdk=iphoneos*]'));
        expect(content, contains('OTHER_LDFLAGS[sdk=iphonesimulator*]'));
        expect(content, isNot(contains('libndr_ffi.a in Frameworks')));
        expect(content, isNot(contains('libhashtree_ffi.a in Frameworks')));
      },
    );

    test(
      'checked-in Apple xcframeworks provide both device and simulator slices',
      () {
        final frameworkExpectations = {
          'ios/Frameworks/NdrFfi.xcframework/Info.plist': const [
            'ios-arm64',
            'ios-arm64_x86_64-simulator',
            'SupportedPlatformVariant',
            'simulator',
          ],
          'ios/Frameworks/HashtreeFfi.xcframework/Info.plist': const [
            'ios-arm64',
            'ios-arm64_x86_64-simulator',
            'SupportedPlatformVariant',
            'simulator',
          ],
        };

        frameworkExpectations.forEach((path, expectedSnippets) {
          final infoPlist = File(path);
          expect(infoPlist.existsSync(), isTrue, reason: 'Missing $path');

          final content = infoPlist.readAsStringSync();
          for (final snippet in expectedSnippets) {
            expect(
              content,
              contains(snippet),
              reason: '$path should describe both device and simulator slices.',
            );
          }
        });
      },
    );
  });
}
