import 'package:intl/intl.dart';

import '../models/models.dart';

String formatChatTime(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  if (day == today) return DateFormat.Hm().format(t);
  if (today.difference(day).inDays < 7) return DateFormat.E().format(t);
  if (t.year == now.year) return DateFormat('d MMM').format(t);
  return DateFormat('dd.MM.yy').format(t);
}

String formatDayHeader(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (t.year == now.year) return DateFormat('d MMMM').format(t);
  return DateFormat('d MMMM y').format(t);
}

String formatLastSeen(AppUser u) {
  if (u.online) return 'online';
  final t = u.lastSeenAt;
  if (t == null) return 'offline';
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'last seen just now';
  if (diff.inMinutes < 60) return 'last seen ${diff.inMinutes} min ago';
  return 'last seen ${formatChatTime(t)}${diff.inDays == 0 ? '' : ' at ${DateFormat.Hm().format(t)}'}';
}

String formatDuration(int ms) {
  final d = Duration(milliseconds: ms);
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

String messagePreview(Message m, {String? myId}) {
  if (m.isSystem) return systemMessageText(m, myId: myId);
  if (m.isDeleted) return 'Message deleted';
  const labels = {'image': '📷 Photo', 'video': '🎬 Video', 'audio': '🎤 Voice message', 'poll': '📊 Poll'};
  if (m.type == 'text') return m.text ?? '';
  final label = labels[m.type] ?? 'Attachment';
  return (m.text?.isNotEmpty ?? false) ? '$label · ${m.text}' : label;
}

/// Human-readable text of a group event ("Anna added Bob", "You left the group"…).
String systemMessageText(Message m, {String? myId}) {
  final meta = m.meta;
  String who(String idKey, String nameKey) =>
      meta[idKey] != null && meta[idKey] == myId ? 'You' : (meta[nameKey] as String? ?? 'Someone');
  final actor = who('actorId', 'actorName');
  final target = who('targetId', 'targetName');
  return switch (meta['event']) {
    'created' => '$actor created the group "${meta['title']}"',
    'joined' => meta['invitedByName'] != null
        ? '$actor joined the group (invited by ${meta['invitedById'] == myId ? 'you' : meta['invitedByName']})'
        : '$actor joined the group',
    'renamed' => '$actor renamed the group to "${meta['title']}"',
    'left' => '$target left the group',
    'removed' => '$actor removed $target',
    _ => 'Group updated',
  };
}
