import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../outbox/outbox.dart';
import '../providers.dart';
import 'alarm_service.dart';
import 'alarm_sync.dart';
import 'upcoming.dart';

/// Why a driver says they cannot run a trip.
///
/// A closed list, not free text: "on leave" and "bus in the workshop" are
/// different problems for the office, and the whole value of the decline is
/// that it separates *I forgot* from *I am not running today*. The values match
/// the server's validation exactly.
enum DeclineReason {
  onLeave('on_leave', 'I am on leave'),
  vehicleBreakdown('vehicle_breakdown', 'Bus is in the workshop'),
  routeCancelled('route_cancelled', 'Route cancelled today'),
  substituteDriver('substitute_driver', 'Another driver is taking it'),
  other('other', 'Something else');

  const DeclineReason(this.value, this.label);

  final String value;
  final String label;
}

/// The alarm currently demanding an answer, or null.
///
/// Held as one piece of state for the same reason the session is: the alarm can
/// arrive from a cold start, from a notification tap while the app is open, or
/// from an action button, and all three should land on the same screen by the
/// same route.
class PendingAlarmNotifier extends StateNotifier<AlarmTarget?> {
  PendingAlarmNotifier() : super(null);

  void raise(AlarmTarget target) => state = target;

  void clear() => state = null;
}

final pendingAlarmProvider =
    StateNotifierProvider<PendingAlarmNotifier, AlarmTarget?>(
        (ref) => PendingAlarmNotifier());

class AdherenceState {
  const AdherenceState({
    this.schedule = UpcomingSchedule.empty,
    this.armedCount = 0,
    this.error,
  });

  final UpcomingSchedule schedule;
  final int armedCount;
  final String? error;
}

/// Keeps the on-device alarms in step with the server's timetable.
class AdherenceController extends StateNotifier<AdherenceState> {
  AdherenceController(this._ref) : super(const AdherenceState());

  final Ref _ref;

  /// Fetch the next 7 days and re-register the OS alarms.
  ///
  /// Runs on every app open and after every sign-in. It is safe to call often:
  /// arming is idempotent, and a failed fetch falls back to the cached payload
  /// rather than disarming a driver who happens to be out of signal — which
  /// would silently remove the alarm exactly when it is needed most.
  Future<void> refreshAndArm() async {
    final result = await AlarmSync.run(api: _ref.read(driverApiProvider));

    state = AdherenceState(
      schedule: result.schedule,
      armedCount: result.armed,
      error: result.error,
    );
  }

  /// "I can't run this trip."
  ///
  /// Queued through the outbox rather than posted directly: a driver telling
  /// the school they are on leave must succeed with no signal, and the server
  /// upserts on (schedule, date, stage) so a replayed decline is a no-op.
  /// Alarms are silenced locally straight away — waiting for the round trip
  /// would leave the phone ringing at someone who has already answered.
  Future<void> decline(
    AlarmTarget target,
    DeclineReason reason, {
    String? note,
  }) async {
    await AlarmService.cancelRun(target.scheduleId, target.date);

    await Outbox.enqueueAction(
      endpoint: '/schedules/${target.scheduleId}/decline',
      payload: {
        'reason': reason.value,
        'trip_date': target.date,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );

    // Remember it locally too, so the next arm() does not resurrect the alarms
    // before the server's own view catches up.
    final schedule =
        (await UpcomingSchedule.restore()).withDeclined(target.scheduleId, target.date);
    await schedule.cache();

    await _ref.read(outboxProvider.notifier).flush();

    final armed = await AlarmService.arm(schedule);
    state = AdherenceState(schedule: schedule, armedCount: armed);
  }

  /// The trip for this run has begun — stop the ladder mid-climb.
  Future<void> onRunStarted(AlarmTarget target) =>
      AlarmService.cancelRun(target.scheduleId, target.date);

  /// Client-side audit trail (`alarm_fired`, `snoozed`, `auto_started`,
  /// `permission_lost`), so "we alerted the driver four times" is provable from
  /// the device side too and not just from what the server sent.
  Future<void> report(
    String type, {
    AlarmTarget? target,
    Map<String, dynamic>? meta,
  }) async {
    await Outbox.enqueueAction(
      endpoint: '/adherence-events',
      payload: {
        'type': type,
        if (target != null) 'schedule_id': target.scheduleId,
        if (target != null) 'trip_date': target.date,
        if (meta != null) 'meta': meta,
      },
    );

    await _ref.read(outboxProvider.notifier).bump();
  }
}

final adherenceProvider =
    StateNotifierProvider<AdherenceController, AdherenceState>(
        (ref) => AdherenceController(ref));
