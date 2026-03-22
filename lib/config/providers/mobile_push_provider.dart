import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/mobile_push_runtime_service.dart';
import '../../core/services/mobile_push_subscription_service.dart';
import '../../features/chat/domain/models/session.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'messaging_preferences_provider.dart';
import 'nostr_provider.dart';

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

  Future<List<String>> messageAuthorPubkeysFromSessions(
    Iterable<ChatSession> sessions,
  ) async {
    final authors = <String>{};
    final sessionManager = ref.read(sessionManagerServiceProvider);
    for (final session in sessions) {
      authors.addAll(
        await sessionManager.getMessagePushAuthorPubkeys(
          session.recipientPubkeyHex,
        ),
      );

      final fallback = session.recipientPubkeyHex.trim().toLowerCase();
      if (fallback.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(fallback)) {
        authors.add(fallback);
      }
    }
    return authors.toList(growable: false);
  }

  Future<void> syncFromState() async {
    final authState = ref.read(authStateProvider);
    final messagingPrefs = ref.read(messagingPreferencesProvider);
    final sessions = ref.read(sessionStateProvider).sessions;
    final messageAuthorPubkeys = await messageAuthorPubkeysFromSessions(
      sessions,
    );
    final enabled =
        authState.isAuthenticated &&
        messagingPrefs.mobilePushNotificationsEnabled;
    await service.sync(
      enabled: enabled,
      ownerPubkeyHex: authState.pubkeyHex,
      messageAuthorPubkeysHex: messageAuthorPubkeys,
    );
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

  ref.listen<SessionState>(sessionStateProvider, (previous, next) {
    if (previous?.sessions != next.sessions) {
      scheduleSync();
    }
  });

  scheduleSync();
});
