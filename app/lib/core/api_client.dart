import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';

import 'app_config.dart';
import 'session_store.dart';

/// Error returned by the API (or a network failure), with a user-friendly message.
class ApiException implements Exception {
  ApiException(this.code, this.message, {this.status, this.field, this.data = const {}});

  final String code;
  final String message;
  final int? status;
  final String? field;
  final Map<String, dynamic> data;

  bool get isNetwork => code == 'NETWORK';

  @override
  String toString() => message;
}

/// Thin wrapper over Dio: base URL, bearer token, transparent token refresh and error mapping.
class ApiClient {
  ApiClient(this.config, this.store) {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(minutes: 3),
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        options.baseUrl = config.serverUrl;
        if (options.extra['noAuth'] != true && store.refreshToken != null && _expiresSoon(store.accessToken)) {
          // Refresh proactively so large uploads don't have to be re-sent after a 401.
          try {
            await refreshTokens();
          } on ApiException catch (e) {
            if (e.code == 'SESSION_EXPIRED') onSessionExpired?.call();
          } catch (_) {}
        }
        final token = store.accessToken;
        if (token != null && options.extra['noAuth'] != true) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        final res = error.response;
        final code = _errorCode(res?.data);
        final retried = error.requestOptions.extra['retried'] == true;
        if (res?.statusCode == 401 &&
            !retried &&
            error.requestOptions.extra['noAuth'] != true &&
            (code == 'TOKEN_EXPIRED' || code == 'UNAUTHORIZED') &&
            store.refreshToken != null) {
          try {
            await refreshTokens();
            final opts = error.requestOptions
              ..extra['retried'] = true
              ..headers['Authorization'] = 'Bearer ${store.accessToken}';
            // A multipart body can only be sent once; resend a fresh copy.
            if (opts.data is FormData) opts.data = (opts.data as FormData).clone();
            return handler.resolve(await _dio.fetch(opts));
          } on ApiException catch (e) {
            if (e.code == 'SESSION_EXPIRED') onSessionExpired?.call();
          } catch (_) {}
        }
        handler.next(error);
      },
    ));
  }

  final AppConfig config;
  final SessionStore store;
  late final Dio _dio;

  /// Called when the refresh token is no longer valid (session expired / revoked).
  void Function()? onSessionExpired;

  /// Called with fresh tokens (e.g. to reconnect the socket).
  void Function()? onTokensRefreshed;

  Completer<void>? _refreshing;

  /// True when the JWT access token is missing or expires within 30 seconds.
  static bool _expiresSoon(String? token) {
    if (token == null) return true;
    try {
      final parts = token.split('.');
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      final exp = DateTime.fromMillisecondsSinceEpoch((payload['exp'] as num).toInt() * 1000);
      return exp.isBefore(DateTime.now().add(const Duration(seconds: 30)));
    } catch (_) {
      return false; // unknown format: let the server decide
    }
  }

  String get baseUrl => config.serverUrl;

  /// Turns a relative media URL returned by the API into an absolute one.
  String? absoluteUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    return '$baseUrl$path';
  }

  /// Single-flight refresh: concurrent 401s wait for the same refresh call.
  Future<void> refreshTokens() async {
    if (_refreshing != null) return _refreshing!.future;
    final completer = _refreshing = Completer<void>();
    completer.future.ignore(); // errors are delivered to the awaiting callers
    try {
      final data = await postPublic('/api/auth/refresh', {'refreshToken': store.refreshToken});
      await store.saveTokens(data['tokens'] as Map<String, dynamic>);
      completer.complete();
      onTokensRefreshed?.call();
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      _refreshing = null;
    }
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _dio.get(path, queryParameters: query));

  Future<Map<String, dynamic>> post(String path, [Object? body]) => _send(() => _dio.post(path, data: body ?? {}));

  /// POST without the access token (login, register, refresh, …).
  Future<Map<String, dynamic>> postPublic(String path, Object body) =>
      _send(() => _dio.post(path, data: body, options: Options(extra: {'noAuth': true})));

  Future<Map<String, dynamic>> patch(String path, Object body) => _send(() => _dio.patch(path, data: body));

  Future<Map<String, dynamic>> put(String path, Object body) => _send(() => _dio.put(path, data: body));

  Future<Map<String, dynamic>> delete(String path) => _send(() => _dio.delete(path));

  Future<Map<String, dynamic>> upload(
    String path, {
    required Uint8List bytes,
    required String filename,
    required String mime,
    Map<String, String> fields = const {},
    String method = 'POST',
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) {
    final form = FormData.fromMap({
      ...fields,
      'file': MultipartFile.fromBytes(bytes, filename: filename, contentType: MediaType.parse(mime)),
    });
    return _send(() => _dio.request(
          path,
          data: form,
          options: Options(method: method),
          cancelToken: cancelToken,
          onSendProgress: onProgress == null ? null : (sent, total) => onProgress(total > 0 ? sent / total : 0),
        ));
  }

  Future<Map<String, dynamic>> _send(Future<Response> Function() request) async {
    try {
      final res = await request();
      final data = res.data;
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  static String? _errorCode(dynamic data) =>
      data is Map && data['error'] is Map ? (data['error']['code'] as String?) : null;

  ApiException _map(DioException e) {
    final res = e.response;
    if (res == null) {
      if (e.type == DioExceptionType.cancel) return ApiException('CANCELLED', 'Cancelled');
      final timeout = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout;
      return ApiException(
        'NETWORK',
        timeout ? 'The server is taking too long to respond. Try again.' : 'Cannot reach the server. Check your connection.',
      );
    }
    final data = res.data;
    if (data is Map && data['error'] is Map) {
      final err = Map<String, dynamic>.from(data['error'] as Map);
      return ApiException(
        err['code'] as String? ?? 'ERROR',
        err['message'] as String? ?? 'Something went wrong',
        status: res.statusCode,
        field: err['field'] as String?,
        data: err,
      );
    }
    if (res.statusCode == 413) return ApiException('FILE_TOO_LARGE', 'File is too large', status: 413);
    return ApiException('HTTP_${res.statusCode}', 'Server error (${res.statusCode}). Try again later.', status: res.statusCode);
  }
}
