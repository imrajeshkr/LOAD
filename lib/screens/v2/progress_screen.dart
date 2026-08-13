import 'package:flutter/material.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/v2_widgets.dart';

/// Progress tab. Seven panels, each answering a question out loud: the number
/// leads, the chart is evidence, and nothing draws until there's enough data to
/// judge it against — every panel has an explicit gated empty state.
class ProgressTab extends StatefulWidget {
  const ProgressTab({super.key});
  @override
  State<ProgressTab> createState() => _ProgressTabState();
}

class _Range {
  final String label;
  final int? weeks; // null = all time
  const _Range(this.label, this.weeks);
  DateTime? get since =>
      weeks == null ? null : DateTime.now().subtract(Duration(days: weeks! * 7));
}

const _ranges = [
  _Range('4W', 4),
  _Range('8W', 8),
  _Range('12W', 12),
  _Range('All', null),
];

class _ProgressTabState extends State<ProgressTab> {
  int _rangeIdx = 2; // 12W default — shows the full seeded history

  ProgressGatesV2? _gates;
  List<LiftStatusV2> _lifts = const [];
  List<(int, int)> _effort = const [];
  List<MuscleChipV2> _muscles = const [];
  List<ConsistencyWeekV2> _weeks = const [];
  PhotoPairV2? _photos;
  BodyTrendV2? _body;
  ProteinWeekV2? _protein;

  bool _loading = true;
  String? _error;

  _Range get _range => _ranges[_rangeIdx];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = SupabaseService.instance;
      final since = _range.since;
      // "Weekly sets per muscle" is always the trailing 7 days — it's a
      // this-week readout, independent of the strength/effort range.
      final muscleSince = DateTime.now().subtract(const Duration(days: 7));
      final r = await Future.wait([
        svc.fetchProgressGates(),
        svc.fetchLiftStatus(since: since),
        svc.fetchEffortHistogram(since: since),
        svc.fetchMuscleSets(since: muscleSince),
        svc.fetchConsistency(since: since),
        svc.fetchPhotoPair(since: since),
        svc.fetchBodyTrend(since: since),
        svc.fetchProteinWeek(),
      ]);
      if (!mounted) return;
      setState(() {
        _gates = r[0] as ProgressGatesV2?;
        _lifts = r[1] as List<LiftStatusV2>;
        _effort = r[2] as List<(int, int)>;
        _muscles = r[3] as List<MuscleChipV2>;
        _weeks = r[4] as List<ConsistencyWeekV2>;
        _photos = r[5] as PhotoPairV2?;
        _body = r[6] as BodyTrendV2?;
        _protein = r[7] as ProteinWeekV2?;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    final gates = _gates;
    if (_error != null || gates == null) {
      return _ErrorBox(message: _error ?? 'Not signed in.', onRetry: _load);
    }
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: AppColors.accent,
        backgroundColor: AppColors.surface,
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          children: [
            Text('Progress', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 14),
            _RangeBar(
              index: _rangeIdx,
              onPick: (i) {
                setState(() => _rangeIdx = i);
                _load();
              },
            ),
            const SizedBox(height: 22),
            _StrengthPanel(lifts: _lifts, gated: gates.hasStrength),
            const SizedBox(height: 26),
            _StallPanel(lifts: _lifts, gated: gates.hasStrength),
            const SizedBox(height: 26),
            _EffortPanel(buckets: _effort, gated: gates.hasEffort, answered: gates.rirAnsweredSets),
            const SizedBox(height: 26),
            _MusclePanel(muscles: _muscles, gated: gates.hasMuscle),
            const SizedBox(height: 26),
            _BodyPanel(body: _body, protein: _protein, gated: gates.hasBody, weighIns: gates.weighIns),
            const SizedBox(height: 26),
            _ConsistencyPanel(weeks: _weeks, gated: gates.hasConsistency),
            const SizedBox(height: 26),
            _PhotoPanel(photos: _photos),
            const SizedBox(height: 20),
            const _FooterNote(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ── range selector ─────────────────────────────────────────────────────────

class _RangeBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onPick;
  const _RangeBar({required this.index, required this.onPick});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _ranges.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onPick(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == index ? AppColors.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(_ranges[i].label,
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: i == index ? AppColors.onAccent : AppColors.textMuted)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── shared panel scaffolding ─────────────────────────────────────────────────

class _PanelHead extends StatelessWidget {
  final String question;
  final String blurb;
  const _PanelHead({required this.question, required this.blurb});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(question,
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 19,
                height: 1.1,
                color: AppColors.textPrimary)),
        const SizedBox(height: 4),
        Text(blurb,
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily, fontSize: 12.5, height: 1.35, color: AppColors.textMuted)),
        const SizedBox(height: 14),
      ],
    );
  }
}

class _Gated extends StatelessWidget {
  final IconData icon;
  final String title;
  final String blurb;
  const _Gated({required this.icon, required this.title, required this.blurb});
  @override
  Widget build(BuildContext context) {
    return V2Card(
      color: AppColors.surfaceSunken,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.textFaint),
          const SizedBox(height: 10),
          Text(title,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w500,
                  fontSize: 13.5,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Text(blurb,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 11.5, height: 1.4, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

// ── panel 1: strength tiles ──────────────────────────────────────────────────

class _StrengthPanel extends StatelessWidget {
  final List<LiftStatusV2> lifts;
  final bool gated;
  const _StrengthPanel({required this.lifts, required this.gated});
  @override
  Widget build(BuildContext context) {
    final tiles = lifts.where((l) => l.status != 'insufficient').toList()
      ..sort((a, b) => (b.latestE1rmKg ?? 0).compareTo(a.latestE1rmKg ?? 0));
    final top = tiles.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(
            question: 'Are you getting stronger?',
            blurb: 'One tile per main lift. The number leads, the line is evidence.'),
        if (!gated || top.isEmpty)
          const _Gated(
              icon: Icons.show_chart_rounded,
              title: 'Log three sessions of a lift and its line appears',
              blurb: 'Two points is a guess. Strength needs a few weeks before a chart means anything.')
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [for (final l in top) _StrengthTile(lift: l)],
          ),
      ],
    );
  }
}

class _StrengthTile extends StatelessWidget {
  final LiftStatusV2 lift;
  const _StrengthTile({required this.lift});
  @override
  Widget build(BuildContext context) {
    final width = (MediaQuery.of(context).size.width - 40 - 12) / 2;
    final up = lift.netChangeKg > 0;
    final flat = lift.netChangeKg == 0;
    final deltaColor = up ? AppColors.accent : (flat ? AppColors.textMuted : AppColors.warn);
    final deltaIcon = up
        ? Icons.trending_up_rounded
        : (flat ? Icons.trending_flat_rounded : Icons.trending_down_rounded);
    return Container(
      width: width,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lift.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(_n(lift.latestE1rmKg ?? 0),
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 26,
                      height: 1,
                      color: AppColors.textPrimary)),
              const SizedBox(width: 4),
              const Padding(
                padding: EdgeInsets.only(bottom: 2),
                child: Text('kg',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(deltaIcon, size: 14, color: deltaColor),
              const SizedBox(width: 3),
              Text('${up ? '+' : ''}${_n(lift.netChangeKg)} kg',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 11.5,
                      color: deltaColor)),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 30,
            width: double.infinity,
            child: CustomPaint(painter: _Sparkline(lift.e1rmSeries, deltaColor)),
          ),
        ],
      ),
    );
  }
}

