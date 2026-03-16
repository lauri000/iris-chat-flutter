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
      if (authState.isLoading) return;

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

    await ref.read(authStateProvider.notifier).login(key);
    final state = ref.read(authStateProvider);
    if (!state.isAuthenticated) return;

    if (!mounted) return;
    context.go('/chats');
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final theme = Theme.of(context);

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
                      onPressed: () {
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
                  onPressed: authState.isLoading ? null : _login,
                  child: authState.isLoading
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
                  onPressed: authState.isLoading ? null : _createIdentity,
                  icon: const Icon(Icons.add),
                  label: authState.isLoading
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
                  onPressed: authState.isLoading
                      ? null
                      : () => setState(() => _showKeyInput = true),
                  icon: const Icon(Icons.key),
                  label: const Text('Import Existing Key'),
                ),
                const SizedBox(height: 12),
                // Link device button (delegated device login)
                TextButton.icon(
                  onPressed: authState.isLoading
                      ? null
                      : () => context.push('/link'),
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
