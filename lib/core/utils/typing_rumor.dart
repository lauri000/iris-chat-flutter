import 'nostr_rumor.dart';

const int kTypingStopExpirationLeewaySeconds = 5;

const Set<String> _kTypingStopContents = {
  'false',
  'stop',
  'typing:false',
  'typing off',
  'typing_off',
  'typing:off',
};

bool isTypingStopRumor(
  NostrRumor rumor, {
  int? expiresAtSeconds,
  DateTime? now,
}) {
  final normalizedContent = rumor.content.trim().toLowerCase();
  if (_kTypingStopContents.contains(normalizedContent)) {
    return true;
  }

  final expiration =
      expiresAtSeconds ?? getExpirationTimestampSeconds(rumor.tags);
  if (expiration == null) return false;

  final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  if (expiration <= nowSeconds) return true;

  // Stop rumors are emitted with expiration ~= created_at; allow for skew.
  return expiration <= rumor.createdAt + kTypingStopExpirationLeewaySeconds;
}

bool isTypingTimestampStale({
  required int typingTimestampMs,
  required int? lastMessageTimestampMs,
}) {
  if (lastMessageTimestampMs == null) return false;
  return typingTimestampMs <= lastMessageTimestampMs;
}
