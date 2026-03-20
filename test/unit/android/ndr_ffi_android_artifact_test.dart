import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'checked-in Android ndr_ffi library exports all UniFFI checksum symbols',
    () async {
      final binding = File(
        'android/app/src/main/kotlin/uniffi/ndr_ffi/ndr_ffi.kt',
      );
      expect(
        binding.existsSync(),
        isTrue,
        reason: 'Expected generated Kotlin UniFFI binding to be checked in.',
      );

      final bindingContent = await binding.readAsString();
      final checksumSymbols = RegExp(
            'uniffi_ndr_ffi_checksum_[A-Za-z0-9_]+',
          )
          .allMatches(bindingContent)
          .map((match) => match.group(0)!)
          .toSet()
          .toList()
        ..sort();

      expect(
        checksumSymbols,
        isNotEmpty,
        reason: 'Expected generated binding to reference UniFFI checksum symbols.',
      );

      final jniLibsDir = Directory('android/app/src/main/jniLibs');
      expect(
        jniLibsDir.existsSync(),
        isTrue,
        reason: 'Expected checked-in Android jniLibs directory.',
      );

      final abiDirs = jniLibsDir
          .listSync()
          .whereType<Directory>()
          .map((dir) => dir.path)
          .toList()
        ..sort();
      expect(
        abiDirs,
        isNotEmpty,
        reason: 'Expected at least one checked-in Android ABI directory.',
      );

      for (final abiDir in abiDirs) {
        final library = File('$abiDir/libndr_ffi.so');
        expect(
          library.existsSync(),
          isTrue,
          reason: 'Expected checked-in Android ndr_ffi artifact at ${library.path}.',
        );

        final stringsResult = await Process.run('strings', [library.path]);
        expect(
          stringsResult.exitCode,
          0,
          reason: 'Failed to inspect ${library.path}',
        );

        final exportedText = stringsResult.stdout as String;
        final missingSymbols = checksumSymbols
            .where((symbol) => !exportedText.contains(symbol))
            .toList();

        expect(
          missingSymbols,
          isEmpty,
          reason:
              'Android ndr_ffi artifact at ${library.path} is out of sync with '
              'checked-in Kotlin bindings. Rebuild '
              '~/src/nostr-double-ratchet/scripts/mobile/build-android.sh '
              'and recopy the jniLibs output. Missing: ${missingSymbols.join(', ')}',
        );
      }
    },
  );
}
