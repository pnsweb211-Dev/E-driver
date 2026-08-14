import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/alarms/alarm_controller.dart';
import '../../core/alarms/alarm_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/tracking/tracking_gate.dart';
import '../../services/background_service.dart';
import '../today/today_controller.dart';

/// The screen a full-screen alarm lands on (§7 Layer 2).
///
/// Deliberately unescapable by the usual gestures — no back button, no scrim to
/// tap away. There are exactly two answers, and they are the two the school
/// needs to be able to tell apart:
///
///   * **Start Trip** — the run is happening.
///   * **Can't run this trip** — with a reason, which is what separates
///     *I forgot* from *I'm on leave*. Nothing in the system could distinguish
///     those before.
///
/// Snooze exists, but it is capped: an uncapped snooze is a dismiss with extra
/// steps.
class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key, required this.target});

  final AlarmTarget target;

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen> {
  bool _busy = false;
  int _snoozesLeft = AlarmService.maxSnoozes;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Reaching this screen IS the evidence that the alarm fired — the OS
      // rings it without running any Dart, so there is no earlier moment we
      // could honestly report from.
      await ref.read(adherenceProvider.notifier).report(
            'alarm_fired',
            target: widget.target,
          );

      final used = await AlarmService.snoozesUsed(
          widget.target.scheduleId, widget.target.date);

      if (mounted) {
        setState(() => _snoozesLeft = AlarmService.maxSnoozes - used);
      }
    });
  }

  Future<void> _start() async {
    setState(() => _busy = true);

    // Same gate as every other way into a trip: never let a trip look like it
    // is running on a phone that cannot report a position.
    final readiness = await TrackingGate.check();

    if (readiness == TrackingReadiness.foregroundOnly && mounted) {
      await TrackingGate.requestAlways(context);
    } else if (readiness != TrackingReadiness.ready) {
      if (!mounted) return;

      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(TrackingGate.message(readiness) ?? 'Cannot start tracking.'),
        backgroundColor: AppColors.warning,
      ));
      return;
    }

    final started = await ref
        .read(todayProvider.notifier)
        .startTrip(scheduleId: widget.target.scheduleId);

    if (!started) {
      if (!mounted) return;

      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not start the trip. Check your signal and try again.'),
        backgroundColor: AppColors.danger,
      ));
      return;
    }

    await setTripActive(true);
    await TrackingGate.startService();
    await ref.read(adherenceProvider.notifier).onRunStarted(widget.target);

    ref.read(pendingAlarmProvider.notifier).clear();
  }

  Future<void> _snooze() async {
    final ok = await AlarmService.snooze(widget.target);

    if (!ok) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No snoozes left. Start the trip or tell the school you cannot.'),
        backgroundColor: AppColors.warning,
      ));
      return;
    }

    await ref.read(adherenceProvider.notifier).report(
          'snoozed',
          target: widget.target,
          meta: {'minutes': AlarmService.snoozeMinutes},
        );

    ref.read(pendingAlarmProvider.notifier).clear();
  }

  Future<void> _decline() async {
    final reason = await showModalBottomSheet<DeclineReason>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 6),
              child: Text(
                'Why can you not run this trip?',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'The school is told straight away, so nobody chases you.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
            for (final reason in DeclineReason.values)
              ListTile(
                title: Text(reason.label,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 16)),
                trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
                onTap: () => Navigator.pop(ctx, reason),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (reason == null) return;

    setState(() => _busy = true);

    await ref.read(adherenceProvider.notifier).decline(widget.target, reason);

    if (!mounted) return;

    ref.read(pendingAlarmProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.target.routeName ?? widget.target.label;

    // No back gesture: the alarm is answered, not dismissed.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.danger,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const Spacer(),
                const Icon(Icons.alarm_on_rounded, size: 72, color: Colors.white),
                const SizedBox(height: 18),
                Text(
                  widget.target.startTime,
                  style: const TextStyle(
                    fontSize: 52,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  route,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.target.direction == 'drop'
                      ? 'Afternoon drop is due to start'
                      : 'Morning pickup is due to start',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, color: Colors.white70),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 68,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _start,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.danger,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : const Icon(Icons.play_arrow_rounded, size: 32),
                    label: const Text(
                      'START TRIP',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _busy ? null : _decline,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white70, width: 1.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Text(
                      "I CAN'T RUN THIS TRIP",
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: _busy || _snoozesLeft <= 0 ? null : _snooze,
                  child: Text(
                    _snoozesLeft > 0
                        ? 'Snooze ${AlarmService.snoozeMinutes} minutes '
                            '($_snoozesLeft left)'
                        : 'No snoozes left',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
