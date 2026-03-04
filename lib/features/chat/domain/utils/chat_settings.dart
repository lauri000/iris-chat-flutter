import 'dart:convert';

/// Inner rumor kind used for 1:1 chat settings signaling (Iris convention).
///
/// See `nostr-double-ratchet` v0.0.77 "Disappearing Message Signaling".
const int kChatSettingsKind = 10448;

/// Parsed "chat-settings" payload.
class ChatSettingsPayload {
  const ChatSettingsPayload({required this.messageTtlSeconds});

  /// Per-chat disappearing message timer in seconds.
  ///
  /// `null` means "Off".
  final int? messageTtlSeconds;
}

/// Parse a "chat-settings" JSON payload from a settings rumor's `content`.
///
/// Expected shape:
/// `{ "type": "chat-settings", "v": 1, "messageTtlSeconds": <seconds|null> }`
ChatSettingsPayload? parseChatSettingsContent(String content) {
  if (content.isEmpty) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(content);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;

  if (decoded['type'] != 'chat-settings') return null;
  if (decoded['v'] != 1) return null;

  final ttl = decoded['messageTtlSeconds'];
  if (ttl == null) {
    return const ChatSettingsPayload(messageTtlSeconds: null);
  }
  if (ttl is num) {
    final normalized = ttl.floor();
    return ChatSettingsPayload(
      messageTtlSeconds: normalized > 0 ? normalized : null,
    );
  }

  return null;
}

/// Build a "chat-settings" payload JSON for sending.
String buildChatSettingsContent({required int? messageTtlSeconds}) {
  final normalized = (messageTtlSeconds != null && messageTtlSeconds > 0)
      ? messageTtlSeconds
      : null;
  return jsonEncode(<String, Object?>{
    'type': 'chat-settings',
    'v': 1,
    'messageTtlSeconds': normalized,
  });
}

/// Human-friendly label for a disappearing-message TTL.
String chatSettingsTtlLabel(int? ttlSeconds) {
  if (ttlSeconds == null || ttlSeconds <= 0) return 'Off';

  return switch (ttlSeconds) {
    300 => '5 minutes',
    3600 => '1 hour',
    86400 => '24 hours',
    604800 => '1 week',
    2592000 => '1 month',
    7776000 => '3 months',
    _ => () {
      const minute = 60;
      const hour = 60 * minute;
      const day = 24 * hour;
      if (ttlSeconds < minute) return '$ttlSeconds seconds';
      if (ttlSeconds < hour) return '${ttlSeconds ~/ minute} minutes';
      if (ttlSeconds < day) return '${ttlSeconds ~/ hour} hours';
      return '${ttlSeconds ~/ day} days';
    }(),
  };
}

/// User-facing text to show when disappearing-message settings changed.
String chatSettingsChangedNotice(int? ttlSeconds) {
  if (ttlSeconds == null || ttlSeconds <= 0) {
    return 'Disappearing messages turned off';
  }
  return 'Disappearing messages set to ${chatSettingsTtlLabel(ttlSeconds)}';
}
