import 'package:flutter_test/flutter_test.dart';

import 'package:driver_app/core/tracking/motion_failsafe.dart';

/// §7 Layer 4 — "the bus is moving but nothing is tracking".
///
/// Coordinates below are around a fixed point in Jaipur; 0.01° of latitude is
/// roughly 1.1 km, which is comfortably past the 500 m threshold.
void main() {
  const anchorLat = 26.9124;
  const anchorLng = 75.7873;

  late MotionFailsafe failsafe;

  setUp(() {
    failsafe = MotionFailsafe();
    failsafe.armFor('schedule-1|2026-08-10');
  });

  test('the first fix only anchors — it never fires', () {
    expect(
      failsafe.consider(lat: anchorLat, lng: anchorLng, speedKmh: 60),
      isFalse,
    );
  });

  test('fires once the bus has both moved far enough and is moving fast', () {
    failsafe.consider(lat: anchorLat, lng: anchorLng, speedKmh: 0);

    expect(
      failsafe.consider(lat: anchorLat + 0.01, lng: anchorLng, speedKmh: 40),
      isTrue,
    );
  });

  test('distance alone is not enough — a parked bus down the road is not a run',
      () {
    failsafe.consider(lat: anchorLat, lng: anchorLng, speedKmh: 0);

    expect(
      failsafe.consider(lat: anchorLat + 0.01, lng: anchorLng, speedKmh: 2),
      isFalse,
    );
  });

  test('speed alone is not enough — a driver on a motorbike is not the bus', () {
    failsafe.consider(lat: anchorLat, lng: anchorLng, speedKmh: 0);

    expect(
      failsafe.consider(lat: anchorLat + 0.0005, lng: anchorLng, speedKmh: 60),
      isFalse,
    );
  });

  test('fires at most once per window', () {
    failsafe.consider(lat: anchorLat, lng: anchorLng, speedKmh: 0);

    expect(
      failsafe.consider(lat: anchorLat + 0.01, lng: anchorLng, speedKmh: 40),
      isTrue,
    );
    // A driver who has already been asked and chose not to start must not be
    // asked again every ten seconds.
    expect(
      failsafe.consider(lat: anchorLat + 0.02, lng: anchorLng, speedKmh: 40),
      isFalse,
    );
  });

  test('a new run re-arms and re-anchors', () {
    failsafe.consider(lat: anchorLat, lng: anchorLng, speedKmh: 0);
    failsafe.consider(lat: anchorLat + 0.01, lng: anchorLng, speedKmh: 40);

    expect(failsafe.hasFired, isTrue);

    failsafe.armFor('schedule-2|2026-08-10');

    expect(failsafe.hasFired, isFalse);
    // Anchor was cleared with the window, so this fix anchors afresh at the
    // school rather than measuring from the depot.
    expect(
      failsafe.consider(lat: anchorLat + 0.01, lng: anchorLng, speedKmh: 40),
      isFalse,
    );
  });

  test('re-arming the same run does not reset a fired alert', () {
    failsafe.consider(lat: anchorLat, lng: anchorLng, speedKmh: 0);
    failsafe.consider(lat: anchorLat + 0.01, lng: anchorLng, speedKmh: 40);

    // armFor runs on every 30s duty tick; if it reset here the driver would be
    // nagged twice a minute.
    failsafe.armFor('schedule-1|2026-08-10');

    expect(failsafe.hasFired, isTrue);
  });

  test('disarmed outside any window, nothing fires', () {
    failsafe.disarm();

    failsafe.consider(lat: anchorLat, lng: anchorLng, speedKmh: 0);

    expect(
      failsafe.consider(lat: anchorLat + 0.05, lng: anchorLng, speedKmh: 80),
      isFalse,
    );
  });
}
