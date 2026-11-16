import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/alarms/alarm_service.dart';
import '../core/alarms/schedule_time.dart';
import '../core/alarms/upcoming.dart';
import '../core/readiness/heartbeat.dart';
import '../core/tracking/motion_failsafe.dart';
import 'api_service.dart';

/// What the service is doing right now.
///
/// Before §7 this service existed only for the duration of a trip. Layers 4 and
/// 5 need it alive between runs too — a motion failsafe that only works while a
/// trip is running would detect nothing, and a heartbeat that stops when the
/// driver forgets to press Start hides the very failure it is there to expose.
/// So the service is now a *duty* service that idles cheaply and wakes into
/// tracking, rather than a trip tracker that is started and stopped.
enum DutyMode {
  /// A trip is running: stream positions and post them. Unchanged from before.
  trip,

  /// A run is due soon (or just was) and no trip is open: watch for the bus
  /// leaving without anyone pressing Start. No pings are sent.
  watch,

  /// Nothing due. No GPS at all.
  idle,
}

/// Set by the app when a trip opens or closes, and read here.
///
/// A SharedPreferences flag rather than a message, because the service can
/// outlive (and be restarted without) the UI — after a reboot there is nobody
/// to send it a message.
const kTripActiveKey = 'trip_active';

Future<void> setTripActive(bool active) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kTripActiveKey, active);
}

// ─── Initialize the Background Service ──────────────────────────
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'vehicle_tracking',
    'Vehicle Tracking',
    description: 'Shows when vehicle location is being tracked.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flnp =
      FlutterLocalNotificationsPlugin();

  await flnp
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      autoStartOnBoot: true,
      notificationChannelId: 'vehicle_tracking',
      initialNotificationTitle: 'School Bus Tracker',
      initialNotificationContent: 'On duty',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

// ─── iOS Background Handler ────────────────────────────────────
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  try {
    DartPluginRegistrant.ensureInitialized();
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.bestForNavigation,
      timeLimit: const Duration(seconds: 15),
    );
    await ApiService.sendLocation(
        position.latitude, position.longitude, position.speed);
  } catch (e) {
    print('[TRACKER] iOS bg error: $e');
  }
  return true;
}

