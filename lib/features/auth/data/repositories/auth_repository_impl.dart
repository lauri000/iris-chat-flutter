import 'package:nostr/nostr.dart' as nostr;

import '../../../../core/ffi/ndr_ffi.dart';
import '../../../../core/services/secure_storage_service.dart';
import '../../domain/models/identity.dart';
import '../../domain/repositories/auth_repository.dart';

const _invalidLoginPrivateKeyMessage = 'Invalid secret key format.';
const _invalidDevicePrivateKeyMessage = 'Invalid device private key format.';

/// Implementation of [AuthRepository] using ndr-ffi and secure storage.
class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl(this._storage);

  final SecureStorageService _storage;

  @override
  Future<Identity> createIdentity() async {
    // Generate new keypair using ndr-ffi
    final keypair = await NdrFfi.generateKeypair();

    // Store keys securely (single-item identity to avoid multiple Keychain prompts).
    await _storage.saveIdentity(
      privkeyHex: keypair.privateKeyHex,
      pubkeyHex: keypair.publicKeyHex,
      ownerPrivkeyHex: keypair.privateKeyHex,
    );

    return Identity(pubkeyHex: keypair.publicKeyHex, createdAt: DateTime.now());
  }

  @override
  Future<Identity> login(
    String privateKeyNsec, {
    String? devicePrivkeyHex,
  }) async {
    final ownerPrivkeyHex = _normalizePrivateKeyNsec(privateKeyNsec);
    final ownerPubkeyHex = await _derivePublicKey(ownerPrivkeyHex);

    final normalizedDevicePrivkeyHex = await _resolveDevicePrivateKeyHex(
      devicePrivkeyHex,
    );
    if (!_isValidPrivateKey(normalizedDevicePrivkeyHex)) {
      throw const InvalidKeyException(_invalidDevicePrivateKeyMessage);
    }

    // Validate that the selected device private key can derive a pubkey.
    await _derivePublicKey(normalizedDevicePrivkeyHex);

    // Store the session private key linked to the owner identity pubkey.
    await _storage.saveIdentity(
      privkeyHex: normalizedDevicePrivkeyHex,
      pubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
    );

    return Identity(pubkeyHex: ownerPubkeyHex, createdAt: DateTime.now());
  }

  @override
  Future<Identity> loginLinkedDevice({
    required String ownerPubkeyHex,
    required String devicePrivkeyHex,
  }) async {
    // Validate key formats
    if (!_isValidPrivateKey(devicePrivkeyHex)) {
      throw const InvalidKeyException('Invalid private key format');
    }
    if (!_isValidHexKey(ownerPubkeyHex)) {
      throw const InvalidKeyException('Invalid public key format');
    }

    // Derive device pubkey to ensure the private key is usable.
    await _derivePublicKey(devicePrivkeyHex);

    // Store device private key + owner public key.
    await _storage.saveIdentity(
      privkeyHex: devicePrivkeyHex,
      pubkeyHex: ownerPubkeyHex,
    );

    return Identity(pubkeyHex: ownerPubkeyHex, createdAt: DateTime.now());
  }

  @override
  Future<Identity?> getCurrentIdentity() async {
    final pubkeyHex = await _storage.getPublicKey();
    if (pubkeyHex == null) return null;

    return Identity(pubkeyHex: pubkeyHex);
  }

  @override
  Future<bool> hasIdentity() async {
    return _storage.hasIdentity();
  }

  @override
  Future<void> logout() async {
    // Wipe all secure-storage entries to avoid stale identity rehydration from
    // legacy keys or platform-specific duplicated records.
    await _storage.deleteAll();
  }

  @override
  Future<String?> getPrivateKey() async {
    return _storage.getPrivateKey();
  }

  @override
  Future<String?> getOwnerPrivateKey() async {
    final explicitOwnerPrivkeyHex = await _storage.getOwnerPrivateKey();
    if (explicitOwnerPrivkeyHex != null && explicitOwnerPrivkeyHex.isNotEmpty) {
      return explicitOwnerPrivkeyHex;
    }

    final devicePrivkeyHex = await _storage.getPrivateKey();
    final ownerPubkeyHex = await _storage.getPublicKey();
    if (devicePrivkeyHex == null || ownerPubkeyHex == null) return null;

    try {
      final derivedDevicePubkeyHex = await _derivePublicKey(devicePrivkeyHex);
      if (derivedDevicePubkeyHex.trim().toLowerCase() ==
          ownerPubkeyHex.trim().toLowerCase()) {
        return devicePrivkeyHex;
      }
    } catch (_) {}

    return null;
  }

  @override
  Future<String?> getDevicePubkeyHex() async {
    final privkeyHex = await _storage.getPrivateKey();
    if (privkeyHex == null) return null;
    try {
      return await _derivePublicKey(privkeyHex);
    } catch (_) {
      return null;
    }
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
      } catch (_) {
        // Ignore and throw a consistent InvalidKeyException below.
      }
      throw const InvalidKeyException(_invalidLoginPrivateKeyMessage);
    }

    throw const InvalidKeyException(_invalidLoginPrivateKeyMessage);
  }

  bool _isValidPrivateKey(String hex) {
    if (hex.length != 64) return false;
    return _isValidHexKey(hex);
  }

  bool _isValidHexKey(String hex) {
    if (hex.length != 64) return false;
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex);
  }

  Future<String> _resolveDevicePrivateKeyHex(String? devicePrivkeyHex) async {
    if (devicePrivkeyHex != null) {
      return devicePrivkeyHex.trim().toLowerCase();
    }

    final generated = await NdrFfi.generateKeypair();
    return generated.privateKeyHex.trim().toLowerCase();
  }

  Future<String> _derivePublicKey(String privkeyHex) async {
    return NdrFfi.derivePublicKey(privkeyHex);
  }
}
