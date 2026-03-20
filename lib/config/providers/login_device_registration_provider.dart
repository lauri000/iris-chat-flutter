import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;

import '../../core/ffi/ndr_ffi.dart';
import '../../core/services/nostr_service.dart';
import '../../core/utils/app_keys_event_fetch.dart';
import '../../core/utils/device_labels.dart';
import '../../features/auth/domain/models/identity.dart';
import 'nostr_provider.dart';

const _invalidLoginPrivateKeyMessage = 'Invalid secret key format.';

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

  Future<void> registerDevice({
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
    final deviceKeypair = await NdrFfi.generateKeypair();
    final currentDevicePrivkeyHex = deviceKeypair.privateKeyHex
        .trim()
        .toLowerCase();
    final currentDevicePubkeyHex = deviceKeypair.publicKeyHex
        .trim()
        .toLowerCase();

    List<FfiDeviceEntry> existingDevices = const <FfiDeviceEntry>[];
    String? loadError;
    var loaded = false;

    try {
      existingDevices = await _loadLatestDevices(
        ownerPubkeyHex,
        ownerPrivkeyHex: ownerPrivkeyHex,
      );
      loaded = true;
    } catch (e) {
      loadError = e.toString();
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final projected = mergeDeviceEntries(
      existingDevices: existingDevices,
      ensuredDevices: [
        buildCurrentDeviceEntry(
          identityPubkeyHex: currentDevicePubkeyHex,
          createdAt: now,
        ),
      ],
    );

    return LoginDeviceRegistrationPreview(
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      currentDevicePrivkeyHex: currentDevicePrivkeyHex,
      currentDevicePubkeyHex: currentDevicePubkeyHex,
      existingDevices: _sortedDevices(existingDevices, currentDevicePubkeyHex),
      devicesIfRegistered: _sortedDevices(projected, currentDevicePubkeyHex),
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
        buildCurrentDeviceEntry(
          identityPubkeyHex: devicePubkeyHex,
          createdAt: now,
        ),
      ],
    );
  }

  @override
  Future<void> registerDevice({
    required String ownerPubkeyHex,
    required String ownerPrivkeyHex,
    required String devicePubkeyHex,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final merged = mergeDeviceEntries(
      existingDevices: await _loadLatestDevices(
        ownerPubkeyHex,
        ownerPrivkeyHex: ownerPrivkeyHex,
      ),
      ensuredDevices: [
        buildCurrentDeviceEntry(
          identityPubkeyHex: devicePubkeyHex,
          createdAt: now,
        ),
      ],
    );

    await publishDeviceList(
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      devices: _sortedDevices(merged, devicePubkeyHex),
    );
  }

  Future<List<FfiDeviceEntry>> _loadLatestDevices(
    String ownerPubkeyHex, {
    String? ownerPrivkeyHex,
  }) async {
    final latestDevices = await fetchLatestAppKeysDevices(
      _nostrService,
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      subscriptionLabel: 'appkeys-login',
    );
    return latestDevices.map(normalizeDeviceEntry).toList();
  }

  List<FfiDeviceEntry> _sortedDevices(
    List<FfiDeviceEntry> devices,
    String currentDevicePubkeyHex,
  ) {
    final sorted = devices.map(normalizeDeviceEntry).toList();

    sorted.sort((a, b) {
      if (a.createdAt != b.createdAt) {
        return b.createdAt.compareTo(a.createdAt);
      }
      return a.identityPubkeyHex.compareTo(b.identityPubkeyHex);
    });
    return sorted;
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
}

final loginDeviceRegistrationServiceProvider =
    Provider<LoginDeviceRegistrationService>((ref) {
      final nostrService = ref.watch(nostrServiceProvider);
      return LoginDeviceRegistrationServiceImpl(nostrService);
    });
