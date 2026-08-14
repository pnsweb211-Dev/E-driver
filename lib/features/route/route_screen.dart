import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/ui.dart';
import '../manifest/manifest_screen.dart';
import '../today/today_controller.dart';

/// One stop on the route.
class RouteStop {
  const RouteStop({
    required this.id,
    required this.name,
    required this.order,
    this.time,
    this.studentCount = 0,
  });

  final int id;
  final String name;
  final int order;
  final String? time;
  final int studentCount;

  factory RouteStop.fromJson(Map<String, dynamic> json) => RouteStop(
        id: json['id'] as int,
        name: json['name'] as String? ?? 'Stop',
        order: (json['stop_order'] as num?)?.toInt() ?? 0,
        time: json['time'] as String?,
        studentCount: (json['student_count'] as num?)?.toInt() ?? 0,
      );

  /// `HH:mm` from whatever shape the server sent (`07:15:00` or `07:15`).
  String? get shortTime {
    if (time == null || time!.length < 4) return null;

    return time!.length >= 5 ? time!.substring(0, 5) : time;
  }
}

class RouteInfo {
  const RouteInfo({
    required this.name,
    this.label,
    this.vehicleNumber,
    this.startTime,
    this.stopCount = 0,
    this.studentCount = 0,
    this.durationMinutes,
  });

  final String name;
  final String? label;
  final String? vehicleNumber;
  final String? startTime;
  final int stopCount;
  final int studentCount;
  final int? durationMinutes;

  factory RouteInfo.fromJson(Map<String, dynamic> json) => RouteInfo(
        name: json['name'] as String? ?? 'Route',
        label: json['label'] as String?,
        vehicleNumber: json['vehicle_number'] as String?,
        startTime: json['start_time'] as String?,
        stopCount: (json['stop_count'] as num?)?.toInt() ?? 0,
        studentCount: (json['student_count'] as num?)?.toInt() ?? 0,
        durationMinutes: (json['duration_minutes'] as num?)?.toInt(),
      );

