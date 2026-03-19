import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../config/providers/auth_provider.dart';
import '../../../../config/providers/chat_provider.dart';
import '../../../../config/providers/hashtree_attachment_provider.dart';
import '../../../../core/utils/hashtree_attachments.dart';
import '../../../../shared/utils/formatters.dart';
import '../../../../shared/widgets/image_viewer_modal.dart';
import '../../domain/models/group.dart';
import '../../domain/models/session.dart';
import '../../domain/utils/chat_settings.dart';
import '../utils/attachment_upload.dart';
import '../utils/chats_layout.dart';
import '../widgets/chats_back_button.dart';
import '../widgets/group_avatar.dart';
import '../widgets/profile_name_text.dart';

class GroupInfoScreen extends ConsumerStatefulWidget {
  const GroupInfoScreen({super.key, required this.groupId});

  final String groupId;

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  final Set<String> _selectedToAdd = <String>{};
  bool _isUploadingPicture = false;
  static const _expirationOptions = <int>[
    5 * 60,
    60 * 60,
    24 * 60 * 60,
    7 * 24 * 60 * 60,
    30 * 24 * 60 * 60,
    90 * 24 * 60 * 60,
  ];

  bool _containsPubkey(List<String> pubkeys, String? target) {
    final normalized = target?.toLowerCase().trim();
    if (normalized == null || normalized.isEmpty) return false;
    for (final pubkey in pubkeys) {
      if (pubkey.toLowerCase().trim() == normalized) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Best-effort: navigation can happen before the list screen initializes.
      ref.read(groupStateProvider.notifier).loadGroups();
    });
  }

  Future<void> _showRenameDialog(ChatGroup group) async {
    var pendingName = group.name;

    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Group'),
        content: TextFormField(
          initialValue: group.name,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Group name',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => pendingName = value,
          onFieldSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(pendingName),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    final next = result?.trim();
    if (next == null || next.isEmpty) return;

    await ref
        .read(groupStateProvider.notifier)
        .renameGroup(widget.groupId, next);
    if (!mounted) return;

    final error = ref.read(groupStateProvider).error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _addSelectedMembers() async {
    final group = _findGroup(ref.read(groupStateProvider).groups);
    if (group == null) return;

    final toAdd = _selectedToAdd.toList();
    if (toAdd.isEmpty) return;

    await ref
        .read(groupStateProvider.notifier)
        .addGroupMembers(widget.groupId, toAdd);
    if (!mounted) return;

    setState(_selectedToAdd.clear);

    final error = ref.read(groupStateProvider).error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Added ${toAdd.length} member${toAdd.length == 1 ? '' : 's'}',
        ),
      ),
    );
  }

  Future<void> _confirmRemoveMember(
    ChatGroup group,
    String memberPubkeyHex,
  ) async {
    final short = formatPubkeyForDisplay(memberPubkeyHex);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Member'),
        content: Text('Remove $short from this group?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref
        .read(groupStateProvider.notifier)
        .removeGroupMember(widget.groupId, memberPubkeyHex);
    if (!mounted) return;

    final error = ref.read(groupStateProvider).error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _setGroupTtl(ChatGroup group, int? ttlSeconds) async {
    await ref
        .read(groupStateProvider.notifier)
        .setGroupMessageTtlSeconds(widget.groupId, ttlSeconds);
    if (!mounted) return;

    final error = ref.read(groupStateProvider).error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    final label = chatSettingsTtlLabel(ttlSeconds);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Disappearing messages: $label')));
  }

  Future<void> _setGroupPicture(ChatGroup group, String? picture) async {
    await ref
        .read(groupStateProvider.notifier)
        .setGroupPicture(widget.groupId, picture);
    if (!mounted) return;

    final error = ref.read(groupStateProvider).error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    final action = picture == null ? 'removed' : 'updated';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Group image $action')));
  }

  Future<void> _pickGroupPicture(ChatGroup group) async {
    if (_isUploadingPicture) return;

    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
        type: FileType.image,
      );
    } on MissingPluginException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Image picker is unavailable on this platform.'),
        ),
      );
      return;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open image picker: $e')),
      );
      return;
    }
    if (picked == null || picked.files.isEmpty) return;

    final pickedFile = picked.files.first;
    setState(() => _isUploadingPicture = true);
    try {
      final attachmentService = ref.read(hashtreeAttachmentServiceProvider);
      final prepared = await preparePickedAttachment(
        pickedFile: pickedFile,
        service: attachmentService,
      );
      await attachmentService.uploadPreparedAttachment(prepared);

      final pictureUri = 'nhash://${prepared.link}';
      await _setGroupPicture(group, pictureUri);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Group image upload failed: $e')));
    } finally {
      if (mounted) setState(() => _isUploadingPicture = false);
    }
  }

  bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
  }

  bool _canOpenGroupPicture(ChatGroup group) {
    final picture = group.picture?.trim();
    if (picture == null || picture.isEmpty) return false;

    final parsed = parseHashtreeFileLink(picture);
    if (parsed != null) {
      return isImageFilename(parsed.filename);
    }

    return _isHttpUrl(picture);
  }

  Future<void> _openGroupPicture(ChatGroup group) async {
    final picture = group.picture?.trim();
    if (picture == null || picture.isEmpty) return;

    final parsed = parseHashtreeFileLink(picture);
    if (parsed != null) {
      if (!isImageFilename(parsed.filename)) return;
      try {
        final bytes = await ref
            .read(hashtreeAttachmentServiceProvider)
            .downloadFile(link: parsed);
        if (!mounted) return;
        if (bytes.isEmpty) {
          throw Exception('empty image');
        }
        await showImageViewerModal(context, imageProvider: MemoryImage(bytes));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to open image: $e')));
      }
      return;
    }

    if (!_isHttpUrl(picture)) return;
    await showImageViewerModal(context, imageProvider: NetworkImage(picture));
  }

  ChatGroup? _findGroup(List<ChatGroup> groups) {
    for (final g in groups) {
      if (g.id == widget.groupId) return g;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(groupStateProvider.select((s) => s.groups));
    final group = _findGroup(groups);
    final useWideLayout = useChatsWideLayout(context);

    if (group == null) {
      return Scaffold(
        appBar: AppBar(
          leading: useWideLayout ? null : const ChatsBackButton(),
          automaticallyImplyLeading: false,
          title: const Text('Group Info'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final authState = ref.watch(authStateProvider);
    final myPubkeyHex = authState.pubkeyHex;
    final isAdmin = _containsPubkey(group.admins, myPubkeyHex);

    final sessions = ref.watch(sessionStateProvider.select((s) => s.sessions));
    final candidates =
        sessions
            .where((s) => !group.members.contains(s.recipientPubkeyHex))
            .toList()
          ..sort(
            (a, b) => a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            ),
          );

    final theme = Theme.of(context);
    final canOpenGroupPicture = _canOpenGroupPicture(group);

    return Scaffold(
      appBar: AppBar(
        leading: useWideLayout ? null : const ChatsBackButton(),
        automaticallyImplyLeading: false,
        title: const Text('Group Info'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      canOpenGroupPicture
                          ? InkResponse(
                              key: const ValueKey('group_info_avatar_button'),
                              onTap: () => _openGroupPicture(group),
                              radius: 34,
                              customBorder: const CircleBorder(),
                              child: GroupAvatar(
                                groupName: group.name,
                                picture: group.picture,
                                radius: 28,
                                backgroundColor:
                                    theme.colorScheme.secondaryContainer,
                                iconColor:
                                    theme.colorScheme.onSecondaryContainer,
                              ),
                            )
                          : GroupAvatar(
                              groupName: group.name,
                              picture: group.picture,
                              radius: 28,
                              backgroundColor:
                                  theme.colorScheme.secondaryContainer,
                              iconColor: theme.colorScheme.onSecondaryContainer,
                            ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Group Name',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              group.name,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (isAdmin) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () => _showRenameDialog(group),
                          icon: const Icon(Icons.drive_file_rename_outline),
                          label: const Text('Edit Name'),
                        ),
                        TextButton.icon(
                          onPressed: _isUploadingPicture
                              ? null
                              : () => _pickGroupPicture(group),
                          icon: _isUploadingPicture
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.photo_camera_outlined),
                          label: const Text('Change Photo'),
                        ),
                        if (group.picture != null &&
                            group.picture!.trim().isNotEmpty)
                          TextButton.icon(
                            onPressed: _isUploadingPicture
                                ? null
                                : () => _setGroupPicture(group, null),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Remove Photo'),
                          ),
                      ],
                    ),
                  ] else if (group.picture != null &&
                      group.picture!.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Group image is shared with members via encrypted metadata.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  _CopyRow(label: 'Group ID', value: group.id),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Members',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest,
            child: Column(
              children: [
                for (final pk in group.members)
                  _MemberTile(
                    pubkeyHex: pk,
                    myPubkeyHex: myPubkeyHex,
                    isAdmin: isAdmin,
                    isMemberAdmin: group.admins.contains(pk),
                    sessions: sessions,
                    onRemove: () => _confirmRemoveMember(group, pk),
                  ),
              ],
            ),
          ),
          if (isAdmin) ...[
            const SizedBox(height: 24),
            Text(
              'Add Members',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    if (candidates.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'No one else to add yet.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      for (final s in candidates)
                        CheckboxListTile(
                          value: _selectedToAdd.contains(s.recipientPubkeyHex),
                          onChanged: (v) {
                            setState(() {
                              if (v ?? false) {
                                _selectedToAdd.add(s.recipientPubkeyHex);
                              } else {
                                _selectedToAdd.remove(s.recipientPubkeyHex);
                              }
                            });
                          },
                          title: ProfileNameText(
                            pubkeyHex: s.recipientPubkeyHex,
                            fallbackName: s.displayName,
                          ),
                          dense: true,
                        ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _selectedToAdd.isEmpty
                            ? null
                            : _addSelectedMembers,
                        child: const Text('Add Selected'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            'Disappearing Messages',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  ListTile(
                    title: const Text('Current'),
                    trailing: Text(
                      chatSettingsTtlLabel(group.messageTtlSeconds),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _DisappearingOptionTile(
                    label: 'Off',
                    selected: group.messageTtlSeconds == null,
                    onTap: isAdmin ? () => _setGroupTtl(group, null) : null,
                  ),
                  for (final ttl in _expirationOptions)
                    _DisappearingOptionTile(
                      label: chatSettingsTtlLabel(ttl),
                      selected: group.messageTtlSeconds == ttl,
                      onTap: isAdmin ? () => _setGroupTtl(group, ttl) : null,
                    ),
                  if (!isAdmin)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Text(
                        'Only group admins can change this setting.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DisappearingOptionTile extends StatelessWidget {
  const _DisappearingOptionTile({
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      title: Text(label),
      dense: true,
      trailing: selected
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Copied')));
            }
          },
        ),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.pubkeyHex,
    required this.myPubkeyHex,
    required this.isAdmin,
    required this.isMemberAdmin,
    required this.sessions,
    required this.onRemove,
  });

  final String pubkeyHex;
  final String? myPubkeyHex;
  final bool isAdmin;
  final bool isMemberAdmin;
  final List<ChatSession> sessions;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalizedMe = myPubkeyHex?.toLowerCase().trim();
    final me =
        normalizedMe != null &&
        normalizedMe.isNotEmpty &&
        pubkeyHex.toLowerCase().trim() == normalizedMe;

    ChatSession? session;
    for (final s in sessions) {
      if (s.recipientPubkeyHex == pubkeyHex) {
        session = s;
        break;
      }
    }

    final title = me ? 'You' : (session?.displayName ?? 'Member');
    final subtitle = formatPubkeyForDisplay(pubkeyHex);

    return ListTile(
      title: Row(
        children: [
          Expanded(child: Text(title)),
          if (isMemberAdmin)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Admin',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: 'Copy pubkey',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: pubkeyHex));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Copied')));
              }
            },
          ),
          if (isAdmin && !me)
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              tooltip: 'Remove',
              color: theme.colorScheme.error,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