// ─── Main Background Service Entry Point ────────────────────────
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Own isolate, own tz database. Without this every duty window resolves in
  // UTC and a 06:45 run in Asia/Kolkata is watched for at lunchtime.
  ScheduleTime.ensureInitialized();

  print('[TRACKER] === SERVICE STARTED ===');

  // Track subscriptions/timers for clean teardown
  StreamSubscription<Position>? positionSubscription;
  Timer? heartbeatTimer;
  Timer? retryTimer;
  Timer? dutyTimer;
  Timer? livenessTimer;

  // Track state for de-duplication and retry
  int consecutiveFailures = 0;
  DateTime? lastSentTime;
  double? lastLat;
  double? lastLng;

  DutyMode mode = DutyMode.idle;
  final failsafe = MotionFailsafe();

  void teardownStream() {
    positionSubscription?.cancel();
    positionSubscription = null;
    retryTimer?.cancel();
    heartbeatTimer?.cancel();
    heartbeatTimer = null;
  }

  service.on('stopService').listen((event) {
    print('[TRACKER] === SERVICE STOPPING ===');
    teardownStream();
    dutyTimer?.cancel();
    livenessTimer?.cancel();
    service.stopSelf();
  });

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) => service.setAsForegroundService());
    service.on('setAsBackground').listen((_) => service.setAsBackgroundService());
  }

  // ── TRIP MODE ───────────────────────────────────────────────────
  //
  // Unchanged from the original tracker, deliberately: this is the path that
  // works in the field today.
  //
  // getPositionStream() rather than Timer.periodic + getCurrentPosition():
  //   1. Android Doze suspends Dart timers
  //   2. getCurrentPosition() opens a new GPS session each call (cold-start)
  //   3. the timer isolate gets killed by the OOM killer
  //
  // On Android a foreground-service location request survives Doze. On iOS,
  // Core Location uses a separate automotive-navigation background policy.
  void startTripStream() {
    final LocationSettings locationSettings = Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 10,
            activityType: ActivityType.automotiveNavigation,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
          )
        : AndroidSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            // Minimum distance change (metres) before we get a callback.
            distanceFilter: 10,
            intervalDuration: const Duration(seconds: 10),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'School Bus Tracker',
              notificationText: 'Tracking your route...',
              notificationChannelName: 'Vehicle Tracking',
              setOngoing: true,
              enableWakeLock: true, // ← acquires WAKE_LOCK automatically
            ),
          );

    // §6.2 adaptive interval. The GPS stream still ticks at 10 s — turning the
    // radio down and up is what actually costs battery, and it is also what
    // makes a bus pulling away take 30 s to appear on a parent's map. What
    // adapts is how often a fix is UPLOADED: a parked bus does not need a point
    // every ten seconds, and on a rural route the data bill is real.
    const movingGapSeconds = 10;
    const stationaryGapSeconds = 60;
    // Above ~3 km/h the bus is moving; below it, this is GPS jitter in a car park.
    const movingSpeedMs = 0.8;

    // Send first position immediately (don't wait for the stream's first tick).
    _sendImmediateLocation(service);

    positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) async {
        print('[TRACKER] Stream: ${position.latitude}, ${position.longitude} '
            '(±${position.accuracy.toInt()}m, speed: ${position.speed.toStringAsFixed(1)} m/s)');

        // Flag a spoofed fix for the heartbeat rather than silently trusting it.
        await Heartbeat.noteMockLocation(position.isMocked);

        // Filter out cell-tower garbage fixes (>100 m accuracy)
        if (position.accuracy > 100) {
          print('[TRACKER] Discarding inaccurate fix: ${position.accuracy.toInt()}m');
          _notify(service, 'Low accuracy (${position.accuracy.toInt()}m), waiting for GPS...');
          return;
        }

        // De-duplicate, and throttle a stationary bus.
        //
        // The distance check alone is not enough: a bus idling at a stop still
        // produces fixes that drift 5-10 m apart, which used to upload as a
        // point every ten seconds for the whole wait.
        if (lastSentTime != null && lastLat != null && lastLng != null) {
          final elapsed = DateTime.now().difference(lastSentTime!).inSeconds;
          final distance = Geolocator.distanceBetween(
            lastLat!, lastLng!, position.latitude, position.longitude,
          );

          final moving = position.speed > movingSpeedMs || distance >= 25;
          final minGap = moving ? movingGapSeconds : stationaryGapSeconds;

          // Always let a genuinely moving bus through on the fast cadence; a
          // parked one reports once a minute so the school can still see it is
          // alive and where.
          if (distance < 3 && elapsed < 8) return;
          if (elapsed < minGap && distance < 100) return;
        }

        final success = await ApiService.sendLocation(
          position.latitude,
          position.longitude,
          position.speed,
        );

        final now = DateTime.now();
        final time = '${now.hour.toString().padLeft(2, '0')}:'
            '${now.minute.toString().padLeft(2, '0')}:'
            '${now.second.toString().padLeft(2, '0')}';

        if (success) {
          consecutiveFailures = 0;
          lastSentTime = now;
          lastLat = position.latitude;
          lastLng = position.longitude;
          print('[TRACKER] ✓ Sent at $time (±${position.accuracy.toInt()}m)');
          _notify(service, '✓ Sent at $time (±${position.accuracy.toInt()}m)');
        } else {
          consecutiveFailures++;
          print('[TRACKER] ✗ Failed at $time (consecutive: $consecutiveFailures)');
          _notify(service, '✗ Failed at $time, retrying...');

          // Exponential backoff retry: 2s, 4s, 8s, max 30s
          if (consecutiveFailures <= 5) {
            final delaySeconds = (2 * consecutiveFailures).clamp(2, 30);
            retryTimer?.cancel();
            retryTimer = Timer(Duration(seconds: delaySeconds), () async {
              final retryPosition = await _safeGetPosition();
              if (retryPosition != null) {
                final retrySuccess = await ApiService.sendLocation(
                  retryPosition.latitude,
                  retryPosition.longitude,
                  retryPosition.speed,
                );
                if (retrySuccess) {
                  consecutiveFailures = 0;
                  lastSentTime = DateTime.now();
                  lastLat = retryPosition.latitude;
                  lastLng = retryPosition.longitude;
                  _notify(service, '✓ Retry successful');
                }
              }
            });
          }
        }
      },
      onError: (error) {
        print('[TRACKER] Stream error: $error');
        _notify(service, 'GPS error, recovering...');
      },
      cancelOnError: false, // CRITICAL: don't kill the subscription on transient errors
    );

    // ── Fallback timer as a safety net ────────────────────────────
    // If the position stream stalls (bus stationary for 5+ min, so the distance
    // filter suppresses callbacks), force a send every 60 s so the server knows
    // the device is still alive.
    heartbeatTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      final now = DateTime.now();
      if (lastSentTime != null && now.difference(lastSentTime!).inSeconds < 55) {
        return; // Stream is active, no fallback needed
      }

      print('[TRACKER] Fallback: stream idle, sending position...');
      final position = await _safeGetPosition();
      if (position != null) {
        final success = await ApiService.sendLocation(
          position.latitude,
          position.longitude,
          position.speed,
        );
        if (success) {
          lastSentTime = now;
          lastLat = position.latitude;
          lastLng = position.longitude;
          _notify(service, '✓ Heartbeat at ${now.hour.toString().padLeft(2, '0')}:'
              '${now.minute.toString().padLeft(2, '0')}');
        }
      }
    });
  }

  // ── WATCH MODE (§7 Layer 4) ─────────────────────────────────────
  //
  // A much cheaper stream: 100 m of movement before a callback, no uploads, no
  // wake lock. All it answers is "has this bus left without a trip open?".
  void startWatchStream(DutyWindow window) {
    final LocationSettings watchSettings = Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.medium,
            distanceFilter: 100,
            activityType: ActivityType.automotiveNavigation,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: false,
          )
        : AndroidSettings(
            accuracy: LocationAccuracy.medium,
            distanceFilter: 100,
            intervalDuration: const Duration(seconds: 60),
          );

    positionSubscription = Geolocator.getPositionStream(
      locationSettings: watchSettings,
    ).listen(
      (Position position) async {
        if (position.accuracy > 200) return;

        final moving = failsafe.consider(
          lat: position.latitude,
          lng: position.longitude,
          // Geolocator reports metres/second.
          speedKmh: position.speed * 3.6,
        );

        if (!moving) return;

        print('[TRACKER] Motion failsafe tripped for schedule ${window.run.scheduleId}');

        await _showMotionAlert(window);
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  /// Decide what the service should be doing, and switch if that changed.
  ///
  /// Runs every 30 s. Cheap: in idle mode it reads two prefs keys and returns.
  Future<void> evaluateDuty() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    final signedIn = (prefs.getString('api_token') ?? '').isNotEmpty;
    final tripActive = prefs.getBool(kTripActiveKey) ?? false;

    if (!signedIn) {
      if (mode != DutyMode.idle) {
        teardownStream();
        mode = DutyMode.idle;
      }
      _notify(service, 'Signed out');
      return;
    }

    DutyWindow? window;

    if (!tripActive) {
      window = currentDutyWindow(await UpcomingSchedule.restore());
    }

    final next = tripActive
        ? DutyMode.trip
        : (window != null ? DutyMode.watch : DutyMode.idle);

    if (next == DutyMode.watch && window != null) {
      failsafe.armFor('${window.run.scheduleId}|${window.day.date}');
    } else {
      failsafe.disarm();
    }

    if (next == mode) {
      // Keep the notification honest even when the mode is unchanged.
      if (mode == DutyMode.watch && window != null) {
        _notify(service, 'On duty · ${window.run.label} due ${window.run.startTime}');
      } else if (mode == DutyMode.idle) {
        _notify(service, 'On duty · no run in progress');
      }
      return;
    }

    teardownStream();
    mode = next;

    switch (mode) {
      case DutyMode.trip:
        _notify(service, 'Trip active · starting GPS...');
        startTripStream();

      case DutyMode.watch:
        _notify(service, 'On duty · ${window!.run.label} due ${window.run.startTime}');
        startWatchStream(window);

      case DutyMode.idle:
        _notify(service, 'On duty · no run in progress');
    }
  }

  await evaluateDuty();
  dutyTimer = Timer.periodic(const Duration(seconds: 30), (_) => evaluateDuty());

  // ── LIVENESS (§7 Layer 5) ───────────────────────────────────────
  // Runs in every mode, including idle: a phone whose service was killed at
  // 05:00 is exactly the case the school needs to see BEFORE the 06:45 run.
  await Heartbeat.send();
  livenessTimer = Timer.periodic(Heartbeat.interval, (_) => Heartbeat.send());
}

