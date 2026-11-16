import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../alarms/alarm_service.dart';
import 'device_channel.dart';
import 'notification_permission.dart';

/// One row of the pre-flight checklist (§7 Layer 1).
enum ReadinessItem {
  locationServices,
  locationAlways,
  notifications,
  alarmChannel,
  exactAlarms,
  batteryOptimisation,
  autostart,
  autoTime,
}

/// How hard a failed row bites.
///
/// This distinction is the whole design of the screen. A *blocking* row is one
/// the app can both verify and fix, so refusing to continue is fair. A row we
/// can only ask about — OEM autostart has no read API at all, on any Android —
/// must never be a hard block, or a driver ends up with an app that will not
/// open and no way through it. Those are acknowledged instead, and the
/// acknowledgement is reported to the school so a misconfigured phone is still
/// visible on Live Ops.
enum ReadinessSeverity { blocking, acknowledge, advisory }

class ReadinessCheck {
  const ReadinessCheck({
    required this.item,
    required this.severity,
    required this.title,
    required this.why,
    required this.passed,
    required this.fixLabel,
  });

  final ReadinessItem item;
  final ReadinessSeverity severity;
  final String title;

  /// Why it matters, in the driver's terms. Never "grant permission X" — the
  /// consequence is what makes someone tap Fix.
  final String why;
  final bool passed;
  final String fixLabel;

  bool get blocks => !passed && severity == ReadinessSeverity.blocking;
}

/// The result of one sweep of the checklist.
class ReadinessReport {
  const ReadinessReport(this.checks);

  final List<ReadinessCheck> checks;

  /// Nothing that can be both verified and fixed is failing.
  bool get canProceed => !checks.any((c) => c.blocks);

  bool get allGreen => checks.every((c) => c.passed);

  List<ReadinessCheck> get failing =>
      checks.where((c) => !c.passed).toList(growable: false);

  /// Compact shape for the `permissions` field of the Layer 5 heartbeat, so
  /// Live Ops can say "battery optimisation is ON, this bus will stop
  /// reporting" instead of a school guessing.
  Map<String, bool> toHeartbeat() => {
        for (final c in checks) c.item.name: c.passed,
      };
}

/// Evaluates and repairs the checklist.
///
/// Deliberately free of BuildContext: the same sweep runs from the gate screen,
/// from an app-resume handler, and from the background service's heartbeat,
/// and only the first of those has a UI to talk to.
class ReadinessService {
  const ReadinessService._();

  static const _ackKey = 'readiness_acknowledged_v1';

  static Future<ReadinessReport> evaluate() async {
    final isAndroid = Platform.isAndroid;
    final isIOS = Platform.isIOS;
    final servicesOn = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    final notifications = await NotificationPermission.isGranted();
    final channelOk = isAndroid
        ? await AlarmService.alarmChannelIsAudible()
        : true;

    // On Android 11 and below the permission does not exist and exact alarms
    // simply work; permission_handler reports `granted` there, so no special
    // case is needed — but do not "improve" this into a version check.
    final exact = isAndroid
        ? await Permission.scheduleExactAlarm.isGranted
        : true;
    final battery = isAndroid
        ? await Permission.ignoreBatteryOptimizations.isGranted
        : true;

    final hasAutostart = isAndroid && await DeviceChannel.hasAutostartSettings();
    final brand = hasAutostart ? await DeviceChannel.manufacturer() : '';
    final autostartAcked = await _acknowledged(ReadinessItem.autostart);
    final autoTime = isAndroid
        ? await DeviceChannel.isAutoTimeEnabled()
        : true;

    return ReadinessReport([
      ReadinessCheck(
        item: ReadinessItem.locationServices,
        severity: ReadinessSeverity.blocking,
        title: 'Location (GPS) is on',
        why: 'Without GPS the bus does not appear on anyone\'s map.',
        passed: servicesOn,
        fixLabel: 'Turn on',
      ),
      ReadinessCheck(
        item: ReadinessItem.locationAlways,
        severity: ReadinessSeverity.blocking,
        title: isIOS
            ? 'Location access set to Always'
            : 'Location set to "Allow all the time"',
        why: isIOS
            ? 'Allows location updates during assigned trips when the app '
                'moves into the background.'
            : 'On "While using the app", tracking stops the moment your screen '
                'locks — and parents stop seeing the bus.',
        passed: permission == LocationPermission.always,
        fixLabel: isIOS ? 'Continue' : 'Allow',
      ),
      ReadinessCheck(
        item: ReadinessItem.notifications,
        severity: ReadinessSeverity.blocking,
        title: 'Notifications allowed',
        why: 'This is how the app reminds you to start the run.',
        passed: notifications,
        fixLabel: isIOS ? 'Continue' : 'Allow',
      ),
      if (isAndroid) ReadinessCheck(
        item: ReadinessItem.alarmChannel,
        severity: ReadinessSeverity.blocking,
        title: 'Trip Alarms not muted',
        why: 'The start-of-run alarm is worthless in a silenced channel.',
        passed: channelOk,
        fixLabel: 'Unmute',
      ),
      if (isAndroid) ReadinessCheck(
        item: ReadinessItem.exactAlarms,
        severity: ReadinessSeverity.blocking,
        title: 'Alarms can ring on time',
        why: 'Without this Android may delay the 6 a.m. alarm by up to an hour.',
        passed: exact,
        fixLabel: 'Allow',
      ),
      if (isAndroid) ReadinessCheck(
        item: ReadinessItem.batteryOptimisation,
        severity: ReadinessSeverity.blocking,
        title: 'Battery saver exemption',
        why: 'Battery optimisation kills tracking mid-route without warning.',
        passed: battery,
        fixLabel: 'Allow',
      ),
      // Unverifiable by design. Hidden entirely on ROMs that have no such
      // screen (stock Android, Pixel) rather than shown as a row that can
      // never go green.
      if (hasAutostart)
        ReadinessCheck(
          item: ReadinessItem.autostart,
          severity: ReadinessSeverity.acknowledge,
          title: 'Autostart enabled for this app',
          why: 'The most common reason tracking dies on a '
              '${brand.isEmpty ? 'phone like this' : brand} phone. Find this '
              'app in the list and switch it on, then tap "I have done this".',
          passed: autostartAcked,
          fixLabel: 'Open',
        ),
      if (isAndroid) ReadinessCheck(
        item: ReadinessItem.autoTime,
        severity: ReadinessSeverity.advisory,
        title: 'Automatic date & time',
        why: 'A wrong clock makes every alarm fire at the wrong moment.',
        passed: autoTime,
        fixLabel: 'Fix',
      ),
    ]);
  }

