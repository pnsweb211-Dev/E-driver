import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/driver_api.dart';
import '../outbox/outbox.dart';
import 'device_channel.dart';

/// §7 Layer 5 — the liveness beat that makes a silent bus diagnosable.
///
/// Posted from the background service every two minutes, in every duty mode.
/// This is the layer that turns "the tracking doesn't work" from a mystery
/// support ticket into a line on the Live Operations console: *battery 6%*,
/// *location downgraded to While using*, *last ping 14 min ago*.
///
/// Deliberately static and provider-free — it runs inside the tracking isolate,
/// which has no Riverpod container. It reads the session straight from
/// SharedPreferences for the same reason the outbox does.
class Heartbeat {
  const Heartbeat._();

  static const interval = Duration(minutes: 2);

  /// Never throws. A failed heartbeat must not take down tracking; the server
  /// notices the gap by itself, which is exactly what it is there for.
  static Future<bool> send() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final token = prefs.getString('api_token');
      final deviceUuid = prefs.getString('device_uuid');

      // The endpoint keys on the bound device, and the legacy per-vehicle token
      // has no driver behind it — nothing to report against.
      if (token == null || token.isEmpty) return false;
      if (deviceUuid == null || deviceUuid.isEmpty) return false;
      if (prefs.getBool('is_driver_token') != true) return false;

      final battery = await DeviceChannel.battery();
      final permissions = await _permissionSnapshot();

      String? version;
      try {
        version = (await PackageInfo.fromPlatform()).version;
      } catch (_) {}

      final api = DriverApi(token: token, isDriverToken: true);

      final result = await api.post('/heartbeat', {
        'device_uuid': deviceUuid,
        if (battery.level != null) 'battery_pct': battery.level,
        if (battery.charging != null) 'is_charging': battery.charging,
        'gps_on': permissions['locationServices'],
        'mock_detected': prefs.getBool('mock_location_seen') ?? false,
        'permissions': permissions,
        'queued_events': await Outbox.pendingCount(),
        if (version != null) 'app_version': version,
      });

      return result.ok;
    } catch (_) {
      return false;
    }
  }

  /// The same keys the readiness screen reports, gathered without a UI.
  ///
  /// Kept independent of ReadinessService.evaluate() on purpose: that call
  /// reaches the notification plugin and the platform channel, neither of which
  /// belongs in a two-minute background timer.
  static Future<Map<String, bool>> _permissionSnapshot() async {
    final permission = await Geolocator.checkPermission();

    return {
      'locationServices': await Geolocator.isLocationServiceEnabled(),
      'locationAlways': permission == LocationPermission.always,
      'notifications': await Permission.notification.isGranted,
      'exactAlarms': await Permission.scheduleExactAlarm.isGranted,
      'batteryOptimisation': await Permission.ignoreBatteryOptimizations.isGranted,
    };
  }

  /// Record that a position claimed to be mocked, so the next heartbeat carries
  /// it even if the trip has since ended. Set from the ping path, which is the
  /// only place that sees a Position.
  static Future<void> noteMockLocation(bool mocked) async {
    if (!mocked) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('mock_location_seen', true);
  }
}