class _Sparkline extends CustomPainter {
  final List<double> values;
  final Color color;
  _Sparkline(this.values, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).abs() < 1e-6 ? 1.0 : hi - lo;
    final dx = size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = dx * i;
      final y = size.height - ((values[i] - lo) / span) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_Sparkline old) => old.values != values || old.color != color;
}

// ── panel 2: stall ───────────────────────────────────────────────────────────

class _StallPanel extends StatelessWidget {
  final List<LiftStatusV2> lifts;
  final bool gated;
  const _StallPanel({required this.lifts, required this.gated});
  @override
  Widget build(BuildContext context) {
    final tracked = lifts.where((l) => l.status != 'insufficient').toList();
    final stalled = tracked.where((l) => l.stalled).toList();
    final fine = tracked.where((l) => !l.stalled).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(
            question: 'Where are you stuck?',
            blurb: 'A lift that stops moving, caught early — before it becomes a month lost.'),
        if (!gated || tracked.isEmpty)
          const _Gated(
              icon: Icons.trending_up_rounded,
              title: 'Three sessions of a lift and I can tell whether it has stopped moving',
              blurb: 'Nothing has stalled yet. Nothing could have.')
        else ...[
          for (final l in stalled) ...[
            _StallCard(lift: l),
            const SizedBox(height: 10),
          ],
          if (stalled.isEmpty)
            const _Gated(
                icon: Icons.check_circle_outline_rounded,
                title: 'Nothing is stuck',
                blurb: 'Every tracked lift is still moving. Keep going.'),
          if (fine.isNotEmpty) ...[
            const SizedBox(height: 2),
            _FineRow(lifts: fine),
          ],
        ],
      ],
    );
  }
}