  /// Attempt to repair one row. Returns once the driver is back from wherever
  /// the fix sent them; the caller re-evaluates rather than trusting a result.
  static Future<void> fix(ReadinessItem item) async {
    switch (item) {
      case ReadinessItem.locationServices:
        await Geolocator.openLocationSettings();

      case ReadinessItem.locationAlways:
        // Android only offers "Allow all the time" after foreground access.
        // iOS may also require a second settings step for Always authorization.
        final current = await Geolocator.checkPermission();

        if (current == LocationPermission.denied) {
          await Geolocator.requestPermission();
        } else if (current == LocationPermission.deniedForever) {
          await Geolocator.openAppSettings();
        } else if (Platform.isIOS) {
          // Don't call Android's permission_handler locationAlways path on iOS.
          // iOS manages escalation to Always in its own authorization flow.
          await Geolocator.openAppSettings();
        } else {
          final result = await Permission.locationAlways.request();
          if (!result.isGranted) await Geolocator.openAppSettings();
        }

      case ReadinessItem.notifications:
        await NotificationPermission.requestOrOpenSettings();

      case ReadinessItem.alarmChannel:
        await AlarmService.openAlarmChannelSettings();

      case ReadinessItem.exactAlarms:
        if (Platform.isAndroid) {
          final result = await Permission.scheduleExactAlarm.request();
          if (!result.isGranted) await openAppSettings();
        }

      case ReadinessItem.batteryOptimisation:
        if (Platform.isAndroid) {
          await Permission.ignoreBatteryOptimizations.request();
        }

      case ReadinessItem.autostart:
        final opened = await DeviceChannel.openAutostartSettings();
        if (!opened) await openAppSettings();

      case ReadinessItem.autoTime:
        await DeviceChannel.openDateTimeSettings();
    }
  }

  /// Record that the driver says they enabled an unverifiable setting.
  static Future<void> acknowledge(ReadinessItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final acked = prefs.getStringList(_ackKey) ?? <String>[];

    if (!acked.contains(item.name)) {
      acked.add(item.name);
      await prefs.setStringList(_ackKey, acked);
    }
  }

  static Future<bool> _acknowledged(ReadinessItem item) async {
    final prefs = await SharedPreferences.getInstance();

    return (prefs.getStringList(_ackKey) ?? const <String>[]).contains(item.name);
  }

  /// Clear acknowledgements on sign-out, so the next driver on this handset is
  /// walked through the checklist rather than inheriting someone else's
  /// "yes, I did that".
  static Future<void> forget() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_ackKey);
  }
}
