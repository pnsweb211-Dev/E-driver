import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/session/session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/ui.dart';
import '../../core/tracking/tracking_gate.dart';
import '../../services/update_service.dart';
import '../history/history_screen.dart';
import '../incident/sos_button.dart';
import '../manifest/manifest_screen.dart';
import '../profile/change_pin_screen.dart';
import '../readiness/readiness_screen.dart';
import '../route/route_screen.dart';
import 'today_controller.dart';
import 'today_models.dart';

/// The driver's home screen.
///
/// Mode-aware (§2.1). In `simple` — the default, and what most schools want —
/// there is ONE trip card with one button and nothing else: the route is
/// inferred server-side, so the driver never picks anything. In `standard` and
/// `full` the run list and the student counters appear.
///
/// Crucially the two are the same screen over the same data, so a school that
/// stays on simple still gets complete trip records; only the surface shrinks.
class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(todayProvider.notifier).load();

      // Once-per-run "update available" check (silent on any failure).
      if (mounted) UpdateService.maybePrompt(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final state = ref.watch(todayProvider);
    final pending = ref.watch(outboxProvider);

    if (session == null) return const SizedBox.shrink();

    final simple = session.capabilities.isSimple;
    final active = state.activeTrip;

    return Scaffold(
      backgroundColor: AppColors.accent,
      body: Column(
        children: [
          _HeaderBand(
            driverName: session.driverName,
            vehicleNumber: state.vehicleNumber ?? session.vehicleNumber,
            pendingSync: pending,
            onSignOut: _signOut,
            onChangePin: () => _push(const ChangePinScreen()),
            onPhoneSetup: () => _push(const ReadinessScreen()),
            onHistory: simple ? null : () => _push(const HistoryScreen()),
          ),
          Expanded(child: _sheet(context, ref, session, state, simple, active)),
        ],
      ),
    );
  }

  /// The content sheet, lifted over the header band.
  ///
  /// The overlap is what makes the band read as a header rather than a stripe
  /// of colour — the page looks like paper sliding up under it.
  Widget _sheet(
    BuildContext context,
    WidgetRef ref,
    Session session,
    TodayState state,
    bool simple,
    ActiveTrip? active,
  ) {
    return Transform.translate(
      offset: const Offset(0, -18),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        clipBehavior: Clip.antiAlias,
        child: RefreshIndicator(
          onRefresh: () => ref.read(todayProvider.notifier).load(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 34),
            children: [
              if (state.error != null) ...[
                StatusStrip(
                  icon: Icons.error_outline_rounded,
                  title: state.error!,
                  tone: AppColors.danger,
                  toneSoft: AppColors.dangerSoft,
                ),
                const SizedBox(height: 12),
              ],
              if (state.message != null) ...[
                StatusStrip(
                  icon: Icons.info_outline_rounded,
                  title: state.message!,
                  tone: AppColors.warning,
                  toneSoft: AppColors.warningSoft,
                ),
                const SizedBox(height: 12),
              ],

              _TripCard(
                state: state,
                schoolName: session.schoolName,
                busy: state.loading,
              ),

              // Counters are only meaningful once boarding is being marked,
              // which is a `full`-mode capability. Showing 0/0/0 to a simple
              // school is noise dressed up as information.
              if (session.capabilities.canMarkBoarding && active != null) ...[
                const SizedBox(height: 12),
                _Counters(trip: active),
              ],

              if (!simple && state.runs.length > 1) ...[
                const SizedBox(height: 18),
                const _SectionLabel('Today\'s runs'),
                const SizedBox(height: 8),
                for (final run in state.runs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _RunRow(
                      run: run,
                      canMark: session.capabilities.canMarkBoarding,
                      activeTripId: active?.id,
                      busy: state.loading,
                    ),
                  ),
              ],

              if (state.runs.isEmpty && state.message == null) ...[
                const SizedBox(height: 12),
                const _EmptyRuns(),
              ],

              // Shortcuts. Route is here in EVERY mode, including simple: a
              // relief driver on a one-button school still has to know where
              // the bus stops, and it exposes no student names.
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _Shortcut(
                      icon: Icons.alt_route_rounded,
                      label: 'My route',
                      tone: AppColors.info,
                      toneSoft: AppColors.infoSoft,
                      toneText: AppColors.infoDark,
                      onTap: () => _push(const RouteScreen()),
                    ),
                  ),
                  if (session.capabilities.canMarkBoarding) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: _Shortcut(
                        icon: Icons.groups_rounded,
                        label: 'Students',
                        tone: AppColors.success,
                        toneSoft: AppColors.successSoft,
                        toneText: AppColors.successDark,
                        // Boarding records need a trip to hang off, so this is
                        // only live once one is running.
                        onTap: active == null
                            ? null
                            : () => _push(ManifestScreen(tripId: active.id)),
                      ),
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 18),
              const _SafetyBar(),

              // Who this bus belongs to, and how to reach them. Nothing else in
              // the app named the school, which matters most for the driver
              // least likely to know: someone handed a spare handset for one
              // morning's relief run.
              if (session.schoolName.isNotEmpty) ...[
                const SizedBox(height: 22),
                _SchoolCard(session: session),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _push(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Sign out?',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text(
          'You will need your Driver ID and PIN to sign back in.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.danger, foregroundColor: Colors.white),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (ok == true) await ref.read(sessionProvider.notifier).signOut();
  }
}

/// Start a trip, but only once the phone can actually report its position.
///
/// Both entry points (the trip card and a run row) go through here, so a trip
/// can never appear to be running on a device that cannot track — the failure
/// that makes a school say "your app doesn't work".
Future<void> _startTrip(BuildContext context, WidgetRef ref, {int? scheduleId}) async {
  final readiness = await TrackingGate.check();

  if (readiness == TrackingReadiness.foregroundOnly) {
    if (!context.mounted) return;
    // Ask, but do not block: foreground-only still tracks while the app is
    // open, which beats refusing to start the run at all.
    await TrackingGate.requestAlways(context);
  } else if (readiness != TrackingReadiness.ready) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(TrackingGate.message(readiness) ?? 'Cannot start tracking.'),
        backgroundColor: AppColors.warning,
        action: SnackBarAction(
          label: 'SETTINGS',
          textColor: Colors.white,
          onPressed: () => readiness == TrackingReadiness.locationServicesOff
              ? Geolocator.openLocationSettings()
              : Geolocator.openAppSettings(),
        ),
      ),
    );
    return;
  }

  final started =
      await ref.read(todayProvider.notifier).startTrip(scheduleId: scheduleId);

  if (started) await TrackingGate.startService();
}

