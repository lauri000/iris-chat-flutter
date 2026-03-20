import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'invite_provider.dart';
import 'nostr_provider.dart';

List<String> sessionBootstrapTargets({
  required Iterable<String> sessionRecipientPubkeysHex,
  String? ownerPubkeyHex,
}) {
  final targets = <String>[];
  final seen = <String>{};

  void addTarget(String? raw) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty || !seen.add(normalized)) return;
    targets.add(normalized);
  }

  for (final recipientPubkeyHex in sessionRecipientPubkeysHex) {
    addTarget(recipientPubkeyHex);
  }
  addTarget(ownerPubkeyHex);

  return targets;
}

Future<List<String>> sessionRelayBootstrapTargets({
  required Iterable<String> bootstrapTargets,
  required Future<String?> Function(String peerPubkeyHex) getActiveSessionState,
}) async {
  final targetsNeedingRelayBootstrap = <String>[];

  for (final target in bootstrapTargets) {
    final activeSessionState = await getActiveSessionState(target);
    if (activeSessionState == null || activeSessionState.isEmpty) {
      targetsNeedingRelayBootstrap.add(target);
    }
  }

  return targetsNeedingRelayBootstrap;
}

class AppBootstrapState {
  const AppBootstrapState({
    this.isLoading = false,
    this.isReady = false,
    this.error,
  });

  final bool isLoading;
  final bool isReady;
  final String? error;

  AppBootstrapState copyWith({
    bool? isLoading,
    bool? isReady,
    String? error,
    bool clearError = false,
  }) {
    return AppBootstrapState(
      isLoading: isLoading ?? this.isLoading,
      isReady: isReady ?? this.isReady,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class AppBootstrapNotifier extends StateNotifier<AppBootstrapState> {
  AppBootstrapNotifier(this._ref)
    : _isFake = false,
      super(const AppBootstrapState());

  AppBootstrapNotifier.fake(super.state) : _ref = null, _isFake = true;

  final Ref? _ref;
  final bool _isFake;
  int _runId = 0;
  Future<void>? _inFlight;

  static const Duration _kRetryDelay = Duration(milliseconds: 500);
  static const Duration _kMaxWait = Duration(seconds: 15);

  void onAuthStateChanged(AuthState authState) {
    if (_isFake) return;

    if (!authState.isInitialized) {
      _cancelPending();
      state = const AppBootstrapState(isLoading: false, isReady: false);
      return;
    }

    if (!authState.isAuthenticated) {
      _cancelPending();
      state = const AppBootstrapState(isLoading: false, isReady: false);
      return;
    }

    unawaited(_bootstrap());
  }

  Future<void> retry() async {
    if (_isFake) return;
    await _bootstrap(force: true);
  }

  void _cancelPending() {
    _runId++;
  }

  Future<void> _bootstrap({bool force = false}) async {
    if (_isFake) return;
    final ref = _ref!;
    if (_inFlight != null && !force) return _inFlight!;

    final runId = ++_runId;
    final completer = Completer<void>();
    _inFlight = completer.future;
    state = state.copyWith(isLoading: true, isReady: false, clearError: true);

    try {
      Future<void> bootstrapCurrentSessions() async {
        final sessionManager = ref.read(sessionManagerServiceProvider);
        final bootstrapTargets = sessionBootstrapTargets(
          sessionRecipientPubkeysHex: ref
              .read(sessionStateProvider)
              .sessions
              .map((session) => session.recipientPubkeyHex),
          ownerPubkeyHex: sessionManager.ownerPubkeyHex,
        );
        await sessionManager.setupUsers(bootstrapTargets);
        final relayBootstrapTargets = await sessionRelayBootstrapTargets(
          bootstrapTargets: bootstrapTargets,
          getActiveSessionState: sessionManager.getActiveSessionState,
        );
        if (relayBootstrapTargets.isNotEmpty) {
          await sessionManager.bootstrapUsersFromRelay(relayBootstrapTargets);
        }
      }

      Future<void> bootstrapOwnPublicSelfSession() async {
        final sessionManager = ref.read(sessionManagerServiceProvider);
        await sessionManager.bootstrapOwnerSelfSessionIfNeeded();
      }

      final deadline = DateTime.now().add(_kMaxWait);
      while (mounted && runId == _runId) {
        await ref.read(sessionStateProvider.notifier).loadSessions();
        await ref.read(groupStateProvider.notifier).loadGroups();

        final sessionError = ref.read(sessionStateProvider).error;
        final groupError = ref.read(groupStateProvider).error;
        if (sessionError == null && groupError == null) {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          state = state.copyWith(
            isLoading: false,
            isReady: false,
            error: sessionError ?? groupError ?? 'Failed to load chats.',
          );
          return;
        }
        await Future<void>.delayed(_kRetryDelay);
      }

      if (!mounted || runId != _runId) return;

      try {
        await bootstrapCurrentSessions();
      } catch (_) {}

      await ref.read(inviteStateProvider.notifier).loadInvites();
      try {
        await ref
            .read(inviteStateProvider.notifier)
            .bootstrapInviteResponsesFromRelay();
      } catch (_) {}
      try {
        await ref.read(sessionStateProvider.notifier).loadSessions();
        await bootstrapCurrentSessions();
        final sessionManager = ref.read(sessionManagerServiceProvider);
        final bootstrapTargets = sessionBootstrapTargets(
          sessionRecipientPubkeysHex: ref
              .read(sessionStateProvider)
              .sessions
              .map((session) => session.recipientPubkeyHex),
          ownerPubkeyHex: sessionManager.ownerPubkeyHex,
        );
        await sessionManager.refreshSubscription();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await sessionManager.repairRecentlyActiveLinkedDeviceRecords(
          bootstrapTargets,
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await sessionManager.repairRecentlyActiveLinkedDeviceRecords(
          bootstrapTargets,
        );
      } catch (_) {}
      try {
        ref.read(messageSubscriptionProvider);
      } catch (_) {}

      try {
        await ref
            .read(inviteStateProvider.notifier)
            .ensurePublishedPublicInvite();
      } catch (_) {}
      try {
        await bootstrapOwnPublicSelfSession();
      } catch (_) {}

      if (!mounted || runId != _runId) return;
      state = state.copyWith(isLoading: false, isReady: true, clearError: true);
    } catch (e) {
      if (!mounted || runId != _runId) return;
      state = state.copyWith(
        isLoading: false,
        isReady: false,
        error: e.toString(),
      );
    } finally {
      if (identical(_inFlight, completer.future)) {
        _inFlight = null;
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }
}

final appBootstrapProvider =
    StateNotifierProvider<AppBootstrapNotifier, AppBootstrapState>((ref) {
      final notifier = AppBootstrapNotifier(ref);
      void handleAuthState(AuthState authState) {
        if (authState.isInitialized && authState.isAuthenticated) {
          ref.read(messageSubscriptionProvider);
        }
        notifier.onAuthStateChanged(authState);
      }

      ref.listen<AuthState>(authStateProvider, (previous, next) {
        handleAuthState(next);
      });
      handleAuthState(ref.read(authStateProvider));
      return notifier;
    });
