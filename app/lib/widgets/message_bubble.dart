import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../models/models.dart';
import '../screens/media_viewer_screen.dart';
import 'audio_message.dart';

/// Sending / sent / delivered / read / failed indicator.
class StatusIcon extends StatelessWidget {
  const StatusIcon({super.key, required this.status, this.color, this.size = 16});
  final MessageStatus status;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.outline;
    return switch (status) {
      MessageStatus.sending => Icon(Icons.schedule, size: size, color: c),
      MessageStatus.failed => Icon(Icons.error, size: size, color: Theme.of(context).colorScheme.error),
      MessageStatus.sent => Icon(Icons.done, size: size, color: c),
      MessageStatus.delivered => Icon(Icons.done_all, size: size, color: c),
      MessageStatus.read => Icon(Icons.done_all, size: size, color: Colors.lightBlueAccent.shade400),
    };
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    this.onLongPress,
    this.onSecondaryTap,
    this.onTapFailed,
  });

  final Message message;
  final bool mine;
  final VoidCallback? onLongPress;

  /// Right click (web / desktop) with the pointer position.
  final void Function(Offset globalPosition)? onSecondaryTap;
  final VoidCallback? onTapFailed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = message;
    final bg = mine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = mine ? scheme.onPrimaryContainer : scheme.onSurface;
    final meta = fg.withValues(alpha: 0.6);
    final hasMedia = !m.isDeleted && m.type != 'text';

    final footer = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.editedAt != null && !m.isDeleted) Text('edited · ', style: TextStyle(fontSize: 11, color: meta)),
        Text(DateFormat.Hm().format(m.createdAt), style: TextStyle(fontSize: 11, color: meta)),
        if (mine) ...[const SizedBox(width: 4), StatusIcon(status: m.status, color: meta, size: 15)],
      ],
    );

    Widget content;
    if (m.isDeleted) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block, size: 16, color: meta),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'This message was deleted',
              style: TextStyle(color: meta, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasMedia) _media(context, m, fg),
          if (m.text != null && m.text!.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: hasMedia ? 6 : 0),
              child: Text(m.text!, style: TextStyle(color: fg, fontSize: 15.5)),
            ),
        ],
      );
    }

    Widget bubble(double maxWidth) => Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      margin: EdgeInsets.only(left: mine ? 48 : 8, right: mine ? 8 : 48, top: 2, bottom: 2),
      padding: EdgeInsets.fromLTRB(hasMedia ? 6 : 12, hasMedia ? 6 : 8, hasMedia ? 6 : 10, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 4),
          bottomRight: Radius.circular(mine ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [content, const SizedBox(height: 2), footer],
      ),
    );

    // Width of the message list (a pane on wide layouts), capped so lines stay readable on big screens.
    return LayoutBuilder(builder: (context, box) => _layout(context, box.maxWidth, bubble));
  }

  Widget _layout(BuildContext context, double listWidth, Widget Function(double maxWidth) bubbleOf) {
    final scheme = Theme.of(context).colorScheme;
    final m = message;
    final bubble = bubbleOf(listWidth * 0.78 > 600 ? 600 : listWidth * 0.78);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: m.isDeleted ? null : onLongPress,
            onSecondaryTapUp: m.isDeleted || onSecondaryTap == null ? null : (d) => onSecondaryTap!(d.globalPosition),
            onTap: m.status == MessageStatus.failed ? onTapFailed : null,
            child: bubble,
          ),
          if (m.status == MessageStatus.failed)
            GestureDetector(
              onTap: onTapFailed,
              child: Padding(
                padding: const EdgeInsets.only(left: 48, right: 12, bottom: 4),
                child: Text(
                  'Not sent${m.error != null ? ': ${m.error}' : ''} · '
                  '${m.retryOnReconnect ? 'will retry when back online, or tap' : 'tap to retry'}',
                  textAlign: TextAlign.end,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _media(BuildContext context, Message m, Color fg) {
    final api = context.read<ApiClient>();
    final url = api.absoluteUrl(m.media?.url);
    final uploading = m.status == MessageStatus.sending && m.local != null && m.local!.uploadedMediaId == null;

    Widget overlayProgress(Widget child) => Stack(
      alignment: Alignment.center,
      children: [
        child,
        if (uploading)
          Container(
            decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
            padding: const EdgeInsets.all(10),
            child: CircularProgressIndicator(value: m.uploadProgress, color: Colors.white, strokeWidth: 3),
          ),
      ],
    );

    switch (m.type) {
      case 'image':
        final w = (m.meta['width'] as num?)?.toDouble();
        final h = (m.meta['height'] as num?)?.toDouble();
        final ratio = (w != null && h != null && h > 0) ? (w / h).clamp(0.5, 2.0) : 4 / 3;
        final Widget img = m.local != null
            ? Image.memory(m.local!.bytes, fit: BoxFit.cover)
            : CachedNetworkImage(
                imageUrl: url ?? '',
                cacheKey: m.media?.id,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(color: Colors.black12),
                errorWidget: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined, size: 40)),
              );
        return GestureDetector(
          onTap: url == null && m.local == null
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ImageViewerScreen(url: url, bytes: m.local?.bytes, cacheKey: m.media?.id),
                  ),
                ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 240,
              child: AspectRatio(aspectRatio: ratio, child: overlayProgress(img)),
            ),
          ),
        );
      case 'video':
        final vw = (m.meta['width'] as num?)?.toDouble();
        final vh = (m.meta['height'] as num?)?.toDouble();
        final vRatio = (vw != null && vh != null && vh > 0) ? (vw / vh).clamp(0.6, 1.8) : 16 / 9;
        final thumbUrl = api.absoluteUrl(m.media?.thumbnailUrl);
        final Widget preview = m.local?.thumbnail != null
            ? Image.memory(m.local!.thumbnail!, fit: BoxFit.cover)
            : thumbUrl != null
            ? CachedNetworkImage(
                imageUrl: thumbUrl,
                cacheKey: '${m.media?.id}-thumb',
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              )
            : const SizedBox.shrink();
        final label = [
          if (m.durationMs != null) formatDuration(m.durationMs!),
          formatBytes(m.media?.size ?? m.local?.bytes.length ?? 0),
        ].join(' · ');
        return GestureDetector(
          onTap: url == null
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoViewerScreen(url: url))),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 240,
              color: Colors.black87,
              child: AspectRatio(
                aspectRatio: vRatio,
                child: overlayProgress(
                  Stack(
                    fit: StackFit.expand,
                    children: [
                      preview,
                      if (!uploading) const Center(child: Icon(Icons.play_circle_fill, color: Colors.white, size: 56)),
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                          child: Row(
                            children: [
                              const Icon(Icons.videocam, color: Colors.white, size: 14),
                              const SizedBox(width: 4),
                              Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      case 'audio':
        return SizedBox(
          width: 230,
          child: uploading
              ? Row(
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(value: m.uploadProgress, strokeWidth: 3),
                    ),
                    const SizedBox(width: 12),
                    Text('Voice message · ${formatDuration(m.durationMs ?? 0)}', style: TextStyle(color: fg)),
                  ],
                )
              : AudioMessage(url: url, localPath: m.local?.path, durationMs: m.durationMs, color: fg),
        );
    }
    return const SizedBox.shrink();
  }
}
