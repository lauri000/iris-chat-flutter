import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

final appVersionProvider = FutureProvider<String>((ref) async {
  final packageInfo = await PackageInfo.fromPlatform();
  final version = packageInfo.version.trim();

  if (version.isEmpty) {
    return 'Unknown';
  }

  return version.startsWith('v') ? version : 'v$version';
});
