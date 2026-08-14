import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../readiness/device_channel.dart';
import 'alarm_ladder.dart';
import 'schedule_time.dart';
import 'upcoming.dart';

/// Which run an alarm is about. Travels as the notification payload and is what
/// the full-screen alarm screen is built from.
class AlarmTarget {
  const AlarmTarget({
    required this.scheduleId,
    required this.date,
    required this.label,
    required this.startTime,
    this.routeName,
    this.direction = 'pickup',
  });

  final int scheduleId;

  /// The run's OWN date (`yyyy-MM-dd`), which is not always today — a 23:50 run
  /// alarmed at 00:05 belongs to yesterday. The server's decline and dedupe
  /// keys are dated the same way, and a mismatch means the driver gets chased
  /// for a run they already dealt with.
  final String date;
  final String label;
  final String startTime;
  final String? routeName;
  final String direction;

  String encode() => jsonEncode({
        'schedule_id': scheduleId,
        'date': date,
        'label': label,
        'start_time': startTime,
        'route_name': routeName,
        'direction': direction,
      });

  static AlarmTarget? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;

    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;

      return AlarmTarget(
        scheduleId: json['schedule_id'] as int,
        date: json['date'] as String,
        label: json['label'] as String? ?? 'Run',
        startTime: json['start_time'] as String? ?? '',
        routeName: json['route_name'] as String?,
        direction: json['direction'] as String? ?? 'pickup',
      );
    } catch (_) {
      return null;
    }
  }
}

/// §7 Layer 2 — the on-device alarm that works offline and with the app killed.
///
/// The server ladder (Layer 3) cannot help a phone that is in a dead zone at
/// 06:45, which is most buses most mornings. So the next week of runs is
/// fetched up front and registered as real OS alarms: exact, alarm-category,
/// full-screen, and re-registered by Android itself after a reboot.
///
/// There are exactly two ways to silence one — start the trip, or decline it
/// with a reason. Snooze exists but is capped, so it cannot be tapped into
/// oblivion.
class AlarmService {
  const AlarmService._();

  static const alarmChannelId = 'trip_alarm';
  static const reminderChannelId = 'trip_reminder';

  static const _armedIdsKey = 'armed_alarm_ids_v1';
  static const _snoozeKeyPrefix = 'alarm_snooze_';
  static const maxSnoozes = 2;
  static const snoozeMinutes = 5;

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static FlutterLocalNotificationsPlugin get plugin => _plugin;

