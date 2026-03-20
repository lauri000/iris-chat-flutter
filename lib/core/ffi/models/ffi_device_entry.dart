/// FFI-friendly device entry for AppKeys.
///
/// Matches Rust `FfiDeviceEntry`.
class FfiDeviceEntry {
  const FfiDeviceEntry({
    required this.identityPubkeyHex,
    required this.createdAt,
    this.deviceLabel,
    this.clientLabel,
  });

  factory FfiDeviceEntry.fromMap(Map<String, dynamic> map) {
    return FfiDeviceEntry(
      identityPubkeyHex: map['identityPubkeyHex'] as String,
      createdAt: (map['createdAt'] as num).toInt(),
      deviceLabel: map['deviceLabel'] as String?,
      clientLabel: map['clientLabel'] as String?,
    );
  }

  /// Device identity public key (hex).
  final String identityPubkeyHex;

  /// Unix timestamp (seconds) when the device entry was created.
  final int createdAt;

  /// Owner-encrypted label for the specific device.
  final String? deviceLabel;

  /// Owner-encrypted label for the client/app.
  final String? clientLabel;

  Map<String, dynamic> toMap() {
    return {
      'identityPubkeyHex': identityPubkeyHex,
      'createdAt': createdAt,
      if (deviceLabel != null) 'deviceLabel': deviceLabel,
      if (clientLabel != null) 'clientLabel': clientLabel,
    };
  }

  FfiDeviceEntry copyWith({
    String? identityPubkeyHex,
    int? createdAt,
    String? deviceLabel,
    bool clearDeviceLabel = false,
    String? clientLabel,
    bool clearClientLabel = false,
  }) {
    return FfiDeviceEntry(
      identityPubkeyHex: identityPubkeyHex ?? this.identityPubkeyHex,
      createdAt: createdAt ?? this.createdAt,
      deviceLabel: clearDeviceLabel ? null : (deviceLabel ?? this.deviceLabel),
      clientLabel: clearClientLabel ? null : (clientLabel ?? this.clientLabel),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is FfiDeviceEntry &&
        other.identityPubkeyHex == identityPubkeyHex &&
        other.createdAt == createdAt &&
        other.deviceLabel == deviceLabel &&
        other.clientLabel == clientLabel;
  }

  @override
  int get hashCode => Object.hash(
    identityPubkeyHex,
    createdAt,
    deviceLabel,
    clientLabel,
  );
}
