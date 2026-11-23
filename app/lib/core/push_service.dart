import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// Optional Firebase Cloud Messaging (push while the app is closed).
///
/// Enabled only when the app is built with the Firebase options, e.g.
///   flutter build apk --dart-define-from-file=firebase.json
/// Otherwise the app relies on realtime socket notifications.
class PushService {
  PushService(this.api);

  final ApiClient api;

  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  static bool get configured => _apiKey.isNotEmpty && _appId.isNotEmpty && _senderId.isNotEmpty && _projectId.isNotEmpty;

  bool _initialized = false;
  StreamSubscription<String>? _tokenSub;
  String? token;
  void Function(String payload)? onOpen;

  Future<void> init() async {
    if (!configured || kIsWeb || _initialized) return;
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(apiKey: _apiKey, appId: _appId, messagingSenderId: _senderId, projectId: _projectId),
      );
      _initialized = true;
      FirebaseMessaging.onMessageOpenedApp.listen(_handleOpen);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _handleOpen(initial);
    } catch (e) {
      debugPrint('FCM init failed: $e');
    }
  }

  void _handleOpen(RemoteMessage m) {
    final type = m.data['type'];
    if (type == 'message' && m.data['chatId'] != null) onOpen?.call('chat:${m.data['chatId']}');
    if (type == 'invite') onOpen?.call('invites');
  }

  /// Registers this device's token with the backend (after login).
  Future<void> register() async {
    if (!_initialized) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      _tokenSub ??= messaging.onRegistered.listen((t) {
        token = t;
        api.post('/api/me/push-token', {'token': t, 'platform': defaultTargetPlatform.name}).ignore();
      });
      await messaging.register();
    } catch (e) {
      debugPrint('FCM register failed: $e');
    }
  }
}
