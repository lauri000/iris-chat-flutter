import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'config/providers/mobile_push_provider.dart';
import 'config/providers/nostr_provider.dart';
import 'config/providers/startup_launch_provider.dart';
import 'config/router.dart';
import 'config/theme.dart';
import 'core/services/mobile_push_runtime_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerMobilePushBackgroundHandler();
  runApp(const ProviderScope(child: IrisChatApp()));
}

class IrisChatApp extends ConsumerWidget {
  const IrisChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    // Initialize startup-launch preference at app start.
    ref.watch(startupLaunchProvider);
    // Keep the encrypted DM receive path alive for the app lifetime.
    ref.watch(messageSubscriptionProvider);
    // Initialize mobile push runtime for supported mobile platforms.
    ref.watch(mobilePushRuntimeBootstrapProvider);
    // Initialize mobile push sync for supported platforms.
    ref.watch(mobilePushSyncBootstrapProvider);

    return ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) {
        return MaterialApp.router(
          title: 'iris chat',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.dark,
          routerConfig: router,
        );
      },
    );
  }
}
