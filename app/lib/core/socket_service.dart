import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'api_client.dart';

class SocketEvent {
  SocketEvent(this.name, this.data);
  final String name;
  final dynamic data;
}

/// Realtime connection. Re-broadcasts server events on a single stream
/// that controllers subscribe to, and reconnects with fresh tokens when needed.
class SocketService extends ChangeNotifier {
  SocketService(this.api);

  final ApiClient api;
  io.Socket? _socket;
  final _events = StreamController<SocketEvent>.broadcast();
  bool _connected = false;
  bool _wanted = false;
  Timer? _retry;
  Timer? _watchdog;
  DateTime _openedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const _serverEvents = [
    'message:new',
    'message:updated',
    'message:status',
    'typing',
    'presence',
    'chat:new',
    'chat:removed',
    'chat:updated',
    'invite:new',
    'invite:updated',
    'user:updated',
    'me:updated',
  ];

  Stream<SocketEvent> get events => _events.stream;
  bool get connected => _connected;

  void connect() {
    _wanted = true;
    _open();
    // Watchdog: if the connection stays down (e.g. a stuck reconnect), rebuild it.
    _watchdog ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (_wanted && !_connected && DateTime.now().difference(_openedAt) > const Duration(seconds: 15)) {
        _open();
      }
    });
  }

  void _open() {
    _dispose();
    final token = api.store.accessToken;
    if (!_wanted || token == null) return;
    _openedAt = DateTime.now();
    final socket = io.io(
      api.baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          // A fresh manager every time: the cached one is closed by dispose() and would never reconnect.
          .enableForceNew()
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .disableAutoConnect()
          .build(),
    );
    socket.onConnect((_) {
      _setConnected(true);
      _events.add(SocketEvent('connect', null));
    });
    socket.onDisconnect((_) => _setConnected(false));
    socket.onConnectError((err) async {
      _setConnected(false);
      final unauthorized = err.toString().contains('UNAUTHORIZED') ||
          (err is Map && err['message'] == 'UNAUTHORIZED');
      if (unauthorized) {
        // Access token expired: refresh and reconnect with the new one.
        socket.dispose();
        try {
          await api.refreshTokens();
          _open();
        } catch (e) {
          if (e is ApiException && e.code == 'SESSION_EXPIRED') {
            api.onSessionExpired?.call();
          } else {
            _scheduleRetry();
          }
        }
      }
    });
    for (final name in _serverEvents) {
      socket.on(name, (data) => _events.add(SocketEvent(name, data)));
    }
    socket.connect();
    _socket = socket;
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), _open);
  }

  /// Reconnect using the latest access token (after refresh / server change).
  void reconnect() {
    if (_wanted) _open();
  }

  void emit(String event, dynamic data) {
    if (_connected) _socket?.emit(event, data);
  }

  void disconnect() {
    _wanted = false;
    _watchdog?.cancel();
    _watchdog = null;
    _dispose();
    _setConnected(false);
  }

  void _dispose() {
    _retry?.cancel();
    _socket?.dispose();
    _socket = null;
  }

  void _setConnected(bool v) {
    if (_connected == v) return;
    _connected = v;
    notifyListeners();
  }
}
