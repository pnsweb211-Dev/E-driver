import 'package:flutter_test/flutter_test.dart';

import 'package:driver_app/core/alarms/alarm_ladder.dart';

void main() {
  group('ladder shape', () {
    test('a near-day run gets the two reminders and a repeating alarm tail', () {
      final rungs = fullLadder();

      expect(rungs.first.offsetMinutes, -30);
      expect(rungs.first.kind, RungKind.reminder);
      expect(rungs[1].offsetMinutes, -10);
      expect(rungs[1].kind, RungKind.warning);

      final alarms = rungs.where((r) => r.kind == RungKind.alarm).toList();

      expect(alarms.first.offsetMinutes, 0);
      expect(alarms.last.offsetMinutes, 30);
      // Every 3 minutes from T+0 to T+30 inclusive.
      expect(alarms.length, 11);
    });

    test('a distant day arms only what must survive a week offline', () {
      final rungs = distantLadder();

      expect(rungs.map((r) => r.offsetMinutes), [-10, 0]);

      // Android caps pending exact alarms per app; the point of the short
      // ladder is that seven days of full ladders would eat that budget.
      expect(rungs.length, lessThan(fullLadder().length));
    });
  });

  group('notification ids', () {
    test('are stable, so re-arming replaces rather than stacks', () {
      const rung = LadderRung(offsetMinutes: 0, kind: RungKind.alarm);

      expect(
        rungNotificationId(12, '2026-08-10', rung),
        rungNotificationId(12, '2026-08-10', rung),
      );
    });

    test('differ by schedule, by date and by rung', () {
      const zero = LadderRung(offsetMinutes: 0, kind: RungKind.alarm);
      const three = LadderRung(offsetMinutes: 3, kind: RungKind.alarm);

      final base = rungNotificationId(12, '2026-08-10', zero);

      expect(rungNotificationId(13, '2026-08-10', zero), isNot(base));
      expect(rungNotificationId(12, '2026-08-11', zero), isNot(base));
      expect(rungNotificationId(12, '2026-08-10', three), isNot(base));
    });

    test('stay inside the positive 32-bit range Android accepts', () {
      // A whole week of runs, which is what arm() actually registers.
      for (var schedule = 1; schedule <= 40; schedule++) {
        for (var day = 1; day <= 7; day++) {
          for (final rung in fullLadder()) {
            final id = rungNotificationId(schedule, '2026-08-0$day', rung);

            expect(id, greaterThan(0));
            expect(id, lessThanOrEqualTo(0x7fffffff));
          }
        }
      }
    });

    test('a full week of ids does not collide', () {
      final ids = <int>{};
      var generated = 0;

      for (var schedule = 1; schedule <= 40; schedule++) {
        for (var day = 10; day <= 16; day++) {
          for (final rung in fullLadder()) {
            ids.add(rungNotificationId(schedule, '2026-08-$day', rung));
            generated++;
          }
        }
      }

      // A collision means one run silently cancels another's alarm.
      expect(ids.length, generated);
    });
  });
}
