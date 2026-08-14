import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';
import '../services/background_service.dart';
import 'alarms/alarm_service.dart';
import 'alarms/upcoming.dart';
import 'api/driver_api.dart';
import 'outbox/outbox.dart';
import 'push/driver_push.dart';
import 'readiness/readiness.dart';
import 'session/session.dart';
import 'tracking/tracking_gate.dart';

/// The signed-in driver, or null. Everything the router does keys off this.
class SessionNotifier extends StateNotifier<Session?> {
  SessionNotifier() : super(null);

  bool _restored = false;
  bool get restored => _restored;

  Future<void> restore() async {
    state = await Session.restore();
    _restored = true;
  }

  Future<void> signIn(Session session) async {
    await session.persist();

    // Kept out of Session.persist() because the background push isolate reads
    // this key on its own, with no session object in scope.
    await DriverPush.rememberConfig(session.firebaseConfig);

    state = session;
  }

  /// Re-read `/me`.
  ///
  /// Capabilities used to be captured at sign-in and never refreshed, so a
  /// school switching a driver to `full` mode did nothing until that driver
  /// happened to sign out and back in. Called on resume; silent on failure,
  /// because a driver out of signal must keep the mode they already have rather
  /// than falling back to `simple` mid-route.
  Future<void> refreshProfile(DriverApi? api) async {
    if (api == null || state == null) return;

    final result = await api.get('/me');

    if (!result.ok) return;

    final data = result.data?['data'] as Map<String, dynamic>?;

    if (data == null) return;

    final school = data['school'] as Map<String, dynamic>?;

    final updated = state!.withProfile(
      capabilities:
          Capabilities.fromJson(data['capabilities'] as Map<String, dynamic>?),
      // Refreshed on resume too, so a school correcting its office number does
      // not have to wait for every driver to sign out and back in.
      schoolName: data['school_name'] as String?,
      schoolPhone: school?['phone'] as String?,
      schoolEmail: school?['email'] as String?,
      schoolAddress: school?['address'] as String?,
    );

    await updated.persist();

    // The school may have registered its own Firebase app since sign-in.
    await DriverPush.rememberConfig(
      data['firebase_config'] as Map<String, dynamic>?,
    );

    state = updated;
  }

  Future<void> signOut() async {
    // Kill the token server-side FIRST, while it is still valid. Signing out
    // used to be local-only: the Sanctum token stayed live until an admin
    // revoked the device, so a driver who "signed out" before handing the phone
    // over had in practice done nothing. Never throws — offline sign-out must
    // still work.
    final current = state;
    if (current != null) await ApiService.logout(current.token);

    await DriverPush.stop();

    // Drop the queue as well: flushing it under the next driver's credentials
    // would attribute one driver's boardings to another.
    await Outbox.clear();

    // Same reasoning for everything §7 left on the handset: armed alarms, the
    // cached timetable and the "yes I enabled autostart" acknowledgements all
    // belong to the driver who is leaving. A relief driver signing in must be
    // walked through the checklist and armed against THEIR runs, not woken at
    // 06:15 for a route they do not drive.
    await AlarmService.cancelAllArmed();
    await UpcomingSchedule.forget();
    await ReadinessService.forget();
    await setTripActive(false);

    // The duty service would idle harmlessly once the token is gone, but it
    // would keep its foreground notification up on a handset nobody is signed
    // in to. Stop it outright.
    await TrackingGate.stopService();

    await Session.forget();
    state = null;
  }
}

final sessionProvider =
    StateNotifierProvider<SessionNotifier, Session?>((ref) => SessionNotifier());

/// API client bound to the current session. Null when signed out.
final driverApiProvider = Provider<DriverApi?>((ref) {
  final session = ref.watch(sessionProvider);

  if (session == null) return null;

  return DriverApi(token: session.token, isDriverToken: session.isDriverToken);
});

/// How many actions are waiting to sync. Surfaced in the UI so a driver knows
/// their taps landed and does not re-tap.
class OutboxNotifier extends StateNotifier<int> {
  OutboxNotifier(this._ref) : super(0) {
    _refresh();

    // Flush the moment signal comes back — the single most valuable trigger,
    // since that is exactly when a queue has built up.
    _connectivity = Connectivity().onConnectivityChanged.listen((result) {
      final online = result.any((r) => r != ConnectivityResult.none);
      if (online) flush();
    });

    _timer = Timer.periodic(const Duration(seconds: 30), (_) => flush());
  }

  final Ref _ref;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _timer;
  bool _flushing = false;

  Future<void> _refresh() async {
    state = await Outbox.pendingCount();
  }

  Future<void> flush() async {
    // A flush already running must not be re-entered: two passes over the same
    // rows would post them twice. The server dedupes, but doing it here saves
    // the round trip and keeps the pending count honest.
    if (_flushing) return;

    final api = _ref.read(driverApiProvider);
    if (api == null) return;

    _flushing = true;
    try {
      await Outbox.flush(api: api);
    } finally {
      _flushing = false;
      await _refresh();
    }
  }

  /// Call after enqueueing so the badge updates immediately.
  Future<void> bump() => _refresh();

  @override
  void dispose() {
    _connectivity?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}

final outboxProvider =
    StateNotifierProvider<OutboxNotifier, int>((ref) => OutboxNotifier(ref));
