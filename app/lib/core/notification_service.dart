import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// System notifications for new messages and invitations.
///
/// Events arrive over the realtime socket while the app process is alive
/// (foreground or background). When the app is killed, FCM push (see
/// [PushService]) delivers them instead.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Whether the app is currently visible.
  bool appInForeground = true;

  /// Chat currently open on screen (no notification for it while visible).
  String? openChatId;

  /// Called with the payload (`chat:ID` or `invites`) when a notification is tapped.
  void Function(String payload)? onTap;
  String? launchPayload;

  static const _messages = AndroidNotificationChannel('messages', 'Messages',
      description: 'New chat messages', importance: Importance.high);
  static const _invites = AndroidNotificationChannel('invites', 'Invitations',
      description: 'New chat invitations', importance: Importance.high);

  Future<void> init() async {
    if (kIsWeb) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (r) {
          if (r.payload != null) onTap?.call(r.payload!);
        },
      );
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_messages);
      await android?.createNotificationChannel(_invites);
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) launchPayload = launch!.notificationResponse?.payload;
      _ready = true;
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  Future<void> requestPermission() async {
    if (!_ready) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {}
  }

  Future<void> showMessage({required String chatId, required String title, required String body}) async {
    if (!_ready) return;
    if (appInForeground && openChatId == chatId) return;
    await _plugin.show(
      id: chatId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      payload: 'chat:$chatId',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(_messages.id, _messages.name,
            channelDescription: _messages.description,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> showInvite({required String title, required String body}) async {
    if (!_ready) return;
    await _plugin.show(
      id: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
      title: title,
      body: body,
      payload: 'invites',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(_invites.id, _invites.name,
            channelDescription: _invites.description, importance: Importance.high, priority: Priority.high),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> cancelChat(String chatId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: chatId.hashCode & 0x7fffffff);
    } catch (_) {}
  }

  Future<void> cancelAll() async {
    if (_ready) await _plugin.cancelAll();
  }
}
