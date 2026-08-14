import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/ui.dart';
import '../route/route_screen.dart';
import 'manifest_controller.dart';
import 'manifest_models.dart';

/// The stop-by-stop student list.
///
/// Built for the actual user: a driver at 6am, in the dark, possibly wearing
/// gloves. Big targets, high contrast, one tap per child, and a whole-stop
/// action so fourteen children boarding at once is not fourteen taps.
class ManifestScreen extends ConsumerStatefulWidget {
  const ManifestScreen({super.key, required this.tripId});

  final int tripId;

  @override
  ConsumerState<ManifestScreen> createState() => _ManifestScreenState();
}

class _ManifestScreenState extends ConsumerState<ManifestScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(manifestProvider.notifier).load(widget.tripId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(manifestProvider);
    final pending = ref.watch(outboxProvider);

    return Scaffold(
      backgroundColor: AppColors.accent,
      body: Column(
        children: [
          _HeaderBand(
            routeName: state.routeName,
            state: state,
            pendingSync: pending,
            onBack: () => Navigator.of(context).pop(),
            onRefresh: () => ref.read(manifestProvider.notifier).load(widget.tripId),
            // Replaces rather than pushes — see _StudentsLink in route_screen
            // for why these two screens swap instead of stacking.
            onRoute: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const RouteScreen()),
            ),
          ),
          Expanded(
            child: Transform.translate(
              offset: const Offset(0, -18),
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                ),
                clipBehavior: Clip.antiAlias,
                child: _body(state),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ManifestState state) {
    if (state.loading && state.stops.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null && state.stops.isEmpty) {
      return _Message(icon: Icons.error_outline, text: state.error!);
    }

    if (state.stops.isEmpty) {
      return const _Message(
        icon: Icons.people_outline,
        text: 'No students are assigned to this route yet.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
      itemCount: state.stops.length,
      itemBuilder: (context, i) => _StopCard(
        stop: state.stops[i],
        index: i + 1,
        of: state.stops.length,
        showPhone: state.canViewGuardianPhone,
        showPhoto: state.canViewStudentPhoto,
      ),
    );
  }
}

/// Coloured band carrying the counters, matching the home screen.
class _HeaderBand extends StatelessWidget {
  const _HeaderBand({
    required this.routeName,
    required this.state,
    required this.pendingSync,
    required this.onBack,
    required this.onRefresh,
    required this.onRoute,
  });

  final String? routeName;
  final ManifestState state;
  final int pendingSync;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  final VoidCallback onRoute;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Container(
        width: double.infinity,
        color: AppColors.accent,
        padding: EdgeInsets.fromLTRB(
            8, MediaQuery.of(context).padding.top + 6, 8, 30),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  onPressed: onBack,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Students',
                          style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Colors.white)),
                      if (routeName != null)
                        Text(routeName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: Colors.white.withValues(alpha: 0.85))),
                    ],
                  ),
                ),
                // A visible queue count is what stops a driver re-tapping when
                // the network is slow — the commonest cause of "it marked
                // twice".
                if (pendingSync > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.cloud_upload_outlined,
                            size: 14, color: Colors.white),
                        const SizedBox(width: 5),
                        Text('$pendingSync',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ],
                    ),
                  ),
                // Labelled, not an icon alone. This screen is used by drivers
                // who do not read fluently, but "Route" next to a route glyph
                // is a pairing they learn in one go — a bare icon is a guess.
                Pressable(
                  onTap: onRoute,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.alt_route_rounded,
                            size: 16, color: Colors.white),
                        SizedBox(width: 5),
                        Text('Route',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                  tooltip: 'Refresh',
                  onPressed: onRefresh,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  _Metric(label: 'On board', value: '${state.done}'),
                  _Metric(label: 'Absent', value: '${state.absent}'),
                  _Metric(label: 'Total', value: '${state.total}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
          Text(label,
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
        ],
      ),
    );
  }
}

class _StopCard extends ConsumerWidget {
  const _StopCard({
    required this.stop,
    required this.index,
    required this.of,
    required this.showPhone,
    required this.showPhoto,
  });

  final ManifestStop stop;
  final int index;
  final int of;
  final bool showPhone;
  final bool showPhoto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Stop $index of $of',
                          style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                      const SizedBox(height: 2),
                      Text(stop.name,
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 2),
                      Text('${stop.done} of ${stop.total} on board',
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                if (stop.pending > 0)
                  TextButton(
                    onPressed: () => _confirmAll(context, ref),
                    child: Text('All ${stop.pending}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...stop.students.map((s) => _StudentRow(
                student: s,
                showPhone: showPhone,
                showPhoto: showPhoto,
              )),
        ],
      ),
    );
  }

  /// Marking a whole stop is destructive-ish (it covers children the driver may
  /// not have looked at), so it asks first.
  Future<void> _confirmAll(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Mark all as picked up?',
            style: TextStyle(color: AppColors.textPrimary)),
        content: Text(
          'This marks the remaining ${stop.pending} student(s) at ${stop.name} as picked up.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mark all')),
        ],
      ),
    );

    if (ok == true) {
      await ref.read(manifestProvider.notifier).markStopPending(stop.stopId, 'picked');
    }
  }
}

