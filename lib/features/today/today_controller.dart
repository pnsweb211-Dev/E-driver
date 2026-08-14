import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/alarms/alarm_service.dart';
import '../../core/providers.dart';
import '../../services/background_service.dart';
import 'today_models.dart';

/// Today's runs and the trip lifecycle.
///
/// Start/stop are NOT queued through the outbox: a trip boundary is the one
/// thing that must be agreed with the server before tracking is meaningful, and
/// a locally-started trip that never reached the server would show the school an
/// idle bus while the driver believed they were live. Boarding marks, which are
/// safe to reconcile later, do go through the queue.
class TodayController extends StateNotifier<TodayState> {
  TodayController(this._ref) : super(const TodayState());

  final Ref _ref;

  Future<void> load() async {
    final api = _ref.read(driverApiProvider);
    if (api == null) return;

    state = state.copyWith(loading: true, clearError: true);

    final result = await api.get('/today');

    if (!result.ok) {
      state = state.copyWith(
        loading: false,
        error: result.message ?? 'Could not load today\'s runs.',
      );
      return;
    }

    final data = result.data?['data'] as Map<String, dynamic>? ?? {};
    final runs = (data['runs'] as List<dynamic>? ?? [])
        .map((r) => TodayRun.fromJson(r as Map<String, dynamic>))
        .toList();
    final active = data['active_trip'] as Map<String, dynamic>?;
    final vehicle = data['vehicle'] as Map<String, dynamic>?;

    state = TodayState(
      runs: runs,
      activeTrip: active == null ? null : ActiveTrip.fromJson(active),
      vehicleNumber: vehicle?['vehicle_number'] as String?,
      message: data['message'] as String?,
      loading: false,
    );

    // Reconcile the duty service with the server, which is the only authority
    // on whether a trip is open.
    //
    // The service decides trip / watch / idle from the `trip_active` pref, and
    // nothing used to keep that pref honest: it was written by startTrip,
    // stopTrip and signOut, and by nothing else. Any divergence was therefore
    // permanent for the rest of the run — the app was reinstalled, the process
    // died between the server call and the pref write, an admin or
    // `close-abandoned-trips` moved the trip, or the driver started it on
    // another handset.
    //
    // The failure was silent and it was the worst possible shape: this screen
    // reads `active_trip` from the SERVER, so it kept showing "Running" and
    // "Parents can see the bus" while the service sat in idle and uploaded
    // nothing. That is exactly the invisible non-tracking §7 exists to prevent.
    //
    // Placed after the !ok early-return on purpose: a failed refresh must never
    // be read as "no trip", or one dead spot would stop tracking for the rest
    // of the route.
    await setTripActive(state.activeTrip != null);
  }

  /// Start a run. [scheduleId] is null in simple mode — the server infers which
  /// run is meant, so the driver never sees a picker.
  Future<bool> startTrip({int? scheduleId, double? lat, double? lng}) async {
    final api = _ref.read(driverApiProvider);
    if (api == null) return false;

    state = state.copyWith(loading: true, clearError: true);

    final result = await api.post('/trip-status', {
      'status': 'start',
      if (scheduleId != null) 'schedule_id': scheduleId,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
    });

    if (!result.ok) {
      state = state.copyWith(
        loading: false,
        error: result.message ?? 'Could not start the trip.',
      );
      return false;
    }

    await load();

    // Tell the duty service a trip is open. It reads a pref rather than taking
    // a message because it can be restarted (after a reboot, or an OEM kill)
    // with nobody around to send it one.
    await setTripActive(true);

    // Stop the §7 ladder mid-climb: an alarm that keeps ringing at a driver who
    // is already driving is how an alarm app gets muted for good. Uses the
    // trip's own date, which the server resolves and is not always today.
    final trip = state.activeTrip;
    if (trip?.scheduleId != null && trip?.tripDate != null) {
      await AlarmService.cancelRun(trip!.scheduleId!, trip.tripDate!);
    }

    return true;
  }

  Future<bool> stopTrip({double? lat, double? lng}) async {
    final api = _ref.read(driverApiProvider);
    if (api == null) return false;

    // Push anything queued before closing the trip, so the server computes the
    // summary over the complete breadcrumb rather than one missing its tail.
    await _ref.read(outboxProvider.notifier).flush();

    state = state.copyWith(loading: true, clearError: true);

    final result = await api.post('/trip-status', {
      'status': 'stop',
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
    });

    if (!result.ok) {
      state = state.copyWith(
        loading: false,
        error: result.message ?? 'Could not stop the trip.',
      );
      return false;
    }

    await setTripActive(false);
    await load();
    return true;
  }
}

final todayProvider =
    StateNotifierProvider<TodayController, TodayState>((ref) => TodayController(ref));