  static AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// Called once at startup, before the first frame.
  ///
  /// [onSelect] fires when the driver taps an alarm or one of its actions. It
  /// runs in the UI isolate, so it can safely hand the target to Riverpod.
  static Future<void> init({
    required void Function(AlarmTarget target, String? actionId) onSelect,
  }) async {
    if (_ready) return;

    ScheduleTime.ensureInitialized();

    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final target = AlarmTarget.decode(response.payload);
        if (target != null) onSelect(target, response.actionId);
      },
    );

    await _createChannels();

    _ready = true;
  }

  static Future<void> _createChannels() async {
    // Importance.max + the alarm audio usage is what makes this ring over a
    // silent profile at alarm volume instead of arriving as a polite chirp.
    await _android?.createNotificationChannel(const AndroidNotificationChannel(
      alarmChannelId,
      'Trip Alarms',
      description: 'Rings when a scheduled run is due to start.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
    ));

    await _android?.createNotificationChannel(const AndroidNotificationChannel(
      reminderChannelId,
      'Trip Reminders',
      description: 'Heads-up before a run is due.',
      importance: Importance.high,
    ));
  }

  /// Did the app get launched by tapping an alarm? Checked on cold start,
  /// because that is the normal path at 06:45: the phone was not open.
  static Future<AlarmTarget?> launchTarget() async {
    final details = await _plugin.getNotificationAppLaunchDetails();

    if (details?.didNotificationLaunchApp != true) return null;

    return AlarmTarget.decode(details!.notificationResponse?.payload);
  }

  /// Whether "Trip Alarms" can actually be heard. A driver who long-pressed the
  /// notification and chose "silent" has disabled the whole mechanism, and
  /// nothing else would ever tell us.
  static Future<bool> alarmChannelIsAudible() async {
    final android = _android;

    if (android == null) return true;

    // No notification permission at all is reported by its own checklist row;
    // do not double-flag it here.
    if (await android.areNotificationsEnabled() == false) return true;

    final channels = await android.getNotificationChannels();

    // Pre-Oreo, or a plugin that cannot enumerate: assume audible rather than
    // block the driver on something unverifiable.
    if (channels == null || channels.isEmpty) return true;

    final channel = channels.where((c) => c.id == alarmChannelId).firstOrNull;

    if (channel == null) return true;

    return channel.importance.value >= Importance.high.value && channel.playSound;
  }

  static Future<bool> openAlarmChannelSettings() =>
      DeviceChannel.openChannelSettings(alarmChannelId);

  // ───────────────────────────────────────────────────────────── arming ──

  /// Register OS alarms for everything in [schedule].
  ///
  /// Idempotent: rung ids are derived from (schedule, date, offset), so calling
  /// this on every app open replaces each alarm in place rather than stacking
  /// duplicates. Anything previously armed and no longer in the payload — a run
  /// that was declined, silenced or deleted — is cancelled.
  ///
  /// Returns how many alarms are now pending, which is what the debug row on
  /// the readiness screen shows.
  static Future<int> arm(UpcomingSchedule schedule, {DateTime? now}) async {
    if (!_ready || schedule.isEmpty) return 0;

    final location = ScheduleTime.resolveLocation(schedule.timezone);
    final reference = tz.TZDateTime.from(now ?? DateTime.now(), location);

    final armed = <int>{};

    for (var dayIndex = 0; dayIndex < schedule.days.length; dayIndex++) {
      final day = schedule.days[dayIndex];

      if (!day.schoolOpen) continue;

      // Days 0–1 get the full nag; the rest get the two rungs that have to
      // survive a week with no signal. See distantLadder().
      final ladder = dayIndex <= 1 ? fullLadder() : distantLadder();

      for (final run in day.runs) {
        if (!run.shouldAlarm) continue;

        final start = ScheduleTime.startOf(location, day.date, run.startTime);

        if (start == null) continue;

        final target = AlarmTarget(
          scheduleId: run.scheduleId,
          date: day.date,
          label: run.label,
          startTime: run.startTime,
          routeName: run.routeName,
          direction: run.direction,
        );

        for (final rung in ladder) {
          final at = start.add(Duration(minutes: rung.offsetMinutes));

          // An alarm in the past cannot be scheduled, and back-dating one would
          // fire it instantly — the classic way this kind of code wakes a
          // driver at midnight for a run that finished at breakfast.
          if (!at.isAfter(reference)) continue;

          final id = rungNotificationId(run.scheduleId, day.date, rung);

          await _schedule(id: id, at: at, rung: rung, run: run, target: target);
          armed.add(id);
        }
      }
    }

    await _reconcile(armed);

    return armed.length;
  }

  static Future<void> _schedule({
    required int id,
    required tz.TZDateTime at,
    required LadderRung rung,
    required UpcomingRun run,
    required AlarmTarget target,
  }) async {
    final isAlarm = rung.kind == RungKind.alarm;
    final route = run.routeName ?? run.label;

    final title = switch (rung.kind) {
      RungKind.reminder => '$route starts in 30 minutes',
      RungKind.warning => '$route starts in 10 minutes',
      RungKind.alarm => rung.offsetMinutes == 0
          ? '$route — start the trip now'
          : '$route has not started',
    };

    final body = switch (rung.kind) {
      RungKind.reminder => 'Scheduled for ${run.startTime}. Tap to open.',
      RungKind.warning => 'Scheduled for ${run.startTime}. Start the trip when you leave.',
      RungKind.alarm =>
        'Due at ${run.startTime}. Start the trip, or tell the school you cannot run it.',
    };

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      at,
      NotificationDetails(
        android: AndroidNotificationDetails(
          isAlarm ? alarmChannelId : reminderChannelId,
          isAlarm ? 'Trip Alarms' : 'Trip Reminders',
          importance: isAlarm ? Importance.max : Importance.high,
          priority: isAlarm ? Priority.max : Priority.high,
          category: isAlarm ? AndroidNotificationCategory.alarm : null,
          audioAttributesUsage:
              isAlarm ? AudioAttributesUsage.alarm : AudioAttributesUsage.notification,
          // Lights the screen at 06:45 with the phone face-down in a pocket.
          fullScreenIntent: isAlarm,
          // Not swipeable: the ONLY ways out are Start and "can't run".
          ongoing: isAlarm,
          autoCancel: !isAlarm,
          playSound: true,
          enableVibration: true,
          actions: isAlarm
              ? const [
                  AndroidNotificationAction('start', 'START TRIP',
                      showsUserInterface: true, cancelNotification: true),
                  AndroidNotificationAction('decline', "CAN'T RUN",
                      showsUserInterface: true, cancelNotification: true),
                ]
              : null,
        ),
      ),
      // exactAllowWhileIdle is the whole point: an inexact alarm can drift by
      // an hour under Doze, which for a 06:45 bus is useless.
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: target.encode(),
    );
  }

  /// Cancel anything we armed last time that is not armed this time.
  ///
  /// Tracking our own ids rather than calling `cancelAll()` keeps this from
  /// tearing down the tracking service's foreground notification, which is
  /// posted by a different plugin and must survive.
  static Future<void> _reconcile(Set<int> armed) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = (prefs.getStringList(_armedIdsKey) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>();

    for (final id in previous) {
      if (!armed.contains(id)) await _plugin.cancel(id);
    }

    await prefs.setStringList(
      _armedIdsKey,
      armed.map((id) => id.toString()).toList(growable: false),
    );
  }

  /// Silence one run for one day — called the moment its trip starts or it is
  /// declined, so the ladder stops mid-climb instead of ringing at a driver who
  /// is already driving.
  static Future<void> cancelRun(int scheduleId, String date) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = (prefs.getStringList(_armedIdsKey) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();

    final ids = {
      for (final rung in fullLadder()) rungNotificationId(scheduleId, date, rung),
      for (final rung in distantLadder()) rungNotificationId(scheduleId, date, rung),
      _snoozeNotificationId(scheduleId, date),
    };

    for (final id in ids) {
      await _plugin.cancel(id);
      previous.remove(id);
    }

    await prefs.setStringList(
      _armedIdsKey,
      previous.map((id) => id.toString()).toList(growable: false),
    );
  }

  /// Drop every armed alarm. Sign-out only — the next driver on this handset
  /// must not inherit the last one's runs.
  static Future<void> cancelAllArmed() async {
    final prefs = await SharedPreferences.getInstance();

    for (final raw in prefs.getStringList(_armedIdsKey) ?? const <String>[]) {
      final id = int.tryParse(raw);
      if (id != null) await _plugin.cancel(id);
    }

    await prefs.remove(_armedIdsKey);

    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(_snoozeKeyPrefix)) await prefs.remove(key);
    }
  }

  // ───────────────────────────────────────────────────────────── snooze ──

  static String _snoozeKey(int scheduleId, String date) =>
      '$_snoozeKeyPrefix${scheduleId}_$date';

  static int _snoozeNotificationId(int scheduleId, String date) =>
      rungNotificationId(scheduleId, date,
          const LadderRung(offsetMinutes: 9999, kind: RungKind.alarm));

  static Future<int> snoozesUsed(int scheduleId, String date) async {
    final prefs = await SharedPreferences.getInstance();

    return prefs.getInt(_snoozeKey(scheduleId, date)) ?? 0;
  }

  static Future<bool> canSnooze(int scheduleId, String date) async =>
      await snoozesUsed(scheduleId, date) < maxSnoozes;

  /// Push the alarm back five minutes, at most twice.
  ///
  /// The cap is deliberate: an uncapped snooze is just a dismiss with extra
  /// steps, and the whole point of this layer is that the run cannot be quietly
  /// ignored. Returns false when the driver has run out.
  static Future<bool> snooze(AlarmTarget target) async {
    final used = await snoozesUsed(target.scheduleId, target.date);

    if (used >= maxSnoozes) return false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_snoozeKey(target.scheduleId, target.date), used + 1);

    final at = tz.TZDateTime.now(tz.local).add(const Duration(minutes: snoozeMinutes));
    final route = target.routeName ?? target.label;

    await _plugin.zonedSchedule(
      _snoozeNotificationId(target.scheduleId, target.date),
      '$route has not started',
      'Snoozed reminder. ${maxSnoozes - used - 1} snooze(s) left.',
      at,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          alarmChannelId,
          'Trip Alarms',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          actions: [
            AndroidNotificationAction('start', 'START TRIP',
                showsUserInterface: true, cancelNotification: true),
            AndroidNotificationAction('decline', "CAN'T RUN",
                showsUserInterface: true, cancelNotification: true),
          ],
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: target.encode(),
    );

    return true;
  }

}
