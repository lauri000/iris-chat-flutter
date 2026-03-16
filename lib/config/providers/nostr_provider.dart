import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/nostr_service.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/session_manager_service.dart';
import '../../core/utils/invite_response_subscription.dart' as invite_response;
import '../../core/utils/nostr_rumor.dart';
import '../../features/chat/domain/utils/chat_settings.dart';
import 'auth_provider.dart';
import 'chat_provider.dart';
import 'invite_provider.dart';
import 'nostr_relay_settings_provider.dart';

abstract class SessionManagerTeardown {
  Future<void> disposeAndClear(SessionManagerService? service);
}

class DefaultSessionManagerTeardown implements SessionManagerTeardown {
  const DefaultSessionManagerTeardown();

  @override
  Future<void> disposeAndClear(SessionManagerService? service) async {
    await service?.dispose();
    await SessionManagerService.clearPersistentStorage();
  }
}

/// Provider for the Nostr service.
final nostrServiceProvider = Provider<NostrService>((ref) {
  final relayUrls = ref.watch(
    nostrRelaySettingsProvider.select((state) => state.relays),
  );
  final service = NostrService(relayUrls: relayUrls);

  // Connect on creation
  service.connect();

  // Disconnect on disposal
  ref.onDispose(service.disconnect);

  return service;
});

/// Provider for session manager service.
final sessionManagerServiceProvider = Provider<SessionManagerService>((ref) {
  // Ensure this provider rebuilds when the authenticated identity/device changes
  // (e.g., login, linked-device login, key rotation).
  final authSnapshot = ref.watch(
    authStateProvider.select(
      (s) => (s.isAuthenticated, s.pubkeyHex, s.devicePubkeyHex),
    ),
  );
  final isAuthenticated = authSnapshot.$1;

  final nostrService = ref.watch(nostrServiceProvider);
  final authRepository = ref.watch(authRepositoryProvider);
  final messageDatasource = ref.watch(messageDatasourceProvider);

  final service = SessionManagerService(
    nostrService,
    authRepository,
    hasProcessedMessageEventId: messageDatasource.messageExists,
  );

  if (isAuthenticated) {
    unawaited(service.start().catchError((error, stackTrace) {}));
  }

  ref.onDispose(() {
    unawaited(service.dispose().catchError((error, stackTrace) {}));
  });

  return service;
});

final sessionManagerTeardownProvider = Provider<SessionManagerTeardown>((ref) {
  return const DefaultSessionManagerTeardown();
});

