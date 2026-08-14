import 'package:geolocator/geolocator.dart';

/// §7 Layer 4 — "the bus is moving but nothing is tracking".
///
/// The most convincing catch in the whole of §7, because it detects the actual
/// event rather than the absence of a button press: the driver did not forget
/// to *be* somewhere, they forgot to press Start, and the bus is already three
/// stops down the road.
///
/// Deliberately dumb and allocation-free — it runs inside the tracking isolate
/// on every position fix. All it holds is where the bus was when the window
/// opened.
class MotionFailsafe {
  MotionFailsafe({
    this.distanceThresholdMetres = 500,
    this.speedThresholdKmh = 15,
  });

  /// How far from the anchor counts as "left the depot".
  final double distanceThresholdMetres;

  /// Movement at walking pace is a driver crossing the yard, not a bus leaving.
  /// Both conditions must hold, so a phone carried into the school office does
  /// not raise an alert.
  final double speedThresholdKmh;

  double? _anchorLat;
  double? _anchorLng;

  /// Fires once per window. A driver who has already been asked and chose not
  /// to start must not be asked again every ten seconds.
  bool _fired = false;

  /// Which run the current anchor belongs to, so re-anchoring happens when the
  /// window moves on rather than on a timer.
  String? _windowKey;

  bool get hasFired => _fired;

  /// Called when no run is in its arming window: forget everything, so the next
  /// window starts from where the bus actually is.
  void disarm() {
    _anchorLat = null;
    _anchorLng = null;
    _windowKey = null;
    _fired = false;
  }

  /// Called when the window changes to a different run.
  void armFor(String windowKey) {
    if (_windowKey == windowKey) return;

    _windowKey = windowKey;
    _anchorLat = null;
    _anchorLng = null;
    _fired = false;
  }

  /// Feed a position. Returns true exactly once, on the fix that first shows
  /// the bus has genuinely left.
  ///
  /// [speedKmh] is passed separately because Geolocator reports metres/second
  /// and reading that wrong by a factor of 3.6 would either never fire or fire
  /// in the car park.
  bool consider({
    required double lat,
    required double lng,
    required double speedKmh,
  }) {
    if (_windowKey == null || _fired) return false;

    if (_anchorLat == null || _anchorLng == null) {
      _anchorLat = lat;
      _anchorLng = lng;
      return false;
    }

    final moved = Geolocator.distanceBetween(_anchorLat!, _anchorLng!, lat, lng);

    if (moved < distanceThresholdMetres) return false;
    if (speedKmh < speedThresholdKmh) return false;

    _fired = true;

    return true;
  }
}
