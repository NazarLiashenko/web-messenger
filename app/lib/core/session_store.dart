import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the session (tokens + last known profile) in the platform keystore
/// (Android Keystore / iOS Keychain / WebCrypto-encrypted storage on web).
class SessionStore {
  static const _storage = FlutterSecureStorage();
  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kUser = 'user';

  String? accessToken;
  String? refreshToken;
  Map<String, dynamic>? cachedUser;

  bool get hasSession => refreshToken != null;

  Future<void> load() async {
    try {
      accessToken = await _storage.read(key: _kAccess);
      refreshToken = await _storage.read(key: _kRefresh);
      final u = await _storage.read(key: _kUser);
      cachedUser = u == null ? null : jsonDecode(u) as Map<String, dynamic>;
    } catch (_) {
      // Corrupted keystore (e.g. after a backup restore): start clean.
      await clear();
    }
  }

  Future<void> saveTokens(Map<String, dynamic> tokens) async {
    accessToken = tokens['accessToken'] as String?;
    refreshToken = tokens['refreshToken'] as String?;
    await _storage.write(key: _kAccess, value: accessToken);
    await _storage.write(key: _kRefresh, value: refreshToken);
  }

  Future<void> saveUser(Map<String, dynamic> user) async {
    cachedUser = user;
    await _storage.write(key: _kUser, value: jsonEncode(user));
  }

  /// Small offline cache (e.g. the chat list), encrypted by the platform keystore.
  /// Wiped together with the session on logout.
  Future<Object?> readCache(String key) async {
    try {
      final v = await _storage.read(key: 'cache_$key');
      return v == null ? null : jsonDecode(v);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCache(String key, Object? value) async {
    try {
      await _storage.write(key: 'cache_$key', value: jsonEncode(value));
    } catch (_) {}
  }

  Future<void> clear() async {
    accessToken = null;
    refreshToken = null;
    cachedUser = null;
    try {
      await _storage.deleteAll();
    } catch (_) {}
  }
}
