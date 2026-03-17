import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ndr_ffi artifact guard', () {
    test('checked-in macOS static library stays release-sized', () {
      final archive = File('libndr_ffi.a');
      expect(archive.existsSync(), isTrue);

      final bytes = archive.lengthSync();
      const maxReleaseSizedArchiveBytes = 80 * 1024 * 1024;

      expect(
        bytes,
        lessThan(maxReleaseSizedArchiveBytes),
        reason:
            'libndr_ffi.a looks like a debug archive (${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB). '
            'Rebuild ndr-ffi with --release and copy rust/target/release/libndr_ffi.a instead.',
      );
    });
  });
}