class _StallCard extends StatelessWidget {
  final LiftStatusV2 lift;
  const _StallCard({required this.lift});
  @override
  Widget build(BuildContext context) {
    final detail = '${lift.streakSessions} sessions at ${_n(lift.latestTopKg ?? 0)} kg, '
        'top of the range ${lift.streakTopHits}×.';
    return V2Card(
      borderColor: AppColors.warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.trending_flat_rounded, size: 16, color: AppColors.warn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(lift.name,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: AppColors.textPrimary)),
              ),
              StatusChip(icon: Icons.warning_amber_rounded, label: 'Stalled', color: AppColors.warn),
            ],
          ),
          const SizedBox(height: 8),
          Text(detail,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 12.5, height: 1.4, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.surfaceSunken,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline_rounded, size: 15, color: AppColors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Ask the trainer about ${lift.name.toLowerCase()}',
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w500,
                              fontSize: 12.5,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 1),
                      const Text('Sends this lift’s recent sessions',
                          style: TextStyle(
                              fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textMuted)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textFaint),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FineRow extends StatelessWidget {
  final List<LiftStatusV2> lifts;
  const _FineRow({required this.lifts});
  @override
  Widget build(BuildContext context) {
    final names = lifts.map((l) => l.name).join(', ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.trending_up_rounded, size: 15, color: AppColors.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text('${lifts.length} still moving — $names',
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 12, height: 1.4, color: AppColors.textMuted)),
        ),
      ],
    );
  }
}

// ── panel 3: effort histogram ────────────────────────────────────────────────

class _EffortPanel extends StatelessWidget {
  final List<(int, int)> buckets;
  final bool gated;
  final int answered;
  const _EffortPanel({required this.buckets, required this.gated, required this.answered});
  @override
  Widget build(BuildContext context) {
    final counts = List<int>.filled(7, 0);
    for (final b in buckets) {
      if (b.$1 >= 0 && b.$1 <= 6) counts[b.$1] = b.$2;
    }
    final total = counts.fold<int>(0, (s, c) => s + c);
    // Effective zone = 1–3 reps in reserve.
    final inZone = counts[1] + counts[2] + counts[3];
    final pct = total == 0 ? 0 : (inZone / total * 100).round();
    final maxC = counts.fold<int>(1, (m, c) => c > m ? c : m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(
            question: 'Are you training hard enough?',
            blurb: 'Where your sets end, relative to failure. The band is the target.'),
        if (!gated)
          _Gated(
              icon: Icons.equalizer_rounded,
              title: 'Eight logged sets with an effort answer and this fills in',
              blurb: 'You have answered $answered so far. A couple answers is an anecdote.')
        else
          V2Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('$pct%',
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 30,
                            height: 1,
                            color: AppColors.accent)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('of sets end in the effective zone',
                          style: TextStyle(
                              fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 112,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < 7; i++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: _EffortBar(
                              count: counts[i],
                              fraction: counts[i] / maxC,
                              inZone: i >= 1 && i <= 3,
                              label: i == 6 ? '6+' : '$i',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Reps left in the tank when you racked it. Green is the target band.',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textFaint)),
              ],
            ),
          ),
      ],
    );
  }
}

class _EffortBar extends StatelessWidget {
  final int count;
  final double fraction;
  final bool inZone;
  final String label;
  const _EffortBar(
      {required this.count, required this.fraction, required this.inZone, required this.label});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(count == 0 ? '' : '$count',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.textMuted)),
        const SizedBox(height: 3),
        Container(
          height: (fraction * 66).clamp(count == 0 ? 0 : 4, 66),
          decoration: BoxDecoration(
            color: inZone ? AppColors.accent : AppColors.inactiveFill,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 5),
        Text(label,
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontSize: 10,
                fontWeight: inZone ? FontWeight.w700 : FontWeight.w400,
                color: inZone ? AppColors.accentDeep : AppColors.textFaint)),
      ],
    );
  }
}

// ── panel 4: muscle sets ─────────────────────────────────────────────────────

