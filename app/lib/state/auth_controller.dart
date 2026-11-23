import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/notification_service.dart';
import '../core/push_service.dart';
import '../core/socket_service.dart';
import '../models/models.dart';

enum AuthStatus { loading, signedOut, signedIn }

class AuthController extends ChangeNotifier {
  AuthController(this.api, this.socket, this.push, this.notifications) {
    api.onSessionExpired = _sessionExpired;
    api.onTokensRefreshed = () {
      if (!socket.connected) socket.reconnect();
    };
    _sub = socket.events.listen((e) {
      if (e.name == 'me:updated' && e.data is Map) _setUser(Map<String, dynamic>.from(e.data as Map));
    });
  }

  final ApiClient api;
  final SocketService socket;
  final PushService push;
  final NotificationService notifications;
  late final StreamSubscription _sub;

  AuthStatus status = AuthStatus.loading;
  AppUser? user;

  /// One-off message shown on the login screen (e.g. "session expired").
  String? notice;

  String get _device => kIsWeb ? 'web' : defaultTargetPlatform.name;

  /// Restores the persisted session so the user stays logged in across restarts.
  Future<void> restore() async {
    await api.store.load();
    if (!api.store.hasSession) {
      status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }
    final cached = api.store.cachedUser;
    if (cached != null) {
      user = AppUser.fromJson(cached);
      _startSession();
      status = AuthStatus.signedIn;
      notifyListeners();
      unawaited(refreshMe().catchError((_) {})); // works offline with cached profile
      return;
    }
    try {
      await refreshMe();
      _startSession();
      status = AuthStatus.signedIn;
    } on ApiException catch (e) {
      if (e.isNetwork && api.store.hasSession) {
        status = AuthStatus.signedOut;
        notice = 'Cannot reach the server. Check the connection or server settings.';
      } else {
        await api.store.clear();
        status = AuthStatus.signedOut;
      }
    }
    notifyListeners();
  }

  Future<void> refreshMe() async {
    final data = await api.get('/api/me');
    await _setUser(Map<String, dynamic>.from(data['user'] as Map));
  }

  Future<void> _setUser(Map<String, dynamic> json) async {
    user = AppUser.fromJson(json);
    await api.store.saveUser(json);
    notifyListeners();
  }

  void _startSession() {
    socket.connect();
    notifications.requestPermission();
    unawaited(push.register());
  }

  Future<void> _signedIn(Map<String, dynamic> data) async {
    await api.store.saveTokens(Map<String, dynamic>.from(data['tokens'] as Map));
    await _setUser(Map<String, dynamic>.from(data['user'] as Map));
    notice = null;
    status = AuthStatus.signedIn;
    _startSession();
    notifyListeners();
  }

  /// Returns whether the verification email was sent.
  Future<bool> register({required String email, required String username, required String password}) async {
    final data = await api.postPublic('/api/auth/register', {'email': email.trim(), 'username': username.trim(), 'password': password});
    return data['emailSent'] != false;
  }

  Future<Map<String, bool>> checkAvailability({String? email, String? username}) async {
    final data = await api.get('/api/auth/availability', query: {
      if (email != null) 'email': email.trim(),
      if (username != null) 'username': username.trim(),
    });
    return data.map((k, v) => MapEntry(k, v == true));
  }

  Future<void> verifyEmail(String email, String code) async {
    final data = await api.postPublic('/api/auth/verify-email', {'email': email.trim(), 'code': code.trim(), 'device': _device});
    await _signedIn(data);
  }

  Future<void> resendVerification(String email) => api.postPublic('/api/auth/resend-verification', {'email': email.trim()});

  Future<void> login(String email, String password) async {
    final data = await api.postPublic('/api/auth/login', {'email': email.trim(), 'password': password, 'device': _device});
    await _signedIn(data);
  }

  Future<void> forgotPassword(String email) => api.postPublic('/api/auth/forgot-password', {'email': email.trim()});

  Future<void> resetPassword(String email, String code, String password) => api.postPublic(
        '/api/auth/reset-password',
        {'email': email.trim(), 'code': code.trim(), 'password': password});

  Future<void> logout() async {
    final refresh = api.store.refreshToken;
    socket.disconnect();
    try {
      await api.postPublic('/api/auth/logout', {'refreshToken': refresh, if (push.token != null) 'pushToken': push.token});
    } catch (_) {
      // Logging out locally must always work, even offline.
    }
    await _clearLocal();
  }

  void _sessionExpired() {
    if (status != AuthStatus.signedIn) return;
    socket.disconnect();
    notice = 'Your session has expired. Please log in again.';
    _clearLocal();
  }

  Future<void> _clearLocal() async {
    await api.store.clear();
    await notifications.cancelAll();
    user = null;
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  /* ---------- profile ---------- */

  Future<void> updateProfile({String? username, String? about}) async {
    final data = await api.patch('/api/me', {'username': ?username?.trim(), 'about': ?about});
    await _setUser(Map<String, dynamic>.from(data['user'] as Map));
  }

  Future<void> uploadAvatar(Uint8List bytes, String mime, String fileName, {void Function(double)? onProgress}) async {
    final data = await api.upload('/api/me/avatar', bytes: bytes, filename: fileName, mime: mime, method: 'PUT', onProgress: onProgress);
    await _setUser(Map<String, dynamic>.from(data['user'] as Map));
  }

  Future<void> removeAvatar() async {
    final data = await api.delete('/api/me/avatar');
    await _setUser(Map<String, dynamic>.from(data['user'] as Map));
  }

  Future<void> changePassword(String current, String next) =>
      api.post('/api/me/password', {'currentPassword': current, 'newPassword': next});

  Future<void> requestEmailChange(String newEmail, String password) async {
    await api.post('/api/me/email', {'newEmail': newEmail.trim(), 'password': password});
    await refreshMe();
  }

  Future<void> confirmEmailChange(String code) async {
    final data = await api.post('/api/me/email/confirm', {'code': code.trim()});
    await _setUser(Map<String, dynamic>.from(data['user'] as Map));
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
