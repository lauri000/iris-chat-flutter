import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/mobile_push_runtime_service.dart';
import '../../core/services/mobile_push_subscription_service.dart';
import 'auth_provider.dart';
import 'messaging_preferences_provider.dart';

final mobilePushTokenProvider = Provider<MobilePushTokenProvider>((ref) {
  return FirebaseMobilePushTokenProvider();
});

final mobilePushSubscriptionServiceProvider =
    Provider<MobilePushSubscriptionService>((ref) {
      final authRepository = ref.watch(authRepositoryProvider);
      final tokenProvider = ref.watch(mobilePushTokenProvider);
      return MobilePushSubscriptionServiceImpl(
        authRepository: authRepository,
        tokenProvider: tokenProvider,
      );
    });

final mobilePushSupportedProvider = Provider<bool>((ref) {
  return ref.watch(mobilePushSubscriptionServiceProvider).isSupported;
});

final mobilePushRuntimeBootstrapProvider = Provider<void>((ref) {
  unawaited(Future<void>.microtask(initializeMobilePushRuntime));
});

final mobilePushSyncBootstrapProvider = Provider<void>((ref) {
  final service = ref.watch(mobilePushSubscriptionServiceProvider);

  Future<void> syncFromState() async {
    final authState = ref.read(authStateProvider);
    final messagingPrefs = ref.read(messagingPreferencesProvider);
    final enabled =
        authState.isAuthenticated &&
        messagingPrefs.mobilePushNotificationsEnabled;
    await service.sync(enabled: enabled, ownerPubkeyHex: authState.pubkeyHex);
  }

  void scheduleSync() {
    unawaited(Future<void>.microtask(syncFromState));
  }

  ref.listen<AuthState>(authStateProvider, (previous, next) {
    if (previous?.isAuthenticated != next.isAuthenticated ||
        previous?.pubkeyHex != next.pubkeyHex) {
      scheduleSync();
    }
  });

  ref.listen<MessagingPreferencesState>(messagingPreferencesProvider, (
    previous,
    next,
  ) {
    if (next.isLoading) return;
    if (previous?.mobilePushNotificationsEnabled !=
        next.mobilePushNotificationsEnabled) {
      scheduleSync();
    }
  });

  scheduleSync();
});
