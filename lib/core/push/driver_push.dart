import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../alarms/alarm_service.dart';
import '../alarms/alarm_sync.dart';
import '../api/driver_api.dart';
import '../../services/api_service.dart';

/// §7 Layer 3, the device half.
///
/// The server ladder pushes the driver at T-30, T-10 and once a run is overdue.
/// Until this existed the app had no Firebase at all, so `driver_devices
/// .fcm_token` was always NULL, `AdherenceService::pushToDriver()` returned
/// early every time, and **all three driver rungs delivered to nobody** — while
/// the manager and admin escalations went out normally, which made the gap look
/// like the driver ignoring the app.
///
/// There is no `google-services.json`. Firebase is initialised from the config
/// the server returns at sign-in (the parent app's pattern), so one APK serves
/// every school and a white-label school supplies its own App ID from the panel
/// without a rebuild.
class DriverPush {
  const DriverPush._();

  static const _configKey = 'firebase_config';

  static bool _started = false;

  /// The T-30 rung is data-only and carries `action: rearm_alarms`. Re-arming
  /// from it is what keeps a phone that has been backgrounded for days ringing
  /// on time.
  static const actionRearm = 'rearm_alarms';
  static const actionOpenToday = 'open_today';

  /// Persist the config so the background isolate — which never sees a login
  /// response — can initialise Firebase too.
  static Future<void> rememberConfig(Map<String, dynamic>? config) async {
    final prefs = await SharedPreferences.getInstance();

    if (config == null || config.isEmpty) {
      await prefs.remove(_configKey);
      return;
    }

    await prefs.setString(_configKey, jsonEncode(config));
  }

  static Future<Map<String, dynamic>?> _storedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_configKey);

    if (raw == null || raw.isEmpty) return null;

    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Bring Firebase up from a stored (or freshly received) config.
  ///
  /// Returns false when there is nothing configured — a perfectly normal state
  /// for a deployment that has not set up FCM, and never an error.
  static Future<bool> _ensureFirebase() async {
    if (Firebase.apps.isNotEmpty) return true;

    final config = await _storedConfig();

    if (config == null) return false;

    final appId = config['appId'] as String? ?? '';
    final apiKey = config['apiKey'] as String? ?? '';
    final senderId = config['messagingSenderId'] as String? ?? '';
    final projectId = config['projectId'] as String? ?? '';

    // A half-filled config initialises "successfully" and then fails to
    // register a token, which is exactly the kind of silent dead end this whole
    // class exists to remove.
    if (appId.isEmpty || apiKey.isEmpty || senderId.isEmpty || projectId.isEmpty) {
      return false;
    }

    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: senderId,
        projectId: projectId,
        storageBucket: config['storageBucket'] as String? ?? '',
      ),
    );

    return true;
  }

  /// Called once the driver is signed in and the phone has passed readiness.
  ///
  /// Never throws: push is an enhancement over the on-device alarms, not a
  /// prerequisite for them, and a Firebase failure must not stop a bus being
  /// tracked.
  static Future<bool> start() async {
    if (_started) return true;

    try {
      if (!await _ensureFirebase()) return false;

      final messaging = FirebaseMessaging.instance;

      await messaging.requestPermission();

      final token = await messaging.getToken();
      if (token != null) await _register(token);

      messaging.onTokenRefresh.listen(_register);

      FirebaseMessaging.onMessage.listen(_handleForeground);
      FirebaseMessaging.onBackgroundMessage(driverPushBackgroundHandler);

      _started = true;

      return true;
    } catch (_) {
      return false;
    }
  }

  /// Hand the token to the server against THIS device row, so the office can
  /// revoke a lost phone and have its pushes stop with it.
  static Future<void> _register(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final apiToken = prefs.getString('api_token');

      // Only a Sanctum driver token identifies a driver; the legacy per-vehicle
      // token is shared with hardware GPS units and has no device row.
      if (apiToken == null || apiToken.isEmpty) return;
      if (prefs.getBool('is_driver_token') != true) return;

      final device = await ApiService.describeDevice();

      await DriverApi(token: apiToken, isDriverToken: true)
          .post('/device', {'device': {...device, 'fcm_token': token}});
    } catch (_) {
      // A failed registration just means the server ladder stays silent for
      // now; the local alarms are unaffected and the next sign-in retries.
    }
  }

  static Future<void> _handleForeground(RemoteMessage message) async {
    if (message.data['action'] == actionRearm) {
      await AlarmSync.run();
      return;
    }

    // The app is open and the local alarm already owns the screen at T-0, so a
    // foreground banner would only duplicate it. Show one only for the rungs
    // that are not backed by an alarm.
    final notification = message.notification;

    if (notification == null) return;

    await AlarmService.plugin.show(
      _pushNotificationId,
      notification.title,
      notification.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          AlarmService.reminderChannelId,
          'Trip Reminders',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  /// Stop this handset receiving pushes. Called on sign-out, before the session
  /// is cleared, so the next driver on the phone does not inherit the last
  /// one's route reminders.
  static Future<void> stop() async {
    try {
      if (Firebase.apps.isNotEmpty) {
        await FirebaseMessaging.instance.deleteToken();
      }
    } catch (_) {
      // Offline sign-out still clears the session; the server-side token dies
      // with the device revoke or the next registration.
    }

    await rememberConfig(null);
    _started = false;
  }
}

/// Fixed id so a second reminder replaces the first instead of stacking.
const _pushNotificationId = 88802;

/// Runs in its OWN isolate when a push arrives with the app backgrounded or
/// killed — which is the normal state at 06:15.
///
/// Must be a top-level function with the vm:entry-point pragma, and must not
/// touch anything from the UI isolate: no providers, no session object. It
/// re-reads the token from SharedPreferences exactly as the outbox does.
@pragma('vm:entry-point')
Future<void> driverPushBackgroundHandler(RemoteMessage message) async {
  if (message.data['action'] != DriverPush.actionRearm) return;

  try {
    if (!await DriverPush._ensureFirebase()) return;

    // The notification plugin is per-isolate; arming without initialising it
    // here would silently schedule nothing.
    await AlarmService.init(onSelect: (_, __) {});

    await AlarmSync.run();
  } catch (_) {
    // A failed re-arm leaves the alarms already on the device in place. They
    // were armed a week ahead precisely so one missed re-arm is survivable.
  }
}
