import 'package:shared_preferences/shared_preferences.dart';

import '../api/driver_api.dart';
import 'alarm_service.dart';
import 'upcoming.dart';

/// The outcome of one arming pass.
class ArmResult {
  const ArmResult({required this.schedule, required this.armed, this.error});

  final UpcomingSchedule schedule;
  final int armed;

  /// Set when the server could not be reached. Not fatal — the cached
  /// timetable was armed instead.
  final String? error;
}

/// Fetch the week's runs and register the OS alarms.
///
/// Provider-free on purpose. Three callers need this and only one of them has a
/// Riverpod container:
///
///   1. the app on launch and after sign-in;
///   2. the **background FCM handler**, which runs in its own isolate when the
///      T-30 data push arrives — the whole reason that push exists is to re-arm
///      a phone that has not been opened for days;
///   3. a decline, which re-arms with one run removed.
///
/// Falling back to the cache on a failed fetch is deliberate: disarming a
/// driver because they happened to be out of signal would remove the alarm at
/// exactly the moment it is most needed.
class AlarmSync {
  const AlarmSync._();

  static Future<ArmResult> run({DriverApi? api}) async {
    var schedule = await UpcomingSchedule.restore();
    String? error;

    final client = api ?? await _clientFromStoredSession();

    if (client != null) {
      final result = await client.get('/schedules/upcoming');

      if (result.ok) {
        final data = result.data?['data'] as Map<String, dynamic>? ?? const {};

        // A driver with no bus assigned gets an empty payload. Cache it anyway —
        // it is the truth, and alarms for a route they no longer drive are
        // worse than none.
        schedule = UpcomingSchedule.fromJson(data);
        await schedule.cache();
      } else {
        error = result.message;
      }
    }

    return ArmResult(
      schedule: schedule,
      armed: await AlarmService.arm(schedule),
      error: error,
    );
  }

  /// Build a client straight from disk. The background isolate has no session
  /// object, and the outbox already reads the token this way.
  static Future<DriverApi?> _clientFromStoredSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token');

    if (token == null || token.isEmpty) return null;

    return DriverApi(
      token: token,
      isDriverToken: prefs.getBool('is_driver_token') ?? false,
    );
  }
}
