import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Snapshot of startup-launch capability + current desired state.
class StartupLaunchSnapshot {
  const StartupLaunchSnapshot({
    required this.isSupported,
    required this.enabled,
  });

  final bool isSupported;
  final bool enabled;
}

/// Service contract for reading/updating startup-launch setting.
abstract class StartupLaunchService {
  Future<StartupLaunchSnapshot> load();
  Future<StartupLaunchSnapshot> setEnabled(bool value);
}

/// Thin adapter around launch_at_startup for easier unit testing.
class LaunchAtStartupAdapter {
  bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  }

  void setup({
    required String appName,
    required String appPath,
    List<String> args = const [],
  }) {
    launchAtStartup.setup(appName: appName, appPath: appPath, args: args);
  }

  Future<bool> enable() => launchAtStartup.enable();
  Future<bool> disable() => launchAtStartup.disable();
}

/// Persisted startup-launch service.
///
/// Default behavior: when supported and no explicit user preference exists,
/// startup launch is enabled on first load.
class StartupLaunchServiceImpl implements StartupLaunchService {
  StartupLaunchServiceImpl({
    LaunchAtStartupAdapter? adapter,
    Future<SharedPreferences> Function()? preferencesFactory,
  }) : _adapter = adapter ?? LaunchAtStartupAdapter(),
       _preferencesFactory =
           preferencesFactory ?? SharedPreferences.getInstance;

  static const _prefKey = 'settings.launch_on_startup';
  static const _appName = 'iris chat';
  static const _startupLaunchArg = '--launch-at-startup';

  final LaunchAtStartupAdapter _adapter;
  final Future<SharedPreferences> Function() _preferencesFactory;
  bool _setupDone = false;

  @override
  Future<StartupLaunchSnapshot> load() async {
    if (!_adapter.isSupportedPlatform) {
      return const StartupLaunchSnapshot(isSupported: false, enabled: false);
    }

    try {
      await _ensureSetup();
      final prefs = await _preferencesFactory();
      final saved = prefs.getBool(_prefKey);

      if (saved == null) {
        final enabled = await _adapter.enable();
        if (!enabled) {
          throw StateError('Failed to enable launch at startup');
        }
        await prefs.setBool(_prefKey, true);
        return const StartupLaunchSnapshot(isSupported: true, enabled: true);
      }

      final updated = saved
          ? await _adapter.enable()
          : await _adapter.disable();
      if (!updated) {
        throw StateError(
          saved
              ? 'Failed to enable launch at startup'
              : 'Failed to disable launch at startup',
        );
      }

      return StartupLaunchSnapshot(isSupported: true, enabled: saved);
    } catch (e) {
      if (_isMissingPluginError(e)) {
        return const StartupLaunchSnapshot(isSupported: false, enabled: false);
      }
      rethrow;
    }
  }

  @override
  Future<StartupLaunchSnapshot> setEnabled(bool value) async {
    if (!_adapter.isSupportedPlatform) {
      return const StartupLaunchSnapshot(isSupported: false, enabled: false);
    }

    try {
      await _ensureSetup();

      final success = value
          ? await _adapter.enable()
          : await _adapter.disable();
      if (!success) {
        throw StateError(
          value
              ? 'Failed to enable launch at startup'
              : 'Failed to disable launch at startup',
        );
      }

      final prefs = await _preferencesFactory();
      await prefs.setBool(_prefKey, value);
      return StartupLaunchSnapshot(isSupported: true, enabled: value);
    } catch (e) {
      if (_isMissingPluginError(e)) {
        return const StartupLaunchSnapshot(isSupported: false, enabled: false);
      }
      rethrow;
    }
  }

  Future<void> _ensureSetup() async {
    if (_setupDone) return;
    _adapter.setup(
      appName: _appName,
      appPath: Platform.resolvedExecutable,
      args: const [_startupLaunchArg],
    );
    _setupDone = true;
  }

  bool _isMissingPluginError(Object error) {
    if (error is MissingPluginException) return true;
    if (error is! PlatformException) return false;

    final code = error.code.toLowerCase();
    final message = (error.message ?? '').toLowerCase();

    return code.contains('missing_plugin') ||
        message.contains('no implementation found for method');
  }
}
