import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One scheduled run on one day.
class UpcomingRun {
  const UpcomingRun({
    required this.scheduleId,
    required this.label,
    required this.direction,
    required this.startTime,
    this.routeName,
    this.endTime,
    this.graceMinutes = 5,
    this.alertsEnabled = true,
    this.declined = false,
  });

  final int scheduleId;
  final String label;
  final String direction;

  /// `HH:mm` in the SCHOOL's timezone, not the handset's.
  final String startTime;
  final String? routeName;
  final String? endTime;
  final int graceMinutes;

  /// The school can silence adherence alerts on a route without disabling the
  /// route itself.
  final bool alertsEnabled;

  /// The driver already said they cannot run this one. Nothing should ring.
  final bool declined;

  /// Ring at all? Both a silenced route and a declined run are legitimate
  /// reasons not to, and conflating them is what makes an alarm app get
  /// uninstalled.
  bool get shouldAlarm => alertsEnabled && !declined;

  factory UpcomingRun.fromJson(Map<String, dynamic> json) => UpcomingRun(
        scheduleId: json['schedule_id'] as int,
        label: json['label'] as String? ?? 'Run',
        direction: json['direction'] as String? ?? 'pickup',
        startTime: json['start_time'] as String? ?? '00:00',
        routeName: json['route_name'] as String?,
        endTime: json['end_time'] as String?,
        graceMinutes: (json['grace_minutes'] as num?)?.toInt() ?? 5,
        alertsEnabled: json['alerts_enabled'] != false,
        declined: json['declined'] == true,
      );

  Map<String, dynamic> toJson() => {
        'schedule_id': scheduleId,
        'label': label,
        'direction': direction,
        'start_time': startTime,
        'route_name': routeName,
        'end_time': endTime,
        'grace_minutes': graceMinutes,
        'alerts_enabled': alertsEnabled,
        'declined': declined,
      };
}

class UpcomingDay {
  const UpcomingDay({
    required this.date,
    required this.schoolOpen,
    required this.runs,
  });

  /// `yyyy-MM-dd`.
  final String date;

  /// Holidays and weekly-offs come down with the payload so the app never
  /// rings on a closed day — the alarm has to know the calendar offline.
  final bool schoolOpen;
  final List<UpcomingRun> runs;

  factory UpcomingDay.fromJson(Map<String, dynamic> json) => UpcomingDay(
        date: json['date'] as String,
        schoolOpen: json['school_open'] != false,
        runs: (json['runs'] as List<dynamic>? ?? const [])
            .map((r) => UpcomingRun.fromJson(r as Map<String, dynamic>))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'date': date,
        'school_open': schoolOpen,
        'runs': runs.map((r) => r.toJson()).toList(),
      };
}

/// The next seven days of runs, as the server sees them.
///
/// Cached on disk because the whole point of §7 Layer 2 is that a phone with no
/// signal all week still rings on time: the alarms are registered with the OS
/// from this payload, and a cold start with no network must be able to re-arm
/// them from the last copy we had.
class UpcomingSchedule {
  const UpcomingSchedule({
    required this.timezone,
    required this.days,
    this.fetchedAt,
  });

  /// The school's timezone name (e.g. `Asia/Kolkata`). Every offset in the
  /// ladder is anchored to it — a handset left on the wrong zone must still
  /// ring when the bus actually leaves.
  final String timezone;
  final List<UpcomingDay> days;
  final DateTime? fetchedAt;

  static const empty = UpcomingSchedule(timezone: '', days: []);

  bool get isEmpty => days.isEmpty;

  factory UpcomingSchedule.fromJson(Map<String, dynamic> json) => UpcomingSchedule(
        timezone: json['timezone'] as String? ?? '',
        days: (json['days'] as List<dynamic>? ?? const [])
            .map((d) => UpcomingDay.fromJson(d as Map<String, dynamic>))
            .toList(growable: false),
        fetchedAt: json['fetched_at'] == null
            ? null
            : DateTime.tryParse(json['fetched_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'timezone': timezone,
        'days': days.map((d) => d.toJson()).toList(),
        'fetched_at': (fetchedAt ?? DateTime.now()).toIso8601String(),
      };

  static const _key = 'upcoming_schedule_v1';

  Future<void> cache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }

  /// Read back the last payload. Returns [empty] on anything unexpected — a
  /// corrupt cache must degrade to "no alarms armed yet", never to a crash on
  /// launch.
  static Future<UpcomingSchedule> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);

      if (raw == null || raw.isEmpty) return empty;

      return UpcomingSchedule.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return empty;
    }
  }

  static Future<void> forget() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// Mark a run declined locally so re-arming does not resurrect its alarms
  /// before the next fetch confirms what the server already knows.
  UpcomingSchedule withDeclined(int scheduleId, String date) => UpcomingSchedule(
        timezone: timezone,
        fetchedAt: fetchedAt,
        days: days
            .map((d) => d.date != date
                ? d
                : UpcomingDay(
                    date: d.date,
                    schoolOpen: d.schoolOpen,
                    runs: d.runs
                        .map((r) => r.scheduleId != scheduleId
                            ? r
                            : UpcomingRun(
                                scheduleId: r.scheduleId,
                                label: r.label,
                                direction: r.direction,
                                startTime: r.startTime,
                                routeName: r.routeName,
                                endTime: r.endTime,
                                graceMinutes: r.graceMinutes,
                                alertsEnabled: r.alertsEnabled,
                                declined: true,
                              ))
                        .toList(growable: false),
                  ))
            .toList(growable: false),
      );
}