class _MusclePanel extends StatelessWidget {
  final List<MuscleChipV2> muscles;
  final bool gated;
  const _MusclePanel({required this.muscles, required this.gated});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(
            question: 'Is anything neglected?',
            blurb: 'Weekly sets per muscle, against the 10–20 set band that drives growth.'),
        if (!gated || muscles.isEmpty)
          const _Gated(
              icon: Icons.grid_view_rounded,
              title: 'One full week of training and this appears',
              blurb: 'Sets per muscle only means something across a whole week.')
        else
          V2Card(
            child: Column(
              children: [
                for (var i = 0; i < muscles.length; i++) ...[
                  _MuscleRow(muscle: muscles[i]),
                  if (i < muscles.length - 1) const SizedBox(height: 12),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _MuscleRow extends StatelessWidget {
  final MuscleChipV2 muscle;
  const _MuscleRow({required this.muscle});
  @override
  Widget build(BuildContext context) {
    const scaleMax = 24.0; // a bit past the 20 top-of-band
    final low = muscle.sets < 10;
    final frac = (muscle.sets / scaleMax).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(muscle.group,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 13, color: AppColors.textSecondary)),
            ),
            Text('${muscle.sets}',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.textPrimary)),
            if (low) ...[
              const SizedBox(width: 6),
              const Text('low',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 10,
                      color: AppColors.warn)),
            ],
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          return Stack(
            children: [
              // 10–20 band shading
              Positioned(
                left: w * (10 / scaleMax),
                width: w * (10 / scaleMax),
                top: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  height: 8,
                  color: AppColors.surfaceSunken,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: frac,
                    child: Container(color: low ? AppColors.warn : AppColors.accent),
                  ),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }
}

// ── panel 5: body & fuel ─────────────────────────────────────────────────────

class _BodyPanel extends StatelessWidget {
  final BodyTrendV2? body;
  final ProteinWeekV2? protein;
  final bool gated;
  final int weighIns;
  const _BodyPanel(
      {required this.body, required this.protein, required this.gated, required this.weighIns});
  @override
  Widget build(BuildContext context) {
    final b = body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(
            question: 'Is your body changing?',
            blurb: 'Daily weight is noise. The seven-day average is the signal.'),
        if (!gated || b == null || b.sevenDayAvg == null)
          _Gated(
              icon: Icons.monitor_weight_outlined,
              title: 'Seven weigh-ins and the average starts to mean something',
              blurb: '$weighIns so far. Day to day it is mostly water, not fat.')
        else
          V2Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('${_n(b.sevenDayAvg!)} kg',
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 28,
                            height: 1,
                            color: AppColors.textPrimary)),
                    const Spacer(),
                    if (b.kgPerWeek != null)
                      Text('${b.kgPerWeek! <= 0 ? '' : '+'}${b.kgPerWeek!.toStringAsFixed(2)} kg/week',
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                              color: AppColors.accent)),
                  ],
                ),
                const SizedBox(height: 2),
                Text('7-day average${b.targetKg != null ? '  ·  target ${_n(b.targetKg!)} kg' : ''}',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
                const SizedBox(height: 16),
                SizedBox(
                  height: 60,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _WeightChart(
                      b.points.map((p) => p.$2).toList(),
                      b.targetKg,
                    ),
                  ),
                ),
                if (protein != null && protein!.loggedDays > 0) ...[
                  const SizedBox(height: 16),
                  const Divider(height: 1, color: AppColors.borderFaint),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(Icons.egg_alt_outlined, size: 16, color: AppColors.textMuted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Protein hit on ${protein!.hitDays} of ${protein!.loggedDays} days',
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w500,
                                fontSize: 13,
                                color: AppColors.textPrimary)),
                      ),
                      Text(
                          '${protein!.targetG ?? '—'} g target · ${_n(protein!.averageG)} g avg',
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textMuted)),
                    ],
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _WeightChart extends CustomPainter {
  final List<double> values;
  final double? target;
  _WeightChart(this.values, this.target);
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var lo = values.reduce((a, b) => a < b ? a : b);
    var hi = values.reduce((a, b) => a > b ? a : b);
    if (target != null) {
      lo = lo < target! ? lo : target!;
      hi = hi > target! ? hi : target!;
    }
    final span = (hi - lo).abs() < 1e-6 ? 1.0 : hi - lo;
    double y(double v) => size.height - ((v - lo) / span) * size.height;
    final dx = size.width / (values.length - 1);

    if (target != null) {
      final ty = y(target!);
      final dash = Paint()
        ..color = AppColors.textFaint
        ..strokeWidth = 1;
      for (var x = 0.0; x < size.width; x += 8) {
        canvas.drawLine(Offset(x, ty), Offset(x + 4, ty), dash);
      }
    }

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final px = dx * i;
      final py = y(values[i]);
      i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = AppColors.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_WeightChart old) => old.values != values || old.target != target;
}

// ── panel 6: consistency ─────────────────────────────────────────────────────