/// Provider for message subscription (backwards-compatible alias).
final messageSubscriptionProvider = Provider<SessionManagerService>((ref) {
  final service = ref.watch(sessionManagerServiceProvider);
  final nostrService = ref.watch(nostrServiceProvider);
  final inviteDatasource = ref.watch(inviteDatasourceProvider);
  final sessionDatasource = ref.watch(sessionDatasourceProvider);
  final messageDatasource = ref.watch(messageDatasourceProvider);
  final groupDatasource = ref.watch(groupDatasourceProvider);
  final groupMessageDatasource = ref.watch(groupMessageDatasourceProvider);

  const groupSenderKeyDistributionKind = 10446;
  var disposed = false;

  // Serialize all processing in this provider to reduce SQLite "database locked"
  // warnings caused by concurrent async stream handlers.
  Future<void> serial = Future.value();
  void schedule(Future<void> Function() task) {
    if (disposed) return;
    serial = serial
        .then((_) async {
          if (disposed) return;
          await task();
        })
        .catchError((error, stackTrace) {});
  }

  Timer? expirationTimer;

  void scheduleExpirationTick(Duration delay) {
    if (disposed) return;
    expirationTimer?.cancel();
    expirationTimer = Timer(delay, () {
      schedule(() async {
        if (disposed) return;
        final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        var nextDelayMs = 60000;

        try {
          // Purge expired messages from persistent storage first.
          final affectedSessions = await messageDatasource
              .deleteExpiredMessages(nowSeconds);
          final affectedGroups = await groupMessageDatasource
              .deleteExpiredMessages(nowSeconds);

          // Purge expired messages from in-memory UI stores.
          ref
              .read(chatStateProvider.notifier)
              .purgeExpiredFromState(nowSeconds);
          ref
              .read(groupStateProvider.notifier)
              .purgeExpiredFromState(nowSeconds);

          final sessionNotifier = ref.read(sessionStateProvider.notifier);
          for (final sessionId in affectedSessions) {
            await sessionDatasource.recomputeDerivedFieldsFromMessages(
              sessionId,
            );
            await sessionNotifier.refreshSession(sessionId);
          }

          final groupNotifier = ref.read(groupStateProvider.notifier);
          for (final groupId in affectedGroups) {
            await groupDatasource.recomputeDerivedFieldsFromMessages(groupId);
            await groupNotifier.refreshGroup(groupId);
          }

          // Schedule next tick based on the next soonest expiration.
          final nextDm = await messageDatasource.getNextExpirationSeconds();
          final nextGroup = await groupMessageDatasource
              .getNextExpirationSeconds();

          int? next;
          if (nextDm != null && nextGroup != null) {
            next = nextDm < nextGroup ? nextDm : nextGroup;
          } else {
            next = nextDm ?? nextGroup;
          }

          if (next != null) {
            nextDelayMs = (next - nowSeconds) * 1000;
          }
        } catch (_) {
          // Best-effort; try again later.
        }

        final clampedMs = nextDelayMs < 1000
            ? 1000
            : (nextDelayMs > 60000 ? 60000 : nextDelayMs);
        scheduleExpirationTick(Duration(milliseconds: clampedMs));
      });
    });
  }

  // Start a little after hydration so initial loads don't race the DB.
  scheduleExpirationTick(const Duration(seconds: 2));
  ref.onDispose(() {
    disposed = true;
    expirationTimer?.cancel();
    expirationTimer = null;
  });

  // Coalesce refresh work so repeated invite state changes don't build up an
  // unbounded Future chain (which can lead to runaway memory usage).
  var refreshScheduled = false;
  var refreshAgain = false;

  Future<void> refreshInviteResponseSubscription() async {
    if (disposed) return;
    await invite_response.refreshInviteResponseSubscription(
      nostrService: nostrService,
      inviteDatasource: inviteDatasource,
      subscriptionId: invite_response.appInviteResponsesSubId,
    );
  }

  // Subscribe for invite responses (and refresh when invites change).
  void requestInviteResponseSubscriptionRefresh() {
    if (disposed) return;
    if (refreshScheduled) {
      refreshAgain = true;
      return;
    }
    refreshScheduled = true;
    schedule(() async {
      try {
        while (true) {
          refreshAgain = false;
          await refreshInviteResponseSubscription();
          if (!refreshAgain) break;
        }
      } finally {
        refreshScheduled = false;
      }
    });
  }

  requestInviteResponseSubscriptionRefresh();
  ref.listen<InviteState>(inviteStateProvider, (previous, next) {
    if (disposed) return;
    requestInviteResponseSubscriptionRefresh();
  });
  ref.onDispose(() {
    disposed = true;
    nostrService.closeSubscription(invite_response.appInviteResponsesSubId);
  });

  final sub = service.decryptedMessages.listen((message) {
    if (disposed) return;
    schedule(() async {
      if (disposed) return;
      final rumor = NostrRumor.tryParse(message.content);
      String? receiptSessionId;
      if (rumor != null) {
        if (rumor.kind == groupSenderKeyDistributionKind) {
          try {
            final decrypted = await service.groupHandleIncomingSessionEvent(
              eventJson: message.content,
              fromOwnerPubkeyHex: message.senderPubkeyHex,
            );
            for (final event in decrypted) {
              final senderPubkeyHex =
                  event.senderOwnerPubkeyHex?.trim().isNotEmpty ?? false
                  ? event.senderOwnerPubkeyHex
                  : message.senderPubkeyHex;
              await ref
                  .read(groupStateProvider.notifier)
                  .handleIncomingGroupRumorJson(
                    event.innerEventJson,
                    eventId: event.outerEventId,
                    senderPubkeyHex: senderPubkeyHex,
                  );
            }
          } catch (_) {}
          return;
        }

        final groupId = getFirstTagValue(rumor.tags, 'l');
        if (groupId != null || rumor.kind == 40) {
          await ref
              .read(groupStateProvider.notifier)
              .handleIncomingGroupRumorJson(
                message.content,
                eventId: message.eventId,
                senderPubkeyHex: message.senderPubkeyHex,
              );
          return;
        }

        if (rumor.kind == kChatSettingsKind) {
          final settings = parseChatSettingsContent(rumor.content);
          if (settings == null) return;

          final owner = service.ownerPubkeyHex;
          final peer = owner != null
              ? resolveRumorPeerPubkey(ownerPubkeyHex: owner, rumor: rumor)
              : message.senderPubkeyHex;
          if (peer == null || peer.isEmpty) return;

          final sessionNotifier = ref.read(sessionStateProvider.notifier);
          final session = await sessionNotifier.ensureSessionForRecipient(peer);
          await sessionNotifier.setMessageTtlSeconds(
            session.id,
            settings.messageTtlSeconds,
          );
          return;
        }

        if (rumor.kind == 15) {
          final owner = service.ownerPubkeyHex;
          final peer = owner != null
              ? resolveRumorPeerPubkey(ownerPubkeyHex: owner, rumor: rumor)
              : message.senderPubkeyHex;
          if (peer != null && peer.isNotEmpty) {
            final session = await ref
                .read(sessionDatasourceProvider)
                .getSessionByRecipient(peer);
            receiptSessionId = session?.id;
          }
        }
      }

      if (disposed) return;
      final chatNotifier = ref.read(chatStateProvider.notifier);
      final chatMessage = await chatNotifier.receiveDecryptedMessage(
        message.senderPubkeyHex,
        message.content,
        eventId: message.eventId,
        createdAt: message.createdAt,
      );

      if (chatMessage == null) {
        if (disposed) return;
        if (receiptSessionId != null) {
          await ref
              .read(sessionStateProvider.notifier)
              .refreshSession(receiptSessionId);
        }
        return;
      }

      if (disposed) return;
      final sessionNotifier = ref.read(sessionStateProvider.notifier);
      final session = await sessionNotifier.ensureSessionForRecipient(
        chatMessage.sessionId,
      );

      await sessionNotifier.updateSessionWithMessage(session.id, chatMessage);

      if (chatMessage.isIncoming) {
        await sessionNotifier.incrementUnread(session.id);
      }
    });
  });

  final inviteSub = nostrService.events.listen((event) {
    if (disposed) return;
    // Filter before scheduling: relays can deliver a high volume of events and
    // queueing no-op tasks here can explode memory if the DB stalls.
    if (event.kind != 1059) return;

    schedule(() async {
      if (disposed) return;
      final pTags = <String>{};
      for (final t in event.tags) {
        if (t.length < 2) continue;
        if (t[0] == 'p') pTags.add(t[1]);
      }
      if (pTags.isEmpty) return;

      final invites = await inviteDatasource.getActiveInvites();
      for (final invite in invites) {
        if (invite.serializedState == null) continue;
        try {
          final serialized = invite.serializedState!;
          final ephemeralPubkey = await invite_response
              .resolveInviteEphemeralPubkey(serialized);
          if (ephemeralPubkey == null || ephemeralPubkey.isEmpty) continue;
          if (!pTags.contains(ephemeralPubkey)) continue;

          await ref
              .read(inviteStateProvider.notifier)
              .handleInviteResponse(invite.id, jsonEncode(event.toJson()));
          return;
        } catch (_) {}
      }
    });
  });

  ref.onDispose(sub.cancel);
  ref.onDispose(inviteSub.cancel);

  return service;
});

/// Provider for connection status.
final nostrConnectionStatusProvider = StreamProvider<Map<String, bool>>((
  ref,
) async* {
  final nostrService = ref.watch(nostrServiceProvider);

  // Emit immediately so status-dependent UI does not wait for the first poll.
  yield nostrService.connectionStatus;

  // Poll connection status every 5 seconds
  yield* Stream.periodic(
    const Duration(seconds: 5),
    (_) => nostrService.connectionStatus,
  );
});

/// Provider for connected relay count.
final connectedRelayCountProvider = Provider<int>((ref) {
  final nostrService = ref.watch(nostrServiceProvider);
  return nostrService.connectedCount;
});

/// Provider for profile service.
final profileServiceProvider = Provider<ProfileService>((ref) {
  final nostrService = ref.watch(nostrServiceProvider);
  final service = ProfileService(nostrService);
  ref.onDispose(service.dispose);
  return service;
});

/// Provider that emits pubkeys whenever cached profile metadata updates.
final profileUpdatesProvider = StreamProvider<String>((ref) {
  final profileService = ref.watch(profileServiceProvider);
  return profileService.profileUpdates;
});
