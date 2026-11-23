import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/notification_service.dart';
import '../core/socket_service.dart';
import '../models/models.dart';
import 'chats_controller.dart';

/// Pending chat invitations (incoming and sent).
class InvitesController extends ChangeNotifier {
  InvitesController(this.api, this.socket, this.notifications, this.chats) {
    _sub = socket.events.listen(_onEvent);
  }

  final ApiClient api;
  final SocketService socket;
  final NotificationService notifications;
  final ChatsController chats;
  late final StreamSubscription _sub;

  List<Invite> incoming = [];
  List<Invite> outgoing = [];
  bool loading = false;
  ApiException? error;

  void reset() {
    incoming = [];
    outgoing = [];
    error = null;
    notifyListeners();
  }

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final data = await api.get('/api/invites');
      incoming = (data['incoming'] as List).map((j) => Invite.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      outgoing = (data['outgoing'] as List).map((j) => Invite.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      error = null;
    } on ApiException catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Sends an invite. Returns the chat if the invite was auto-accepted (they had invited us).
  Future<Chat?> send(String userId) async {
    final data = await api.post('/api/invites', {'userId': userId});
    if (data['chat'] is Map) {
      final chat = Chat.fromJson(Map<String, dynamic>.from(data['chat'] as Map));
      chats.upsert(chat);
      incoming.removeWhere((i) => i.user.id == userId);
      notifyListeners();
      return chat;
    }
    final invite = Invite.fromJson(Map<String, dynamic>.from(data['invite'] as Map));
    _add(invite);
    return null;
  }

  Future<Chat> accept(Invite invite) async {
    final data = await api.post('/api/invites/${invite.id}/accept');
    _remove(invite.id);
    final chat = Chat.fromJson(Map<String, dynamic>.from(data['chat'] as Map));
    chats.upsert(chat);
    return chat;
  }

  Future<void> decline(Invite invite) async {
    await api.post('/api/invites/${invite.id}/decline');
    _remove(invite.id);
  }

  Future<void> cancel(String inviteId) async {
    await api.delete('/api/invites/$inviteId');
    _remove(inviteId);
  }

  void _add(Invite i) {
    _removeSilently(i.id);
    (i.incoming ? incoming : outgoing).insert(0, i);
    notifyListeners();
  }

  void _removeSilently(String id) {
    incoming.removeWhere((i) => i.id == id);
    outgoing.removeWhere((i) => i.id == id);
  }

  void _remove(String id) {
    _removeSilently(id);
    notifyListeners();
  }

  void _onEvent(SocketEvent e) {
    if (e.name == 'connect') {
      load();
      return;
    }
    if (e.data is! Map) return;
    final data = Map<String, dynamic>.from(e.data as Map);
    if (e.name == 'invite:new') {
      final invite = Invite.fromJson(data);
      _add(invite);
      if (invite.incoming) {
        notifications.showInvite(title: 'New chat invitation', body: '${invite.user.username} wants to chat with you');
      }
    } else if (e.name == 'invite:updated') {
      final invite = Invite.fromJson(data);
      if (invite.status != 'pending') _remove(invite.id);
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
