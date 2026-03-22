import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_chat/core/services/startup_launch_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeLaunchAtStartupAdapter extends LaunchAtStartupAdapter {
  FakeLaunchAtStartupAdapter({
    required this.supported,
    this.enableResult = true,
    this.disableResult = true,
    this.throwMissingPluginOnEnable = false,
    this.throwMissingPluginOnDisable = false,
  });

  final bool supported;
  final bool enableResult;
  final bool disableResult;
  final bool throwMissingPluginOnEnable;
  final bool throwMissingPluginOnDisable;
  int setupCalls = 0;
  int enableCalls = 0;
  int disableCalls = 0;
  String? lastAppName;
  String? lastAppPath;
  List<String> lastArgs = const [];

  @override
  bool get isSupportedPlatform => supported;

  @override
  void setup({
    required String appName,
    required String appPath,
    List<String> args = const [],
  }) {
    setupCalls += 1;
    lastAppName = appName;
    lastAppPath = appPath;
    lastArgs = args;
  }

  @override
  Future<bool> enable() async {
    enableCalls += 1;
    if (throwMissingPluginOnEnable) {
      throw MissingPluginException(
        'No implementation found for method launchAtStartupIsEnabled on channel launch_at_startup',
      );
    }
    return enableResult;
  }

  @override
  Future<bool> disable() async {
    disableCalls += 1;
    if (throwMissingPluginOnDisable) {
      throw MissingPluginException(
        'No implementation found for method launchAtStartupDisable on channel launch_at_startup',
      );
    }
    return disableResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StartupLaunchServiceImpl', () {
    test('load defaults to enabled=true on first run when supported', () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = FakeLaunchAtStartupAdapter(supported: true);
      final service = StartupLaunchServiceImpl(
        adapter: adapter,
        preferencesFactory: SharedPreferences.getInstance,
      );

      final snapshot = await service.load();

      expect(snapshot.isSupported, isTrue);
      expect(snapshot.enabled, isTrue);
      expect(adapter.setupCalls, 1);
      expect(adapter.enableCalls, 1);
      expect(adapter.lastAppName, 'iris chat');
      expect(adapter.lastAppPath, isNotEmpty);
      expect(adapter.lastArgs, const ['--launch-at-startup']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings.launch_on_startup'), isTrue);
    });

    test('load applies saved disabled preference when supported', () async {
      SharedPreferences.setMockInitialValues({
        'settings.launch_on_startup': false,
      });
      final adapter = FakeLaunchAtStartupAdapter(supported: true);
      final service = StartupLaunchServiceImpl(
        adapter: adapter,
        preferencesFactory: SharedPreferences.getInstance,
      );

      final snapshot = await service.load();

      expect(snapshot.isSupported, isTrue);
      expect(snapshot.enabled, isFalse);
      expect(adapter.disableCalls, 1);
      expect(adapter.enableCalls, 0);
    });

    test('setEnabled persists toggle and applies native setting', () async {
      SharedPreferences.setMockInitialValues({
        'settings.launch_on_startup': true,
      });
      final adapter = FakeLaunchAtStartupAdapter(supported: true);
      final service = StartupLaunchServiceImpl(
        adapter: adapter,
        preferencesFactory: SharedPreferences.getInstance,
      );

      final snapshot = await service.setEnabled(false);

      expect(snapshot.isSupported, isTrue);
      expect(snapshot.enabled, isFalse);
      expect(adapter.disableCalls, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings.launch_on_startup'), isFalse);
    });

    test(
      'load returns unsupported when platform does not support startup launch',
      () async {
        SharedPreferences.setMockInitialValues({});
        final adapter = FakeLaunchAtStartupAdapter(supported: false);
        final service = StartupLaunchServiceImpl(
          adapter: adapter,
          preferencesFactory: SharedPreferences.getInstance,
        );

        final snapshot = await service.load();

        expect(snapshot.isSupported, isFalse);
        expect(snapshot.enabled, isFalse);
        expect(adapter.setupCalls, 0);
        expect(adapter.enableCalls, 0);
        expect(adapter.disableCalls, 0);
      },
    );

    test('load returns unsupported when startup plugin is missing', () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = FakeLaunchAtStartupAdapter(
        supported: true,
        throwMissingPluginOnEnable: true,
      );
      final service = StartupLaunchServiceImpl(
        adapter: adapter,
        preferencesFactory: SharedPreferences.getInstance,
      );

      final snapshot = await service.load();

      expect(snapshot.isSupported, isFalse);
      expect(snapshot.enabled, isFalse);
      expect(adapter.setupCalls, 1);
      expect(adapter.enableCalls, 1);
    });

    test(
      'setEnabled returns unsupported when startup plugin is missing',
      () async {
        SharedPreferences.setMockInitialValues({});
        final adapter = FakeLaunchAtStartupAdapter(
          supported: true,
          throwMissingPluginOnDisable: true,
        );
        final service = StartupLaunchServiceImpl(
          adapter: adapter,
          preferencesFactory: SharedPreferences.getInstance,
        );

        final snapshot = await service.setEnabled(false);

        expect(snapshot.isSupported, isFalse);
        expect(snapshot.enabled, isFalse);
        expect(adapter.setupCalls, 1);
        expect(adapter.disableCalls, 1);
      },
    );
  });
}
