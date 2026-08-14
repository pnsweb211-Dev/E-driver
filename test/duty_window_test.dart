import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:driver_app/core/alarms/schedule_time.dart';
import 'package:driver_app/core/alarms/upcoming.dart';

/// The arming window for the motion failsafe (§7 Layer 4).
///
/// These tests exist because the backend's equivalent logic shipped a bug that
/// only surfaced when the suite happened to run at 00:17: every offset was
/// measured against *today at start_time*, so a run scheduled just before
/// midnight read as almost a full day away and nothing fired. Time-of-day code
/// has to be exercised at more than one time of day, so the clock is injected
/// here rather than read.
void main() {
  setUpAll(ScheduleTime.ensureInitialized);

  const kolkata = 'Asia/Kolkata';

  UpcomingSchedule scheduleWith(
    List<UpcomingDay> days, {
    String timezone = kolkata,
  }) =>
      UpcomingSchedule(timezone: timezone, days: days);

  UpcomingRun run(
    String startTime, {
    int id = 1,
    bool alertsEnabled = true,
    bool declined = false,
  }) =>
      UpcomingRun(
        scheduleId: id,
        label: 'Morning Pickup',
        direction: 'pickup',
        startTime: startTime,
        alertsEnabled: alertsEnabled,
        declined: declined,
      );

  DateTime at(String date, String time) =>
      tz.TZDateTime.parse(tz.getLocation(kolkata), '$date $time');

  test('arms 45 minutes before the run and not a minute earlier', () {
    final schedule = scheduleWith([
      UpcomingDay(date: '2026-08-10', schoolOpen: true, runs: [run('06:45')]),
    ]);

    expect(currentDutyWindow(schedule, now: at('2026-08-10', '05:59')), isNull);
    expect(currentDutyWindow(schedule, now: at('2026-08-10', '06:01')), isNotNull);
  });

  test('disarms an hour after the planned start', () {
    final schedule = scheduleWith([
      UpcomingDay(date: '2026-08-10', schoolOpen: true, runs: [run('06:45')]),
    ]);

    expect(currentDutyWindow(schedule, now: at('2026-08-10', '07:44')), isNotNull);
    expect(currentDutyWindow(schedule, now: at('2026-08-10', '07:46')), isNull);
  });

  test('a run just before midnight is still armed after midnight', () {
    // The bug the clock found, in app form: dating the run by wall clock puts a
    // 23:50 run 23h40m in the future at 00:10, and the failsafe watches nothing
    // on the one bus that is actually moving.
    final schedule = scheduleWith([
      UpcomingDay(date: '2026-08-10', schoolOpen: true, runs: [run('23:50')]),
      const UpcomingDay(date: '2026-08-11', schoolOpen: true, runs: []),
    ]);

    final window = currentDutyWindow(schedule, now: at('2026-08-11', '00:10'));

    expect(window, isNotNull);
    expect(window!.day.date, '2026-08-10');
  });

  test('never arms on a day the school is closed', () {
    final schedule = scheduleWith([
      UpcomingDay(date: '2026-08-10', schoolOpen: false, runs: [run('06:45')]),
    ]);

    expect(currentDutyWindow(schedule, now: at('2026-08-10', '06:40')), isNull);
  });

  test('a declined run is not watched', () {
    final schedule = scheduleWith([
      UpcomingDay(
        date: '2026-08-10',
        schoolOpen: true,
        runs: [run('06:45', declined: true)],
      ),
    ]);

    expect(currentDutyWindow(schedule, now: at('2026-08-10', '06:40')), isNull);
  });

  test('a route the school has silenced is not watched', () {
    final schedule = scheduleWith([
      UpcomingDay(
        date: '2026-08-10',
        schoolOpen: true,
        runs: [run('06:45', alertsEnabled: false)],
      ),
    ]);

    expect(currentDutyWindow(schedule, now: at('2026-08-10', '06:40')), isNull);
  });

  test('with two overlapping runs the one already started wins', () {
    final schedule = scheduleWith([
      UpcomingDay(date: '2026-08-10', schoolOpen: true, runs: [
        run('13:30', id: 1),
        run('14:00', id: 2),
      ]),
    ]);

    // 14:05 is inside both windows; the bus is on the 14:00 run.
    final window = currentDutyWindow(schedule, now: at('2026-08-10', '14:05'));

    expect(window!.run.scheduleId, 2);
  });

  test('offsets follow the school timezone, not the handset', () {
    final schedule = scheduleWith([
      UpcomingDay(date: '2026-08-10', schoolOpen: true, runs: [run('06:45')]),
    ]);

    // 01:00 UTC is 06:30 in Kolkata — inside the window. A naive implementation
    // reading the device clock would see 01:00 and arm nothing.
    final utcMorning = DateTime.utc(2026, 8, 10, 1, 0);

    expect(currentDutyWindow(schedule, now: utcMorning), isNotNull);
  });

  test('an unparseable time is skipped rather than crashing the sweep', () {
    final schedule = scheduleWith([
      UpcomingDay(date: '2026-08-10', schoolOpen: true, runs: [run('not-a-time')]),
    ]);

    expect(currentDutyWindow(schedule, now: at('2026-08-10', '06:40')), isNull);
  });

  test('an empty schedule arms nothing', () {
    expect(currentDutyWindow(UpcomingSchedule.empty), isNull);
  });
}
