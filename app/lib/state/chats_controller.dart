import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../core/notification_service.dart';
import '../core/socket_service.dart';
import '../models/models.dart';

/// Chat list, presence, typing indicators and global message events.
class ChatsController extends ChangeNotifier {
  ChatsController(this.api, this.socket, this.notifications, this.myId) {
    _sub = socket.events.listen(_onEvent);
    _typingTicker = Timer.periodic(const Duration(seconds: 2), (_) => _expireTyping());
  }

  final ApiClient api;
  final SocketService socket;
  final NotificationService notifications;
  String myId;
  late final StreamSubscription _sub;
  late final Timer _typingTicker;

  final Map<String, Chat> _chats = {};
  /// chatId -> (userId -> typing until). Several people can type at once in a group.
  final Map<String, Map<String, DateTime>> _typing = {};

  /// Chats the user was removed from / left while they were open (the chat screen closes itself).
  final Set<String> removedChatIds = {};
  bool loading = false;
  bool loaded = false;
  ApiException? error;

  List<Chat> _sorted(bool archived) =>
      _chats.values.where((c) => c.archived == archived).toList()..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));

  List<Chat> get active => _sorted(false);
  List<Chat> get archived => _sorted(true);
  Chat? byId(String id) => _chats[id];
  Chat? byPeer(String userId) => _chats.values.where((c) => !c.isGroup && c.peer?.id == userId).firstOrNull;
  bool isTyping(String chatId) => typingUserIds(chatId).isNotEmpty;

  /// Who is typing in the chat right now.
  List<String> typingUserIds(String chatId) {
    final now = DateTime.now();
    return [for (final e in (_typing[chatId] ?? const <String, DateTime>{}).entries) if (e.value.isAfter(now)) e.key];
  }

  /// "typing…" / "Bob is typing…" / "Bob and Ann are typing…"
  String? typingLabel(String chatId) {
    final ids = typingUserIds(chatId);
    if (ids.isEmpty) return null;
    final chat = _chats[chatId];
    if (chat == null || !chat.isGroup) return 'typing…';
    final names = ids.map((id) => chat.member(id)?.username ?? 'Someone').toList();
    if (names.length == 1) return '${names.first} is typing…';
    if (names.length == 2) return '${names[0]} and ${names[1]} are typing…';
    return '${names.length} people are typing…';
  }
  int get unreadChats => _chats.values.where((c) => !c.archived && c.unreadCount > 0).length;

  /// Clears all state when the signed-in account changes.
  void reset(String? userId) {
    myId = userId ?? '';
    _chats.clear();
    _typing.clear();
    removedChatIds.clear();
    loaded = false;
    error = null;
    notifyListeners();
  }

  void _fill(List list) {
    _chats
      ..clear()
      ..addEntries(list.map((j) {
        final c = Chat.fromJson(Map<String, dynamic>.from(j as Map));
        return MapEntry(c.id, c);
      }));
  }

  Future<void> load() async {
    loading = true;
    // Offline-first: show the last known list (kept encrypted on the device) while fetching.
    if (!loaded && _chats.isEmpty) {
      final cached = await api.store.readCache('chats');
      if (cached is List && _chats.isEmpty) {
        _fill(cached);
        loaded = true;
      }
    }
    notifyListeners();
    try {
      final data = await api.get('/api/chats');
      _fill(data['chats'] as List);
      api.store.writeCache('chats', data['chats']).ignore();
      error = null;
      loaded = true;
    } on ApiException catch (e) {
      error = e; // keep showing the last known list
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Re-fetches one chat (members, title, counters) from the server.
  Future<void> refreshChat(String chatId) async {
    try {
      final data = await api.get('/api/chats/$chatId');
      if (data['chat'] is Map) upsert(Chat.fromJson(Map<String, dynamic>.from(data['chat'] as Map)));
    } catch (_) {
      // not a member any more / offline: the next full load fixes it
    }
  }

  void upsert(Chat chat) {
    _chats[chat.id] = chat;
    notifyListeners();
  }

  /* ---------------- groups ---------------- */

  /// Creates a group and invites [memberIds]. Returns the chat and the people who could not be invited.
  Future<(Chat, List<String>)> createGroup(String title, List<String> memberIds) async {
    final data = await api.post('/api/groups', {'title': title, 'memberIds': memberIds});
    final chat = Chat.fromJson(Map<String, dynamic>.from(data['chat'] as Map));
    // Realtime events (chat:new / chat:updated when someone accepts right away) may already be newer.
    if (!_chats.containsKey(chat.id)) upsert(chat);
    final failed = [for (final f in (data['failed'] as List? ?? const [])) (f as Map)['message'] as String];
    return (chat, failed);
  }

  Future<void> renameGroup(String chatId, String title) async {
    final data = await api.patch('/api/groups/$chatId', {'title': title});
    upsert(Chat.fromJson(Map<String, dynamic>.from(data['chat'] as Map)));
  }

  Future<void> removeMember(String chatId, String userId) async {
    final data = await api.delete('/api/groups/$chatId/members/$userId');
    if (data['chat'] is Map) upsert(Chat.fromJson(Map<String, dynamic>.from(data['chat'] as Map)));
  }

  Future<void> leaveGroup(String chatId) async {
    await api.post('/api/groups/$chatId/leave');
    if (_chats.remove(chatId) != null) {
      removedChatIds.add(chatId);
      notifyListeners();
    }
  }

  /// Optimistic archive / mute with rollback on failure.
  Future<void> update(String chatId, {bool? archived, bool? muted}) async {
    final chat = _chats[chatId];
    if (chat == null) return;
    final before = (chat.archived, chat.muted);
    if (archived != null) chat.archived = archived;
    if (muted != null) chat.muted = muted;
    notifyListeners();
    try {
      await api.patch('/api/chats/$chatId', {'archived': ?archived, 'muted': ?muted});
    } catch (e) {
      chat.archived = before.$1;
      chat.muted = before.$2;
      notifyListeners();
      rethrow;
    }
  }

  void markLocallyRead(String chatId) {
    final chat = _chats[chatId];
    if (chat != null && chat.unreadCount != 0) {
      chat.unreadCount = 0;
      notifyListeners();
    }
    notifications.cancelChat(chatId);
  }

  /// Called by the chat screen when it sends / edits so the list preview stays in sync.
  void onLocalMessage(Message m) {
    final chat = _chats[m.chatId];
    if (chat == null) return;
    if (chat.lastMessage == null ||
        chat.lastMessage!.clientId == m.clientId ||
        !m.createdAt.isBefore(chat.lastMessage!.createdAt)) {
      chat.lastMessage = m;
      if (m.createdAt.isAfter(chat.lastActivityAt)) chat.lastActivityAt = m.createdAt;
      notifyListeners();
    }
  }

  void _onEvent(SocketEvent e) {
    final data = e.data is Map ? Map<String, dynamic>.from(e.data as Map) : <String, dynamic>{};
    switch (e.name) {
      case 'connect':
        load(); // resync everything missed while disconnected
      case 'message:new':
        _onNewMessage(Message.fromJson(Map<String, dynamic>.from(data['message'] as Map)));
      case 'message:updated':
        final m = Message.fromJson(Map<String, dynamic>.from(data['message'] as Map));
        final chat = _chats[m.chatId];
        if (chat?.lastMessage?.id == m.id) {
          chat!.lastMessage = m;
          notifyListeners();
        }
      case 'message:status':
        final chat = _chats[data['chatId']];
        final last = chat?.lastMessage;
        if (last != null && (data['messageIds'] as List).contains(last.id)) {
          last.upgradeStatus(data['status'] == 'read' ? MessageStatus.read : MessageStatus.delivered);
          if (data['status'] == 'read' && last.senderId != myId) chat!.unreadCount = 0;
          notifyListeners();
        } else if (data['status'] == 'read' && chat != null) {
          notifyListeners();
        }
      case 'typing':
        final chatId = data['chatId'] as String;
        final userId = data['userId'] as String? ?? '';
        if (data['isTyping'] == true) {
          (_typing[chatId] ??= {})[userId] = DateTime.now().add(const Duration(seconds: 6));
        } else {
          _typing[chatId]?.remove(userId);
        }
        notifyListeners();
      case 'presence':
        final userId = data['userId'] as String?;
        final lastSeen = data['lastSeenAt'] != null ? DateTime.tryParse(data['lastSeenAt'] as String)?.toLocal() : null;
        _updateUser(userId, (u) => u.copyWith(online: data['online'] == true, lastSeenAt: lastSeen));
        if (data['online'] != true) {
          for (final t in _typing.values) {
            t.remove(userId);
          }
        }
        notifyListeners();
      case 'user:updated':
        final u = AppUser.fromJson(data);
        _updateUser(u.id, (old) => old.withProfileOf(u));
        notifyListeners();
      case 'chat:new':
      case 'chat:updated':
        if (data['id'] != null) {
          removedChatIds.remove(data['id']);
          upsert(Chat.fromJson(data));
        }
      case 'chat:removed':
        final chatId = data['chatId'] as String?;
        if (chatId != null && _chats.remove(chatId) != null) {
          removedChatIds.add(chatId);
          _typing.remove(chatId);
          notifications.cancelChat(chatId);
          notifyListeners();
        }
    }
  }

  /// Applies a profile / presence change to the user wherever they appear (1:1 peer, group member lists).
  void _updateUser(String? userId, AppUser Function(AppUser) change) {
    if (userId == null) return;
    for (final c in _chats.values) {
      if (c.peer?.id == userId) c.peer = change(c.peer!);
      if (c.isGroup && c.members.any((m) => m.id == userId)) {
        c.members = [for (final m in c.members) m.id == userId ? change(m) : m];
      }
    }
  }

  void _onNewMessage(Message m) {
    final mine = m.senderId == myId;
    if (!mine) {
      socket.emit('message:delivered', {'messageIds': [m.id]});
      _typing[m.chatId]?.remove(m.senderId);
    }
    final chat = _chats[m.chatId];
    if (chat == null) {
      load(); // a chat we don't know yet
      return;
    }
    chat.lastMessage = m;
    chat.lastActivityAt = m.createdAt;
    // A group message from someone we don't know yet (missed membership update): resync that chat.
    if (chat.isGroup && !m.isSystem && m.senderId != null && chat.member(m.senderId) == null) refreshChat(chat.id);
    final viewing = notifications.isViewing(m.chatId);
    if (!mine && !viewing && !m.isSystem) chat.unreadCount += 1;
    notifyListeners();
    if (!mine && !chat.muted && !m.isSystem) {
      final preview = messagePreview(m, myId: myId);
      notifications.showMessage(
        chatId: chat.id,
        title: chat.name,
        body: chat.isGroup ? '${chat.member(m.senderId)?.username ?? 'Someone'}: $preview' : preview,
      );
    }
  }

  void _expireTyping() {
    final now = DateTime.now();
    var changed = false;
    for (final t in _typing.values) {
      final before = t.length;
      t.removeWhere((_, until) => until.isBefore(now));
      changed |= t.length != before;
    }
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    _typingTicker.cancel();
    super.dispose();
  }
}
