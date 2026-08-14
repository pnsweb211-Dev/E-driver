/// The shape of the alarm ladder, kept free of plugins so it can be tested.
///
/// For a 06:45 run:
///
/// ```
/// 06:15  quiet reminder      "Route 26 starts in 30 min"
/// 06:35  reminder + sound    "Route 26 starts in 10 min — start the trip"
/// 06:45  FULL-SCREEN ALARM   rings until acted on
/// 06:48 → 07:15              re-alarm every 3 minutes
/// ```
library;

/// What a single rung is for.
enum RungKind {
  /// Quiet heads-up. Notification only.
  reminder,

  /// Louder pre-start nudge.
  warning,

  /// The full-screen, alarm-category ring.
  alarm,
}

class LadderRung {
  const LadderRung({required this.offsetMinutes, required this.kind});

  /// Minutes relative to the run's planned start. Negative is before.
  final int offsetMinutes;
  final RungKind kind;

  /// Stable identity within a run, used to derive the OS notification id so
  /// re-arming replaces a rung instead of stacking a second copy of it.
  String get key => 'r${offsetMinutes >= 0 ? '+' : ''}$offsetMinutes';
}

/// Rungs for a run the driver has to be nagged about properly — today and
/// tomorrow.
///
/// The repeat tail stops at T+30 rather than running forever: past that point
/// the server ladder has already escalated to the transport manager and the
/// admin (§7 Layer 3), and a phone that has rung eleven times unanswered is
/// not going to be answered by a twelfth.
List<LadderRung> fullLadder() => [
      const LadderRung(offsetMinutes: -30, kind: RungKind.reminder),
      const LadderRung(offsetMinutes: -10, kind: RungKind.warning),
      for (var m = 0; m <= 30; m += 3)
        LadderRung(offsetMinutes: m, kind: RungKind.alarm),
    ];

/// Rungs for a run further out than tomorrow.
///
/// Android caps how many exact alarms one app may hold, so arming the full
/// thirteen-rung ladder for all seven days would burn the budget on runs the
/// app will almost certainly re-arm before they matter. Days 3–7 get the two
/// that actually have to survive a week offline; every app open re-arms the
/// near days in full.
List<LadderRung> distantLadder() => [
      const LadderRung(offsetMinutes: -10, kind: RungKind.warning),
      const LadderRung(offsetMinutes: 0, kind: RungKind.alarm),
    ];

/// Deterministic, positive, 31-bit notification id for one rung of one run on
/// one day.
///
/// Deterministic matters: re-arming has to overwrite the same OS slot, or a
/// driver who opens the app three times before 6 a.m. gets three alarms.
int rungNotificationId(int scheduleId, String date, LadderRung rung) {
  var hash = 0x811c9dc5;

  for (final unit in '$scheduleId|$date|${rung.key}'.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }

  // 0 is a legal notification id but is also the value a bug most often
  // produces, so keep it out of the space.
  return hash == 0 ? 1 : hash;
}
