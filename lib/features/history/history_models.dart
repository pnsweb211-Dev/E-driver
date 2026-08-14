/// One completed (or abandoned) run.
class PastTrip {
  const PastTrip({
    required this.id,
    required this.tripDate,
    required this.label,
    required this.status,
    this.direction = 'pickup',
    this.routeName,
    this.vehicleNumber,
    this.startedAt,
    this.endedAt,
    this.delayMinutes,
    this.distanceKm,
    this.studentTotal,
    this.studentPicked,
    this.closedBy,
  });

  final int id;
  final String tripDate;
  final String label;
  final String status;
  final String direction;
  final String? routeName;
  final String? vehicleNumber;
  final String? startedAt;
  final String? endedAt;
  final int? delayMinutes;
  final double? distanceKm;
  final int? studentTotal;
  final int? studentPicked;

  /// `driver` | `auto` | `admin`. Worth showing: a run the system had to close
  /// is a run the driver forgot to stop, and they should see that themselves
  /// rather than first hearing it from the office.
  final String? closedBy;

  bool get wasAbandoned => status == 'abandoned';
  bool get autoClosed => closedBy == 'auto';
  bool get wasLate => (delayMinutes ?? 0) > 5;

  factory PastTrip.fromJson(Map<String, dynamic> json) => PastTrip(
        id: json['id'] as int,
        tripDate: json['trip_date'] as String? ?? '',
        label: json['label'] as String? ?? 'Run',
        status: json['status'] as String? ?? 'completed',
        direction: json['direction'] as String? ?? 'pickup',
        routeName: json['route_name'] as String?,
        vehicleNumber: json['vehicle_number'] as String?,
        startedAt: json['started_at'] as String?,
        endedAt: json['ended_at'] as String?,
        delayMinutes: (json['delay_minutes'] as num?)?.toInt(),
        distanceKm: (json['distance_km'] as num?)?.toDouble(),
        studentTotal: (json['student_total'] as num?)?.toInt(),
        studentPicked: (json['student_picked'] as num?)?.toInt(),
        closedBy: json['closed_by'] as String?,
      );
}

/// Totals over the whole selected range, not the visible page.
class HistorySummary {
  const HistorySummary({
    this.trips = 0,
    this.completed = 0,
    this.abandoned = 0,
    this.distanceKm = 0,
    this.studentsPicked = 0,
    this.onTimePct,
  });

  final int trips;
  final int completed;
  final int abandoned;
  final double distanceKm;
  final int studentsPicked;

  /// Null when there are no trips at all — "0% on time" for a driver who was on
  /// leave all month would be a lie.
  final int? onTimePct;

  factory HistorySummary.fromJson(Map<String, dynamic> json) => HistorySummary(
        trips: (json['trips'] as num?)?.toInt() ?? 0,
        completed: (json['completed'] as num?)?.toInt() ?? 0,
        abandoned: (json['abandoned'] as num?)?.toInt() ?? 0,
        distanceKm: (json['distance_km'] as num?)?.toDouble() ?? 0,
        studentsPicked: (json['students_picked'] as num?)?.toInt() ?? 0,
        onTimePct: (json['on_time_pct'] as num?)?.toInt(),
      );
}

class HistoryState {
  const HistoryState({
    this.trips = const [],
    this.summary = const HistorySummary(),
    this.loading = false,
    this.error,
  });

  final List<PastTrip> trips;
  final HistorySummary summary;
  final bool loading;
  final String? error;
}
