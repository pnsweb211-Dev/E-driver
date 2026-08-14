import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../core/outbox/outbox.dart';

class ApiService {
  // Single source of truth — server URL lives in AppConfig (edit there per client).
  static const String _defaultBaseUrl = AppConfig.origin;
  static const Duration _timeout = Duration(seconds: 15);

  /// Public base URL (scheme + host) for callers like BrandingService.
  static String get baseUrl => _defaultBaseUrl;

  // ===========================================================================
  // Driver ID sign-in (current)
  //
  // The Driver ID is globally unique, so it identifies the school by itself —
  // which is the whole point: the driver is never told the school's email
  // address, which is also the school admin's login.
  // ===========================================================================

  /// Sign in with the Driver ID and PIN issued by the school office.
  static Future<Map<String, dynamic>> loginWithCode(
    String loginCode,
    String pin,
  ) async {
    return _authRequest('/api/v1/driver/login', {
      'login_code': loginCode.trim(),
      'pin': pin,
      'device': await describeDevice(),
    });
  }

  /// First-run setup from the QR (or setup code) the school office shows.
  /// The driver picks their own PIN here — nobody reads one out to them.
  static Future<Map<String, dynamic>> enrol(
    String enrolmentToken,
    String pin,
  ) async {
    return _authRequest('/api/v1/driver/enrol', {
      'enrolment_token': enrolmentToken.trim(),
      'pin': pin,
      'pin_confirmation': pin,
      'device': await describeDevice(),
    });
  }

  /// Shared POST + session-persistence for every sign-in path.
  static Future<Map<String, dynamic>> _authRequest(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_defaultBaseUrl$path'),
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && responseData['status'] == 'success') {
        await _persistSession(responseData['data']);
      }

