import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Server address. Can be baked in at build time (`--dart-define=API_URL=...`)
/// and changed at runtime from the login screen ("Server settings").
class AppConfig extends ChangeNotifier {
  AppConfig._(this._prefs, this._serverUrl);

  static const _key = 'server_url';

  /// Android emulators reach the host machine via 10.0.2.2.
  static const String defaultServerUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: kIsWeb ? '' : 'http://10.0.2.2:3000',
  );

  final SharedPreferences _prefs;
  String _serverUrl;

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    var url = prefs.getString(_key) ?? defaultServerUrl;
    if (kIsWeb && url.isEmpty) url = Uri.base.origin; // web build served next to the API
    return AppConfig._(prefs, url);
  }

  String get serverUrl => _serverUrl;

  Future<void> setServerUrl(String url) async {
    _serverUrl = normalize(url);
    await _prefs.setString(_key, _serverUrl);
    notifyListeners();
  }

  static String normalize(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}