class _ConsistencyPanel extends StatelessWidget {
  final List<ConsistencyWeekV2> weeks;
  final bool gated;
  const _ConsistencyPanel({required this.weeks, required this.gated});
  @override
  Widget build(BuildContext context) {
    final counted = weeks.where((w) => !w.fullyPaused).toList();
    final rate = counted.isEmpty
        ? 0.0
        : counted.fold<int>(0, (s, w) => s + w.sessionCount) / counted.length;
    final target = weeks.isEmpty ? 4 : weeks.last.target;
    final maxC = weeks.fold<int>(target, (m, w) => w.sessionCount > m ? w.sessionCount : m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(
            question: 'Are you showing up?',
            blurb: 'A rate against your target, not a streak that one missed week kills.'),
        if (!gated || weeks.isEmpty)
          const _Gated(
              icon: Icons.event_available_outlined,
              title: 'Three weeks before a rate is worth plotting',
              blurb: 'Until then the number is the whole story.')
        else
          V2Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(rate.toStringAsFixed(1),
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 30,
                            height: 1,
                            color: AppColors.textPrimary)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('sessions a week against a target of $target',
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 78,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final w in weeks)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: _WeekBar(
                              week: w,
                              fraction: w.sessionCount / maxC,
                              targetFraction: target / maxC,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _WeekBar extends StatelessWidget {
  final ConsistencyWeekV2 week;
  final double fraction;
  final double targetFraction;
  const _WeekBar(
      {required this.week, required this.fraction, required this.targetFraction});
  @override
  Widget build(BuildContext context) {
    final hitTarget = week.sessionCount >= week.target;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          height: (fraction * 52).clamp(week.sessionCount == 0 ? 2 : 5, 52),
          decoration: BoxDecoration(
            color: week.fullyPaused
                ? AppColors.borderFaint
                : (hitTarget ? AppColors.accent : AppColors.accentDeep),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(height: 5),
        Text('${week.weekStart.day}',
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily, fontSize: 9, color: AppColors.textFaint)),
      ],
    );
  }
}

// ── panel 7: photos ──────────────────────────────────────────────────────────

class _PhotoPanel extends StatelessWidget {
  final PhotoPairV2? photos;
  const _PhotoPanel({required this.photos});
  @override
  Widget build(BuildContext context) {
    final p = photos;
    final hasPair = p != null && p.first != null && p.latest != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(
            question: 'Can you see it?',
            blurb: 'Two photos, weeks apart. The mirror lies day to day; side by side does not.'),
        if (!hasPair)
          const _Gated(
              icon: Icons.add_a_photo_outlined,
              title: 'Add a photo to start the comparison',
              blurb: 'One now, one in a month. That gap is where change shows.')
        else
          Row(
            children: [
              Expanded(child: _PhotoSlot(photo: p.first!, caption: 'First')),
              const SizedBox(width: 12),
              Expanded(child: _PhotoSlot(photo: p.latest!, caption: 'Latest')),
            ],
          ),
      ],
    );
  }
}

class _PhotoSlot extends StatelessWidget {
  final PhotoV2 photo;
  final String caption;
  const _PhotoSlot({required this.photo, required this.caption});
  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceSunken,
            border: Border.all(color: AppColors.border),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<String?>(
                future: SupabaseService.instance.signedPhotoUrl(photo.storagePath),
                builder: (context, snap) {
                  final url = snap.data;
                  if (url == null) {
                    return const Center(
                        child: Icon(Icons.image_outlined, size: 26, color: AppColors.textFaint));
                  }
                  return Image.network(url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Center(
                          child: Icon(Icons.broken_image_outlined, size: 26, color: AppColors.textFaint)));
                },
              ),
              // Bottom gradient + label for legibility over the photo.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(caption,
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: Colors.white)),
                      Text(
                          '${_fmtDayMonth(photo.takenOn)}'
                          '${photo.weightKg != null ? ' · ${_n(photo.weightKg!)} kg' : ''}',
                          style: TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 10.5,
                              color: Colors.white.withValues(alpha: 0.8))),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── footer + misc ────────────────────────────────────────────────────────────

class _FooterNote extends StatelessWidget {
  const _FooterNote();
  @override
  Widget build(BuildContext context) {
    return Text(
        'Total volume and streaks are deliberately absent. Volume rewards junk sets, '
        'and a streak one illness kills tells you nothing about strength.',
        style: const TextStyle(
            fontFamily: AppTheme.fontFamily, fontSize: 11, height: 1.5, color: AppColors.textFaint));
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBox({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load Progress', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ── formatting ───────────────────────────────────────────────────────────────

String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _fmtDayMonth(DateTime d) => '${d.day} ${_months[d.month - 1]}';