Future<void> _stopTrip(WidgetRef ref) async {
  // Note what is NOT here: the background service is no longer stopped. It is
  // a duty service now — §7 Layers 4 and 5 have to keep working between the
  // morning pickup and the afternoon drop. `stopTrip` clears the trip-active
  // flag and the service's own duty tick drops it to watch or idle.
  await ref.read(todayProvider.notifier).stopTrip();
}

/// The one card that answers "what am I doing, and what do I press".
class _TripCard extends ConsumerWidget {
  const _TripCard({
    required this.state,
    required this.schoolName,
    required this.busy,
  });

  final TodayState state;
  final String schoolName;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = state.activeTrip;
    final running = active != null;

    // Which run this card is about: the open one, else the next one due.
    final pending = state.runs.where((r) => !r.isDone);
    final next = pending.isEmpty ? null : pending.first;
    final title = running
        ? _pretty(active.routeName ?? 'Trip running')
        : (next == null ? 'No run scheduled' : _pretty(next.label));
    final subtitle = running
        ? 'Started ${_hhmm(active.startedAt) ?? 'just now'}'
        : (next?.plannedStartTime != null
            ? 'Due ${next!.plannedStartTime!.substring(0, 5)}'
            : schoolName);

    // A gradient rather than a flat slab. The card fills a third of the screen,
    // and at that size one solid colour reads as a printed block; the light
    // corner is what makes it look like a surface with the light on it.
    final top = running ? AppColors.success : AppColors.accent;
    final bottom = running ? AppColors.successDark : AppColors.accentDark;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [top, bottom],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: bottom.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
              if (running)
                const Pill(
                  label: 'Running',
                  tone: AppColors.successDark,
                  toneSoft: Colors.white,
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.85)),
          ),
          const SizedBox(height: 16),
          BigButton(
            label: running ? 'STOP TRIP' : 'START TRIP',
            icon: running ? Icons.stop_rounded : Icons.play_arrow_rounded,
            busy: busy,
            // Amber to start — it has to be the loudest thing on the screen.
            // Red to stop, because stopping early strands children and should
            // never be the easy accident.
            color: running ? AppColors.danger : AppColors.cta,
            foreground: running ? Colors.white : AppColors.ctaText,
            height: 64,
            onPressed: () => running
                ? _stopTrip(ref)
                : _startTrip(context, ref, scheduleId: next?.scheduleId),
          ),
          const SizedBox(height: 12),
          // Boxed rather than loose text: it is the card's status line, and on
          // a gradient a bare sentence reads as a caption nobody looks at.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  running ? Icons.podcasts_rounded : Icons.gps_off_rounded,
                  size: 17,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    running
                        // The single most motivating sentence on the screen: it
                        // tells the driver why the button mattered.
                        ? 'Parents can see the bus'
                        : 'Parents cannot see the bus yet',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String? _hhmm(String? iso) {
    if (iso == null) return null;

    final parsed = DateTime.tryParse(iso);

    if (parsed == null) return null;

    final local = parsed.toLocal();

    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _Counters extends StatelessWidget {
  const _Counters({required this.trip});

  final ActiveTrip trip;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: StatTile(
            value: '${trip.studentPicked ?? 0}',
            label: 'On board',
            icon: Icons.check_rounded,
            tone: AppColors.success,
            toneSoft: AppColors.successSoft,
            toneText: AppColors.successDark,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: StatTile(
            value: '${trip.studentAbsent ?? 0}',
            label: 'Absent',
            icon: Icons.person_off_outlined,
            tone: AppColors.warning,
            toneSoft: AppColors.warningSoft,
            toneText: AppColors.warningDark,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: StatTile(
            value: '${trip.studentTotal ?? 0}',
            label: 'Total',
            icon: Icons.groups_outlined,
            tone: AppColors.info,
            toneSoft: AppColors.infoSoft,
            toneText: AppColors.infoDark,
          ),
        ),
      ],
    );
  }
}

