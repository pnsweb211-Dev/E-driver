import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/outbox/outbox.dart';
import '../../core/providers.dart';
import 'manifest_models.dart';

/// The stop-by-stop student list, and marking who got on.
///
/// Marking is OPTIMISTIC and offline-first: the tap updates local state and is
/// written to the outbox, never awaited against the network. A driver at a stop
/// in the dark with one bar of signal cannot be made to wait for a round trip
/// before the next child can be marked — that is the difference between a tool
/// that gets used and one that gets abandoned.
class ManifestController extends StateNotifier<ManifestState> {
  ManifestController(this._ref) : super(const ManifestState());

  final Ref _ref;

  Future<void> load(int tripId) async {
    final api = _ref.read(driverApiProvider);
    if (api == null) return;

    state = state.copyWith(tripId: tripId, loading: true, clearError: true);

    final result = await api.get('/trips/$tripId/manifest');

    if (!result.ok) {
      state = state.copyWith(
        loading: false,
        error: result.message ?? 'Could not load the student list.',
      );
      return;
    }

    final data = result.data?['data'] as Map<String, dynamic>? ?? {};
    final caps = data['capabilities'] as Map<String, dynamic>? ?? {};

    state = ManifestState(
      tripId: tripId,
      routeName: data['route_name'] as String?,
      stops: (data['stops'] as List<dynamic>? ?? [])
          .map((s) => ManifestStop.fromJson(s as Map<String, dynamic>))
          .toList(),
      canViewGuardianPhone: caps['can_view_guardian_phone'] != false,
      canViewStudentPhoto: caps['can_view_student_photo'] != false,
      loading: false,
    );
  }

  /// Mark one student. Returns immediately; the sync happens behind the badge.
  Future<void> mark(int studentId, String status) async {
    final tripId = state.tripId;
    if (tripId == null) return;

    _applyLocally(studentId, status);

    await Outbox.enqueueAction(
      endpoint: '/trips/$tripId/students/$studentId/status',
      payload: {
        'status': status,
        'method': 'manual',
        // The moment the driver actually tapped, not when this eventually
        // reaches the server after a dead zone.
        'event_at': DateTime.now().toUtc().toIso8601String(),
      },
    );

    await _ref.read(outboxProvider.notifier).bump();
    unawaited(_ref.read(outboxProvider.notifier).flush());
  }

  /// Mark every still-pending student at a stop — one tap for fourteen children.
  Future<void> markStopPending(int stopId, String status) async {
    final tripId = state.tripId;
    if (tripId == null) return;

    final stop = state.stops.firstWhere((s) => s.stopId == stopId);
    final ids = stop.students.where((s) => s.isPending).map((s) => s.studentId).toList();

    if (ids.isEmpty) return;

    for (final id in ids) {
      _applyLocally(id, status);
    }

    await Outbox.enqueueAction(
      endpoint: '/trips/$tripId/students/bulk',
      payload: {
        'status': status,
        'student_ids': ids,
        'method': 'manual',
      },
    );

    await _ref.read(outboxProvider.notifier).bump();
    unawaited(_ref.read(outboxProvider.notifier).flush());
  }

  /// Record that a guardian's number was revealed, before the dialer opens.
  Future<void> logCall(int studentId) async {
    final tripId = state.tripId;
    if (tripId == null) return;

    await Outbox.enqueueAction(
      endpoint: '/trips/$tripId/students/$studentId/call',
      payload: const {},
    );

    await _ref.read(outboxProvider.notifier).bump();
    unawaited(_ref.read(outboxProvider.notifier).flush());
  }

  void _applyLocally(int studentId, String status) {
    state = state.copyWith(
      stops: state.stops
          .map((stop) => stop.copyWithStudents(
                stop.students
                    .map((s) => s.studentId == studentId
                        ? s.copyWith(
                            status: status,
                            eventAt: DateTime.now().toIso8601String(),
                          )
                        : s)
                    .toList(),
              ))
          .toList(),
    );
  }
}

final manifestProvider =
    StateNotifierProvider<ManifestController, ManifestState>(
        (ref) => ManifestController(ref));
