import 'dart:io' show Platform;

import '../../shared/utils/formatters.dart';
import '../ffi/models/ffi_device_entry.dart';

const _genericClientLabel = 'Iris Chat';

String? _normalizeLabel(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _normalizePubkeyHex(String value) => value.trim().toLowerCase();

String _titleCaseWords(String value) {
  return value.replaceAllMapped(
    RegExp(r'\b\w'),
    (match) => match.group(0)!.toUpperCase(),
  );
}

String? _prettifyHostname(String value) {
  final normalized = _normalizeLabel(value)?.replaceAll(RegExp('[._-]+'), ' ');
  return normalized == null ? null : _titleCaseWords(normalized);
}

String _currentClientLabel() {
  switch (Platform.operatingSystem) {
    case 'android':
    case 'ios':
      return 'Iris Chat Mobile';
    case 'macos':
    case 'windows':
    case 'linux':
      return 'Iris Chat Desktop';
    default:
      return _genericClientLabel;
  }
}

String _currentDeviceLabel() {
  final host = _prettifyHostname(Platform.localHostname);
  if (host != null) return host;

  switch (Platform.operatingSystem) {
    case 'android':
      return 'Android device';
    case 'ios':
      return 'iPhone';
    case 'macos':
      return 'Mac';
    case 'windows':
      return 'Windows PC';
    case 'linux':
      return 'Linux machine';
    default:
      return 'This device';
  }
}

FfiDeviceEntry buildCurrentDeviceEntry({
  required String identityPubkeyHex,
  required int createdAt,
}) {
  return FfiDeviceEntry(
    identityPubkeyHex: _normalizePubkeyHex(identityPubkeyHex),
    createdAt: createdAt,
    deviceLabel: _currentDeviceLabel(),
    clientLabel: _currentClientLabel(),
  );
}

FfiDeviceEntry buildLinkedDeviceEntry({
  required String identityPubkeyHex,
  required int createdAt,
}) {
  return FfiDeviceEntry(
    identityPubkeyHex: _normalizePubkeyHex(identityPubkeyHex),
    createdAt: createdAt,
    deviceLabel: 'Linked device',
    clientLabel: _genericClientLabel,
  );
}

FfiDeviceEntry normalizeDeviceEntry(FfiDeviceEntry device) {
  return FfiDeviceEntry(
    identityPubkeyHex: _normalizePubkeyHex(device.identityPubkeyHex),
    createdAt: device.createdAt,
    deviceLabel: _normalizeLabel(device.deviceLabel),
    clientLabel: _normalizeLabel(device.clientLabel),
  );
}

FfiDeviceEntry _mergeDeviceEntry(
  FfiDeviceEntry current,
  FfiDeviceEntry incoming,
) {
  final normalizedCurrent = normalizeDeviceEntry(current);
  final normalizedIncoming = normalizeDeviceEntry(incoming);
  return FfiDeviceEntry(
    identityPubkeyHex: normalizedCurrent.identityPubkeyHex,
    createdAt:
        normalizedIncoming.createdAt > 0 &&
            (normalizedCurrent.createdAt == 0 ||
                normalizedIncoming.createdAt < normalizedCurrent.createdAt)
        ? normalizedIncoming.createdAt
        : normalizedCurrent.createdAt,
    deviceLabel:
        normalizedCurrent.deviceLabel ?? normalizedIncoming.deviceLabel,
    clientLabel:
        normalizedCurrent.clientLabel ?? normalizedIncoming.clientLabel,
  );
}

List<FfiDeviceEntry> mergeDeviceEntries({
  required Iterable<FfiDeviceEntry> existingDevices,
  Iterable<FfiDeviceEntry> ensuredDevices = const <FfiDeviceEntry>[],
}) {
  final merged = <String, FfiDeviceEntry>{};

  for (final device in existingDevices.followedBy(ensuredDevices)) {
    final normalized = normalizeDeviceEntry(device);
    final key = normalized.identityPubkeyHex;
    final previous = merged[key];
    merged[key] = previous == null
        ? normalized
        : _mergeDeviceEntry(previous, normalized);
  }

  return merged.values.toList();
}

String deviceDisplayTitle(FfiDeviceEntry device) {
  return _normalizeLabel(device.deviceLabel) ??
      _normalizeLabel(device.clientLabel) ??
      formatPubkeyForDisplay(formatPubkeyAsNpub(device.identityPubkeyHex));
}

String? deviceDisplaySubtitle(FfiDeviceEntry device) {
  final fallback = formatPubkeyForDisplay(
    formatPubkeyAsNpub(device.identityPubkeyHex),
  );
  final deviceLabel = _normalizeLabel(device.deviceLabel);
  final clientLabel = _normalizeLabel(device.clientLabel);

  if (deviceLabel != null) {
    return clientLabel != null ? '$clientLabel • $fallback' : fallback;
  }

  if (clientLabel != null) {
    return fallback;
  }

  return null;
}