class _RunRow extends ConsumerWidget {
  const _RunRow({
    required this.run,
    required this.canMark,
    required this.activeTripId,
    required this.busy,
  });

  final TodayRun run;
  final bool canMark;
  final int? activeTripId;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = run.isRunning;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: run.isDone ? AppColors.successSoft : AppColors.accentSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              run.direction == 'drop'
                  ? Icons.home_work_outlined
                  : Icons.directions_bus_filled_outlined,
              size: 22,
              color: run.isDone ? AppColors.success : AppColors.accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _pretty(run.label),
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                ),
                Text(
                  [
                    if (run.routeName != null) run.routeName!,
                    if (run.plannedStartTime != null)
                      run.plannedStartTime!.substring(0, 5),
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          if (run.isDone)
            const Pill(
              label: 'Done',
              tone: AppColors.success,
              toneSoft: AppColors.successSoft,
            )
          else if (canMark && running && activeTripId != null)
            Pressable(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => ManifestScreen(tripId: activeTripId!)),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Students',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.accent),
                ),
              ),
            )
          else
            Pressable(
              onTap: busy
                  ? () {}
                  : () => _startTrip(context, ref, scheduleId: run.scheduleId),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.cta,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'Start',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.ctaText),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// SOS plus the calmer "report a problem", pinned in every mode.