      return responseData;
    } on http.ClientException {
      return {
        'status': 'error',
        'message': 'Could not connect to server. Please check your internet connection.'
      };
    } catch (e) {
      return {'status': 'error', 'message': 'Connection failed: ${e.toString()}'};
    }
  }

  /// Stores whichever session shape came back.
  ///
  /// `token` is the Sanctum driver token (new sign-in); `api_token` is the
  /// legacy per-vehicle token. Both are written to `api_token` so the existing
  /// background tracker keeps working unchanged, and `is_driver_token` records
  /// which one it is so the tracker knows whether to send it as a Bearer header
  /// or in the request body.
  static Future<void> _persistSession(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();

    final driverToken = data['token'] as String?;
    final legacyToken = data['api_token'] as String?;

    await prefs.setString('api_token', driverToken ?? legacyToken ?? '');
    await prefs.setBool('is_driver_token', driverToken != null);
    await prefs.setString('driver_name', data['driver_name'] ?? 'Driver');
    await prefs.setString('school_name', data['school_name'] ?? '');

    // New payload nests the bus; the legacy one carries it flat.
    final vehicle = data['vehicle'] as Map<String, dynamic>?;
    await prefs.setString(
      'vehicle_number',
      (vehicle?['vehicle_number'] ?? data['vehicle_number'] ?? '') as String,
    );

    final capabilities = data['capabilities'] as Map<String, dynamic>?;
    // Fail closed to `simple`: an app that cannot tell what it is allowed to
    // show must show the least, never the most.
    await prefs.setString('app_mode', (capabilities?['app_mode'] ?? 'simple') as String);

    if (data['login_code'] != null) {
      await prefs.setString('login_code', data['login_code'] as String);
    }

    await saveSchoolId(data['school_id']);
  }

  /// Stable per-install id plus the handset details the office sees when it
  /// needs to sign a lost or stolen phone out.
  static Future<Map<String, dynamic>> describeDevice() async {
    final prefs = await SharedPreferences.getInstance();

    var uuid = prefs.getString('device_uuid');
    if (uuid == null || uuid.isEmpty) {
      final random = Random.secure();
      uuid = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString('device_uuid', uuid);
    }

    String? model;
    String platform = Platform.operatingSystem;
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        model = '${android.manufacturer} ${android.model}';
      } else if (Platform.isIOS) {
        final ios = await info.iosInfo;
        model = ios.utsname.machine;
      }
    } catch (_) {
      // Device details are useful, not essential — never block a sign-in on them.
    }

    String? appVersion;
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}

    return {
      'uuid': uuid,
      'platform': platform,
      if (model != null) 'model': model,
      if (appVersion != null) 'app_version': appVersion,
    };
  }

  /// True when the stored token is a Sanctum driver token rather than the
  /// legacy per-vehicle one. Decides how the token is presented to the server.
  static Future<bool> isDriverToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('is_driver_token') ?? false;
  }

  /// LEGACY Driver Login (school email + vehicle number + vehicle password).
  /// Kept so a driver who has not updated the app is not stranded; the server
  /// gates it per school and it will be removed.
  static Future<Map<String, dynamic>> login(
    String schoolEmail,
    String vehicleNumber,
    String password,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('$_defaultBaseUrl/api/v1/driver/login'),
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode({
          'school_email': schoolEmail,
          'vehicle_number': vehicleNumber,
          'password': password,
        }),
      ).timeout(_timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && responseData['status'] == 'success') {
        await _persistSession(responseData['data']);
      }

      return responseData;
    } on http.ClientException {
      return {'status': 'error', 'message': 'Could not connect to server. Please check your internet connection.'};
    } catch (e) {
      return {'status': 'error', 'message': 'Connection failed: ${e.toString()}'};
    }
  }

  /// Persist the logged-in school so [BrandingService] can ask for THIS school's
  /// driver brand instead of the platform default. Tolerates an int or a string
  /// (and an older backend that omits the key entirely — then nothing is stored
  /// and branding stays on the platform brand, exactly as before).
  static Future<void> saveSchoolId(dynamic raw) async {
    final id = raw is int ? raw : int.tryParse('${raw ?? ''}');
    if (id == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('school_id', id);
  }

  /// Returns true when the backend runs in demo mode. Defaults to false on any
  /// error so real deployments never show the demo button.
  static Future<bool> checkDemoMode() async {
    try {
      final response = await http.get(
        Uri.parse('$_defaultBaseUrl/api/v1/demo/config'),
        headers: {'Accept': 'application/json'},
      ).timeout(_timeout);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['demo_mode'] == true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// One-tap demo login: the server picks a seeded demo vehicle and returns the
  /// same payload as [login]. Persists the session identically.
  ///
  /// Sends `device` like every other sign-in path. It used to post no body at
  /// all, and the consequences were entirely invisible: `touchDevice()` bails
  /// on a blank uuid, so no `driver_devices` row was ever created, the Sanctum
  /// token was named `driver-device:unknown`, and — because it is
  /// [describeDevice] that mints the `device_uuid` pref — [Heartbeat.send]
  /// short-circuited on the handset before it ever reached the server. A demo
  /// session therefore ran with §7 Layer 5 liveness dead and no FCM binding,
  /// which is precisely the configuration a demo is meant to show off.
  static Future<Map<String, dynamic>> demoLogin() async {
    try {
      final response = await http.post(
        Uri.parse('$_defaultBaseUrl/api/v1/driver/demo-login'),
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode({'device': await describeDevice()}),
      ).timeout(_timeout);

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && responseData['status'] == 'success') {
        await _persistSession(responseData['data']);
      }

      return responseData;
    } on http.ClientException {
      return {'status': 'error', 'message': 'Could not connect to server. Please check your internet connection.'};
    } catch (e) {
      return {'status': 'error', 'message': 'Connection failed: ${e.toString()}'};
    }
  }

  /// Headers and body wrapper that presents whichever token this session holds.
  ///
  /// A driver token is a Sanctum token and belongs in the Authorization header;
  /// the legacy per-vehicle token is what hardware GPS units send, and the
  /// server still reads that from the body.
  static Future<(Map<String, String>, Map<String, dynamic>)> _tokenEnvelope(
    String token,
    Map<String, dynamic> body,
  ) async {
    final headers = {'Content-Type': 'application/json', 'Accept': 'application/json'};

    if (await isDriverToken()) {
      headers['Authorization'] = 'Bearer $token';
      return (headers, body);
    }

    return (headers, {...body, 'api_token': token});
  }

  /// Revoke this handset's session server-side.
  ///
  /// Only meaningful for a Sanctum driver token — the legacy per-vehicle token
  /// is shared with the hardware GPS unit and must never be revoked from here.
  /// Never throws: signing out locally has to work with no signal.
  static Future<void> logout(String token) async {
    if (!await isDriverToken()) return;

    try {
      await http.post(
        Uri.parse('$_defaultBaseUrl/api/v1/driver/logout'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(_timeout);
    } catch (_) {
      // Offline sign-out still clears the local session; the token is left to
      // expire or be revoked by the office.
    }
  }

  /// Toggle Trip (start / stop)
  static Future<Map<String, dynamic>> toggleTrip(String apiToken, String status) async {
    try {
      final (headers, body) = await _tokenEnvelope(apiToken, {'status': status});

      final response = await http.post(
        Uri.parse('$_defaultBaseUrl/api/v1/driver/trip-status'),
        headers: headers,
        body: jsonEncode(body),
      ).timeout(_timeout);

      return jsonDecode(response.body);
    } on http.ClientException {
      return {'status': 'error', 'message': 'Could not connect to server.'};
    } catch (e) {
      return {'status': 'error', 'message': 'Connection failed: ${e.toString()}'};
    }
  }

  /// Send Location — called by the background service.
  ///
  /// Every position is written to the durable outbox FIRST and only then sent.
  /// Buses drive through dead zones: before this, a ping that failed a handful
  /// of retries was simply lost and the trail had a hole in it. Now the row
  /// survives until the server has acknowledged it.
  ///
  /// Returns true when the queue was drained, so the tracker's own notification
  /// still reflects reality.
  static Future<bool> sendLocation(double lat, double lng, double speed) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token');

    if (token == null || token.isEmpty) return false;

    await Outbox.enqueuePing(lat: lat, lng: lng, speed: speed);

    // Runs in the background ISOLATE, which is why Outbox is plain sqflite with
    // no provider wiring — none of the app's DI exists out here.
    try {
      final cleared = await Outbox.flush();

      return cleared > 0;
    } catch (e) {
      // Queued is good enough; the next fix, or the app's own 30s timer, will
      // try again.
      return false;
    }
  }

  /// Legacy single-ping POST. Retained for reference and for any caller that
  /// genuinely needs a synchronous send; the tracker no longer uses it.
  static Future<bool> sendLocationDirect(double lat, double lng, double speed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('api_token');

      if (token == null || token.isEmpty) return false;

      final (headers, body) = await _tokenEnvelope(token, {
        'lat': lat,
        'lng': lng,
        'speed': speed,
      });

      final response = await http.post(
        Uri.parse('$_defaultBaseUrl/api/v1/driver/location'),
        headers: headers,
        body: jsonEncode(body),
      ).timeout(_timeout);

      final data = jsonDecode(response.body);
      if (data['status'] != 'success') {
        print('[TRACKER] Server returned non-success: ${response.body} (Status: ${response.statusCode})');
      }
      return data['status'] == 'success';
    } catch (e) {
      print('ApiService.sendLocation error: $e');
      return false;
    }
  }
}