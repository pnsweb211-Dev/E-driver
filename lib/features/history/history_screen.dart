import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import 'history_models.dart';

/// The driver's own duty record.
///
/// Read-only and honest: it shows the late starts and the runs the system had
/// to auto-close as well as the good days. A driver who can see their own
/// punctuality can argue with it — which is the entire point of recording it,
/// rather than it existing only in a report the office reads without them.
class HistoryController extends StateNotifier<HistoryState> {
  HistoryController(this._ref) : super(const HistoryState());

  final Ref _ref;

  Future<void> load({DateTime? from, DateTime? to}) async {
    final api = _ref.read(driverApiProvider);
    if (api == null) return;

    state = HistoryState(trips: state.trips, summary: state.summary, loading: true);

    final result = await api.get('/trips/history', query: {
      if (from != null) 'from': _date(from),
      if (to != null) 'to': _date(to),
    });

    if (!result.ok) {
      state = HistoryState(
        trips: state.trips,
        summary: state.summary,
        error: result.message ?? 'Could not load your trips.',
      );
      return;
    }

    final data = result.data?['data'] as Map<String, dynamic>? ?? const {};

    state = HistoryState(
      trips: (data['trips'] as List<dynamic>? ?? const [])
          .map((t) => PastTrip.fromJson(t as Map<String, dynamic>))
          .toList(growable: false),
      summary:
          HistorySummary.fromJson(data['summary'] as Map<String, dynamic>? ?? const {}),
    );
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

final historyProvider =
    StateNotifierProvider<HistoryController, HistoryState>((ref) => HistoryController(ref));

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  /// Days back. Deliberately three fixed choices rather than a date picker —
  /// two taps beats a calendar dialog for this audience.
  int _range = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  void _reload() {
    final now = DateTime.now();
    ref.read(historyProvider.notifier).load(
          from: now.subtract(Duration(days: _range - 1)),
          to: now,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(historyProvider);

    return Scaffold(
      backgroundColor: AppColors.primary,
      appBar: AppBar(
        title: const Text('My trips', style: TextStyle(color: AppColors.textPrimary)),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 7, label: Text('7 days')),
                  ButtonSegment(value: 30, label: Text('30 days')),
                  ButtonSegment(value: 90, label: Text('3 months')),
                ],
                selected: {_range},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  setState(() => _range = s.first);
                  _reload();
                },
              ),
            ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(state.error!,
                    style: const TextStyle(color: AppColors.danger, fontSize: 13)),
              ),
            _SummaryStrip(summary: state.summary),
            Expanded(
              child: state.loading && state.trips.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: () async => _reload(),
                      child: state.trips.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: const [
                                SizedBox(height: 80),
                                Icon(Icons.history_rounded,
                                    size: 44, color: AppColors.textMuted),
                                SizedBox(height: 12),
                                Center(
                                  child: Text('No trips in this period.',
                                      style: TextStyle(color: AppColors.textSecondary)),
                                ),
                              ],
                            )
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                              itemCount: state.trips.length,
                              itemBuilder: (_, i) => _TripCard(trip: state.trips[i]),
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final HistorySummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Stat(value: '${summary.trips}', label: 'Trips'),
          _Stat(
            value: summary.distanceKm >= 1000
                ? '${(summary.distanceKm / 1000).toStringAsFixed(1)}k'
                : summary.distanceKm.toStringAsFixed(0),
            label: 'km',
          ),
          _Stat(
            value: summary.onTimePct == null ? '—' : '${summary.onTimePct}%',
            label: 'On time',
            tone: summary.onTimePct == null
                ? null
                : (summary.onTimePct! >= 90 ? AppColors.success : AppColors.warning),
          ),
          _Stat(value: '${summary.studentsPicked}', label: 'Picked up'),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.tone});

  final String value;
  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: tone ?? AppColors.textPrimary,
            )),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
      ],
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip});

  final PastTrip trip;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                trip.direction == 'drop'
                    ? Icons.home_work_outlined
                    : Icons.school_outlined,
                size: 20,
                color: AppColors.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  trip.routeName ?? trip.label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: AppColors.textPrimary),
                ),
              ),
              Text(trip.tripDate,
                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (trip.startedAt != null)
                _Pill(
                  icon: Icons.schedule,
                  text: '${trip.startedAt} – ${trip.endedAt ?? '—'}',
                ),
              if (trip.distanceKm != null)
                _Pill(
                  icon: Icons.route_outlined,
                  text: '${trip.distanceKm!.toStringAsFixed(1)} km',
                ),
              if (trip.studentTotal != null && trip.studentTotal! > 0)
                _Pill(
                  icon: Icons.people_alt_outlined,
                  text: '${trip.studentPicked ?? 0}/${trip.studentTotal}',
                ),
              if (trip.wasLate)
                _Pill(
                  icon: Icons.timer_outlined,
                  text: '${trip.delayMinutes} min late',
                  tone: AppColors.warning,
                ),
              // Shown plainly rather than buried: this is the "you forgot to
              // press Stop" signal, and it is excluded from the distance and
              // punctuality figures above.
              if (trip.wasAbandoned || trip.autoClosed)
                const _Pill(
                  icon: Icons.error_outline,
                  text: 'Closed automatically',
                  tone: AppColors.danger,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, this.tone});

  final IconData icon;
  final String text;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final color = tone ?? AppColors.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}
