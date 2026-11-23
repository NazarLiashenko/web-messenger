import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../core/socket_service.dart';
import '../models/models.dart';
import 'chats_controller.dart';

/// Messages of one open chat: paging, optimistic sending with retry, edit / delete,
/// delivery / read receipts and the outgoing typing indicator.
class ChatRoomController extends ChangeNotifier {
  ChatRoomController({required this.api, required this.socket, required this.chats, required this.chatId, required this.myId}) {
    _sub = socket.events.listen(_onEvent);
  }

  final ApiClient api;
  final SocketService socket;
  final ChatsController chats;
  final String chatId;
  final String myId;
  late final StreamSubscription _sub;
  static const _uuid = Uuid();

  final List<Message> messages = []; // ascending by time
  bool loading = false;
  bool loadingMore = false;
  bool hasMore = true;
  ApiException? error;
  bool _visible = true;
  bool _disposed = false;

  Timer? _readDebounce;
  Timer? _typingStop;
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);

  /* ---------------- loading ---------------- */

  Future<void> load() async {
    loading = true;
    error = null;
    if (messages.isEmpty) {
      // Offline-first: last known messages from the encrypted on-device cache.
      final cached = await api.store.readCache('msgs_$chatId');
      if (cached is List && messages.isEmpty) {
        messages.addAll(cached.map((j) => Message.fromJson(Map<String, dynamic>.from(j as Map))));
      }
    }
    _notify();
    try {
      final data = await api.get('/api/chats/$chatId/messages', query: {'limit': 50});
      api.store.writeCache('msgs_$chatId', data['messages']).ignore();
      final fresh = (data['messages'] as List).map((j) => Message.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      final pending = messages.where((m) => m.isPending).toList();
      messages
        ..clear()
        ..addAll(fresh)
        ..addAll(pending.where((p) => !fresh.any((f) => f.clientId == p.clientId)));
      hasMore = data['hasMore'] == true;
      _scheduleRead();
    } on ApiException catch (e) {
      error = e;
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> loadMore() async {
    if (loadingMore || !hasMore || messages.isEmpty) return;
    loadingMore = true;
    _notify();
    try {
      final oldest = messages.firstWhere((m) => m.id != null, orElse: () => messages.first);
      final data = await api.get('/api/chats/$chatId/messages',
          query: {'limit': 50, 'before': oldest.createdAt.toUtc().toIso8601String()});
      final older = (data['messages'] as List).map((j) => Message.fromJson(Map<String, dynamic>.from(j as Map)));
      messages.insertAll(0, older.where((o) => !messages.any((m) => m.id == o.id)));
      hasMore = data['hasMore'] == true;
    } on ApiException catch (_) {
      // Keep what we have; the user can scroll up again to retry.
    } finally {
      loadingMore = false;
      _notify();
    }
  }

  /* ---------------- sending ---------------- */

  Message _newLocal(String type, {String? text, LocalAttachment? local, Map<String, dynamic> meta = const {}}) => Message(
        clientId: _uuid.v4(),
        chatId: chatId,
        senderId: myId,
        type: type,
        text: text,
        local: local,
        meta: meta,
        createdAt: DateTime.now(),
        status: MessageStatus.sending,
      );

  Future<void> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    stopTyping();
    final m = _newLocal('text', text: t);
    messages.add(m);
    chats.onLocalMessage(m);
    _notify();
    await _deliver(m);
  }

  Future<void> sendMedia(String type, LocalAttachment file, {Map<String, dynamic> meta = const {}, String? caption}) async {
    final m = _newLocal(type, text: caption, local: file, meta: meta);
    messages.add(m);
    chats.onLocalMessage(m);
    _notify();
    await _deliver(m);
  }

  /// Uploads (if needed) and posts the message. On failure the message stays in the list as "failed".
  Future<void> _deliver(Message m) async {
    m.status = MessageStatus.sending;
    m.error = null;
    _notify();
    try {
      String? mediaId;
      final local = m.local;
      if (local != null) {
        if (local.thumbnail != null && local.uploadedThumbnailId == null) {
          final thumb = await api.upload('/api/media',
              bytes: local.thumbnail!, filename: 'thumbnail.jpg', mime: 'image/jpeg', fields: {'kind': 'image'});
          local.uploadedThumbnailId = (thumb['media'] as Map)['id'] as String;
          m.meta = {...m.meta, 'thumbnailMediaId': local.uploadedThumbnailId};
        }
        mediaId = local.uploadedMediaId;
        if (mediaId == null) {
          final up = await api.upload('/api/media',
              bytes: local.bytes,
              filename: local.fileName,
              mime: local.mime,
              fields: {'kind': m.type},
              onProgress: (p) {
                m.uploadProgress = p;
                _notify();
              });
          mediaId = local.uploadedMediaId = (up['media'] as Map)['id'] as String;
        }
      }
      final data = await api.post('/api/chats/$chatId/messages', {
        'clientId': m.clientId,
        'type': m.type,
        'text': m.text,
        'mediaId': ?mediaId,
        if (m.meta.isNotEmpty) 'meta': m.meta,
      });
      _applyServer(Message.fromJson(Map<String, dynamic>.from(data['message'] as Map)));
    } on ApiException catch (e) {
      m.status = MessageStatus.failed;
      m.error = e.message;
      m.retryOnReconnect = e.isNetwork || (e.status ?? 0) >= 500;
      m.uploadProgress = null;
      _notify();
    }
  }

  Future<void> retry(Message m) => _deliver(m);

  void discardFailed(Message m) {
    messages.remove(m);
    _notify();
  }

  /// Merges a server copy into the list (replacing the optimistic local copy).
  void _applyServer(Message server) {
    final i = messages.indexWhere((m) => (m.id != null && m.id == server.id) || (m.clientId == server.clientId && m.senderId == server.senderId));
    if (i >= 0) {
      final existing = messages[i];
      // Keep the local bytes so the image doesn't flicker while the network copy loads.
      server.local = existing.local;
      if (existing.status.index > server.status.index && !existing.isPending) server.status = existing.status;
      messages[i] = server;
    } else {
      messages.add(server);
      messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    chats.onLocalMessage(server);
    _notify();
  }

  /* ---------------- edit / delete ---------------- */

  Future<void> edit(Message m, String text) async {
    final before = (m.text, m.editedAt);
    m.text = text.trim();
    m.editedAt = DateTime.now();
    _notify();
    try {
      final data = await api.patch('/api/messages/${m.id}', {'text': text});
      _applyServer(Message.fromJson(Map<String, dynamic>.from(data['message'] as Map)));
    } catch (e) {
      m.text = before.$1;
      m.editedAt = before.$2;
      _notify();
      rethrow;
    }
  }

  Future<void> delete(Message m) async {
    final data = await api.delete('/api/messages/${m.id}');
    _applyServer(Message.fromJson(Map<String, dynamic>.from(data['message'] as Map)));
  }

  /* ---------------- receipts & typing ---------------- */

  void setVisible(bool visible) {
    _visible = visible;
    if (visible) _scheduleRead();
  }

  void _scheduleRead() {
    if (!_visible) return;
    final hasUnread = messages.any((m) => m.senderId != myId && m.status != MessageStatus.read && !m.isDeleted && m.id != null);
    chats.markLocallyRead(chatId);
    if (!hasUnread) return;
    _readDebounce?.cancel();
    _readDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        await api.post('/api/chats/$chatId/read');
        for (final m in messages.where((m) => m.senderId != myId)) {
          m.upgradeStatus(MessageStatus.read);
        }
        _notify();
      } catch (_) {}
    });
  }

  void onComposerChanged(String text) {
    if (text.trim().isEmpty) {
      stopTyping();
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastTypingSent) > const Duration(seconds: 3)) {
      _lastTypingSent = now;
      socket.emit('typing', {'chatId': chatId, 'isTyping': true});
    }
    _typingStop?.cancel();
    _typingStop = Timer(const Duration(seconds: 4), stopTyping);
  }

  void stopTyping() {
    _typingStop?.cancel();
    if (_lastTypingSent.millisecondsSinceEpoch != 0) {
      socket.emit('typing', {'chatId': chatId, 'isTyping': false});
      _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  void _onEvent(SocketEvent e) {
    if (e.name == 'connect') {
      // Catch up after reconnect, then resend what failed because the network was down.
      load().then((_) {
        for (final m in messages.where((m) => m.status == MessageStatus.failed && m.retryOnReconnect).toList()) {
          _deliver(m);
        }
      });
      return;
    }
    if (e.data is! Map) return;
    final data = Map<String, dynamic>.from(e.data as Map);
    switch (e.name) {
      case 'message:new':
      case 'message:updated':
        final m = Message.fromJson(Map<String, dynamic>.from(data['message'] as Map));
        if (m.chatId != chatId) return;
        _applyServer(m);
        if (m.senderId != myId) _scheduleRead();
      case 'message:status':
        if (data['chatId'] != chatId) return;
        final ids = (data['messageIds'] as List).cast<String>().toSet();
        final status = data['status'] == 'read' ? MessageStatus.read : MessageStatus.delivered;
        for (final m in messages.where((m) => ids.contains(m.id))) {
          m.upgradeStatus(status);
        }
        _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stopTyping();
    _readDebounce?.cancel();
    _sub.cancel();
    super.dispose();
  }
}