  String get durationLabel {
    final minutes = durationMinutes;

    if (minutes == null || minutes <= 0) return '—';
    if (minutes < 60) return '${minutes}m';

    final h = minutes ~/ 60;
    final m = minutes % 60;

    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

class RouteState {
  const RouteState({this.route, this.stops = const [], this.loading = false, this.message});

  final RouteInfo? route;
  final List<RouteStop> stops;
  final bool loading;

  /// Server-supplied explanation when there is nothing to show — no bus
  /// assigned, or no route configured.
  final String? message;
}

class RouteController extends StateNotifier<RouteState> {
  RouteController(this._ref) : super(const RouteState());

  final Ref _ref;

  Future<void> load() async {
    final api = _ref.read(driverApiProvider);
    if (api == null) return;

    state = RouteState(route: state.route, stops: state.stops, loading: true);

    final result = await api.get('/route');

    if (!result.ok) {
      state = RouteState(message: result.message ?? 'Could not load your route.');
      return;
    }

    final data = result.data?['data'] as Map<String, dynamic>? ?? const {};
    final route = data['route'] as Map<String, dynamic>?;

    state = RouteState(
      route: route == null ? null : RouteInfo.fromJson(route),
      stops: (data['stops'] as List<dynamic>? ?? const [])
          .map((s) => RouteStop.fromJson(s as Map<String, dynamic>))
          .toList(growable: false),
      message: data['message'] as String?,
    );
  }
}

final routeProvider =
    StateNotifierProvider<RouteController, RouteState>((ref) => RouteController(ref));

/// The stop list, readable before the trip starts.
///
/// This is what a relief driver opens the night before, and what a regular
/// driver checks when the office adds a stop. Deliberately read-only and
/// name-free — student counts, never student names. Names belong on the
/// manifest, which is gated on a running trip.
class RouteScreen extends ConsumerStatefulWidget {
  const RouteScreen({super.key});

  @override
  ConsumerState<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends ConsumerState<RouteScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => ref.read(routeProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(routeProvider);

    // The Students link needs both a permission and an open trip — boarding
    // records have to hang off a trip. Read from Today rather than re-fetching:
    // this screen is only ever reached from there, so the state is already warm.
    final session = ref.watch(sessionProvider);
    final activeTrip = ref.watch(todayProvider).activeTrip;
    final canMark = session?.capabilities.canMarkBoarding ?? false;

    return Scaffold(
      backgroundColor: AppColors.primary,
      appBar: AppBar(
        title: const Text('My route',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19)),
        backgroundColor: AppColors.primary,
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () => ref.read(routeProvider.notifier).load(),
          child: state.loading && state.route == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                  children: [
                    if (state.route == null)
                      _NoRoute(message: state.message)
                    else ...[
                      _RouteHeader(route: state.route!),
                      if (canMark) ...[
                        const SizedBox(height: 12),
                        _StudentsLink(
                          studentCount: state.route!.studentCount,
                          // Sibling screens, both one level under Today, so this
                          // REPLACES rather than pushes. Pushing would let a
                          // driver bounce Route→Students→Route and build a back
                          // stack they then have to unwind tap by tap.
                          onTap: activeTrip == null
                              ? null
                              : () => Navigator.of(context).pushReplacement(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ManifestScreen(tripId: activeTrip.id),
                                    ),
                                  ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      const _SectionLabel('Stops in order'),
                      const SizedBox(height: 8),
                      AppCard(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                        child: Column(
                          children: [
                            for (var i = 0; i < state.stops.length; i++)
                              _StopRow(
                                stop: state.stops[i],
                                isLast: i == state.stops.length - 1,
                              ),
                          ],
                        ),
                      ),
                      if (state.stops.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 14),
                          child: Text(
                            'No stops have been added to this route yet.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13.5, color: AppColors.textSecondary),
                          ),
                        ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _RouteHeader extends StatelessWidget {
  const _RouteHeader({required this.route});

  final RouteInfo route;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Full brand colour, matching the trip card on Today. The pale tint
        // this replaces made the most important line on the screen — which
        // route am I looking at — the quietest thing on it.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.accent, AppColors.accentDark],
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: AppColors.accentDark.withValues(alpha: 0.26),
                blurRadius: 16,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      route.name,
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Colors.white),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (route.label != null) route.label!,
                        if (route.startTime != null) 'due ${route.startTime}',
                        if (route.vehicleNumber != null) route.vehicleNumber!,
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.88),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.directions_bus_filled_rounded,
                    size: 30, color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // The same three coloured tiles as Today's counters, so a driver reads
        // one visual language across both screens. Each number carries an icon
        // as well, which is the part that survives not reading the label.
        Row(
          children: [
            Expanded(
              child: StatTile(
                value: '${route.stopCount}',
                label: 'Stops',
                icon: Icons.place_rounded,
                tone: AppColors.info,
                toneSoft: AppColors.infoSoft,
                toneText: AppColors.infoDark,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                value: '${route.studentCount}',
                label: 'Students',
                icon: Icons.groups_rounded,
                tone: AppColors.success,
                toneSoft: AppColors.successSoft,
                toneText: AppColors.successDark,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                value: route.durationLabel,
                label: 'Usual time',
                icon: Icons.schedule_rounded,
                tone: AppColors.warning,
                toneSoft: AppColors.warningSoft,
                toneText: AppColors.warningDark,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The bridge to the student list.
///
/// Route and Students are the two halves of the same run — stops without who
/// boards there, and who boards without the order. Reaching one from the other
/// used to mean going back to Today first.
///
/// Greys out rather than disappearing when no trip is open, and says why: a
/// control that vanishes teaches nothing.
class _StudentsLink extends StatelessWidget {
  const _StudentsLink({required this.studentCount, required this.onTap});

  final int studentCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final tone = enabled ? AppColors.success : AppColors.textMuted;

    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: enabled ? null : AppColors.surface,
        gradient: enabled
            ? const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [AppColors.successSoft, AppColors.surface],
              )
            : null,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: enabled
              ? AppColors.success.withValues(alpha: 0.3)
              : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: enabled ? AppColors.success : AppColors.surfaceLight,
              shape: BoxShape.circle,
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: AppColors.success.withValues(alpha: 0.32),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Icon(Icons.groups_rounded,
                size: 23, color: enabled ? Colors.white : AppColors.textMuted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Students',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: enabled ? AppColors.successDark : AppColors.textMuted,
                  ),
                ),
                Text(
                  enabled
                      ? 'Mark who is on board'
                      : 'Opens once you start the trip',
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (enabled)
            Icon(Icons.chevron_right_rounded, size: 26, color: tone)
          else
            const Icon(Icons.lock_outline_rounded,
                size: 20, color: AppColors.textMuted),
        ],
      ),
    );

    return enabled ? Pressable(onTap: onTap!, child: body) : body;
  }
}

/// One row of the timeline: a numbered dot, a connector, the stop, its time
/// and how many children board there.
class _StopRow extends StatelessWidget {
  const _StopRow({required this.stop, required this.isLast});

  final RouteStop stop;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    // A stop with nobody on it is the one thing worth colour-coding here: it is
    // derivable from the data, and it answers "do I actually need to stop?"
    // without reading a word. Everything else on this screen is reference.
    final hasStudents = stop.studentCount > 0;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.accent, AppColors.accentDark],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Text(
                  '${stop.order}',
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: Colors.white),
                ),
              ),
              // The connector is what turns a list into a route. Tinted with
              // the brand rather than left hairline grey, so the line reads as
              // part of the route instead of a table border.
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 3,
                    color: AppColors.accent.withValues(alpha: 0.28),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(0, 12, 0, isLast ? 12 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stop.name,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary),
                  ),
                  if (stop.shortTime != null) ...[
                    const SizedBox(height: 5),
                    _Chip(
                      icon: Icons.schedule_rounded,
                      label: stop.shortTime!,
                      tone: AppColors.accent,
                      toneSoft: AppColors.accentSoft,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _Chip(
              icon: hasStudents
                  ? Icons.groups_rounded
                  : Icons.person_off_outlined,
              label: hasStudents ? '${stop.studentCount}' : 'none',
              tone: hasStudents ? AppColors.successDark : AppColors.textMuted,
              toneSoft:
                  hasStudents ? AppColors.successSoft : AppColors.surfaceLight,
            ),
          ),
        ],
      ),
    );
  }
}

/// An icon plus a very short label. The icon is the point: it is what a driver
/// who does not read the label still understands.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.tone,
    required this.toneSoft,
  });

  final IconData icon;
  final String label;
  final Color tone;
  final Color toneSoft;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: toneSoft,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: tone),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w700, color: tone),
          ),
        ],
      ),
    );
  }
}

class _NoRoute extends StatelessWidget {
  const _NoRoute({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 18),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
                color: AppColors.surfaceLight, shape: BoxShape.circle),
            child: const Icon(Icons.alt_route_rounded,
                size: 30, color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
          const Text('No route yet',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text(
            message ?? 'The school has not set up a route for your bus.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13.5, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
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
