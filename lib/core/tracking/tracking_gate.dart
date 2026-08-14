import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';

import '../theme/app_colors.dart';

/// Outcome of the pre-trip permission checks.
enum TrackingReadiness {
  ready,

  /// The device's location services are switched off entirely.
  locationServicesOff,

  /// The app has no location permission at all.
  permissionDenied,

  /// Permanently denied — only a trip to system settings fixes it.
  permissionDeniedForever,

  /// Foreground-only. Tracking works while the app is visible and dies when it
  /// is swiped away, which is the single most common reason a school reports
  /// "the bus stopped showing up".
  foregroundOnly,
}

/// The gate between "driver pressed Start" and "tracking is actually running".
///
/// This is the seed of §7 Layer 1: a trip must never appear to be running on a
/// phone that cannot report its position. Extracted from the old dashboard so
/// the checks live in one place and can grow into the full readiness screen
/// (exact alarms, battery optimisation, OEM autostart) without being rewritten.
class TrackingGate {
  const TrackingGate._();

  static Future<TrackingReadiness> check() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return TrackingReadiness.locationServicesOff;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      return TrackingReadiness.permissionDeniedForever;
    }

    if (permission == LocationPermission.denied) {
      return TrackingReadiness.permissionDenied;
    }

    if (permission == LocationPermission.whileInUse) {
      return TrackingReadiness.foregroundOnly;
    }

    return TrackingReadiness.ready;
  }

  /// Ask for "Allow all the time", explaining why first.
  ///
  /// The explanation matters: Android shows a bare permission dialog with no
  /// context, and a driver who taps the wrong option here silently breaks
  /// tracking for the whole route.
  static Future<void> requestAlways(BuildContext context) async {
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.gps_fixed, color: AppColors.accent, size: 24),
            const SizedBox(width: 10),
            const Text('Background Location',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 18)),
          ],
        ),
        content: const Text(
          'For tracking to keep working when the app is closed, please choose '
          '"Allow all the time" on the next screen.\n\n'
          'Without it, parents stop seeing the bus as soon as your phone locks.',
          style: TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Continue', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (proceed == true) {
      await Geolocator.requestPermission();
    }
  }

  static Future<void> startService() async {
    final service = FlutterBackgroundService();

    if (!await service.isRunning()) {
      await service.startService();
    }
  }

  static Future<void> stopService() async {
    FlutterBackgroundService().invoke('stopService');
  }

  /// Human-readable reason a trip could not start.
  static String? message(TrackingReadiness readiness) => switch (readiness) {
        TrackingReadiness.locationServicesOff =>
          'Location services are OFF. Please turn on GPS.',
        TrackingReadiness.permissionDenied =>
          'Location permission is required to track the bus.',
        TrackingReadiness.permissionDeniedForever =>
          'Location permission is blocked. Please allow it in Settings.',
        _ => null,
      };
}
