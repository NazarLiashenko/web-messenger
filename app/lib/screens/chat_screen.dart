import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/api_client.dart';
import '../core/chat_navigation.dart';
import '../core/format.dart';
import '../core/media_picker.dart';
import '../core/notification_service.dart';
import '../core/socket_service.dart';
import '../models/models.dart';
import '../state/auth_controller.dart';
import '../state/chat_room_controller.dart';
import '../state/chats_controller.dart';
import '../widgets/common.dart';
import '../widgets/message_bubble.dart';
import 'group_screens.dart';
import 'user_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.embedded = false});
  final String chatId;

  /// Shown as a pane next to the chat list (wide layout) instead of a full-screen page.
  final bool embedded;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final ChatRoomController _room;
  late final NotificationService _notifications;
  late final ChatsController _chats;
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  Message? _editing;
  bool _compressing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chats = context.read<ChatsController>();
    _notifications = context.read<NotificationService>();
    _room = ChatRoomController(
      api: context.read<ApiClient>(),
      socket: context.read<SocketService>(),
      chats: _chats,
      chatId: widget.chatId,
      myId: context.read<AuthController>().user!.id,
    )..load();
    _notifications.openChatIds.add(widget.chatId);
    _focus.onKeyEvent = _onComposerKey;
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _room.loadMore();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.embedded) _focus.requestFocus(); // keyboard users can type right away
      _chats.markLocallyRead(widget.chatId);
      if (_chats.byId(widget.chatId) == null) _fetchChat();
    });
  }

  Future<void> _fetchChat() async {
    try {
      final data = await context.read<ApiClient>().get('/api/chats/${widget.chatId}');
      _chats.upsert(Chat.fromJson(Map<String, dynamic>.from(data['chat'] as Map)));
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _room.setVisible(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notifications.openChatIds.remove(widget.chatId);
    _room.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _closing = false;

  /// We left / were removed from this group while it was open: close it and say why.
  void _onRemoved() {
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (widget.embedded) {
        ChatNavigation.close(widget.chatId);
      } else {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
      messenger.showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('You are no longer a member of this group'),
      ));
    });
  }

  /* ---------------- actions ---------------- */

  /// With a hardware keyboard (web / desktop): Enter sends, Shift+Enter inserts a new line,
  /// Esc cancels editing. Phones keep the on-screen keyboard behaviour (Enter = new line).
  static final bool _keyboardFirst =
      kIsWeb ||
      const {TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux}.contains(defaultTargetPlatform);

  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (!_keyboardFirst || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (_input.text.trim().isNotEmpty) _send();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _editing != null) {
      _cancelEdit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final editing = _editing;
    if (editing != null) {
      if (text == editing.text) {
        _cancelEdit();
        return;
      }
      _cancelEdit();
      try {
        await _room.edit(editing, text);
      } catch (e) {
        if (mounted) showMessage(context, 'Could not edit the message: $e');
      }
      return;
    }
    _input.clear();
    setState(() {});
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    await _room.sendText(text);
  }

  void _startEdit(Message m) {
    setState(() => _editing = m);
    _input.text = m.text ?? '';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _focus.requestFocus();
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _input.clear();
  }

  Future<void> _delete(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('It will be deleted for everyone in this chat.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(d).colorScheme.error),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _room.delete(m);
    } catch (e) {
      if (mounted) showMessage(context, 'Could not delete the message: $e');
    }
  }

  /// Message actions: a context menu at the pointer (right click) or a bottom sheet (long press).
  Future<void> _messageMenu(Message m, bool mine, {Offset? at}) async {
    final canEdit = mine && m.type == 'text' && m.id != null && !m.isPending;
    final canDelete = mine && m.id != null && !m.isPending;
    final canCopy = m.text?.isNotEmpty ?? false;
    if (at != null) {
      if (!canCopy && !canEdit && !canDelete) return;
      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
      final choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
        items: [
          if (canCopy)
            const PopupMenuItem(
              value: 'copy',
              child: ListTile(leading: Icon(Icons.copy), title: Text('Copy text')),
            ),
          if (canEdit)
            const PopupMenuItem(
              value: 'edit',
              child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit')),
            ),
          if (canDelete)
            PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            ),
        ],
      );
      if (!mounted) return;
      switch (choice) {
        case 'copy':
          await Clipboard.setData(ClipboardData(text: m.text!));
          if (mounted) showMessage(context, 'Copied', error: false);
        case 'edit':
          _startEdit(m);
        case 'delete':
          _delete(m);
      }
      return;
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy text'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: m.text!));
                  Navigator.pop(sheet);
                  showMessage(context, 'Copied', error: false);
                },
              ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(sheet);
                  _startEdit(m);
                },
              ),
            if (canDelete)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(sheet).colorScheme.error),
                title: Text('Delete', style: TextStyle(color: Theme.of(sheet).colorScheme.error)),
                onTap: () {
                  Navigator.pop(sheet);
                  _delete(m);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _failedMenu(Message m) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.error != null) Padding(padding: const EdgeInsets.all(16), child: Text(m.error!)),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Retry'),
              onTap: () {
                Navigator.pop(sheet);
                _room.retry(m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove'),
              onTap: () {
                Navigator.pop(sheet);
                _room.discardFailed(m);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo from gallery'),
              onTap: () => Navigator.pop(sheet, 'image'),
            ),
            if (!kIsWeb)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(sheet, 'camera'),
              ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Video from gallery'),
              onTap: () => Navigator.pop(sheet, 'video'),
            ),
            if (!kIsWeb)
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: const Text('Record a video'),
                onTap: () => Navigator.pop(sheet, 'record'),
              ),
            const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 12), child: Text('Images and videos up to 20 MB')),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      if (choice == 'image' || choice == 'camera') {
        final picked = await MediaPicker.pickImage(choice == 'camera' ? ImageSource.camera : ImageSource.gallery);
        if (picked != null) await _room.sendMedia('image', picked.$1, meta: picked.$2);
      } else {
        final picked = await MediaPicker.pickVideo(
          choice == 'record' ? ImageSource.camera : ImageSource.gallery,
          onCompressing: () => setState(() => _compressing = true),
        );
        if (mounted) setState(() => _compressing = false);
        if (picked != null) await _room.sendMedia('video', picked.$1, meta: picked.$2);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _compressing = false);
        showMessage(context, e);
      }
    }
  }

  /* ---------------- UI ---------------- */

  @override
  Widget build(BuildContext context) {
    final chats = context.watch<ChatsController>();
    final chat = chats.byId(widget.chatId);
    final connected = context.watch<SocketService>().connected;
    final theme = Theme.of(context);
    if (chats.removedChatIds.contains(widget.chatId)) _onRemoved();
    final typing = chats.typingLabel(widget.chatId);
    final online = chat?.peer?.online ?? false;
    final String status;
    if (!connected) {
      status = 'waiting for connection…';
    } else if (typing != null) {
      status = typing;
    } else if (chat == null) {
      status = '';
    } else if (chat.isGroup) {
      final n = chat.members.length;
      final on = chat.members.where((m) => m.online && m.id != _room.myId).length;
      status = '$n ${n == 1 ? 'member' : 'members'}${on > 0 ? ', $on online' : ''}';
    } else {
      status = formatLastSeen(chat.peer!);
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        titleSpacing: widget.embedded ? 16 : 0,
        title: chat == null
            ? const Text('Chat')
            : InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => chat.isGroup
                        ? GroupInfoScreen(chatId: chat.id)
                        : UserProfileScreen(userId: chat.peer!.id, initial: chat.peer),
                  ),
                ),
                child: Row(
                  children: [
                    ChatAvatar(chat: chat, radius: 20, showOnline: connected),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(chat.name, overflow: TextOverflow.ellipsis),
                          Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: connected && (typing != null || online)
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                              fontStyle: typing != null ? FontStyle.italic : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        actions: [
          if (chat != null)
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'info') {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupInfoScreen(chatId: chat.id)));
                  return;
                }
                try {
                  if (v == 'mute') await chats.update(chat.id, muted: !chat.muted);
                  if (v == 'archive') {
                    await chats.update(chat.id, archived: !chat.archived);
                    if (context.mounted) {
                      showMessage(context, chat.archived ? 'Chat archived' : 'Chat unarchived', error: false);
                    }
                  }
                } catch (e) {
                  if (context.mounted) showMessage(context, e);
                }
              },
              itemBuilder: (_) => [
                if (chat.isGroup) const PopupMenuItem(value: 'info', child: Text('Group info')),
                PopupMenuItem(value: 'mute', child: Text(chat.muted ? 'Unmute notifications' : 'Mute notifications')),
                PopupMenuItem(value: 'archive', child: Text(chat.archived ? 'Unarchive chat' : 'Archive chat')),
              ],
            ),
          if (widget.embedded)
            IconButton(
              tooltip: 'Close chat',
              icon: const Icon(Icons.close),
              onPressed: () => ChatNavigation.close(widget.chatId),
            ),
        ],
      ),
      body: Column(
        children: [
          ConnectionBanner(connected: connected),
          Expanded(
            child: ListenableBuilder(listenable: _room, builder: (context, _) => _messageList(context)),
          ),
          if (_compressing)
            Container(
              color: theme.colorScheme.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: const Row(
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Compressing video…'),
                ],
              ),
            ),
          if (_editing != null) _editBanner(theme),
          _Composer(
            controller: _input,
            focusNode: _focus,
            editing: _editing != null,
            onChanged: (v) {
              setState(() {});
              if (_editing == null) _room.onComposerChanged(v);
            },
            onSend: _send,
            onAttach: _attach,
            onVoice: (file, durationMs) => _room.sendMedia('audio', file, meta: {'durationMs': durationMs}),
          ),
        ],
      ),
    );
  }

  Widget _editBanner(ThemeData theme) => Container(
    color: theme.colorScheme.surfaceContainerHigh,
    padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
    child: Row(
      children: [
        Icon(Icons.edit, color: theme.colorScheme.primary, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Edit message',
                style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
              ),
              Text(_editing!.text ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        IconButton(onPressed: _cancelEdit, icon: const Icon(Icons.close)),
      ],
    ),
  );

  static const _nameColors = [
    Color(0xFFE53935), Color(0xFF8E24AA), Color(0xFF3949AB), Color(0xFF00897B),
    Color(0xFFF4511E), Color(0xFF6D4C41), Color(0xFF1E88E5), Color(0xFF43A047),
  ];
  Color _nameColor(String userId) => _nameColors[userId.codeUnits.fold<int>(0, (a, b) => a + b) % _nameColors.length];

  Widget _messageList(BuildContext context) {
    final msgs = _room.messages;
    final me = _room.myId;
    final chat = context.read<ChatsController>().byId(widget.chatId);
    // Names of people who left the group, known from group events in the history.
    final formerNames = <String, String>{};
    if (chat?.isGroup ?? false) {
      for (final m in msgs.where((m) => m.isSystem)) {
        for (final (idKey, nameKey) in const [('actorId', 'actorName'), ('targetId', 'targetName'), ('invitedById', 'invitedByName')]) {
          final id = m.meta[idKey], name = m.meta[nameKey];
          if (id is String && name is String) formerNames[id] = name;
        }
      }
    }
    if (_room.loading && msgs.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_room.error != null && msgs.isEmpty) return ErrorRetry(message: _room.error!.message, onRetry: _room.load);
    if (msgs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('👋', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 8),
            Text('No messages yet. Say hi!', style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: msgs.length + (_room.loadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == msgs.length) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final index = msgs.length - 1 - i;
        final m = msgs[index];
        final prev = index > 0 ? msgs[index - 1] : null;
        final newDay = prev == null || !DateUtils.isSameDay(prev.createdAt, m.createdAt);
        final mine = m.senderId == me;
        if (m.isSystem) {
          return Column(children: [
            if (newDay) _DayChip(date: m.createdAt),
            _SystemChip(text: systemMessageText(m, myId: me)),
          ]);
        }
        // Groups: name above the first message of a run from the same person.
        final showSender = chat != null &&
            chat.isGroup &&
            !mine &&
            (newDay || prev.isSystem || prev.senderId != m.senderId);
        final sender = showSender ? chat.member(m.senderId) : null;
        return Column(
          children: [
            if (newDay) _DayChip(date: m.createdAt),
            MessageBubble(
              senderName: showSender ? (sender?.username ?? formerNames[m.senderId] ?? 'Former member') : null,
              senderColor: showSender ? _nameColor(m.senderId ?? '') : null,
              key: ValueKey(m.clientId),
              message: m,
              mine: mine,
              onLongPress: () => _messageMenu(m, mine),
              onSecondaryTap: (pos) => _messageMenu(m, mine, at: pos),
              onTapFailed: () => _failedMenu(m),
            ),
          ],
        );
      },
    );
  }
}

