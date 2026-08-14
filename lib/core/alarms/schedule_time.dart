import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'upcoming.dart';

/// Turning a school timetable into instants.
///
/// Pure and plugin-free so it can be tested off-device, which matters more here
/// than anywhere else in the app: the backend's equivalent logic shipped a bug
/// that only appeared when the suite happened to run at 00:17, and time-of-day
/// code that is only ever exercised at one time of day hides exactly that class
/// of mistake.
class ScheduleTime {
  const ScheduleTime._();

  static bool _initialised = false;

  /// Load the tz database. Idempotent, and needed in EVERY isolate that
  /// resolves a school timezone — the background tracker has its own, and
  /// without this its `getLocation` throws and every window silently collapses
  /// to UTC.
  static void ensureInitialized() {
    if (_initialised) return;

    tzdata.initializeTimeZones();
    _initialised = true;
  }

  /// The school's zone, falling back to the device's rather than throwing.
  ///
  /// A wrong-but-plausible zone still rings roughly on time; an exception here
  /// rings never, and this runs during startup.
  static tz.Location resolveLocation(String name) {
    ensureInitialized();

    if (name.isEmpty) return tz.local;

    try {
      return tz.getLocation(name);
    } catch (_) {
      return tz.local;
    }
  }

  /// Combine `yyyy-MM-dd` and `HH:mm` in [location]. Null on anything
  /// unparseable — a malformed row must skip, never crash the arming pass.
  static tz.TZDateTime? startOf(tz.Location location, String date, String time) {
    final d = date.split('-');
    final t = time.split(':');

    if (d.length < 3 || t.length < 2) return null;

    final year = int.tryParse(d[0]);
    final month = int.tryParse(d[1]);
    final day = int.tryParse(d[2]);
    final hour = int.tryParse(t[0]);
    final minute = int.tryParse(t[1]);

    if (year == null || month == null || day == null || hour == null || minute == null) {
      return null;
    }

    return tz.TZDateTime(location, year, month, day, hour, minute);
  }
}

/// A run whose start is close enough to now that the motion failsafe should be
/// watching (§7 Layer 4).
class DutyWindow {
  const DutyWindow({required this.day, required this.run, required this.startsAt});

  final UpcomingDay day;
  final UpcomingRun run;
  final tz.TZDateTime startsAt;
}

/// The arming window either side of a planned start.
///
/// Bounded on purpose: an always-on motion watch is a battery complaint waiting
/// to happen, and movement at 3 p.m. on a bus with no afternoon run is not
/// evidence of anything.
const motionArmBefore = Duration(minutes: 45);
const motionArmAfter = Duration(minutes: 60);

/// The run the app should currently be watching for, if any.
///
/// Scans every cached day rather than assuming "today": a 23:50 run is still
/// live at 00:10 the next morning, and dating it by wall clock is precisely the
/// bug that silently disabled the server ladder.
DutyWindow? currentDutyWindow(UpcomingSchedule schedule, {DateTime? now}) {
  if (schedule.isEmpty) return null;

  final location = ScheduleTime.resolveLocation(schedule.timezone);
  final reference = tz.TZDateTime.from(now ?? DateTime.now(), location);

  DutyWindow? nearest;

  for (final day in schedule.days) {
    if (!day.schoolOpen) continue;

    for (final run in day.runs) {
      if (!run.shouldAlarm) continue;

      final start = ScheduleTime.startOf(location, day.date, run.startTime);

      if (start == null) continue;

      if (reference.isBefore(start.subtract(motionArmBefore))) continue;
      if (reference.isAfter(start.add(motionArmAfter))) continue;

      // Two runs can overlap in the window (a late pickup and an early drop);
      // the one that started most recently is the one being driven.
      if (nearest == null || start.isAfter(nearest.startsAt)) {
        nearest = DutyWindow(day: day, run: run, startsAt: start);
      }
    }
  }

  return nearest;
}
