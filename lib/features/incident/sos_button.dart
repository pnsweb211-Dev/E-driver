import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import 'incident_controller.dart';

/// The SOS control (plan §12 item 3 — "one button that makes the product feel
/// serious").
///
/// **Press and hold**, not tap. A tap-to-send SOS sitting on the main screen of
/// a phone that lives in a bus cradle would fire by accident several times a
/// week, and an emergency channel that cries wolf is worse than no channel at
/// all. A 1.5-second hold with a visible fill is unmistakably deliberate and
/// still faster than any confirmation dialog.
class SosButton extends ConsumerStatefulWidget {
  const SosButton({super.key});

  @override
  ConsumerState<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends ConsumerState<SosButton>
    with SingleTickerProviderStateMixin {
  static const _holdDuration = Duration(milliseconds: 1500);

  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: _holdDuration,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) _fire();
    });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  Future<void> _fire() async {
    // Two distinct buzzes: the driver may not be looking at the screen, and
    // needs to know the hold registered without checking.
    await HapticFeedback.heavyImpact();

    final sent = await ref.read(incidentProvider.notifier).report(IncidentType.sos);

    if (!mounted) return;

    _hold.reset();

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(sent ? Icons.check_circle : Icons.error_outline,
                color: sent ? AppColors.success : AppColors.danger),
            const SizedBox(width: 10),
            Text(sent ? 'School alerted' : 'Could not send',
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 18)),
          ],
        ),
        content: Text(
          sent
              // Honest about the offline case rather than claiming delivery we
              // cannot confirm.
              ? 'Your SOS has been sent. If you have no signal it will go the '
                  'moment you do. Stay with the bus and keep the children on board.'
              : 'Something went wrong. Call the school office directly.',
          style: const TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(incidentProvider);

    return GestureDetector(
      onTapDown: (_) => busy ? null : _hold.forward(),
      onTapUp: (_) => _hold.reverse(),
      onTapCancel: () => _hold.reverse(),
      child: AnimatedBuilder(
        animation: _hold,
        builder: (context, _) => Container(
          height: 62,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            // Solid red at rest, not a pale tint behind a red outline. On the
            // light canvas that tint left white text sitting on near-white and
            // the control was unreadable until the hold was already underway.
            color: AppColors.danger,
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // The fill IS the instruction: the driver can see how much longer
              // to hold without reading anything.
              FractionallySizedBox(
                widthFactor: _hold.value,
                child: Container(color: AppColors.dangerDark),
              ),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.emergency_share_rounded,
                        color: Colors.white, size: 26),
                    const SizedBox(width: 10),
                    Text(
                      _hold.value > 0 ? 'KEEP HOLDING…' : 'HOLD FOR SOS',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The calmer sibling: breakdown, traffic, detour.
///
/// Separated from SOS on purpose. Folding "stuck in traffic" into the same
/// control as "there has been an accident" is what turns an emergency button
/// into something the office learns to ignore.
Future<void> showIncidentSheet(BuildContext context, WidgetRef ref) async {
  final type = await showModalBottomSheet<IncidentType>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text('Report a problem',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text('The school sees this straight away.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          for (final type in IncidentType.reportable)
            ListTile(
              title: Text(type.label,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 16)),
              subtitle: type.hint.isEmpty
                  ? null
                  : Text(type.hint,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
              onTap: () => Navigator.pop(ctx, type),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (type == null) return;

  final sent = await ref.read(incidentProvider.notifier).report(type);

  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(sent
        ? 'Reported. The school can see it now.'
        : 'Could not report. Please call the school office.'),
    backgroundColor: sent ? AppColors.success : AppColors.danger,
    behavior: SnackBarBehavior.floating,
  ));
}
