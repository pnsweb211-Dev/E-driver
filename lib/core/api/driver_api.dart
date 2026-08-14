import 'package:dio/dio.dart';

import '../../config/app_config.dart';

/// Outcome of a queued request.
///
/// [isFinal] is the important bit for the outbox: it means "stop retrying this
/// row". A success is final; so is a rejection the server will never accept
/// (a 404 for a student who left, a 422 for a malformed payload). A network
/// error or a 5xx is NOT final — the row stays queued.
class ApiResult {
  const ApiResult({
    required this.ok,
    required this.isFinal,
    this.data,
    this.message,
    this.statusCode,
  });

  final bool ok;
  final bool isFinal;
  final Map<String, dynamic>? data;
  final String? message;
  final int? statusCode;

  factory ApiResult.success(Map<String, dynamic>? data) =>
      ApiResult(ok: true, isFinal: true, data: data);

  /// Server said no, and will keep saying no.
  factory ApiResult.rejected(int status, String? message) =>
      ApiResult(ok: false, isFinal: true, message: message, statusCode: status);

  /// Could not be delivered — try again later.
  factory ApiResult.deferred(String message, [int? status]) =>
      ApiResult(ok: false, isFinal: false, message: message, statusCode: status);
}

/// Thin Dio wrapper over the driver API.
///
/// Constructed with an explicit token rather than reading global state, so it
/// works unchanged inside the background tracking isolate — which has no access
/// to the app's provider container.
class DriverApi {
  DriverApi({
    required this.token,
    required this.isDriverToken,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: '${AppConfig.origin}/api/v1/driver',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'Accept': 'application/json'},
              // Handle every status ourselves; a 4xx is information, not a crash.
              validateStatus: (_) => true,
            ));

  final Dio _dio;
  final String token;

  /// A Sanctum driver token goes in the Authorization header; the legacy
  /// per-vehicle token (which hardware GPS units also use) goes in the body.
  final bool isDriverToken;

  Options get _options => Options(
        headers: isDriverToken ? {'Authorization': 'Bearer $token'} : null,
      );

  Map<String, dynamic> _withToken(Map<String, dynamic> body) =>
      isDriverToken ? body : {...body, 'api_token': token};

  Future<ApiResult> post(String path, Map<String, dynamic> body) async {
    try {
      final res = await _dio.post(path, data: _withToken(body), options: _options);

      return _interpret(res);
    } on DioException catch (e) {
      return ApiResult.deferred(e.message ?? 'Network error');
    }
  }

  Future<ApiResult> get(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.get(
        path,
        queryParameters: query,
        options: _options,
      );

      return _interpret(res);
    } on DioException catch (e) {
      return ApiResult.deferred(e.message ?? 'Network error');
    }
  }

  Future<ApiResult> sendLocationBatch(List<Map<String, dynamic>> pings) =>
      post('/location/batch', {'pings': pings});

  ApiResult _interpret(Response res) {
    final status = res.statusCode ?? 0;
    final body = res.data is Map<String, dynamic> ? res.data as Map<String, dynamic> : null;
    final message = body?['message'] as String?;

    if (status >= 200 && status < 300) {
      // The server answers 200 with status:"ignored" for a ping sent while no
      // trip is running. That is a definite outcome — the row must be dropped,
      // not retried forever.
      return ApiResult.success(body);
    }

    // 401/403 — the token may have been revoked, or the school switched off
    // this feature. Not retryable by the outbox; the session layer handles it.
    // 429 IS retryable: it is a rate limit, not a rejection.
    if (status == 429 || status >= 500) {
      return ApiResult.deferred(message ?? 'Server unavailable', status);
    }

    return ApiResult.rejected(status, message);
  }
}
