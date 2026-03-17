import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ffi/ndr_ffi.dart';
import '../../core/services/error_service.dart';
import '../../core/services/nostr_service.dart';
import '../../core/utils/app_keys_event_fetch.dart';
import '../../features/auth/domain/repositories/auth_repository.dart';
import 'auth_provider.dart';
import 'nostr_provider.dart';

class DeviceManagerState {
  const DeviceManagerState({
    this.isLoading = true,
    this.isUpdating = false,
    this.devices = const [],
    this.currentDevicePubkeyHex,
    this.error,
  });

  final bool isLoading;
  final bool isUpdating;
  final List<FfiDeviceEntry> devices;
  final String? currentDevicePubkeyHex;
  final String? error;

  bool get isCurrentDeviceRegistered {
    final current = currentDevicePubkeyHex;
    if (current == null || current.isEmpty) return false;
    return devices.any((device) => device.identityPubkeyHex == current);
  }

  DeviceManagerState copyWith({
    bool? isLoading,
    bool? isUpdating,
    List<FfiDeviceEntry>? devices,
    String? currentDevicePubkeyHex,
    String? error,
    bool clearError = false,
  }) {
    return DeviceManagerState(
      isLoading: isLoading ?? this.isLoading,
      isUpdating: isUpdating ?? this.isUpdating,
      devices: devices ?? this.devices,
      currentDevicePubkeyHex:
          currentDevicePubkeyHex ?? this.currentDevicePubkeyHex,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class DeviceManagerNotifier extends StateNotifier<DeviceManagerState> {
  DeviceManagerNotifier(
    this._ref,
    this._nostrService,
    this._authRepository, {
    bool autoLoad = true,
  }) : super(const DeviceManagerState()) {
    if (autoLoad) {
      Future<void>.microtask(loadDevices);
    }
  }

  final Ref _ref;
  final NostrService _nostrService;
  final AuthRepository _authRepository;

  Future<void> loadDevices() async {
    final authState = _ref.read(authStateProvider);
    final ownerPubkeyHex = _normalizeHex(authState.pubkeyHex);
    final currentDevicePubkeyHex = _normalizeHex(authState.devicePubkeyHex);

    if (!authState.isAuthenticated || ownerPubkeyHex == null) {
      state = const DeviceManagerState(
        isLoading: false,
        isUpdating: false,
        devices: <FfiDeviceEntry>[],
      );
      return;
    }

    state = state.copyWith(
      isLoading: true,
      currentDevicePubkeyHex: currentDevicePubkeyHex,
      clearError: true,
    );

    try {
      final merged = await _loadLatestDevicesMap(ownerPubkeyHex);
      state = state.copyWith(
        isLoading: false,
        devices: _sortedDevices(merged, currentDevicePubkeyHex),
        currentDevicePubkeyHex: currentDevicePubkeyHex,
        clearError: true,
      );
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(isLoading: false, error: appError.message);
    }
  }

  Future<bool> registerCurrentDevice() async {
    final authState = _ref.read(authStateProvider);
    final ownerPubkeyHex = _normalizeHex(authState.pubkeyHex);
    if (!authState.isAuthenticated || ownerPubkeyHex == null) {
      state = state.copyWith(error: 'Not authenticated');
      return false;
    }
    if (!authState.hasOwnerKey) {
      state = state.copyWith(
        error: 'Linked devices cannot register other devices',
      );
      return false;
    }

    state = state.copyWith(isUpdating: true, clearError: true);
    try {
      final ownerPrivkeyHex = await _authRepository.getOwnerPrivateKey();
      if (ownerPrivkeyHex == null) {
        throw Exception('Private key not found');
      }

      final currentDevicePubkeyHex =
          _normalizeHex(authState.devicePubkeyHex) ??
          _normalizeHex(await NdrFfi.derivePublicKey(ownerPrivkeyHex));
      if (currentDevicePubkeyHex == null) {
        throw Exception('Current device key not found');
      }

      final merged = await _loadLatestDevicesMap(ownerPubkeyHex);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      merged.putIfAbsent(currentDevicePubkeyHex, () => now);

      await _publishDevices(
        ownerPubkeyHex: ownerPubkeyHex,
        ownerPrivkeyHex: ownerPrivkeyHex,
        devices: merged,
      );

      state = state.copyWith(
        isUpdating: false,
        devices: _sortedDevices(merged, currentDevicePubkeyHex),
        currentDevicePubkeyHex: currentDevicePubkeyHex,
        clearError: true,
      );
      return true;
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(isUpdating: false, error: appError.message);
      return false;
    }
  }

  Future<bool> deleteDevice(String identityPubkeyHex) async {
    final authState = _ref.read(authStateProvider);
    final ownerPubkeyHex = _normalizeHex(authState.pubkeyHex);
    if (!authState.isAuthenticated || ownerPubkeyHex == null) {
      state = state.copyWith(error: 'Not authenticated');
      return false;
    }
    if (!authState.hasOwnerKey) {
      state = state.copyWith(error: 'Linked devices cannot delete devices');
      return false;
    }

    final target = _normalizeHex(identityPubkeyHex);
    if (target == null) {
      state = state.copyWith(error: 'Invalid device key');
      return false;
    }

    state = state.copyWith(isUpdating: true, clearError: true);
    try {
      final ownerPrivkeyHex = await _authRepository.getOwnerPrivateKey();
      if (ownerPrivkeyHex == null) {
        throw Exception('Private key not found');
      }

      final merged = await _loadLatestDevicesMap(ownerPubkeyHex);
      merged.remove(target);

      await _publishDevices(
        ownerPubkeyHex: ownerPubkeyHex,
        ownerPrivkeyHex: ownerPrivkeyHex,
        devices: merged,
      );

      state = state.copyWith(
        isUpdating: false,
        devices: _sortedDevices(merged, state.currentDevicePubkeyHex),
        clearError: true,
      );
      return true;
    } catch (e, st) {
      final appError = AppError.from(e, st);
      state = state.copyWith(isUpdating: false, error: appError.message);
      return false;
    }
  }

  Future<Map<String, int>> _loadLatestDevicesMap(String ownerPubkeyHex) async {
    final fromState = <String, int>{
      for (final device in state.devices)
        _normalizeHex(device.identityPubkeyHex) ?? device.identityPubkeyHex:
            device.createdAt,
    };

    final latestDevices = await fetchLatestAppKeysDevices(
      _nostrService,
      ownerPubkeyHex: ownerPubkeyHex,
      subscriptionLabel: 'appkeys-settings',
    );
    if (latestDevices.isEmpty) return fromState;

    final merged = <String, int>{};
    for (final device in latestDevices) {
      final key = _normalizeHex(device.identityPubkeyHex);
      if (key == null) continue;
      merged[key] = device.createdAt;
    }

    return merged.isEmpty ? fromState : merged;
  }

  Future<void> _publishDevices({
    required String ownerPubkeyHex,
    required String ownerPrivkeyHex,
    required Map<String, int> devices,
  }) async {
    final eventJson = await NdrFfi.createSignedAppKeysEvent(
      ownerPubkeyHex: ownerPubkeyHex,
      ownerPrivkeyHex: ownerPrivkeyHex,
      devices: devices.entries
          .map(
            (entry) => FfiDeviceEntry(
              identityPubkeyHex: entry.key,
              createdAt: entry.value,
            ),
          )
          .toList(),
    );
    await _nostrService.publishEvent(eventJson);
  }

  List<FfiDeviceEntry> _sortedDevices(
    Map<String, int> deviceMap,
    String? currentDevicePubkeyHex,
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

  String? _normalizeHex(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return null;
    return normalized;
  }
}

final deviceManagerProvider =
    StateNotifierProvider<DeviceManagerNotifier, DeviceManagerState>((ref) {
      ref.watch(
        authStateProvider.select(
          (s) => (s.isAuthenticated, s.pubkeyHex, s.devicePubkeyHex),
        ),
      );
      final nostrService = ref.watch(nostrServiceProvider);
      final authRepository = ref.watch(authRepositoryProvider);
      return DeviceManagerNotifier(ref, nostrService, authRepository);
    });