class _StudentRow extends ConsumerWidget {
  const _StudentRow({
    required this.student,
    required this.showPhone,
    required this.showPhoto,
  });

  final ManifestStudent student;
  final bool showPhone;
  final bool showPhoto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(manifestProvider.notifier);

    return InkWell(
      // The ROW no longer marks anyone.
      //
      // It used to: a single tap anywhere on it meant "picked". That made
      // sense when the only other affordance was a grey "Tap" chip, but now
      // that the row carries an explicit tick and cross, a whole-row hit
      // target is a hazard — a driver steadying the phone, or tapping to read
      // a name, silently boards a child who is not there.
      //
      // Long-press still opens the full set (no-show, dropped off).
      onLongPress: () => _statusSheet(context, controller),
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (showPhoto) _avatar(),
            if (showPhoto) const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(student.name,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  if (student.guardianName != null)
                    Text(student.guardianName!,
                        style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                ],
              ),
            ),
            if (showPhone && (student.guardianPhone ?? '').isNotEmpty)
              IconButton(
                icon: const Icon(Icons.call_rounded, color: AppColors.success),
                tooltip: 'Call guardian',
                onPressed: () => _call(context, ref),
              ),
            const SizedBox(width: 4),
            _status(controller),
          ],
        ),
      ),
    );
  }

  /// Initials, not a grey silhouette.
  ///
  /// Most students have no photo, and a column of identical grey figures
  /// identifies nobody. Initials at least differ, and the colour is stable per
  /// child so the same face appears every morning.
  Widget _avatar() {
    if ((student.photoUrl ?? '').isNotEmpty) {
      return CircleAvatar(
        radius: 22,
        backgroundColor: AppColors.surfaceLight,
        backgroundImage: NetworkImage(student.photoUrl!),
      );
    }

    return InitialsAvatar(name: student.name, size: 44);
  }

  /// Marked children get a calm pill; unmarked ones get two explicit targets.
  ///
  /// The old design showed a grey chip reading "Tap", which told the driver
  /// nothing about what tapping would do and gave "absent" no affordance at
  /// all — it was hidden behind a long-press nobody discovers.
  Widget _status(ManifestController controller) {
    if (student.isOnBoard) {
      return const Pill(
        label: 'On board',
        tone: AppColors.success,
        toneSoft: AppColors.successSoft,
      );
    }

    if (student.isAbsent) {
      return const Pill(
        label: 'Absent',
        tone: AppColors.warning,
        toneSoft: AppColors.warningSoft,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MarkButton(
          icon: Icons.check_rounded,
          tone: Colors.white,
          background: AppColors.success,
          onTap: () => controller.mark(student.studentId, 'picked'),
        ),
        const SizedBox(width: 8),
        _MarkButton(
          icon: Icons.close_rounded,
          tone: AppColors.danger,
          background: AppColors.dangerSoft,
          onTap: () => controller.mark(student.studentId, 'absent'),
        ),
      ],
    );
  }

  Future<void> _call(BuildContext context, WidgetRef ref) async {
    // Logged BEFORE dialling: the school's audit trail must record the reveal
    // even if the call itself never connects.
    await ref.read(manifestProvider.notifier).logCall(student.studentId);

    final uri = Uri(scheme: 'tel', path: student.guardianPhone);

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the dialer.')),
      );
    }
  }

  Future<void> _statusSheet(BuildContext context, ManifestController controller) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(student.name,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary)),
            ),
            for (final option in const [
              ('picked', 'Picked up', Icons.check_circle_outline),
              ('absent', 'Absent today', Icons.event_busy_outlined),
              ('no_show', 'Did not board', Icons.person_off_outlined),
              ('dropped', 'Dropped off', Icons.where_to_vote_outlined),
            ])
              ListTile(
                leading: Icon(option.$3, color: AppColors.accent),
                title: Text(option.$2, style: const TextStyle(color: AppColors.textPrimary)),
                onTap: () {
                  Navigator.pop(ctx);
                  controller.mark(student.studentId, option.$1);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// A 44dp square target. Sized for a gloved thumb, per plan §6.3.
class _MarkButton extends StatelessWidget {
  const _MarkButton({
    required this.icon,
    required this.tone,
    required this.background,
    required this.onTap,
  });

  final IconData icon;
  final Color tone;
  final Color background;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.9,
      onTap: onTap,
      child: Container(
        width: 46,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 24, color: tone),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppColors.textMuted),
            const SizedBox(height: 14),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
