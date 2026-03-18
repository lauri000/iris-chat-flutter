import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS FFI fallback configuration', () {
    test('ndr_ffi Swift bindings stay behind the native FFI compile flag', () {
      final bindingFile = File('ios/Runner/ndr_ffi.swift');
      expect(bindingFile.existsSync(), isTrue);

      final content = bindingFile.readAsStringSync();
      expect(
        content,
        startsWith('#if NATIVE_RUST_FFI_ENABLED'),
        reason:
            'ios/Runner/ndr_ffi.swift must stay compile-guarded so fallback iOS '
            'builds do not try to link native ndr symbols.',
      );
      expect(
        content.trimRight(),
        endsWith('#endif'),
        reason:
            'ios/Runner/ndr_ffi.swift should close the NATIVE_RUST_FFI_ENABLED '
            'guard at the end of the file.',
      );
    });

    test(
      'plugin exposes the disabled fallback for iOS builds without native FFI',
      () {
        final pluginFile = File('ios/Runner/NdrFfiPlugin.swift');
        expect(pluginFile.existsSync(), isTrue);

        final content = pluginFile.readAsStringSync();
        expect(content, contains('result("ffi-disabled")'));
        expect(content, contains('iOS native FFI is disabled in this build.'));
      },
    );
  });
}
