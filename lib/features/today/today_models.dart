/// One scheduled run of a bus, as the driver sees it.
class TodayRun {
  const TodayRun({
    required this.scheduleId,
    required this.label,
    required this.direction,
    this.routeName,
    this.plannedStartTime,
    this.tripStatus,
    this.tripId,
  });

  final int scheduleId;
  final String label;
  final String direction;
  final String? routeName;
  final String? plannedStartTime;
  final String? tripStatus;
  final int? tripId;

  bool get isRunning => tripStatus == 'in_progress';
  bool get isDone => tripStatus == 'completed';

  factory TodayRun.fromJson(Map<String, dynamic> json) => TodayRun(
        scheduleId: json['schedule_id'] as int,
        label: json['label'] as String? ?? 'Run',
        direction: json['direction'] as String? ?? 'pickup',
        routeName: json['route_name'] as String?,
        plannedStartTime: json['planned_start_time'] as String?,
        tripStatus: json['trip_status'] as String?,
        tripId: json['trip_id'] as int?,
      );
}

/// The currently running trip, if any.
class ActiveTrip {
  const ActiveTrip({
    required this.id,
    required this.status,
    this.routeName,
    this.startedAt,
    this.delayMinutes,
    this.scheduleId,
    this.tripDate,
    this.studentTotal,
    this.studentPicked,
    this.studentAbsent,
  });

  final int id;
  final String status;
  final String? routeName;
  final String? startedAt;
  final int? delayMinutes;

  /// Which timetabled run this trip belongs to. Null when the bus has no
  /// timetable and the trip was bound to the vehicle's only route.
  final int? scheduleId;

  /// The run's own date (`yyyy-MM-dd`) as the SERVER resolved it — not
  /// necessarily today. Used to silence exactly the right day's alarms.
  final String? tripDate;

  /// Denormalised boarding counters, so the home screen can show on-board /
  /// absent / total without pulling the whole manifest.
  final int? studentTotal;
  final int? studentPicked;
  final int? studentAbsent;

  factory ActiveTrip.fromJson(Map<String, dynamic> json) => ActiveTrip(
        id: json['id'] as int,
        status: json['status'] as String? ?? 'in_progress',
        routeName: json['route_name'] as String?,
        startedAt: json['started_at'] as String?,
        delayMinutes: json['delay_minutes'] as int?,
        scheduleId: json['schedule_id'] as int?,
        tripDate: json['trip_date'] as String?,
        studentTotal: (json['student_total'] as num?)?.toInt(),
        studentPicked: (json['student_picked'] as num?)?.toInt(),
        studentAbsent: (json['student_absent'] as num?)?.toInt(),
      );
}

class TodayState {
  const TodayState({
    this.runs = const [],
    this.activeTrip,
    this.vehicleNumber,
    this.message,
    this.loading = false,
    this.error,
  });

  final List<TodayRun> runs;
  final ActiveTrip? activeTrip;
  final String? vehicleNumber;

  /// Server-supplied explanation when there is nothing to show — e.g. no bus
  /// has been assigned yet.
  final String? message;

  final bool loading;
  final String? error;

  bool get isTripActive => activeTrip != null;

  TodayState copyWith({
    List<TodayRun>? runs,
    ActiveTrip? activeTrip,
    bool clearActiveTrip = false,
    String? vehicleNumber,
    String? message,
    bool? loading,
    String? error,
    bool clearError = false,
  }) =>
      TodayState(
        runs: runs ?? this.runs,
        activeTrip: clearActiveTrip ? null : (activeTrip ?? this.activeTrip),
        vehicleNumber: vehicleNumber ?? this.vehicleNumber,
        message: message ?? this.message,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}
