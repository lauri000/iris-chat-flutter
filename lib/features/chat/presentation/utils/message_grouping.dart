import '../../domain/models/message.dart';

const Duration kMessageGroupingThreshold = Duration(minutes: 1);
const String _selfSenderKey = '__self__';
const String _peerSenderKey = '__peer__';

bool canGroupChatMessages(
  ChatMessage leading,
  ChatMessage trailing, {
  required bool isDirectMessage,
}) {
  if (_breaksMessageGroup(leading) || _breaksMessageGroup(trailing)) {
    return false;
  }

  if (!_isSameDay(leading.timestamp, trailing.timestamp)) {
    return false;
  }

  final leadingSenderKey = _senderKeyForGrouping(
    leading,
    isDirectMessage: isDirectMessage,
  );
  final trailingSenderKey = _senderKeyForGrouping(
    trailing,
    isDirectMessage: isDirectMessage,
  );
  if (leadingSenderKey == null || trailingSenderKey == null) {
    return false;
  }
  if (leadingSenderKey != trailingSenderKey) {
    return false;
  }

  final timeDiff = trailing.timestamp.difference(leading.timestamp);
  if (!timeDiff.isNegative && timeDiff <= kMessageGroupingThreshold) {
    return true;
  }

  if (!isDirectMessage) return false;

  final leadingMinuteBucket =
      leading.timestamp.millisecondsSinceEpoch ~/
      Duration.millisecondsPerMinute;
  final trailingMinuteBucket =
      trailing.timestamp.millisecondsSinceEpoch ~/
      Duration.millisecondsPerMinute;
  final minuteDiff = trailingMinuteBucket - leadingMinuteBucket;
  return minuteDiff >= 0 && minuteDiff <= 1;
}

String? _senderKeyForGrouping(
  ChatMessage message, {
  required bool isDirectMessage,
}) {
  if (message.isOutgoing) return _selfSenderKey;
  if (isDirectMessage) return _peerSenderKey;

  final senderPubkey = message.senderPubkeyHex?.trim().toLowerCase();
  if (senderPubkey == null || senderPubkey.isEmpty) return null;
  return senderPubkey;
}

bool _breaksMessageGroup(ChatMessage message) {
  final hasReply = message.replyToId?.trim().isNotEmpty ?? false;
  return hasReply || message.reactions.isNotEmpty;
}

bool _isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}
