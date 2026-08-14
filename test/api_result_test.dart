import 'package:dio/dio.dart';
import 'package:driver_app/core/api/driver_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// The retry contract the outbox depends on.
///
/// `isFinal` decides whether a queued row is deleted or retried forever. Getting
/// it backwards is expensive in both directions: a row wrongly kept spins
/// against the server on every flush, and a row wrongly dropped silently loses
/// a boarding record.
void main() {
  late Dio dio;
  late DriverApi api;
  late _StubAdapter adapter;

  setUp(() {
    dio = Dio(BaseOptions(validateStatus: (_) => true));
    adapter = _StubAdapter();
    dio.httpClientAdapter = adapter;
    api = DriverApi(token: 't', isDriverToken: true, dio: dio);
  });

  test('2xx is a final success', () async {
    adapter.status = 200;
    adapter.body = '{"status":"success"}';

    final result = await api.post('/x', {});

    expect(result.ok, isTrue);
    expect(result.isFinal, isTrue);
  });

  test('a ping sent outside a trip is final, not retried forever', () async {
    // The server answers 200 status:"ignored" when no trip is running. Treating
    // that as retryable would leave the row queued for the rest of time.
    adapter.status = 200;
    adapter.body = '{"status":"ignored","message":"Trip is not active"}';

    final result = await api.post('/location/batch', {});

    expect(result.isFinal, isTrue);
  });

  test('422 is a final rejection — the payload will never be accepted', () async {
    adapter.status = 422;
    adapter.body = '{"message":"Invalid"}';

    final result = await api.post('/x', {});

    expect(result.ok, isFalse);
    expect(result.isFinal, isTrue);
  });

  test('404 is final — e.g. a student who left the school', () async {
    adapter.status = 404;
    adapter.body = '{"message":"That student is not on this route."}';

    expect((await api.post('/x', {})).isFinal, isTrue);
  });

  test('429 is NOT final — a rate limit is a "later", not a "no"', () async {
    adapter.status = 429;
    adapter.body = '{"message":"Too many"}';

    final result = await api.post('/x', {});

    expect(result.isFinal, isFalse);
  });

  test('5xx is NOT final', () async {
    adapter.status = 503;
    adapter.body = '{"message":"Down"}';

    expect((await api.post('/x', {})).isFinal, isFalse);
  });

  test('a network failure is NOT final', () async {
    adapter.throwError = true;

    final result = await api.post('/x', {});

    expect(result.isFinal, isFalse);
    expect(result.ok, isFalse);
  });

  test('a legacy token travels in the body, not the header', () async {
    final legacy = DriverApi(token: 'veh-token', isDriverToken: false, dio: dio);
    adapter.status = 200;
    adapter.body = '{"status":"success"}';

    await legacy.post('/trip-status', {'status': 'start'});

    expect(adapter.lastBody, contains('veh-token'));
    expect(adapter.lastHeaders?.containsKey('Authorization') ?? false, isFalse);
  });

  test('a driver token travels in the header, not the body', () async {
    adapter.status = 200;
    adapter.body = '{"status":"success"}';

    await api.post('/trip-status', {'status': 'start'});

    expect(adapter.lastBody, isNot(contains('api_token')));
    expect(adapter.lastHeaders?['Authorization'], 'Bearer t');
  });
}

class _StubAdapter implements HttpClientAdapter {
  int status = 200;
  String body = '{}';
  bool throwError = false;

  String? lastBody;
  Map<String, dynamic>? lastHeaders;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastHeaders = options.headers;
    lastBody = options.data?.toString();

    if (throwError) {
      throw DioException(requestOptions: options, message: 'No route to host');
    }

    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
