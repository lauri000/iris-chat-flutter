import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../config/providers/hashtree_attachment_provider.dart';
import '../../../../core/utils/hashtree_attachments.dart';
import '../../../../shared/utils/formatters.dart';
import '../../../../shared/widgets/image_viewer_modal.dart';
import '../../domain/models/message.dart';

enum _MessageMenuAction { copy, deleteLocal }

class ChatMessageBubble extends ConsumerStatefulWidget {
  const ChatMessageBubble({
    super.key,
    required this.message,
    required this.onReact,
    required this.onDeleteLocal,
    this.onReply,
    this.senderLabel,
    this.replyToMessage,
    this.onOpenReply,
    this.onMediaLayoutChanged,
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
  });

  final ChatMessage message;

  /// Called when the user selects an emoji to react with.
  final Future<void> Function(String emoji) onReact;

  /// Delete this message from local storage only.
  final Future<void> Function() onDeleteLocal;

  /// Optional "reply" action. (UI-level reply/quote is implemented by the screen.)
  final VoidCallback? onReply;

  /// Optional sender label for group messages (shown only for incoming messages).
  final String? senderLabel;
  final ChatMessage? replyToMessage;
  final VoidCallback? onOpenReply;

  /// Called when media content resolves and may change message layout height.
  final VoidCallback? onMediaLayoutChanged;
  final bool isFirstInGroup;
  final bool isLastInGroup;

  @override
  ConsumerState<ChatMessageBubble> createState() => _ChatMessageBubbleState();
}

class _ChatMessageBubbleState extends ConsumerState<ChatMessageBubble> {
  bool _isHovering = false;
  bool _isHoveringDock = false;
  Timer? _hoverHideTimer;
  final Map<String, Uint8List> _attachmentCache = {};
  final Map<String, Future<Uint8List>> _attachmentFutureCache = {};
  final Set<String> _notifiedMediaLayout = <String>{};
  final List<TapGestureRecognizer> _linkRecognizers = [];

  static const _quickEmojis = ['❤️', '👍', '😂', '😮', '😢', '🙏'];
  static final RegExp _urlPattern = RegExp(
    r'((?:https?:\/\/|www\.)[^\s<]+)',
    caseSensitive: false,
  );
  static const _padding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
  static const _bubbleRadius = Radius.circular(16);
  static const _compactRadius = Radius.circular(4);

  @override
  void dispose() {
    _hoverHideTimer?.cancel();
    _disposeLinkRecognizers();
    super.dispose();
  }

  void _disposeLinkRecognizers() {
    for (final recognizer in _linkRecognizers) {
      recognizer.dispose();
    }
    _linkRecognizers.clear();
  }

  void _onHoverEnter(PointerEnterEvent _) {
    _hoverHideTimer?.cancel();
    if (_isHovering) return;
    setState(() => _isHovering = true);
  }

  void _onHoverExit(PointerExitEvent _) {
    _scheduleHoverHide();
  }

  void _onDockHoverEnter(PointerEnterEvent _) {
    _hoverHideTimer?.cancel();
    if (_isHoveringDock && _isHovering) return;
    setState(() {
      _isHoveringDock = true;
      _isHovering = true;
    });
  }

  void _onDockHoverExit(PointerExitEvent _) {
    if (_isHoveringDock) {
      setState(() => _isHoveringDock = false);
    }
    _scheduleHoverHide();
  }

