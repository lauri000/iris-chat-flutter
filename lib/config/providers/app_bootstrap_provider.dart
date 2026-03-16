import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import 'chat_provider.dart';
import 'invite_provider.dart';
import 'nostr_provider.dart';

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
        await ref
            .read(sessionManagerServiceProvider)
            .setupUsers(
              ref
                  .read(sessionStateProvider)
                  .sessions
                  .map((session) => session.recipientPubkeyHex),
            );
      } catch (_) {}

      await ref.read(inviteStateProvider.notifier).loadInvites();
      try {
        await ref
            .read(inviteStateProvider.notifier)
            .ensurePublishedPublicInvite();
      } catch (_) {}

      try {
        ref.read(messageSubscriptionProvider);
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
      ref.listen<AuthState>(authStateProvider, (previous, next) {
        notifier.onAuthStateChanged(next);
      });
      notifier.onAuthStateChanged(ref.read(authStateProvider));
      return notifier;
    });
