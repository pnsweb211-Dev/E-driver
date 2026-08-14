import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:driver_app/core/alarms/upcoming.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> payload() => {
        'timezone': 'Asia/Kolkata',
        'days': [
          {
            'date': '2026-08-10',
            'school_open': true,
            'runs': [
              {
                'schedule_id': 7,
                'label': 'Morning Pickup',
                'direction': 'pickup',
                'route_name': 'Route 26',
                'start_time': '06:45',
                'end_time': '08:10',
                'grace_minutes': 3,
                'alerts_enabled': true,
                'declined': false,
              },
            ],
          },
          {'date': '2026-08-11', 'school_open': false, 'runs': []},
        ],
      };

  test('parses the server payload', () {
    final schedule = UpcomingSchedule.fromJson(payload());

    expect(schedule.timezone, 'Asia/Kolkata');
    expect(schedule.days, hasLength(2));
    expect(schedule.days.first.runs.single.scheduleId, 7);
    expect(schedule.days.first.runs.single.graceMinutes, 3);
    expect(schedule.days[1].schoolOpen, isFalse);
  });

  test('a run defaults to alarming, and stops when silenced or declined', () {
    const base = UpcomingRun(
      scheduleId: 1,
      label: 'Run',
      direction: 'pickup',
      startTime: '06:45',
    );

    expect(base.shouldAlarm, isTrue);

    expect(
      const UpcomingRun(
        scheduleId: 1,
        label: 'Run',
        direction: 'pickup',
        startTime: '06:45',
        alertsEnabled: false,
      ).shouldAlarm,
      isFalse,
    );

    expect(
      const UpcomingRun(
        scheduleId: 1,
        label: 'Run',
        direction: 'pickup',
        startTime: '06:45',
        declined: true,
      ).shouldAlarm,
      isFalse,
    );
  });

  test('survives a cache round trip — this is what rings with no signal',
      () async {
    await UpcomingSchedule.fromJson(payload()).cache();

    final restored = await UpcomingSchedule.restore();

    expect(restored.timezone, 'Asia/Kolkata');
    expect(restored.days.first.runs.single.startTime, '06:45');
  });

  test('a corrupt cache degrades to empty rather than crashing the launch',
      () async {
    SharedPreferences.setMockInitialValues({
      'upcoming_schedule_v1': 'not json at all',
    });

    expect((await UpcomingSchedule.restore()).isEmpty, isTrue);
  });

  test('declining marks only that run on that day', () {
    final schedule = UpcomingSchedule.fromJson({
      'timezone': 'Asia/Kolkata',
      'days': [
        {
          'date': '2026-08-10',
          'school_open': true,
          'runs': [
            {'schedule_id': 7, 'start_time': '06:45'},
            {'schedule_id': 8, 'start_time': '14:00'},
          ],
        },
        {
          'date': '2026-08-11',
          'school_open': true,
          'runs': [
            {'schedule_id': 7, 'start_time': '06:45'},
          ],
        },
      ],
    });

    final after = schedule.withDeclined(7, '2026-08-10');

    expect(after.days[0].runs[0].declined, isTrue);
    // The afternoon run is a different trip; declining the morning one must not
    // silence it.
    expect(after.days[0].runs[1].declined, isFalse);
    // And tomorrow is a different day entirely.
    expect(after.days[1].runs[0].declined, isFalse);
  });
}