/// Group event ("Bob joined the group") in the middle of the history.
class _SystemChip extends StatelessWidget {
  const _SystemChip({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(text, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        ),
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.date});
  final DateTime date;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Chip(
      label: Text(formatDayHeader(date), style: Theme.of(context).textTheme.labelSmall),
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
    ),
  );
}

/* ============================== COMPOSER ============================== */

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.editing,
    required this.onChanged,
    required this.onSend,
    required this.onAttach,
    required this.onVoice,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool editing;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final void Function(LocalAttachment file, int durationMs) onVoice;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _recorder = AudioRecorder();
  final _stopwatch = Stopwatch();
  Timer? _ticker;
  bool _recording = false;

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) showMessage(context, 'Microphone permission is required to record voice messages');
        return;
      }
      final String path;
      final RecordConfig config;
      if (kIsWeb) {
        path = '';
        config = const RecordConfig(encoder: AudioEncoder.opus);
      } else {
        final dir = await getTemporaryDirectory();
        path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
        config = const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1);
      }
      await _recorder.start(config, path: path);
      _stopwatch
        ..reset()
        ..start();
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
      setState(() => _recording = true);
    } catch (e) {
      if (mounted) showMessage(context, 'Could not start recording: $e');
    }
  }

  Future<void> _stopRecording({required bool send}) async {
    _ticker?.cancel();
    _stopwatch.stop();
    final duration = _stopwatch.elapsedMilliseconds;
    setState(() => _recording = false);
    try {
      if (!send) {
        await _recorder.cancel();
        return;
      }
      final path = await _recorder.stop();
      if (path == null) throw Exception('no recording');
      if (duration < 800) {
        if (mounted) showMessage(context, 'Hold on a bit longer — the recording is too short', error: false);
        return;
      }
      final bytes = await XFile(path).readAsBytes();
      widget.onVoice(
        LocalAttachment(
          bytes: bytes,
          mime: kIsWeb ? 'audio/webm' : 'audio/mp4',
          fileName: kIsWeb ? 'voice.webm' : 'voice.m4a',
          path: kIsWeb ? null : path,
        ),
        duration,
      );
    } catch (e) {
      if (mounted) showMessage(context, 'Recording failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasText = widget.controller.text.trim().isNotEmpty;

    if (_recording) {
      return SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Cancel',
                icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                onPressed: () => _stopRecording(send: false),
              ),
              const SizedBox(width: 8),
              const _BlinkingDot(),
              const SizedBox(width: 8),
              Text(formatDuration(_stopwatch.elapsedMilliseconds), style: theme.textTheme.titleMedium),
              const SizedBox(width: 12),
              const Expanded(child: Text('Recording…')),
              IconButton.filled(
                tooltip: 'Send voice message',
                icon: const Icon(Icons.send),
                onPressed: () => _stopRecording(send: true),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!widget.editing)
              IconButton(
                tooltip: 'Attach photo or video',
                icon: const Icon(Icons.attach_file),
                onPressed: widget.onAttach,
              ),
            if (widget.editing) const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                minLines: 1,
                maxLines: 6,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message',
                  counterText: '',
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                ),
                onChanged: widget.onChanged,
              ),
            ),
            const SizedBox(width: 6),
            if (hasText || widget.editing)
              IconButton.filled(
                tooltip: widget.editing ? 'Save' : 'Send',
                icon: Icon(widget.editing ? Icons.check : Icons.send),
                onPressed: hasText ? widget.onSend : null,
              )
            else
              IconButton.filledTonal(
                tooltip: 'Record voice message',
                icon: const Icon(Icons.mic),
                onPressed: _startRecording,
              ),
          ],
        ),
      ),
    );
  }
}

class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();
  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _c,
    child: Container(
      width: 12,
      height: 12,
      decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
    ),
  );
}
