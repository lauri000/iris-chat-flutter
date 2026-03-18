import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class _SeenSyncLifecycleObserver with WidgetsBindingObserver {
  _SeenSyncLifecycleObserver({required VoidCallback onResumed})
    : _onResumed = onResumed;

  final VoidCallback _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    }
  }
}

/// Reusable lifecycle-aware helper for marking visible chats as seen.
mixin SeenSyncMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool _seenSyncInFlight = false;
  _SeenSyncLifecycleObserver? _seenSyncObserver;

  bool get hasUnseenIncomingMessages;

  @protected
  bool get hasUnreadIndicator => hasUnseenIncomingMessages;

  Future<void> markConversationSeen();

  Future<void> afterConversationSeen() async {}

  @protected
  bool get isAppResumed {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @protected
  void initSeenSyncObserver() {
    _seenSyncObserver ??= _SeenSyncLifecycleObserver(
      onResumed: scheduleSeenSync,
    );
    WidgetsBinding.instance.addObserver(_seenSyncObserver!);
  }

  @protected
  void disposeSeenSyncObserver() {
    final observer = _seenSyncObserver;
    if (observer == null) return;
    WidgetsBinding.instance.removeObserver(observer);
  }

  @protected
  void scheduleSeenSync() {
    if (!mounted) return;
    if (_seenSyncInFlight || !isAppResumed || !hasUnreadIndicator) {
      return;
    }

    _seenSyncInFlight = true;
    unawaited(() async {
      try {
        if (!mounted) return;
        try {
          await markConversationSeen();
        } catch (_) {
          // Best-effort task; provider/widget may be disposing.
          return;
        }
        if (!mounted) return;
        if (isAppResumed) {
          try {
            await afterConversationSeen();
          } catch (_) {
            // Best-effort task; provider/widget may be disposing.
            return;
          }
        }
      } finally {
        _seenSyncInFlight = false;
      }
    }());
  }
}
