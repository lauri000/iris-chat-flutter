import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nostr/nostr.dart' as nostr;

import '../../../../config/providers/auth_provider.dart';
import '../../../../config/providers/chat_provider.dart';
import '../../../../config/providers/invite_provider.dart';
import '../../../../config/providers/login_device_registration_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _keyController = TextEditingController();
  bool _showKeyInput = false;
  bool _isProcessingNsecLogin = false;
  Timer? _autoLoginDebounce;
  String? _lastAutoSubmittedNsec;

  @override
  void dispose() {
    _autoLoginDebounce?.cancel();
    _keyController.dispose();
    super.dispose();
  }

  String? _extractValidNsecCandidate(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    var candidate = trimmed;
    if (candidate.toLowerCase().startsWith('nostr:')) {
      candidate = candidate.substring('nostr:'.length).trim();
    }

    final nsecMatch = RegExp(
      'nsec1[0-9a-z]+',
      caseSensitive: false,
    ).firstMatch(candidate);
    final nsecCandidate = nsecMatch?.group(0);
    if (nsecCandidate == null || nsecCandidate.isEmpty) return null;

    try {
      final decoded = nostr.Nip19.decodePrivkey(nsecCandidate);
      if (decoded.trim().length == 64) {
        return nsecCandidate;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void _maybeAutoSubmitLogin(String rawInput) {
    if (!_showKeyInput) return;

    final nsecCandidate = _extractValidNsecCandidate(rawInput);
    if (nsecCandidate == null) {
      _lastAutoSubmittedNsec = null;
      _autoLoginDebounce?.cancel();
      return;
    }

    if (_lastAutoSubmittedNsec == nsecCandidate) return;

    _autoLoginDebounce?.cancel();
    _autoLoginDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || !_showKeyInput) return;

      final authState = ref.read(authStateProvider);
      if (authState.isLoading || _isProcessingNsecLogin) return;

      final latestCandidate = _extractValidNsecCandidate(_keyController.text);
      if (latestCandidate == null || latestCandidate != nsecCandidate) return;

      _lastAutoSubmittedNsec = nsecCandidate;
      unawaited(_login());
    });
  }

  Future<void> _createIdentity() async {
    // "Create new identity" must start from a clean local state so we don't
    // leak prior-account chats into a brand new account.
    await ref.read(databaseServiceProvider).deleteDatabase();
    ref.invalidate(sessionStateProvider);
    ref.invalidate(chatStateProvider);
    ref.invalidate(groupStateProvider);
    ref.invalidate(inviteStateProvider);

    await ref.read(authStateProvider.notifier).createIdentity();
    final state = ref.read(authStateProvider);
    if (!state.isAuthenticated) return;

    await _autoRegisterCurrentDeviceForNewIdentity();
    await _ensureSignupInviteLink();
    if (!mounted) return;
    context.go('/chats');
  }

  Future<void> _ensureSignupInviteLink() async {
    try {
      await ref
          .read(inviteStateProvider.notifier)
          .ensurePublishedPublicInvite()
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      // Non-blocking: signup should succeed even if invite publish/storage fails.
    }
  }

  Future<void> _autoRegisterCurrentDeviceForNewIdentity() async {
    final authState = ref.read(authStateProvider);
    final ownerPubkeyHex = authState.pubkeyHex;
    if (ownerPubkeyHex == null) return;

    final ownerPrivkeyHex = await ref
        .read(authRepositoryProvider)
        .getOwnerPrivateKey();
    if (ownerPrivkeyHex == null) return;

    try {
      await ref
          .read(loginDeviceRegistrationServiceProvider)
          .publishSingleDevice(
            ownerPubkeyHex: ownerPubkeyHex,
            ownerPrivkeyHex: ownerPrivkeyHex,
            devicePubkeyHex: ownerPubkeyHex,
          );
    } catch (_) {
      // Non-blocking: account creation should still complete even if relay
      // publishing fails.
    }
  }

  Future<void> _login() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;

    final nsecCandidate = _extractValidNsecCandidate(key);
    if (nsecCandidate == null) {
      await ref.read(authStateProvider.notifier).login(key);
      final state = ref.read(authStateProvider);
      if (!state.isAuthenticated || !mounted) return;
      context.go('/chats');
      return;
    }

    if (_isProcessingNsecLogin) return;
    _autoLoginDebounce?.cancel();
    _lastAutoSubmittedNsec = nsecCandidate;
    setState(() {
      _isProcessingNsecLogin = true;
    });

    try {
      final registrationService = ref.read(
        loginDeviceRegistrationServiceProvider,
      );
      final preview = await registrationService.buildPreviewFromPrivateKeyNsec(
        nsecCandidate,
      );

      await ref
          .read(authStateProvider.notifier)
          .login(
            nsecCandidate,
            devicePrivkeyHex: preview.currentDevicePrivkeyHex,
          );

      final state = ref.read(authStateProvider);
      if (!state.isAuthenticated || !mounted) return;

      setState(() {
        _isProcessingNsecLogin = false;
      });
      await _showRegisterCurrentDeviceDialog(preview);
      if (!mounted) return;
      context.go('/chats');
    } finally {
      if (mounted && _isProcessingNsecLogin) {
        setState(() {
          _isProcessingNsecLogin = false;
        });
      }
    }
  }

  Future<void> _showRegisterCurrentDeviceDialog(
    LoginDeviceRegistrationPreview preview,
  ) async {
    if (!mounted) return;

    final registrationService = ref.read(
      loginDeviceRegistrationServiceProvider,
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var isRegistering = false;
        String? registrationError;

        Future<void> registerDevice(StateSetter setState) async {
          setState(() {
            isRegistering = true;
            registrationError = null;
          });
          try {
            await registrationService.registerDevice(
              ownerPubkeyHex: preview.ownerPubkeyHex,
              ownerPrivkeyHex: preview.ownerPrivkeyHex,
              devicePubkeyHex: preview.currentDevicePubkeyHex,
            );
            if (dialogContext.mounted) {
              Navigator.of(dialogContext).pop();
            }
          } catch (error) {
            setState(() {
              isRegistering = false;
              registrationError = error.toString();
            });
          }
        }

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Register This Device?'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This sign-in created a fresh device key. Register it now so this device can receive private messages from your other devices and from other people.',
                      ),
                      const SizedBox(height: 16),
                      _buildRegistrationStatusBanner(preview),
                      if (registrationError != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          registrationError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      if (preview.deviceListLoaded &&
                          preview.existingDevices.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Previously active devices',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        ...preview.existingDevices.map(
                          (device) => _DeviceListRow(
                            label: _deviceLabel(device.identityPubkeyHex),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        'Active devices after registering this one',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      ...preview.devicesIfRegistered.map(
                        (device) => _DeviceListRow(
                          label: _deviceLabel(device.identityPubkeyHex),
                          isCurrentDevice:
                              device.identityPubkeyHex ==
                              preview.currentDevicePubkeyHex,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isRegistering
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Skip for now'),
                ),
                FilledButton(
                  onPressed: isRegistering
                      ? null
                      : () => registerDevice(setState),
                  child: isRegistering
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Register Device'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildRegistrationStatusBanner(
    LoginDeviceRegistrationPreview preview,
  ) {
    if (!preview.deviceListLoaded) {
      return Text(
        'Previous devices could not be loaded from your relays. You can still register this device now.',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }

    if (preview.existingDevices.isEmpty) {
      return Text(
        'No previous devices were found. Registering now will publish this device as the first active device for this account.',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }

    final count = preview.existingDevices.length;
    final noun = count == 1 ? 'device' : 'devices';
    return Text('Found $count previously active $noun on your relays.');
  }

  String _deviceLabel(String pubkeyHex) {
    final normalized = pubkeyHex.trim();
    if (normalized.length <= 20) return normalized;
    return '${normalized.substring(0, 12)}...${normalized.substring(normalized.length - 8)}';
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final theme = Theme.of(context);
    final isBusy = authState.isLoading || _isProcessingNsecLogin;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              // Logo/Title
              Image.asset('assets/icons/app_icon.png', width: 100, height: 100),
              const SizedBox(height: 24),
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: theme.textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  children: [
                    TextSpan(
                      text: 'iris',
                      style: TextStyle(color: theme.colorScheme.primary),
                    ),
                    const TextSpan(text: ' chat'),
                  ],
                ),
              ),
              const SizedBox(height: 48),

              // Error message
              if (authState.error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    authState.error!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Key input (if showing)
              if (_showKeyInput) ...[
                TextField(
                  controller: _keyController,
                  decoration: InputDecoration(
                    labelText: 'Private Key (nsec)',
                    hintText: 'Enter your private key',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: isBusy
                          ? null
                          : () {
                              setState(() {
                                _showKeyInput = false;
                                _keyController.clear();
                                _lastAutoSubmittedNsec = null;
                              });
                              ref.read(authStateProvider.notifier).clearError();
                            },
                    ),
                  ),
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: _maybeAutoSubmitLogin,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: isBusy ? null : _login,
                  child: isBusy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Login'),
                ),
              ] else ...[
                // Create new identity button
                FilledButton.icon(
                  onPressed: isBusy ? null : _createIdentity,
                  icon: const Icon(Icons.add),
                  label: isBusy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create New Identity'),
                ),
                const SizedBox(height: 12),
                // Import existing key button
                OutlinedButton.icon(
                  onPressed: isBusy
                      ? null
                      : () => setState(() => _showKeyInput = true),
                  icon: const Icon(Icons.key),
                  label: const Text('Import Existing Key'),
                ),
                const SizedBox(height: 12),
                // Link device button (delegated device login)
                TextButton.icon(
                  onPressed: isBusy ? null : () => context.push('/link'),
                  icon: const Icon(Icons.devices),
                  label: const Text('Link This Device'),
                ),
              ],
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceListRow extends StatelessWidget {
  const _DeviceListRow({required this.label, this.isCurrentDevice = false});

  final String label;
  final bool isCurrentDevice;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isCurrentDevice ? Icons.smartphone : Icons.devices_outlined,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(isCurrentDevice ? '$label (This device)' : label),
          ),
        ],
      ),
    );
  }
}
