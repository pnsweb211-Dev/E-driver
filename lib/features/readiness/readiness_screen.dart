import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/readiness/readiness.dart';
import '../../core/theme/app_colors.dart';

/// §7 Layer 1 — the pre-flight checklist.
///
/// The app will not reach the Today screen while a *blocking* row is red: there
/// is no point letting a driver believe they are tracking on a phone that
/// cannot. Every red row carries a one-tap fix that deep-links to the exact
/// settings page, never "please go to settings and find…".
///
/// Acknowledge-only rows (OEM autostart) are the exception, and the reason
/// [ReadinessSeverity] exists: no Android API can read that setting back, so
/// blocking on it would strand a driver in an app that will not open. They are
/// asked to confirm instead, and the answer travels to the school on the
/// heartbeat so a lie is at least visible.
class ReadinessScreen extends ConsumerStatefulWidget {
  const ReadinessScreen({super.key, this.onPassed});

  /// Called once nothing blocking is failing. Null when the screen is opened
  /// for review from inside the app rather than as a gate.
  final VoidCallback? onPassed;

  @override
  ConsumerState<ReadinessScreen> createState() => _ReadinessScreenState();
}

class _ReadinessScreenState extends ConsumerState<ReadinessScreen>
    with WidgetsBindingObserver {
  ReadinessReport? _report;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _evaluate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Every fix sends the driver out to a system screen. Re-checking on resume
    // is what turns "I tapped Fix" into a row that actually goes green, and it
    // is also how the two-pass "Allow all the time" flow completes.
    if (state == AppLifecycleState.resumed) _evaluate();
  }

  Future<void> _evaluate() async {
    setState(() => _checking = true);

    final report = await ReadinessService.evaluate();

    if (!mounted) return;

    setState(() {
      _report = report;
      _checking = false;
    });
  }

  Future<void> _fix(ReadinessCheck check) async {
    await ReadinessService.fix(check.item);

    if (check.severity == ReadinessSeverity.acknowledge && mounted) {
      await _askAcknowledgement(check);
    }

    await _evaluate();
  }

  /// The honest version of an unverifiable check: ask, and record the answer.
  Future<void> _askAcknowledgement(ReadinessCheck check) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Did you switch it on?',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 18)),
        content: Text(
          '${check.title}\n\nWe cannot check this one from inside the app, so '
          'please confirm honestly — if it is off, tracking will stop and the '
          'school will be told the phone is unreachable.',
          style: const TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet',
                style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I have done this'),
          ),
        ],
      ),
    );

    if (done == true) await ReadinessService.acknowledge(check.item);
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final canProceed = report?.canProceed ?? false;

    return Scaffold(
      backgroundColor: AppColors.primary,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Set up this phone',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          canProceed
                              ? 'This phone is ready to track.'
                              : 'Tracking will not work until these are fixed.',
                          style: TextStyle(
                            fontSize: 13,
                            color: canProceed
                                ? AppColors.success
                                : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_checking)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded,
                          color: AppColors.textMuted),
                      tooltip: 'Check again',
                      onPressed: _evaluate,
                    ),
                ],
              ),
            ),
            Expanded(
              child: report == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      children: [
                        for (final check in report.checks)
                          _CheckRow(check: check, onFix: () => _fix(check)),
                        const SizedBox(height: 8),
                        // Signing out is the only way off this screen when a
                        // phone genuinely cannot be fixed — a driver handed the
                        // wrong handset must not be trapped in it.
                        TextButton(
                          onPressed: () =>
                              ref.read(sessionProvider.notifier).signOut(),
                          child: const Text('Sign out',
                              style: TextStyle(color: AppColors.textMuted)),
                        ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: canProceed ? widget.onPassed ?? () => Navigator.of(context).maybePop() : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    disabledBackgroundColor: AppColors.surface,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    canProceed ? 'CONTINUE' : 'FIX THE RED ITEMS TO CONTINUE',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, letterSpacing: 0.8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check, required this.onFix});

  final ReadinessCheck check;
  final VoidCallback onFix;

  Color get _tone {
    if (check.passed) return AppColors.success;

    return switch (check.severity) {
      ReadinessSeverity.blocking => AppColors.danger,
      ReadinessSeverity.acknowledge => AppColors.warning,
      ReadinessSeverity.advisory => AppColors.warning,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            check.passed ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            color: _tone,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  check.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  check.why,
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.textSecondary, height: 1.4),
                ),
                if (!check.passed && check.severity != ReadinessSeverity.blocking)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'You can continue, but tracking may be unreliable.',
                      style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                    ),
                  ),
              ],
            ),
          ),
          if (!check.passed) ...[
            const SizedBox(width: 8),
            SizedBox(
              height: 40,
              child: ElevatedButton(
                onPressed: onFix,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _tone,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(check.fixLabel,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
