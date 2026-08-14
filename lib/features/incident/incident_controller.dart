import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/outbox/outbox.dart';
import '../../core/providers.dart';

/// What a driver can report from the road (plan §4.6).
///
/// A short, closed list with plain labels. A driver at the roadside is not
/// going to write a description, and a free-text box would produce fifty
/// spellings of "puncture" that no report could ever group.
enum IncidentType {
  sos('sos', 'SOS — emergency', 'The school is alerted immediately'),
  breakdown('breakdown', 'Bus has broken down', 'Engine, tyre, anything mechanical'),
  accident('accident', 'Accident', 'Collision or injury'),
  trafficJam('traffic_jam', 'Stuck in traffic', 'The run will be late'),
  detour('detour', 'Taking a detour', 'Road closed or blocked'),
  other('other', 'Something else', '');

  const IncidentType(this.value, this.label, this.hint);

  final String value;
  final String label;
  final String hint;

  /// SOS gets its own button; the sheet lists the rest.
  static List<IncidentType> get reportable =>
      values.where((t) => t != IncidentType.sos).toList(growable: false);
}

/// Reporting an incident, offline-safe.
///
/// Queued through the outbox like every other driver action. That matters most
/// for the SOS: the places a bus breaks down and the places with no signal are
/// substantially the same places, and a button that only works on 4G is not an
/// emergency button. The server dedupes on `client_event_id`, so a blind replay
/// cannot raise a second alarm at the school.
class IncidentController extends StateNotifier<bool> {
  IncidentController(this._ref) : super(false);

  final Ref _ref;

  /// Returns true once the report is durably queued — NOT once the server has
  /// it. The distinction is deliberate: the driver gets their confirmation
  /// immediately, because waiting on a round trip they may not have is exactly
  /// how an emergency button loses trust.
  Future<bool> report(IncidentType type, {String? note}) async {
    state = true;

    try {
      final position = await _position();

      await Outbox.enqueueAction(
        endpoint: '/incidents',
        payload: {
          'type': type.value,
          if (note != null && note.isNotEmpty) 'note': note,
          if (position != null) 'lat': position.latitude,
          if (position != null) 'lng': position.longitude,
        },
      );

      // Try immediately; if it fails the queue keeps it and the 30s flush,
      // the connectivity listener and the trip-end flush all retry.
      await _ref.read(outboxProvider.notifier).flush();

      return true;
    } finally {
      state = false;
    }
  }

  /// Best-effort location. An SOS with no coordinates is still an SOS — never
  /// block the report on a GPS fix that may take fifteen seconds.
  Future<Position?> _position() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 5),
      );
    } catch (_) {
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }
}

final incidentProvider =
    StateNotifierProvider<IncidentController, bool>((ref) => IncidentController(ref));