  void _scheduleHoverHide() {
    _hoverHideTimer?.cancel();
    _hoverHideTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || !_isHovering || _isHoveringDock) return;
      setState(() => _isHovering = false);
    });
  }

  Future<void> _onReact(String emoji) async {
    await widget.onReact(emoji);
  }

  void _notifyMediaLayoutResolved(String key) {
    if (!_notifiedMediaLayout.add(key)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onMediaLayoutChanged?.call();
    });
  }

  Future<void> _copyToClipboard() async {
    final text = widget.message.text;
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      // Best-effort: Clipboard can be unavailable on some platforms/test environments.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _deleteLocal() async {
    await widget.onDeleteLocal();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Deleted locally'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  (String, String) _splitTrailingUrlPunctuation(String value) {
    const trailingPunctuation = '.,!?;:)]}';
    var splitIndex = value.length;
    while (splitIndex > 0 &&
        trailingPunctuation.contains(value[splitIndex - 1])) {
      splitIndex--;
    }
    return (value.substring(0, splitIndex), value.substring(splitIndex));
  }

  String _normalizeLinkUrl(String value) {
    final lower = value.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return value;
    }
    if (lower.startsWith('www.')) {
      return 'https://$value';
    }
    return value;
  }

  Future<void> _openMessageLink(String text) async {
    final normalized = _normalizeLinkUrl(text);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return;
    }

    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to open link'),
          duration: Duration(seconds: 1),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to open link'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  List<InlineSpan> _buildBodyTextSpans(
    String text,
    TextStyle baseStyle,
    TextStyle linkStyle,
  ) {
    _disposeLinkRecognizers();
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _urlPattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(text: text.substring(cursor, match.start), style: baseStyle),
        );
      }

      final rawMatch = match.group(0)!;
      final (linkText, trailingText) = _splitTrailingUrlPunctuation(rawMatch);
      if (linkText.isNotEmpty) {
        final recognizer = TapGestureRecognizer()
          ..onTap = () => unawaited(_openMessageLink(linkText));
        _linkRecognizers.add(recognizer);
        spans.add(
          TextSpan(text: linkText, style: linkStyle, recognizer: recognizer),
        );
      } else {
        spans.add(TextSpan(text: rawMatch, style: baseStyle));
      }
      if (trailingText.isNotEmpty) {
        spans.add(TextSpan(text: trailingText, style: baseStyle));
      }
      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
    }

    return spans;
  }

  Widget _buildMessageBodyText(String text, ThemeData theme, bool isOutgoing) {
    final baseStyle = TextStyle(
      color: isOutgoing
          ? theme.colorScheme.onPrimaryContainer
          : theme.colorScheme.onSurface,
    );
    if (!_urlPattern.hasMatch(text)) {
      _disposeLinkRecognizers();
      return Text(text, style: baseStyle);
    }

    final linkStyle = baseStyle.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    return Text.rich(
      TextSpan(children: _buildBodyTextSpans(text, baseStyle, linkStyle)),
      style: baseStyle,
    );
  }

  Future<void> _copyAttachmentLink(HashtreeFileLink link) async {
    try {
      await Clipboard.setData(ClipboardData(text: link.rawLink));
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied attachment link: ${link.filename}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  EdgeInsets _bubbleMargin(bool hasReactions) {
    return EdgeInsets.only(
      top: widget.isFirstInGroup ? 4 : 1,
      bottom: hasReactions ? 0 : (widget.isLastInGroup ? 4 : 1),
    );
  }

  BorderRadius _bubbleBorderRadius(bool isOutgoing) {
    final isFirstInGroup = widget.isFirstInGroup;
    final isLastInGroup = widget.isLastInGroup;

    if (isFirstInGroup && isLastInGroup) {
      return BorderRadius.circular(16);
    }

    if (isFirstInGroup) {
      return isOutgoing
          ? const BorderRadius.only(
              topLeft: _bubbleRadius,
              topRight: _bubbleRadius,
              bottomLeft: _bubbleRadius,
              bottomRight: _compactRadius,
            )
          : const BorderRadius.only(
              topLeft: _bubbleRadius,
              topRight: _bubbleRadius,
              bottomLeft: _compactRadius,
              bottomRight: _bubbleRadius,
            );
    }

    if (isLastInGroup) {
      return isOutgoing
          ? const BorderRadius.only(
              topLeft: _bubbleRadius,
              topRight: _compactRadius,
              bottomLeft: _bubbleRadius,
              bottomRight: _bubbleRadius,
            )
          : const BorderRadius.only(
              topLeft: _compactRadius,
              topRight: _bubbleRadius,
              bottomLeft: _bubbleRadius,
              bottomRight: _bubbleRadius,
            );
    }

    return isOutgoing
        ? const BorderRadius.only(
            topLeft: _bubbleRadius,
            topRight: _compactRadius,
            bottomLeft: _bubbleRadius,
            bottomRight: _compactRadius,
          )
        : const BorderRadius.only(
            topLeft: _compactRadius,
            topRight: _bubbleRadius,
            bottomLeft: _compactRadius,
            bottomRight: _bubbleRadius,
          );
  }

  Future<Uint8List> _loadAttachmentBytes(HashtreeFileLink link) async {
    return _attachmentFutureCache.putIfAbsent(link.rawLink, () async {
      final cached = _attachmentCache[link.rawLink];
      if (cached != null) return cached;

      try {
        final bytes = await ref
            .read(hashtreeAttachmentServiceProvider)
            .downloadFile(link: link);
        _attachmentCache[link.rawLink] = bytes;
        return bytes;
      } catch (e) {
        unawaited(_attachmentFutureCache.remove(link.rawLink));
        rethrow;
      }
    });
  }

  Future<void> _showInlineImage(HashtreeFileLink link) async {
    try {
      final bytes = await _loadAttachmentBytes(link);
      if (!mounted) return;
      await showImageViewerModal(context, imageProvider: MemoryImage(bytes));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to open image: $e')));
    }
  }

  Future<void> _downloadAttachment(HashtreeFileLink link) async {
    try {
      String? savePath;
      try {
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save attachment',
          fileName: link.filename,
        );
      } on MissingPluginException {
        final downloadsDir = await getDownloadsDirectory();
        final fallbackDir = downloadsDir ?? await getTemporaryDirectory();
        savePath = p.join(fallbackDir.path, link.filename);
      }
      if (savePath == null || savePath.trim().isEmpty) return;

      final targetPath = _nextAvailablePath(savePath.trim());
      await ref
          .read(hashtreeAttachmentServiceProvider)
          .downloadFileToPath(link: link, outputPath: targetPath);

      if (!mounted) return;
      final basename = p.basename(targetPath);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved attachment: $basename')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save attachment: $e')));
    }
  }

  String _nextAvailablePath(String requestedPath) {
    final path = requestedPath;

    // `file_picker` can return paths without extension adjustments; preserve
    // user choice while avoiding accidental overwrites.
    final file = File(path);
    if (!file.existsSync()) return path;

    final dir = p.dirname(path);
    final stem = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    var i = 1;
    while (true) {
      final candidate = p.join(dir, '$stem ($i)$ext');
      if (!File(candidate).existsSync()) return candidate;
      i++;
    }
  }

  Future<void> _openAttachment(HashtreeFileLink link) async {
    if (isImageFilename(link.filename)) {
      await _showInlineImage(link);
      return;
    }
    await _downloadAttachment(link);
  }

  RelativeRect _menuPositionFromGlobal(Offset globalPosition) {
    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()
            as RenderBox;
    final rect = Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0);
    return RelativeRect.fromRect(rect, Offset.zero & overlay.size);
  }

  RelativeRect _menuPositionFromBubble() {
    final box = context.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()
            as RenderBox;

    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final rect = Rect.fromPoints(topLeft, bottomRight);
    return RelativeRect.fromRect(rect, Offset.zero & overlay.size);
  }

  bool get _useSheetForMenu {
    switch (Theme.of(context).platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return false;
    }
  }

  Future<void> _showActionsMenu({Offset? globalPosition}) async {
    final position = globalPosition != null
        ? _menuPositionFromGlobal(globalPosition)
        : _menuPositionFromBubble();

    final result = await showMenu<Object>(
      context: context,
      position: position,
      items: [
        const _EmojiMenuEntry(emojis: _quickEmojis),
        const PopupMenuDivider(),
        const PopupMenuItem<Object>(
          value: _MessageMenuAction.copy,
          child: Text('Copy'),
        ),
        const PopupMenuItem<Object>(
          value: _MessageMenuAction.deleteLocal,
          child: Text('Delete locally'),
        ),
      ],
    );

    if (result is String) {
      await _onReact(result);
      return;
    }

    switch (result) {
      case _MessageMenuAction.copy:
        await _copyToClipboard();
        break;
      case _MessageMenuAction.deleteLocal:
        await _deleteLocal();
        break;
      default:
        break;
    }
  }

  Future<void> _showActionsSheet() async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
              child: Wrap(
                spacing: 8,
                children: _quickEmojis
                    .map(
                      (emoji) => InkResponse(
                        onTap: () {
                          Navigator.pop(ctx);
                          unawaited(_onReact(emoji));
                        },
                        radius: 22,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            emoji,
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_copyToClipboard());
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(
                'Delete locally',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_deleteLocal());
              },
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  void _openActions({Offset? globalPosition}) {
    if (_useSheetForMenu) {
      unawaited(_showActionsSheet());
    } else {
      unawaited(_showActionsMenu(globalPosition: globalPosition));
    }
  }

  void _onLongPress() {
    _openActions();
  }

  Widget _buildAttachmentTile(
    HashtreeFileLink attachment,
    ThemeData theme,
    bool isOutgoing,
  ) {
    final baseColor = isOutgoing
        ? theme.colorScheme.primary.withValues(alpha: 28)
        : theme.colorScheme.surface;
    final textColor = isOutgoing
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    final isImage = isImageFilename(attachment.filename);
    final attachmentKey = ValueKey(
      'chat_message_attachment_${attachment.filenameEncoded}',
    );

    Widget imagePreview(Uint8List bytes) {
      return LayoutBuilder(
        builder: (_, constraints) {
          final previewHeight = (constraints.maxWidth * 0.62).clamp(
            140.0,
            320.0,
          );
          return SizedBox(
            width: double.infinity,
            height: previewHeight,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => Center(
                child: Icon(Icons.broken_image_outlined, color: textColor),
              ),
            ),
          );
        },
      );
    }

    Widget imageErrorTile() {
      return SizedBox(
        height: 180,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, color: textColor),
              const SizedBox(height: 6),
              Text(
                'Tap to retry image download',
                style: TextStyle(color: textColor),
              ),
            ],
          ),
        ),
      );
    }

    if (isImage) {
      final cachedBytes = _attachmentCache[attachment.rawLink];
      if (cachedBytes != null) {
        _notifyMediaLayoutResolved(attachment.rawLink);
      }
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: InkWell(
          key: attachmentKey,
          onTap: () => unawaited(_openAttachment(attachment)),
          onLongPress: () => unawaited(_copyAttachmentLink(attachment)),
          borderRadius: BorderRadius.circular(10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: cachedBytes != null
                ? imagePreview(cachedBytes)
                : FutureBuilder<Uint8List>(
                    future: _loadAttachmentBytes(attachment),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const SizedBox(
                          height: 180,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (snapshot.hasError || !snapshot.hasData) {
                        return imageErrorTile();
                      }
                      _notifyMediaLayoutResolved(attachment.rawLink);
                      return imagePreview(snapshot.data!);
                    },
                  ),
          ),
        ),
      );
    }

    final filenameRow = Row(
      children: [
        Icon(
          isImage ? Icons.image_outlined : Icons.download_outlined,
          size: 16,
          color: textColor,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            attachment.filename,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: () => unawaited(_openAttachment(attachment)),
        onLongPress: () => unawaited(_copyAttachmentLink(attachment)),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          key: attachmentKey,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: baseColor,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: filenameRow,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final isOutgoing = message.isOutgoing;
    final hasReactions = message.reactions.isNotEmpty;
    final extracted = extractHashtreeFileLinks(message.text);
    final bodyText = extracted.text;
    final attachments = extracted.links;
    final replyToMessage = widget.replyToMessage;
    final senderLabel =
        (!isOutgoing &&
            widget.senderLabel != null &&
            widget.senderLabel!.trim().isNotEmpty &&
            widget.isFirstInGroup)
        ? widget.senderLabel!.trim()
        : null;

    final actionDock = MouseRegion(
      onEnter: _onDockHoverEnter,
      onExit: _onDockHoverExit,
      child: Material(
        elevation: 2,
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.reply, size: 18),
              tooltip: 'Reply',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onReply,
            ),
            IconButton(
              icon: const Icon(Icons.emoji_emotions_outlined, size: 18),
              tooltip: 'React',
              visualDensity: VisualDensity.compact,
              onPressed: _openActions,
            ),
            IconButton(
              icon: const Icon(Icons.more_horiz, size: 18),
              tooltip: 'More',
              visualDensity: VisualDensity.compact,
              onPressed: _openActions,
            ),
          ],
        ),
      ),
    );

    return MouseRegion(
      hitTestBehavior: HitTestBehavior.translucent,
      onEnter: _onHoverEnter,
      onExit: _onHoverExit,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: _onLongPress,
        onSecondaryTapDown: (d) =>
            _openActions(globalPosition: d.globalPosition),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: isOutgoing
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (senderLabel != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 8, bottom: 2),
                  child: Text(
                    senderLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final showDock = _isHovering;
                  final dockSlotWidth = showDock
                      ? math.min(124.0, constraints.maxWidth * 0.38)
                      : 0.0;
                  final dockGap = showDock
                      ? math.min(8.0, constraints.maxWidth * 0.03)
                      : 0.0;
                  final screenMaxBubbleWidth =
                      MediaQuery.sizeOf(context).width * 0.75;
                  final bubbleMaxWidth = math.min(
                    screenMaxBubbleWidth,
                    math.max(
                      0.0,
                      constraints.maxWidth - dockSlotWidth - dockGap,
                    ),
                  );

                  final bubble = Flexible(
                    child: Align(
                      alignment: isOutgoing
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: bubbleMaxWidth),
                        child: Container(
                          key: ValueKey(
                            'chat_message_bubble_body_${message.id}',
                          ),
                          margin: _bubbleMargin(hasReactions),
                          padding: _padding,
                          decoration: BoxDecoration(
                            color: isOutgoing
                                ? theme.colorScheme.primaryContainer
                                : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: _bubbleBorderRadius(isOutgoing),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (replyToMessage != null) ...[
                                const SizedBox(height: 4),
                                InkWell(
                                  onTap: widget.onOpenReply,
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      6,
                                      8,
                                      6,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      color: isOutgoing
                                          ? theme.colorScheme.primary
                                                .withValues(alpha: 28)
                                          : theme.colorScheme.surface,
                                      border: Border(
                                        left: BorderSide(
                                          color: theme.colorScheme.primary,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          replyToMessage.isOutgoing
                                              ? 'You'
                                              : 'Them',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color:
                                                    theme.colorScheme.primary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          buildAttachmentAwarePreview(
                                            replyToMessage.text,
                                            maxLength: 120,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: isOutgoing
                                                    ? theme
                                                          .colorScheme
                                                          .onPrimaryContainer
                                                    : theme
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                              if (attachments.isNotEmpty)
                                ...attachments.map(
                                  (attachment) => _buildAttachmentTile(
                                    attachment,
                                    theme,
                                    isOutgoing,
                                  ),
                                ),
                              if (attachments.isNotEmpty && bodyText.isNotEmpty)
                                const SizedBox(height: 8),
                              if (bodyText.isNotEmpty)
                                _buildMessageBodyText(
                                  bodyText,
                                  theme,
                                  isOutgoing,
                                ),
                              if (bodyText.isNotEmpty || attachments.isNotEmpty)
                                const SizedBox(height: 4),
                              Wrap(
                                spacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    formatTime(message.timestamp),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: isOutgoing
                                          ? theme.colorScheme.onPrimaryContainer
                                                .withValues(alpha: 179)
                                          : theme.colorScheme.onSurfaceVariant,
                                      fontSize: 11,
                                    ),
                                  ),
                                  if (isOutgoing)
                                    _StatusIcon(status: message.status),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );

                  final dockSlot = SizedBox(
                    width: dockSlotWidth,
                    child: Align(
                      alignment: isOutgoing
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: isOutgoing
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: actionDock,
                      ),
                    ),
                  );

                  return Row(
                    mainAxisAlignment: isOutgoing
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (isOutgoing && showDock) dockSlot,
                      if (isOutgoing && showDock) SizedBox(width: dockGap),
                      bubble,
                      if (!isOutgoing && showDock) SizedBox(width: dockGap),
                      if (!isOutgoing && showDock) dockSlot,
                    ],
                  );
                },
              ),
              if (hasReactions)
                Row(
                  mainAxisAlignment: isOutgoing
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.start,
                  children: [
                    Transform.translate(
                      offset: const Offset(0, -8),
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: isOutgoing ? 8 : 0,
                          left: isOutgoing ? 0 : 8,
                        ),
                        child: _ReactionsDisplay(
                          reactions: message.reactions,
                          alignment: isOutgoing
                              ? WrapAlignment.end
                              : WrapAlignment.start,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmojiMenuEntry extends PopupMenuEntry<Object> {
  const _EmojiMenuEntry({required this.emojis});

  final List<String> emojis;

  @override
  double get height => 48;

  @override
  bool represents(Object? value) => false;

  @override
  State<_EmojiMenuEntry> createState() => _EmojiMenuEntryState();
}

class _EmojiMenuEntryState extends State<_EmojiMenuEntry> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final emoji in widget.emojis)
            InkResponse(
              onTap: () => Navigator.pop(context, emoji),
              radius: 22,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(emoji, style: const TextStyle(fontSize: 20)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReactionsDisplay extends StatelessWidget {
  const _ReactionsDisplay({
    required this.reactions,
    this.alignment = WrapAlignment.end,
  });

  final Map<String, List<String>> reactions;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      alignment: alignment,
      spacing: 4,
      children: reactions.entries.map((entry) {
        final emoji = entry.key;
        final count = entry.value.length;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 14)),
              if (count > 1) ...[
                const SizedBox(width: 2),
                Text(
                  count.toString(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final MessageStatus status;

  static const _queuedIcon = Icon(
    Icons.cloud_queue,
    size: 14,
    color: Colors.orange,
  );
  static const _iconSize = 14.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = theme.colorScheme.onPrimaryContainer.withValues(
      alpha: 179,
    );

    switch (status) {
      case MessageStatus.pending:
        return Icon(Icons.schedule, size: _iconSize, color: baseColor);
      case MessageStatus.queued:
        return _queuedIcon;
      case MessageStatus.sent:
        return Icon(Icons.check, size: _iconSize, color: baseColor);
      case MessageStatus.delivered:
        return Icon(Icons.done_all, size: _iconSize, color: baseColor);
      case MessageStatus.seen:
        return const Icon(Icons.done_all, size: _iconSize, color: Colors.blue);
      case MessageStatus.failed:
        return Icon(
          Icons.error_outline,
          size: _iconSize,
          color: theme.colorScheme.error,
        );
    }
  }
}
