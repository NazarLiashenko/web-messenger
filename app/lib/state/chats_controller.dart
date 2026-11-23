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
  final Map<String, DateTime> _typingUntil = {};
  bool loading = false;
  bool loaded = false;
  ApiException? error;

  List<Chat> _sorted(bool archived) =>
      _chats.values.where((c) => c.archived == archived).toList()..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));

  List<Chat> get active => _sorted(false);
  List<Chat> get archived => _sorted(true);
  Chat? byId(String id) => _chats[id];
  Chat? byPeer(String userId) => _chats.values.where((c) => c.peer.id == userId).firstOrNull;
  bool isTyping(String chatId) => (_typingUntil[chatId]?.isAfter(DateTime.now())) ?? false;
  int get unreadChats => _chats.values.where((c) => !c.archived && c.unreadCount > 0).length;

  /// Clears all state when the signed-in account changes.
  void reset(String? userId) {
    myId = userId ?? '';
    _chats.clear();
    _typingUntil.clear();
    loaded = false;
    error = null;
    notifyListeners();
  }

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final data = await api.get('/api/chats');
      _chats
        ..clear()
        ..addEntries((data['chats'] as List).map((j) {
          final c = Chat.fromJson(Map<String, dynamic>.from(j as Map));
          return MapEntry(c.id, c);
        }));
      error = null;
      loaded = true;
    } on ApiException catch (e) {
      error = e; // keep showing the last known list
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void upsert(Chat chat) {
    _chats[chat.id] = chat;
    notifyListeners();
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
        if (data['isTyping'] == true) {
          _typingUntil[chatId] = DateTime.now().add(const Duration(seconds: 6));
        } else {
          _typingUntil.remove(chatId);
        }
        notifyListeners();
      case 'presence':
        for (final c in _chats.values.where((c) => c.peer.id == data['userId'])) {
          c.peer = c.peer.copyWith(
            online: data['online'] == true,
            lastSeenAt: data['lastSeenAt'] != null ? DateTime.tryParse(data['lastSeenAt'] as String)?.toLocal() : null,
          );
        }
        if (data['online'] != true) {
          _typingUntil.removeWhere((chatId, _) => _chats[chatId]?.peer.id == data['userId']);
        }
        notifyListeners();
      case 'user:updated':
        final u = AppUser.fromJson(data);
        for (final c in _chats.values.where((c) => c.peer.id == u.id)) {
          c.peer = u;
        }
        notifyListeners();
      case 'chat:new':
      case 'chat:updated':
        if (data['id'] != null) upsert(Chat.fromJson(data));
    }
  }

  void _onNewMessage(Message m) {
    final mine = m.senderId == myId;
    if (!mine) {
      socket.emit('message:delivered', {'messageIds': [m.id]});
      _typingUntil.remove(m.chatId);
    }
    final chat = _chats[m.chatId];
    if (chat == null) {
      load(); // a chat we don't know yet
      return;
    }
    chat.lastMessage = m;
    chat.lastActivityAt = m.createdAt;
    final viewing = notifications.openChatId == m.chatId && notifications.appInForeground;
    if (!mine && !viewing) chat.unreadCount += 1;
    notifyListeners();
    if (!mine && !chat.muted) {
      notifications.showMessage(chatId: chat.id, title: chat.peer.username, body: messagePreview(m));
    }
  }

  void _expireTyping() {
    final now = DateTime.now();
    final before = _typingUntil.length;
    _typingUntil.removeWhere((_, until) => until.isBefore(now));
    if (_typingUntil.length != before) notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    _typingTicker.cancel();
    super.dispose();
  }
}