/// "Bus is moving — start the trip?"
///
/// A notification rather than a dialog because the app is almost certainly not
/// on screen: the whole scenario is a driver who never opened it. Tapping opens
/// the same alarm screen the scheduled alarm uses, so there is one place that
/// answers "start or decline".
Future<void> _showMotionAlert(DutyWindow window) async {
  final plugin = FlutterLocalNotificationsPlugin();

  // The isolate has its own plugin instance and must initialise it before
  // showing anything; the channels themselves already exist from the UI side.
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ),
  );

  final target = AlarmTarget(
    scheduleId: window.run.scheduleId,
    date: window.day.date,
    label: window.run.label,
    startTime: window.run.startTime,
    routeName: window.run.routeName,
    direction: window.run.direction,
  );

  await plugin.show(
    _motionAlertId,
    'Bus is moving — start the trip?',
    '${window.run.routeName ?? window.run.label} is not started. '
        'Tap to start it now.',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        AlarmService.alarmChannelId,
        'Trip Alarms',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: false,
        actions: [
          AndroidNotificationAction('start', 'START TRIP',
              showsUserInterface: true, cancelNotification: true),
          AndroidNotificationAction('decline', "CAN'T RUN",
              showsUserInterface: true, cancelNotification: true),
        ],
      ),
      iOS: DarwinNotificationDetails(),
    ),
    payload: target.encode(),
  );
}