class _SafetyBar extends ConsumerWidget {
  const _SafetyBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        const Expanded(flex: 3, child: SosButton()),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: Pressable(
            onTap: () => showIncidentSheet(context, ref),
            child: Container(
              height: 62,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.report_problem_outlined,
                      size: 20, color: AppColors.textSecondary),
                  SizedBox(height: 2),
                  Text('Problem',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textSecondary)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The school this bus runs for, plus one tap to reach the office.
///
/// Deliberately at the BOTTOM and deliberately calm. It answers a question the
/// driver asks once ("whose bus is this?") and one they ask rarely but urgently
/// ("the bus won't start, who do I ring?"), so it must be findable without
/// competing with STOP TRIP for attention.
///
/// Buttons appear only for channels the school actually filled in — a Call
/// button that dials nothing is worse than no button.
class _SchoolCard extends StatelessWidget {
  const _SchoolCard({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final phone = session.schoolPhone;
    final email = session.schoolEmail;
    final address = session.schoolAddress;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.apartment_rounded,
                    size: 23, color: AppColors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.schoolName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (address != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        address,
                        style: const TextStyle(
                            fontSize: 12.5, color: AppColors.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (session.hasSchoolContact) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (phone != null)
                  Expanded(
                    child: _ContactButton(
                      icon: Icons.call_rounded,
                      label: 'Call school',
                      tone: AppColors.success,
                      toneSoft: AppColors.successSoft,
                      toneText: AppColors.successDark,
                      onTap: () => _launch(
                        context,
                        Uri(scheme: 'tel', path: phone),
                        'Could not open the dialer.',
                      ),
                    ),
                  ),
                if (phone != null && email != null) const SizedBox(width: 10),
                if (email != null)
                  Expanded(
                    child: _ContactButton(
                      icon: Icons.mail_rounded,
                      label: 'Email',
                      tone: AppColors.info,
                      toneSoft: AppColors.infoSoft,
                      toneText: AppColors.infoDark,
                      onTap: () => _launch(
                        context,
                        Uri(scheme: 'mailto', path: email),
                        'No email app is set up on this phone.',
                      ),
                    ),
                  ),
              ],
            ),
            if (phone != null) ...[
              const SizedBox(height: 8),
              // The number in full, because a phone with no dialer app — or a
              // driver who would rather use their own handset — still needs it.
              Text(
                phone,
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textMuted),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _launch(BuildContext context, Uri uri, String onFailure) async {
    final ok = await canLaunchUrl(uri) && await launchUrl(uri);

    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(onFailure)));
    }
  }
}

/// A labelled, tinted action. Icon AND word, never one alone.
class _ContactButton extends StatelessWidget {
  const _ContactButton({
    required this.icon,
    required this.label,
    required this.tone,
    required this.toneSoft,
    required this.toneText,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color tone;
  final Color toneSoft;
  final Color toneText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: toneSoft,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: tone.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: tone),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: toneText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The coloured band across the top, in the school's own brand colour.
///
/// Carries the status bar with it, so the colour runs to the very top of the
/// screen rather than sitting under a white strip.
class _HeaderBand extends StatelessWidget {
  const _HeaderBand({
    required this.driverName,
    required this.vehicleNumber,
    required this.pendingSync,
    required this.onSignOut,
    required this.onChangePin,
    required this.onPhoneSetup,
    required this.onHistory,
  });

  final String driverName;
  final String vehicleNumber;
  final int pendingSync;
  final VoidCallback onSignOut;
  final VoidCallback onChangePin;
  final VoidCallback onPhoneSetup;

  /// Null in simple mode, where the entry is not shown at all.
  final VoidCallback? onHistory;

  String get _partOfDay {
    final hour = DateTime.now().hour;

    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';

    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Light status-bar icons: this band is the school's colour and is
      // usually dark. Without this the clock and battery disappear into it.
      value: SystemUiOverlayStyle.light,
      child: Container(
        width: double.infinity,
        color: AppColors.accent,
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.of(context).padding.top + 12,
          8,
          30,
        ),
        child: _row(),
      ),
    );
  }

  Widget _row() {
    return Row(
      children: [
        // Tinted white rather than the shared palette: on a coloured band the
        // pastel avatar colours turn to mud.
        InitialsAvatar(
          name: driverName,
          size: 46,
          tone: AppColors.accent,
          background: Colors.white,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_partOfDay,
                  style: TextStyle(
                      fontSize: 12.5, color: Colors.white.withValues(alpha: 0.85))),
              Text(
                driverName.split(' ').first,
                style: const TextStyle(
                    fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white),
              ),
              if (vehicleNumber.isNotEmpty)
                Text(vehicleNumber,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withValues(alpha: 0.85))),
            ],
          ),
        ),
        // Only shown when there is something queued — a permanent indicator
        // would just become part of the furniture.
        if (pendingSync > 0)
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_upload_outlined, size: 15, color: Colors.white),
                const SizedBox(width: 5),
                Text('$pendingSync',
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ],
            ),
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
          color: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          onSelected: (value) => switch (value) {
            'pin' => onChangePin(),
            'setup' => onPhoneSetup(),
            'history' => onHistory?.call(),
            _ => onSignOut(),
          },
          itemBuilder: (_) => [
            if (onHistory != null)
              const PopupMenuItem(
                value: 'history',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.history_rounded, color: AppColors.textSecondary),
                  title: Text('My trips',
                      style: TextStyle(color: AppColors.textPrimary)),
                ),
              ),
            const PopupMenuItem(
              value: 'setup',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.phonelink_setup_rounded,
                    color: AppColors.textSecondary),
                title:
                    Text('Phone setup', style: TextStyle(color: AppColors.textPrimary)),
              ),
            ),
            const PopupMenuItem(
              value: 'pin',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading:
                    Icon(Icons.password_rounded, color: AppColors.textSecondary),
                title:
                    Text('Change PIN', style: TextStyle(color: AppColors.textPrimary)),
              ),
            ),
            const PopupMenuItem(
              value: 'signout',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.logout_rounded, color: AppColors.danger),
                title: Text('Sign out', style: TextStyle(color: AppColors.danger)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Sentence-case a label the school typed.
///
/// Route schedule labels come straight from a text field, so real data reads
/// `morning` / `mid`. The proper fix is validation at the point of entry, but
/// a driver should not be shown lowercase fragments while that is pending.
String _pretty(String raw) {
  final trimmed = raw.trim();

  if (trimmed.isEmpty) return 'Run';

  return trimmed[0].toUpperCase() + trimmed.substring(1);
}

/// A tile shortcut, tinted by its own tone so the two read as two destinations
/// rather than one grey strip.
///
/// Greys out rather than disappearing when unavailable — a control that
/// vanishes teaches the driver nothing about why. The disabled state drops the
/// colour entirely, which is the point: the tile only looks live when it is.
class _Shortcut extends StatelessWidget {
  const _Shortcut({
    required this.icon,
    required this.label,
    required this.tone,
    required this.toneSoft,
    required this.toneText,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color tone;
  final Color toneSoft;
  final Color toneText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    final body = Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: enabled ? null : AppColors.surface,
        gradient: enabled
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.surface, toneSoft],
              )
            : null,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: enabled ? tone.withValues(alpha: 0.24) : AppColors.border,
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: enabled ? tone : AppColors.surfaceLight,
              shape: BoxShape.circle,
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: tone.withValues(alpha: 0.32),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Icon(icon,
                size: 22, color: enabled ? Colors.white : AppColors.textMuted),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: enabled ? toneText : AppColors.textMuted,
            ),
          ),
          if (!enabled)
            const Text('after start',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
        ],
      ),
    );

    return enabled ? Pressable(onTap: onTap!, child: body) : body;
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary),
      );
}

class _EmptyRuns extends StatelessWidget {
  const _EmptyRuns();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
      child: Column(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
                color: AppColors.surfaceLight, shape: BoxShape.circle),
            child: const Icon(Icons.event_available_outlined,
                size: 30, color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
          const Text('No runs scheduled today',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text(
            'Enjoy the day. The school will add runs to your timetable.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
