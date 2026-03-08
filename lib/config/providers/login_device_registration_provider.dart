import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;

import '../../core/ffi/ndr_ffi.dart';
import '../../core/services/nostr_service.dart';
import '../../core/utils/app_keys_event_fetch.dart';
import '../../features/auth/domain/models/identity.dart';
import 'nostr_provider.dart';

const _invalidLoginPrivateKeyMessage =
    'Invalid private key format. Expected nsec.';

class LoginDeviceRegistrationPreview {
  const LoginDeviceRegistrationPreview({
    required this.ownerPubkeyHex,
    required this.ownerPrivkeyHex,
    required this.currentDevicePrivkeyHex,
    required this.currentDevicePubkeyHex,
    required this.existingDevices,
    required this.devicesIfRegistered,
    required this.deviceListLoaded,
    this.deviceListLoadError,
  });

  final String ownerPubkeyHex;
  final String ownerPrivkeyHex;
  final String currentDevicePrivkeyHex;
  final String currentDevicePubkeyHex;
  final List<FfiDeviceEntry> existingDevices;
  final List<FfiDeviceEntry> devicesIfRegistered;
  final bool deviceListLoaded;
  final String? deviceListLoadError;

  bool get isCurrentDeviceRegistered {
    return existingDevices.any(
      (device) => device.identityPubkeyHex == currentDevicePubkeyHex,
    );
  }
}

abstract class LoginDeviceRegistrationService {
  Future<LoginDeviceRegistrationPreview> buildPreviewFromPrivateKeyNsec(
    String privateKeyNsec,
  );

  Future<void> publishDeviceList({
    required String ownerPubkeyHex,
    required String ownerPrivkeyHex,
    required List<FfiDeviceEntry> devices,
  });

  Future<void> publishSingleDevice({
    required String ownerPubkeyHex,
    required String ownerPrivkeyHex,
    required String devicePubkeyHex,
  });
}

class LoginDeviceRegistrationServiceImpl
    implements LoginDeviceRegistrationService {
  LoginDeviceRegistrationServiceImpl(this._nostrService);

  final NostrService _nostrService;

  @override
  Future<LoginDeviceRegistrationPreview> buildPreviewFromPrivateKeyNsec(
    String privateKeyNsec,
  ) async {
    final ownerPrivkeyHex = _normalizePrivateKeyNsec(privateKeyNsec);
    final ownerPubkeyHex = (await NdrFfi.derivePublicKey(
      ownerPrivkeyHex,
    )).trim().toLowerCase();
    final currentDevicePrivkeyHex = ownerPrivkeyHex;
    final currentDevicePubkeyHex = ownerPubkeyHex;

    Map<String, int> existingMap = <String, int>{};
    String? loadError;
    var loaded = false;

    try {
      existingMap = await _loadLatestDevicesMap(ownerPubkeyHex);
      loaded = true;
    } catch (e) {
      loadError = e.toString();
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final withCurrent = <String, int>{...existingMap};
    withCurrent.putIfAbsent(currentDevicePubkeyHex, () => now);

    final existing = _sortedDevices(existingMap, currentDevicePubkeyHex);
    final projected = _sortedDevices(withCurrent, currentDevicePubkeyHex);

    return LoginDeviceRegistrationPreview(
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      currentDevicePrivkeyHex: currentDevicePrivkeyHex,
      currentDevicePubkeyHex: currentDevicePubkeyHex,
      existingDevices: existing,
      devicesIfRegistered: projected,
      deviceListLoaded: loaded,
      deviceListLoadError: loadError,
    );
  }

  @override
  Future<void> publishDeviceList({
    required String ownerPubkeyHex,
    required String ownerPrivkeyHex,
    required List<FfiDeviceEntry> devices,
  }) async {
    final eventJson = await NdrFfi.createSignedAppKeysEvent(
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      devices: devices,
    );
    await _nostrService.publishEvent(eventJson);
  }

  @override
  Future<void> publishSingleDevice({
    required String ownerPubkeyHex,
    required String ownerPrivkeyHex,
    required String devicePubkeyHex,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await publishDeviceList(
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      devices: [
        FfiDeviceEntry(identityPubkeyHex: devicePubkeyHex, createdAt: now),
      ],
    );
  }

  Future<Map<String, int>> _loadLatestDevicesMap(String ownerPubkeyHex) async {
    final latest = await fetchLatestAppKeysEvent(
      _nostrService,
      ownerPubkeyHex: ownerPubkeyHex,
      subscriptionLabel: 'appkeys-login',
    );
    if (latest == null) return <String, int>{};

    final parsed = await NdrFfi.parseAppKeysEvent(jsonEncode(latest.toJson()));
    final merged = <String, int>{};
    for (final device in parsed) {
      final key = _normalizeHex(device.identityPubkeyHex);
      if (key == null) continue;
      merged[key] = device.createdAt;
    }
    return merged;
  }

  List<FfiDeviceEntry> _sortedDevices(
    Map<String, int> deviceMap,
    String currentDevicePubkeyHex,
  ) {
    final current = _normalizeHex(currentDevicePubkeyHex);
    final devices = deviceMap.entries
        .map(
          (entry) => FfiDeviceEntry(
            identityPubkeyHex: entry.key,
            createdAt: entry.value,
          ),
        )
        .toList();

    devices.sort((a, b) {
      final aCurrent = current != null && a.identityPubkeyHex == current;
      final bCurrent = current != null && b.identityPubkeyHex == current;
      if (aCurrent != bCurrent) return aCurrent ? -1 : 1;

      if (a.createdAt != b.createdAt) {
        return b.createdAt.compareTo(a.createdAt);
      }
      return a.identityPubkeyHex.compareTo(b.identityPubkeyHex);
    });
    return devices;
  }

  String _normalizePrivateKeyNsec(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const InvalidKeyException(_invalidLoginPrivateKeyMessage);
    }

    var candidate = trimmed;
    if (candidate.toLowerCase().startsWith('nostr:')) {
      candidate = candidate.substring('nostr:'.length).trim();
    }

    final nsecMatch = RegExp(
      'nsec1[0-9a-z]+',
      caseSensitive: false,
    ).firstMatch(candidate);
    final nsecCandidate = nsecMatch?.group(0);
    if (nsecCandidate != null && nsecCandidate.isNotEmpty) {
      try {
        final decoded = nostr.Nip19.decodePrivkey(
          nsecCandidate,
        ).trim().toLowerCase();
        if (_isValidPrivateKey(decoded)) {
          return decoded;
        }
      } catch (_) {}
      throw const InvalidKeyException(_invalidLoginPrivateKeyMessage);
    }

    throw const InvalidKeyException(_invalidLoginPrivateKeyMessage);
  }

  bool _isValidPrivateKey(String hex) {
    if (hex.length != 64) return false;
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex);
  }

  String? _normalizeHex(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    return normalized;
  }
}

final loginDeviceRegistrationServiceProvider =
    Provider<LoginDeviceRegistrationService>((ref) {
      final nostrService = ref.watch(nostrServiceProvider);
      return LoginDeviceRegistrationServiceImpl(nostrService);
    });