/// Fixed id: a second motion alert must replace the first, not stack.
const _motionAlertId = 88801;

/// Get position with multi-strategy fallback.
/// Returns null only if ALL strategies fail.
Future<Position?> _safeGetPosition() async {
  // Strategy 1: Best-for-navigation (GPS + GNSS + sensor fusion)
  try {
    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.bestForNavigation,
      timeLimit: const Duration(seconds: 15),
    );
  } catch (e) {
    print('[TRACKER] Best accuracy fallback failed: $e');
  }

  // Strategy 2: High accuracy
  try {
    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 10),
    );
  } catch (e) {
    print('[TRACKER] High accuracy fallback failed: $e');
  }

  // Strategy 3: Last known position (cached from any app on device)
  try {
    final lastKnown = await Geolocator.getLastKnownPosition();
    if (lastKnown != null) {
      print('[TRACKER] Using cached position (±${lastKnown.accuracy.toInt()}m)');
      return lastKnown;
    }
  } catch (e) {
    print('[TRACKER] Last known failed: $e');
  }

  return null;
}

/// Send location immediately at trip start (don't wait for the stream's first tick).
Future<void> _sendImmediateLocation(ServiceInstance service) async {
  try {
    final position = await _safeGetPosition();
    if (position == null) {
      _notify(service, 'Waiting for GPS signal...');
      return;
    }

    if (position.accuracy > 100) {
      _notify(service, 'Low accuracy (${position.accuracy.toInt()}m), waiting for GPS...');
      return;
    }

    final success = await ApiService.sendLocation(
      position.latitude,
      position.longitude,
      position.speed,
    );

    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    if (success) {
      _notify(service, '✓ Started at $time (±${position.accuracy.toInt()}m)');
    } else {
      _notify(service, '✗ Initial send failed, stream will retry...');
    }
  } catch (e) {
    print('[TRACKER] Initial location error: $e');
    _notify(service, 'Starting GPS...');
  }
}

void _notify(ServiceInstance service, String content) {
  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'School Bus Tracker',
      content: content,
    );
  }
}
