import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:url_launcher/url_launcher.dart';

import '../../../../config/providers/app_version_provider.dart';
import '../../../../config/providers/auth_provider.dart';
import '../../../../config/providers/chat_provider.dart';
import '../../../../config/providers/desktop_notification_provider.dart';
import '../../../../config/providers/device_manager_provider.dart';
import '../../../../config/providers/imgproxy_settings_provider.dart';
import '../../../../config/providers/invite_provider.dart';
import '../../../../config/providers/messaging_preferences_provider.dart';
import '../../../../config/providers/mobile_push_provider.dart';
import '../../../../config/providers/nostr_provider.dart';
import '../../../../config/providers/nostr_relay_settings_provider.dart';
import '../../../../config/providers/startup_launch_provider.dart';
import '../../../../core/services/imgproxy_service.dart';
import '../../../../core/services/nostr_relay_settings_service.dart';
import '../../../../core/services/profile_service.dart';
import '../../../../shared/utils/formatters.dart';
import '../../../../shared/widgets/image_viewer_modal.dart';
import '../../../chat/presentation/widgets/chats_back_button.dart';
import '../../../chat/presentation/widgets/profile_avatar.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    final deviceState = ref.watch(deviceManagerProvider);
    final canManageDevices = authState.hasOwnerKey;
    final startupLaunchState = ref.watch(startupLaunchProvider);
    final messagingPreferences = ref.watch(messagingPreferencesProvider);
    final imgproxySettings = ref.watch(imgproxySettingsProvider);
    final relaySettings = ref.watch(nostrRelaySettingsProvider);
    final relayConnectionStatus =
        ref.watch(nostrConnectionStatusProvider).valueOrNull ??
        const <String, bool>{};
    final desktopNotificationsSupported = ref.watch(
      desktopNotificationsSupportedProvider,
    );
    final mobilePushSupported = ref.watch(mobilePushSupportedProvider);
    final appVersion = ref.watch(appVersionProvider);
    ref.watch(profileUpdatesProvider);
    final profileService = ref.watch(profileServiceProvider);
    final ownProfile = authState.pubkeyHex == null
        ? null
        : profileService.getCachedProfile(authState.pubkeyHex!);
    final ownProfilePicture = ownProfile?.picture?.trim();
    final hasOwnProfilePicture =
        ownProfilePicture != null &&
        ownProfilePicture.isNotEmpty &&
        _isHttpUrl(ownProfilePicture);
    final imgproxyService = ImgproxyService(imgproxySettings.config);
    final ownProfileViewerUrl = hasOwnProfilePicture
        ? imgproxyService.proxiedUrl(ownProfilePicture)
        : null;
    final npub = authState.pubkeyHex != null
        ? formatPubkeyAsNpub(authState.pubkeyHex!)
        : null;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: const ChatsBackButton(),
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // Identity section
          const _SectionHeader(title: 'Identity'),
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Public Key'),
            subtitle: Text(
              npub != null ? formatPubkeyForDisplay(npub) : 'Not logged in',
            ),
            trailing: npub != null
                ? IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: npub));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied public key')),
                        );
                      }
                    },
                  )
                : null,
          ),
          if (authState.pubkeyHex != null)
            ListTile(
              leading:
                  hasOwnProfilePicture &&
                      ownProfileViewerUrl != null &&
                      authState.pubkeyHex != null
                  ? InkResponse(
                      key: const ValueKey('settings_profile_avatar_button'),
                      onTap: () => showImageViewerModal(
                        context,
                        imageProvider: NetworkImage(ownProfileViewerUrl),
                      ),
                      radius: 22,
                      customBorder: const CircleBorder(),
                      child: ProfileAvatar(
                        pubkeyHex: authState.pubkeyHex!,
                        displayName: ownProfile?.bestName ?? 'You',
                        pictureUrl: ownProfilePicture,
                        radius: 18,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        foregroundTextColor:
                            theme.colorScheme.onPrimaryContainer,
                      ),
                    )
                  : const Icon(Icons.badge),
              title: const Text('Profile'),
              subtitle: Text(
                !authState.hasOwnerKey
                    ? 'This device cannot edit the owner profile'
                    : _profileSummary(ownProfile),
              ),
              onTap: () => _showEditProfileDialog(
                context,
                ref,
                ownerPubkeyHex: authState.pubkeyHex!,
                hasOwnerKey: authState.hasOwnerKey,
              ),
            ),

          // Devices section
          const _SectionHeader(title: 'Devices'),
          ListTile(
            leading: const Icon(Icons.devices),
            title: const Text('Link a Device'),
            subtitle: Text(
              _deviceLinkSubtitle(canManageDevices: canManageDevices),
            ),
            onTap: canManageDevices ? () => context.push('/invite/scan') : null,
          ),
          if (!deviceState.isCurrentDeviceRegistered)
            ListTile(
              leading: const Icon(Icons.app_registration),
              title: const Text('Register This Device'),
              subtitle: Text(
                canManageDevices
                    ? 'Add this device to your encrypted messaging devices'
                    : 'Linked-device sessions cannot update the device list. Sign in here with your main Secret Key if you want to register this device.',
              ),
              onTap: deviceState.isUpdating
                  ? null
                  : canManageDevices
                  ? () => _registerCurrentDevice(context, ref)
                  : () => _showRegisterCurrentDeviceHelpDialog(context),
            ),
          if (!authState.hasOwnerKey)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Device Access'),
              subtitle: Text(
                _deviceAccessSubtitle(
                  isCurrentDeviceRegistered:
                      deviceState.isCurrentDeviceRegistered,
                ),
              ),
            ),
          if (deviceState.isLoading)
            const ListTile(
              leading: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Loading registered devices...'),
            ),
          if (!deviceState.isLoading && deviceState.devices.isEmpty)
            ListTile(
              leading: const Icon(Icons.devices_other),
              title: const Text('No registered devices yet'),
              subtitle: Text(
                canManageDevices
                    ? 'Register this device to enable multi-device sync'
                    : 'Registered devices will appear here in read-only mode',
              ),
            ),
          ...deviceState.devices.map((device) {
            final isCurrent =
                device.identityPubkeyHex == deviceState.currentDevicePubkeyHex;
            final addedAt = DateTime.fromMillisecondsSinceEpoch(
              device.createdAt * 1000,
            );
            return ListTile(
              leading: const Icon(Icons.computer),
              title: Text(
                formatPubkeyForDisplay(
                  formatPubkeyAsNpub(device.identityPubkeyHex),
                ),
              ),
              subtitle: Text(
                isCurrent
                    ? 'This device • Added ${formatDate(addedAt)}'
                    : 'Added ${formatDate(addedAt)}',
              ),
              trailing: canManageDevices
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: isCurrent
                          ? 'Remove this device'
                          : 'Delete device',
                      onPressed: deviceState.isUpdating
                          ? null
                          : () => _confirmDeleteDevice(
                              context,
                              ref,
                              identityPubkeyHex: device.identityPubkeyHex,
                              isCurrentDevice: isCurrent,
                            ),
                    )
                  : null,
            );
          }),
          if (deviceState.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                deviceState.error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),

          // Security section
          const _SectionHeader(title: 'Security'),
          ListTile(
            key: const ValueKey('settings_export_private_key'),
            leading: const Icon(Icons.key),
            title: Text(
              authState.isLinkedDevice
                  ? 'Export Device Key'
                  : 'Export Secret Key',
            ),
            subtitle: Text(
              authState.isLinkedDevice
                  ? 'Copy the key stored on this device'
                  : 'Backup your key securely',
            ),
            onTap: () => _showExportKeyDialog(context, ref),
          ),

          // Messaging section
          const _SectionHeader(title: 'Messaging'),
          SwitchListTile(
            secondary: const Icon(Icons.keyboard),
            title: const Text('Send Typing Indicators'),
            subtitle: const Text(
              'Share when you are actively typing in a conversation',
            ),
            value: messagingPreferences.typingIndicatorsEnabled,
            onChanged: messagingPreferences.isLoading
                ? null
                : (value) => ref
                      .read(messagingPreferencesProvider.notifier)
                      .setTypingIndicatorsEnabled(value),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.done_all),
            title: const Text('Send Delivery Receipts'),
            subtitle: const Text('Allow others to see when messages arrive'),
            value: messagingPreferences.deliveryReceiptsEnabled,
            onChanged: messagingPreferences.isLoading
                ? null
                : (value) => ref
                      .read(messagingPreferencesProvider.notifier)
                      .setDeliveryReceiptsEnabled(value),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility),
            title: const Text('Send Read Receipts'),
            subtitle: const Text('Allow others to see when you open messages'),
            value: messagingPreferences.readReceiptsEnabled,
            onChanged: messagingPreferences.isLoading
                ? null
                : (value) => ref
                      .read(messagingPreferencesProvider.notifier)
                      .setReadReceiptsEnabled(value),
          ),
          if (desktopNotificationsSupported)
            SwitchListTile(
              secondary: const Icon(Icons.notifications_active),
              title: const Text('Desktop Notifications'),
              subtitle: const Text(
                'Show incoming message and reaction alerts when app is unfocused',
              ),
              value: messagingPreferences.desktopNotificationsEnabled,
              onChanged: messagingPreferences.isLoading
                  ? null
                  : (value) => ref
                        .read(messagingPreferencesProvider.notifier)
                        .setDesktopNotificationsEnabled(value),
            ),
          if (mobilePushSupported)
            SwitchListTile(
              secondary: const Icon(Icons.phone_iphone),
              title: const Text('Mobile Push Notifications'),
              subtitle: const Text(
                'Register this device for server-delivered chat push alerts',
              ),
              value: messagingPreferences.mobilePushNotificationsEnabled,
              onChanged: messagingPreferences.isLoading
                  ? null
                  : (value) => ref
                        .read(messagingPreferencesProvider.notifier)
                        .setMobilePushNotificationsEnabled(value),
            ),
          if (messagingPreferences.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                messagingPreferences.error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),

          // Media section
          const _SectionHeader(title: 'Media'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'These settings are used when loading profile pictures.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('settings_imgproxy_enabled'),
            secondary: const Icon(Icons.image),
            title: const Text('Load Avatars via Image Proxy'),
            subtitle: const Text(
              'Route profile pictures through imgproxy before loading',
            ),
            value: imgproxySettings.enabled,
            onChanged: imgproxySettings.isLoading
                ? null
                : (value) => ref
                      .read(imgproxySettingsProvider.notifier)
                      .setEnabled(value),
          ),
          ListTile(
            key: const ValueKey('settings_imgproxy_url'),
            leading: const Icon(Icons.link),
            title: const Text('Image Proxy URL'),
            subtitle: Text(_ellipsizeMiddle(imgproxySettings.url)),
            onTap: imgproxySettings.isLoading
                ? null
                : () => _editImgproxyValue(
                    context,
                    ref,
                    title: 'Image Proxy URL',
                    initialValue: imgproxySettings.url,
                    hintText: ImgproxyConfig.defaultUrl,
                    onSave: (value) => ref
                        .read(imgproxySettingsProvider.notifier)
                        .setUrl(value),
                  ),
          ),
          ListTile(
            key: const ValueKey('settings_imgproxy_key'),
            leading: const Icon(Icons.key),
            title: const Text('Image Proxy Key'),
            subtitle: Text(_maskHex(imgproxySettings.keyHex)),
            onTap: imgproxySettings.isLoading
                ? null
                : () => _editImgproxyValue(
                    context,
                    ref,
                    title: 'Image Proxy Key (Hex)',
                    initialValue: imgproxySettings.keyHex,
                    hintText: ImgproxyConfig.defaultKeyHex,
                    onSave: (value) => ref
                        .read(imgproxySettingsProvider.notifier)
                        .setKeyHex(value),
                  ),
          ),
          ListTile(
            key: const ValueKey('settings_imgproxy_salt'),
            leading: const Icon(Icons.safety_check),
            title: const Text('Image Proxy Salt'),
            subtitle: Text(_maskHex(imgproxySettings.saltHex)),
            onTap: imgproxySettings.isLoading
                ? null
                : () => _editImgproxyValue(
                    context,
                    ref,
                    title: 'Image Proxy Salt (Hex)',
                    initialValue: imgproxySettings.saltHex,
                    hintText: ImgproxyConfig.defaultSaltHex,
                    onSave: (value) => ref
                        .read(imgproxySettingsProvider.notifier)
                        .setSaltHex(value),
                  ),
          ),
          ListTile(
            key: const ValueKey('settings_imgproxy_reset'),
            leading: const Icon(Icons.restore),
            title: const Text('Reset Image Proxy Defaults'),
            onTap: imgproxySettings.isLoading
                ? null
                : () => ref
                      .read(imgproxySettingsProvider.notifier)
                      .resetDefaults(),
          ),
          if (imgproxySettings.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                imgproxySettings.error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),

          // Application section
          if (startupLaunchState.isLoading || startupLaunchState.isSupported)
            const _SectionHeader(title: 'Application'),
          if (startupLaunchState.isLoading || startupLaunchState.isSupported)
            SwitchListTile(
              secondary: const Icon(Icons.power_settings_new),
              title: const Text('Launch on System Startup'),
              subtitle: Text(
                startupLaunchState.isLoading
                    ? 'Applying startup setting...'
                    : 'Automatically start iris chat when you log in',
              ),
              value: startupLaunchState.enabled,
              onChanged: startupLaunchState.isLoading
                  ? null
                  : (value) => ref
                        .read(startupLaunchProvider.notifier)
                        .setEnabled(value),
            ),
          if (startupLaunchState.error != null &&
              (startupLaunchState.isLoading || startupLaunchState.isSupported))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                startupLaunchState.error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),

          // Nostr relays section
          const _SectionHeader(title: 'Nostr Relays'),
          ListTile(
            leading: const Icon(Icons.add_link),
            title: const Text('Add Relay'),
            subtitle: const Text('Add a ws:// or wss:// relay endpoint'),
            onTap: relaySettings.isLoading
                ? null
                : () => _showAddRelayDialog(context, ref),
          ),
          if (relaySettings.isLoading)
            const ListTile(
              leading: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Updating relay settings...'),
            ),
          if (!relaySettings.isLoading)
            ...relaySettings.relays.map((relayUrl) {
              final canDelete = relaySettings.relays.length > 1;
              final isConnected = relayConnectionStatus[relayUrl];
              return ListTile(
                leading: const Icon(Icons.hub),
                title: Text(relayUrl),
                subtitle: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      key: ValueKey('relay-status-dot-$relayUrl'),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _relayStatusColor(isConnected),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_relayStatusLabel(isConnected)),
                  ],
                ),
                trailing: SizedBox(
                  width: 96,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        key: ValueKey('relay-edit-$relayUrl'),
                        icon: const Icon(Icons.edit),
                        tooltip: 'Edit relay',
                        onPressed: () =>
                            _showEditRelayDialog(context, ref, relayUrl),
                      ),
                      IconButton(
                        key: ValueKey('relay-delete-$relayUrl'),
                        icon: const Icon(Icons.delete_outline),
                        tooltip: canDelete
                            ? 'Delete relay'
                            : 'At least one relay is required',
                        onPressed: canDelete
                            ? () => _confirmDeleteRelay(context, ref, relayUrl)
                            : null,
                      ),
                    ],
                  ),
                ),
              );
            }),
          if (relaySettings.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                relaySettings.error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),

          // About section
          const _SectionHeader(title: 'About'),
          ListTile(
            leading: const Icon(Icons.info),
            title: const Text('Version'),
            subtitle: appVersion.when(
              data: Text.new,
              loading: () => const Text('Loading...'),
              error: (error, stackTrace) => const Text('Unknown'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('Source Code'),
            subtitle: const Text('github.com/irislib/iris-chat-flutter'),
            onTap: () =>
                _openUrl('https://github.com/irislib/iris-chat-flutter'),
          ),

          // Danger zone
          const _SectionHeader(title: 'Danger Zone'),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text(
              'Logout',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            subtitle: const Text('Remove local chats from this device'),
            onTap: () => _confirmLogout(context, ref),
          ),
          ListTile(
            leading: Icon(Icons.delete_forever, color: theme.colorScheme.error),
            title: Text(
              'Delete All Data',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            subtitle: const Text('Remove all data including keys'),
            onTap: () => _confirmDeleteAll(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _showExportKeyDialog(BuildContext context, WidgetRef ref) async {
    final authState = ref.read(authStateProvider);
    final dialogTitle = authState.isLinkedDevice
        ? 'Export Device Key'
        : 'Export Secret Key';
    final dialogContent = authState.isLinkedDevice
        ? 'This device stores its own device key, not your main Secret Key. Copy the device key from this device?'
        : 'Your secret key gives full access to your identity. Never share it with anyone. Make sure to store it securely.';
    final copyLabel = authState.isLinkedDevice ? 'Copy Device Key' : 'Copy';

    final shouldCopy = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(dialogTitle),
        content: Text(dialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(copyLabel),
          ),
        ],
      ),
    );

    if ((shouldCopy ?? false) && context.mounted) {
      final authRepo = ref.read(authRepositoryProvider);
      final privkey = await authRepo.getPrivateKey();

      if (privkey != null && context.mounted) {
        final exportableKey = _toExportableNsec(privkey);
        await Clipboard.setData(ClipboardData(text: exportableKey));
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
        }
      }
    }
  }

  String _toExportableNsec(String privateKey) {
    final normalized = privateKey.trim().toLowerCase();

    // Existing installs store the private key as 64-char hex. Convert to nsec
    // so exported keys can be re-imported through the nsec-only login flow.
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
      try {
        final encoded = nostr.Nip19.encodePrivkey(normalized);
        if (encoded is String && encoded.isNotEmpty) {
          return encoded;
        }
      } catch (_) {}
    }

    return privateKey;
  }

  bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
  }

  String _profileSummary(NostrProfile? profile) {
    if (profile == null) return 'No profile metadata published';

    final name = profile.bestName;
    final picture = profile.picture?.trim();
    final hasPicture = picture != null && picture.isNotEmpty;

    if (name != null && hasPicture) {
      return '$name • Picture set';
    }
    if (name != null) return name;
    if (hasPicture) return 'Picture set';
    return 'No profile metadata published';
  }

  String _deviceLinkSubtitle({required bool canManageDevices}) {
    if (canManageDevices) {
      return 'Scan a link invite from the new device';
    }
    return 'Only a session with your main Secret Key can link more devices';
  }

  String _deviceAccessSubtitle({required bool isCurrentDeviceRegistered}) {
    if (isCurrentDeviceRegistered) {
      return 'Read-only on this device. Use a session with your main Secret Key to add or remove devices.';
    }
    return 'This linked-device session is read-only and is not registered. Sign in here with your main Secret Key if you want to register this device.';
  }

  String _ellipsizeMiddle(String value, {int head = 22, int tail = 16}) {
    final normalized = value.trim();
    if (normalized.length <= head + tail + 3) {
      return normalized;
    }
    return '${normalized.substring(0, head)}...${normalized.substring(normalized.length - tail)}';
  }

  String _maskHex(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return '(empty)';
    return _ellipsizeMiddle(normalized, head: 10, tail: 8);
  }

  String _relayStatusLabel(bool? isConnected) {
    if (isConnected ?? false) return 'Connected';
    if (isConnected == false) return 'Disconnected';
    return 'Connecting';
  }

  Color _relayStatusColor(bool? isConnected) {
    if (isConnected ?? false) return Colors.green;
    if (isConnected == false) return Colors.grey;
    return Colors.orange;
  }

  Future<void> _editImgproxyValue(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String initialValue,
    required String hintText,
    required Future<void> Function(String value) onSave,
  }) async {
    final value = await _showEditableValueDialog(
      context,
      title: title,
      initialValue: initialValue,
      hintText: hintText,
    );
    if (value == null) return;

    await onSave(value);
    if (!context.mounted) return;
    final error = ref.read(imgproxySettingsProvider).error;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? '$title updated')));
  }

  Future<String?> _showEditableValueDialog(
    BuildContext context, {
    required String title,
    required String initialValue,
    required String hintText,
  }) async {
    final controller = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: hintText),
          maxLines: 2,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditProfileDialog(
    BuildContext context,
    WidgetRef ref, {
    required String ownerPubkeyHex,
    required bool hasOwnerKey,
  }) async {
    if (!hasOwnerKey) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Profile Editing'),
          content: const Text(
            'This device does not store your main Secret Key, so it cannot publish profile metadata for the owner key.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final profileService = ref.read(profileServiceProvider);
    var existingProfile = profileService.getCachedProfile(ownerPubkeyHex);
    if (existingProfile == null) {
      try {
        existingProfile = await profileService.getProfile(ownerPubkeyHex);
      } catch (_) {}
    }
    if (!context.mounted) return;

    final nameController = TextEditingController(
      text: existingProfile?.bestName ?? '',
    );
    final pictureController = TextEditingController(
      text: existingProfile?.picture?.trim() ?? '',
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit Profile'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Profile name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pictureController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Profile picture URL',
                  hintText: 'https://example.com/avatar.jpg',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final draft = await _prepareProfileMetadataSave(
                context,
                ref,
                name: nameController.text,
                pictureUrl: pictureController.text,
              );
              if (draft == null) return;
              if (!context.mounted) return;
              if (dialogContext.mounted) {
                Navigator.of(dialogContext, rootNavigator: true).pop();
              }
              unawaited(
                _saveProfileMetadata(
                  context,
                  ref,
                  ownerPubkeyHex: ownerPubkeyHex,
                  privkey: draft.privkey,
                  name: draft.name,
                  pictureUrl: draft.pictureUrl,
                  existingProfile: existingProfile,
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<({String privkey, String name, String pictureUrl})?>
  _prepareProfileMetadataSave(
    BuildContext context,
    WidgetRef ref, {
    required String name,
    required String pictureUrl,
  }) async {
    final authRepo = ref.read(authRepositoryProvider);
    final privkey = await authRepo.getOwnerPrivateKey();
    if (privkey == null || privkey.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Private key is unavailable')),
        );
      }
      return null;
    }

    final trimmedName = name.trim();
    final trimmedPicture = pictureUrl.trim();
    if (trimmedPicture.isNotEmpty) {
      final uri = Uri.tryParse(trimmedPicture);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile picture URL is invalid')),
          );
        }
        return null;
      }
    }

    return (privkey: privkey, name: trimmedName, pictureUrl: trimmedPicture);
  }

  Future<void> _saveProfileMetadata(
    BuildContext context,
    WidgetRef ref, {
    required String ownerPubkeyHex,
    required String privkey,
    required String name,
    required String pictureUrl,
    required NostrProfile? existingProfile,
  }) async {
    final trimmedName = name.trim();
    final trimmedPicture = pictureUrl.trim();

    final content = <String, dynamic>{};
    if (trimmedName.isNotEmpty) {
      content['name'] = trimmedName;
      content['display_name'] = trimmedName;
    }
    if (trimmedPicture.isNotEmpty) {
      content['picture'] = trimmedPicture;
    }
    final about = existingProfile?.about?.trim();
    if (about != null && about.isNotEmpty) {
      content['about'] = about;
    }
    final nip05 = existingProfile?.nip05?.trim();
    if (nip05 != null && nip05.isNotEmpty) {
      content['nip05'] = nip05;
    }

    try {
      final event = nostr.Event.from(
        kind: 0,
        tags: const [],
        content: jsonEncode(content),
        privkey: privkey,
        verify: false,
      );
      await ref
          .read(nostrServiceProvider)
          .publishEvent(jsonEncode(event.toJson()));
      ref
          .read(profileServiceProvider)
          .upsertProfile(
            pubkey: ownerPubkeyHex,
            name: trimmedName.isNotEmpty ? trimmedName : null,
            displayName: trimmedName.isNotEmpty ? trimmedName : null,
            picture: trimmedPicture.isNotEmpty ? trimmedPicture : null,
            about: about,
            nip05: nip05,
            updatedAt: DateTime.now(),
          );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Profile updated')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update profile: $e')));
      }
    }
  }

  Future<void> _registerCurrentDevice(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final ok = await ref
        .read(deviceManagerProvider.notifier)
        .registerCurrentDevice();
    if (!context.mounted) return;

    if (ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Device registered')));
      return;
    }

    final error = ref.read(deviceManagerProvider).error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'Failed to register device')),
    );
  }

  Future<void> _showRegisterCurrentDeviceHelpDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Register This Device'),
        content: const Text(
          'This linked-device session cannot update the device list. Sign out here and sign in again with your main Secret Key if you want this device to become your owner session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteDevice(
    BuildContext context,
    WidgetRef ref, {
    required String identityPubkeyHex,
    required bool isCurrentDevice,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isCurrentDevice ? 'Remove This Device?' : 'Delete Device?'),
        content: Text(
          isCurrentDevice
              ? 'This removes the current device from your authorized device list. '
                    'You can register it again later.'
              : 'This device will no longer be authorized for encrypted messaging.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(isCurrentDevice ? 'Remove' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final ok = await ref
        .read(deviceManagerProvider.notifier)
        .deleteDevice(identityPubkeyHex);
    if (!context.mounted) return;

    if (ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Device removed')));
      return;
    }

    final error = ref.read(deviceManagerProvider).error;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'Failed to remove device')));
  }

  Future<void> _showAddRelayDialog(BuildContext context, WidgetRef ref) async {
    final relayUrl = await _showRelayUrlDialog(
      context,
      title: 'Add Relay',
      actionLabel: 'Add',
    );
    if (relayUrl == null) return;

    await ref.read(nostrRelaySettingsProvider.notifier).addRelay(relayUrl);
    if (!context.mounted) return;
    _showRelayUpdateFeedback(context, ref, successMessage: 'Relay added');
  }

  Future<void> _showEditRelayDialog(
    BuildContext context,
    WidgetRef ref,
    String relayUrl,
  ) async {
    final updatedRelayUrl = await _showRelayUrlDialog(
      context,
      title: 'Edit Relay',
      actionLabel: 'Save',
      initialValue: relayUrl,
    );
    if (updatedRelayUrl == null) return;

    await ref
        .read(nostrRelaySettingsProvider.notifier)
        .updateRelay(relayUrl, updatedRelayUrl);
    if (!context.mounted) return;
    _showRelayUpdateFeedback(context, ref, successMessage: 'Relay updated');
  }

  Future<void> _confirmDeleteRelay(
    BuildContext context,
    WidgetRef ref,
    String relayUrl,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Relay?'),
        content: Text('Stop connecting to $relayUrl?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await ref.read(nostrRelaySettingsProvider.notifier).removeRelay(relayUrl);
    if (!context.mounted) return;
    _showRelayUpdateFeedback(context, ref, successMessage: 'Relay deleted');
  }

  Future<String?> _showRelayUrlDialog(
    BuildContext context, {
    required String title,
    required String actionLabel,
    String? initialValue,
  }) async {
    var currentValue = initialValue ?? '';
    String? validationError;

    final value = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(title),
            content: TextFormField(
              initialValue: currentValue,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: 'wss://relay.example.com',
                errorText: validationError,
              ),
              onChanged: (value) {
                currentValue = value;
                if (validationError != null) {
                  setState(() => validationError = null);
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: () {
                  FocusScope.of(context).unfocus();
                  Navigator.pop(context);
                },
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  FocusScope.of(context).unfocus();
                  final error = _relayUrlValidationError(currentValue);
                  if (error != null) {
                    setState(() => validationError = error);
                    return;
                  }

                  Navigator.pop(context, normalizeNostrRelayUrl(currentValue));
                },
                child: Text(actionLabel),
              ),
            ],
          );
        },
      ),
    );

    return value;
  }

  String? _relayUrlValidationError(String rawUrl) {
    try {
      normalizeNostrRelayUrl(rawUrl);
      return null;
    } on FormatException catch (e) {
      return e.message.toString();
    } catch (_) {
      return 'Invalid relay URL';
    }
  }

  void _showRelayUpdateFeedback(
    BuildContext context,
    WidgetRef ref, {
    required String successMessage,
  }) {
    final error = ref.read(nostrRelaySettingsProvider).error;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? successMessage)));
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout?'),
        content: const Text(
          'This signs you out and deletes local chats from this device. '
          'Keep your secret key to log back in later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await _runDestructiveSignOut(
        context,
        ref,
        container,
        failureMessage: 'Failed to finish logout cleanup.',
      );
    }
  }

  Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Data?'),
        content: const Text(
          'This will permanently delete your identity, messages, and all app data. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await _runDestructiveSignOut(
        context,
        ref,
        container,
        failureMessage: 'Failed to delete all local data.',
      );
    }
  }

  Future<void> _runDestructiveSignOut(
    BuildContext context,
    WidgetRef ref,
    ProviderContainer container, {
    required String failureMessage,
  }) async {
    final activeSessionManager = ref.exists(sessionManagerServiceProvider)
        ? container.read(sessionManagerServiceProvider)
        : null;

    try {
      await container.read(authStateProvider.notifier).logout();
      _invalidateChatProviders(container);
      await container
          .read(sessionManagerTeardownProvider)
          .disposeAndClear(activeSessionManager);
      await container.read(databaseServiceProvider).deleteDatabase();

      if (context.mounted) {
        context.go('/login');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failureMessage)));
      }
    }
  }

  void _invalidateChatProviders(ProviderContainer container) {
    container.invalidate(messageSubscriptionProvider);
    container.invalidate(sessionManagerServiceProvider);
    container.invalidate(sessionStateProvider);
    container.invalidate(chatStateProvider);
    container.invalidate(groupStateProvider);
    container.invalidate(inviteStateProvider);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
