import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../services/failure.dart';
import '../../widgets/failure_view.dart';
import '../../theme/app_colors.dart';
import '../../widgets/pressable.dart';
import '../../theme/app_theme.dart';
import '../../widgets/v2_widgets.dart';

/// Progress tab. Seven panels, each answering a question out loud: the number
/// leads, the chart is evidence, and nothing draws until there's enough data to
/// judge it against — every panel has an explicit gated empty state.
class ProgressTab extends StatefulWidget {
  /// Pushes a pre-filled question into the Trainer tab and switches to it —
  /// wired by NavShell, which owns tab switching and the Trainer composer.
  final void Function(String question) onAskTrainer;
  const ProgressTab({super.key, required this.onAskTrainer});
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
  ProgressGatesV2? _gates;
  List<LiftStatusV2> _lifts = const [];
  List<MuscleChipV2> _muscles = const [];
  ProteinWeekV2? _protein;
  Set<String> _monthDays = const {};

  bool _loading = true;
  Failure? _error;

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
      // Strength/stall fetch all-time; each tile slices to its own window
      // client-side. "Weekly sets per muscle" is always the trailing 7 days.
      final muscleSince = DateTime.now().subtract(const Duration(days: 7));
      final now = DateTime.now();
      final monthStart = DateTime(now.year, now.month, 1);
      final monthEnd = DateTime(now.year, now.month + 1, 0);
      final r = await Future.wait([
        svc.fetchProgressGates(),
        svc.fetchLiftStatus(since: null),
        svc.fetchMuscleSets(since: muscleSince),
        svc.fetchProteinWeek(),
        svc.fetchTrainingDayKeys(monthStart, monthEnd),
      ]);
      if (!mounted) return;
      setState(() {
        _gates = r[0] as ProgressGatesV2?;
        _lifts = r[1] as List<LiftStatusV2>;
        _muscles = r[2] as List<MuscleChipV2>;
        _protein = r[3] as ProteinWeekV2?;
        _monthDays = r[4] as Set<String>;
        _loading = false;
      });
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _error = classifyFailure('progress.load', e, st);
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
      return FailureView(
        failure: _error ?? const Failure(FailureKind.session, 'no gates'),
        onRetry: _load,
      );
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
            const SizedBox(height: 20),
            _StrengthPanel(lifts: _lifts, gated: gates.hasStrength),
            const SizedBox(height: 26),
            _StallPanel(lifts: _lifts, gated: gates.hasStrength, onAsk: widget.onAskTrainer),
            const SizedBox(height: 26),
            _EffortPanel(gated: gates.hasEffort, answered: gates.rirAnsweredSets),
            const SizedBox(height: 26),
            _MusclePanel(muscles: _muscles, gated: gates.hasMuscle),
            const SizedBox(height: 26),
            _BodyPanel(protein: _protein, gated: gates.hasBody, weighIns: gates.weighIns),
            const SizedBox(height: 26),
            _ConsistencyPanel(trainedDays: _monthDays, gated: gates.hasConsistency),
            const SizedBox(height: 26),
            const _PhotoPanel(),
            const SizedBox(height: 20),
            const _FooterNote(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ── shared panel scaffolding ─────────────────────────────────────────────────

/// Panel heading — the question, plus an optional "i" that reveals a short
/// explanation of the chart (replacing the always-on blurbs), and an optional
/// trailing control (e.g. a per-chart period cycle).
class _PanelHead extends StatelessWidget {
  final String question;
  final Widget? trailing;
  const _PanelHead({required this.question, this.trailing});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(question,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    height: 1.1,
                    color: AppColors.textPrimary)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A small "i" that opens a short explanation of a chart — how to read it —
/// so the panels can drop their always-on descriptive text.
class _InfoDot extends StatelessWidget {
  final String title;
  final String body;
  const _InfoDot({required this.title, required this.body});
  @override
  Widget build(BuildContext context) {
    return Pressable(
      behavior: HitTestBehavior.opaque,
      onTap: () => showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) => Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceRaised,
            border: Border(top: BorderSide(color: AppColors.border)),
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
          padding: EdgeInsets.fromLTRB(22, 10, 22, 24 + MediaQuery.of(context).padding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                      color: AppColors.borderStrong, borderRadius: BorderRadius.circular(3)),
                ),
              ),
              Text(title,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              Text(body,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 13,
                      height: 1.5,
                      color: AppColors.textSecondary)),
            ],
          ),
        ),
      ),
      child: Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: const Text('i',
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                height: 1,
                color: AppColors.textMuted)),
      ),
    );
  }
}

/// Compact per-chart period control — tap to cycle 4W → 8W → 12W → All.
class _RangeCycle extends StatelessWidget {
  final int index;
  final ValueChanged<int> onChanged;
  final bool small;
  const _RangeCycle({required this.index, required this.onChanged, this.small = false});
  @override
  Widget build(BuildContext context) {
    return Pressable(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged((index + 1) % _ranges.length),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: small ? 7 : 9, vertical: small ? 3 : 5),
        decoration: BoxDecoration(
          color: AppColors.surfaceSunken,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(_ranges[index].label,
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: small ? 9.5 : 11,
                height: 1,
                color: AppColors.accent)),
      ),
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
        const _PanelHead(question: 'Are you getting stronger?'),
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

class _StrengthTile extends StatefulWidget {
  final LiftStatusV2 lift;
  const _StrengthTile({required this.lift});
  @override
  State<_StrengthTile> createState() => _StrengthTileState();
}

class _StrengthTileState extends State<_StrengthTile> {
  int _rangeIdx = 0; // 4W default

  @override
  Widget build(BuildContext context) {
    final lift = widget.lift;
    final width = (MediaQuery.of(context).size.width - 40 - 12) / 2;

    // Slice the dated series to the tile's own window. Fall back to the whole
    // series (older payloads without dates) so nothing breaks.
    final since = _ranges[_rangeIdx].since;
    final hasDates = lift.e1rmPoints.isNotEmpty;
    final windowed = hasDates
        ? (since == null
            ? lift.e1rmPoints
            : lift.e1rmPoints.where((p) => !p.$1.isBefore(since)).toList())
        : const <(DateTime, double)>[];
    final vals = hasDates ? windowed.map((p) => p.$2).toList() : lift.e1rmSeries;

    final net = hasDates
        ? (vals.length >= 2 ? vals.last - vals.first : 0.0)
        : lift.netChangeKg;
    final headline = vals.isNotEmpty ? vals.last : (lift.latestE1rmKg ?? 0);
    final enough = vals.length >= 2;

    final up = net > 0.001;
    final down = net < -0.001;
    final deltaColor = up ? AppColors.accent : (down ? AppColors.warn : AppColors.textMuted);
    final deltaIcon = up
        ? Icons.trending_up_rounded
        : (down ? Icons.trending_down_rounded : Icons.trending_flat_rounded);

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
          Row(
            children: [
              Expanded(
                child: Text(lift.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
              ),
              const SizedBox(width: 6),
              _RangeCycle(
                index: _rangeIdx,
                small: true,
                onChanged: (i) => setState(() => _rangeIdx = i),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(_n(headline),
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
          if (enough)
            Row(
              children: [
                Icon(deltaIcon, size: 14, color: deltaColor),
                const SizedBox(width: 3),
                Text('${up ? '+' : ''}${_n(net)} kg',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                        color: deltaColor)),
              ],
            )
          else
            const Text('not enough in window',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textFaint)),
          const SizedBox(height: 10),
          SizedBox(
            height: 30,
            width: double.infinity,
            child: CustomPaint(painter: _Sparkline(vals, enough ? deltaColor : AppColors.textFaint)),
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
  final void Function(String question) onAsk;
  const _StallPanel({required this.lifts, required this.gated, required this.onAsk});

  /// A varied, situation-specific read of *why* a lift is flagged — not one
  /// fixed sentence. Branches on how it stalled.
  static String stallLine(LiftStatusV2 l) {
    final kg = _n(l.latestTopKg ?? 0);
    final n = l.streakSessions;
    if (l.streakTopHits >= 2) {
      return 'Cleared the top of the rep range ${l.streakTopHits}× at $kg kg — it is asking for more load.';
    }
    if (l.netChangeKg < -0.001) {
      return 'Slipping — down ${_n(l.netChangeKg.abs())} kg across the last $n sessions at $kg kg.';
    }
    if (n >= 5) {
      return 'Flat for $n straight sessions at $kg kg.';
    }
    if (n >= 3) {
      return 'Held at $kg kg for $n sessions with no jump.';
    }
    return 'Not moving at $kg kg.';
  }

  @override
  Widget build(BuildContext context) {
    final tracked = lifts.where((l) => l.status != 'insufficient').toList();
    final stalled = tracked.where((l) => l.stalled).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(question: 'Where are you stuck?'),
        if (!gated || tracked.isEmpty)
          const _Gated(
              icon: Icons.trending_up_rounded,
              title: 'Three sessions of a lift and I can tell whether it has stopped moving',
              blurb: 'Nothing has stalled yet. Nothing could have.')
        else if (stalled.isEmpty)
          const _Gated(
              icon: Icons.check_circle_outline_rounded,
              title: 'Nothing is stuck',
              blurb: 'Every tracked lift is still moving. Keep going.')
        else
          _StallList(lifts: stalled, onAsk: onAsk),
      ],
    );
  }
}

/// All stalled lifts in one card — a row per lift, each with a dynamic read and
/// a compact "Consult trainer" action (which hands over the lift's context).
class _StallList extends StatelessWidget {
  final List<LiftStatusV2> lifts;
  final void Function(String question) onAsk;
  const _StallList({required this.lifts, required this.onAsk});
  @override
  Widget build(BuildContext context) {
    return V2Card(
      borderColor: AppColors.warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lifts.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: 12),
              const Divider(height: 1, color: AppColors.borderFaint),
              const SizedBox(height: 12),
            ],
            _StallRow(lift: lifts[i], onAsk: onAsk),
          ],
        ],
      ),
    );
  }
}

class _StallRow extends StatelessWidget {
  final LiftStatusV2 lift;
  final void Function(String question) onAsk;
  const _StallRow({required this.lift, required this.onAsk});
  @override
  Widget build(BuildContext context) {
    return Column(
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
            // Compact "Consult trainer" — chat icon + label, hands over context.
            Pressable(
              behavior: HitTestBehavior.opaque,
              onTap: () => onAsk(
                'My ${lift.name.toLowerCase()} has been stuck at ${_n(lift.latestTopKg ?? 0)} kg '
                'for ${lift.streakSessions} sessions — what should I do?',
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSunken,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.chat_bubble_outline_rounded, size: 14, color: AppColors.accent),
                    SizedBox(width: 6),
                    Text('Consult trainer',
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                            color: AppColors.accent)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Text(_StallPanel.stallLine(lift),
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 12.5,
                  height: 1.4,
                  color: AppColors.textSecondary)),
        ),
      ],
    );
  }
}

// ── panel 3: effort histogram ────────────────────────────────────────────────

class _EffortPanel extends StatefulWidget {
  final bool gated;
  final int answered;
  const _EffortPanel({required this.gated, required this.answered});
  @override
  State<_EffortPanel> createState() => _EffortPanelState();
}

class _EffortPanelState extends State<_EffortPanel> {
  int _rangeIdx = 0; // 4W default
  List<(int, int)> _buckets = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    final b = await SupabaseService.instance.fetchEffortHistogram(since: _ranges[_rangeIdx].since);
    if (mounted) setState(() { _buckets = b; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final counts = List<int>.filled(7, 0);
    for (final b in _buckets) {
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
        _PanelHead(
            question: 'Are you training hard enough?',
            trailing: widget.gated
                ? _RangeCycle(index: _rangeIdx, onChanged: (i) { setState(() => _rangeIdx = i); _fetch(); })
                : null),
        if (!widget.gated)
          _Gated(
              icon: Icons.equalizer_rounded,
              title: 'Eight logged sets with an effort answer and this fills in',
              blurb: 'You have answered ${widget.answered} so far. A couple answers is an anecdote.')
        else if (total == 0 && !_loading)
          const _Gated(
              icon: Icons.equalizer_rounded,
              title: 'No effort answers in this window',
              blurb: 'Widen the period, or log a few sets with an effort answer.')
        else
          V2Card(
            child: Stack(
              children: [
                Column(
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
                      child: Padding(
                        padding: EdgeInsets.only(right: 24),
                        child: Text('of sets end in the effective zone',
                            style: TextStyle(
                                fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
                      ),
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
              ],
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: _InfoDot(
                      title: 'Are you training hard enough?',
                      body: 'Each bar counts your working sets by how many reps you had left in '
                          'the tank (RIR) when you stopped. The green 1–3 band is the effective '
                          'zone — hard enough to grow, not so hard it wrecks recovery. The % is '
                          'the share of sets that landed in it, over the chosen period.'),
                ),
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

const double _muscleScaleMax = 24.0; // a bit past the 20 top-of-band

/// (label, color) for a weekly set count against the 10–20 growth band.
(String, Color) _muscleStatus(int sets) {
  if (sets < 10) return ('LOW', AppColors.warn);
  if (sets <= 20) return ('ON TRACK', AppColors.accent);
  return ('HIGH', AppColors.textMuted);
}

class _MusclePanel extends StatelessWidget {
  final List<MuscleChipV2> muscles;
  final bool gated;
  const _MusclePanel({required this.muscles, required this.gated});
  @override
  Widget build(BuildContext context) {
    // Most-neglected first — the whole point of the panel is spotting the gap.
    final sorted = [...muscles]..sort((a, b) => a.sets.compareTo(b.sets));
    final lowCount = sorted.where((m) => m.sets < 10).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(question: 'Is anything neglected?'),
        if (!gated || sorted.isEmpty)
          const _Gated(
              icon: Icons.grid_view_rounded,
              title: 'One full week of training and this appears',
              blurb: 'Sets per muscle only means something across a whole week.')
        else
          V2Card(
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (lowCount > 0) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 24),
                        child: Text(
                            lowCount == 1
                                ? '1 muscle under the band this week'
                                : '$lowCount muscles under the band this week',
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                color: AppColors.warn)),
                      ),
                      const SizedBox(height: 14),
                    ],
                    for (var i = 0; i < sorted.length; i++) ...[
                      _MuscleRow(muscle: sorted[i]),
                      if (i < sorted.length - 1) const SizedBox(height: 14),
                    ],
                    const SizedBox(height: 12),
                    const _MuscleAxis(),
                  ],
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: _InfoDot(
                      title: 'Is anything neglected?',
                      body: 'Hard working sets per muscle group over the last 7 days. The shaded '
                          '10–20 band is the weekly volume that reliably drives growth for most '
                          'lifters — below it a muscle is under-stimulated, well above it is '
                          'usually junk volume. Sorted with the most neglected on top.'),
                ),
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
    final (statusLabel, statusColor) = _muscleStatus(muscle.sets);
    final frac = (muscle.sets / _muscleScaleMax).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(muscle.group,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      color: AppColors.textPrimary)),
            ),
            Text('${muscle.sets}',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.textPrimary)),
            const Text(' sets',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textMuted)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(statusLabel,
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 8.5,
                      letterSpacing: 0.3,
                      color: statusColor)),
            ),
          ],
        ),
        const SizedBox(height: 7),
        LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          return SizedBox(
            height: 10,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // track
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Container(height: 10, color: AppColors.surfaceSunken),
                ),
                // 10–20 growth band
                Positioned(
                  left: w * (10 / _muscleScaleMax),
                  width: w * (10 / _muscleScaleMax),
                  top: 0,
                  bottom: 0,
                  child: Container(color: AppColors.accent.withValues(alpha: 0.12)),
                ),
                // band edge ticks at 10 and 20
                for (final t in const [10.0, 20.0])
                  Positioned(
                    left: w * (t / _muscleScaleMax) - 0.5,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 1, color: AppColors.border),
                  ),
                // fill
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: frac,
                    child: Container(height: 10, color: statusColor),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

/// A one-time scale under the muscle rows: 0 · the 10–20 band · 24+.
class _MuscleAxis extends StatelessWidget {
  const _MuscleAxis();
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      Widget tick(double v, String label) => Positioned(
            left: (w * (v / _muscleScaleMax) - 10).clamp(0.0, w - 20),
            child: SizedBox(
              width: 20,
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 8.5, color: AppColors.textFaint)),
            ),
          );
      return SizedBox(
        height: 12,
        child: Stack(
          children: [tick(0, '0'), tick(10, '10'), tick(20, '20'), tick(24, '24+')],
        ),
      );
    });
  }
}

// ── panel 5: body & fuel ─────────────────────────────────────────────────────

class _BodyPanel extends StatefulWidget {
  final ProteinWeekV2? protein;
  final bool gated;
  final int weighIns;
  const _BodyPanel({required this.protein, required this.gated, required this.weighIns});
  @override
  State<_BodyPanel> createState() => _BodyPanelState();
}

class _BodyPanelState extends State<_BodyPanel> {
  int _rangeIdx = 0; // 4W default
  BodyTrendV2? _body;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final b = await SupabaseService.instance.fetchBodyTrend(since: _ranges[_rangeIdx].since);
    if (mounted) setState(() => _body = b);
  }

  String _spanLabel(BodyTrendV2 b) {
    final label = _ranges[_rangeIdx].label;
    final windowName = label == 'All' ? 'all time' : 'last $label'.replaceAll('W', ' weeks');
    if (b.points.length >= 2) {
      final from = b.points.first.$1;
      final to = b.points.last.$1;
      return 'Trend over $windowName · ${_fmtDayMonth(from)} – ${_fmtDayMonth(to)}';
    }
    return 'Trend over $windowName';
  }

  @override
  Widget build(BuildContext context) {
    final protein = widget.protein;
    final b = _body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PanelHead(
            question: 'Is your body changing?',
            trailing: widget.gated
                ? _RangeCycle(index: _rangeIdx, onChanged: (i) { setState(() => _rangeIdx = i); _fetch(); })
                : null),
        if (!widget.gated || b == null || b.sevenDayAvg == null)
          _Gated(
              icon: Icons.monitor_weight_outlined,
              title: 'Seven weigh-ins and the average starts to mean something',
              blurb: '${widget.weighIns} so far. Day to day it is mostly water, not fat.')
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
                const SizedBox(height: 8),
                Text(_spanLabel(b),
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textFaint)),
                if (protein != null && protein.loggedDays > 0) ...[
                  const SizedBox(height: 16),
                  const Divider(height: 1, color: AppColors.borderFaint),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(Icons.egg_alt_outlined, size: 16, color: AppColors.textMuted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Protein hit on ${protein.hitDays} of ${protein.loggedDays} days',
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w500,
                                fontSize: 13,
                                color: AppColors.textPrimary)),
                      ),
                      Text(
                          '${protein.targetG ?? '—'} g target · ${_n(protein.averageG)} g avg',
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
  /// 'yyyy-MM-dd' keys the user trained on, this month.
  final Set<String> trainedDays;
  final bool gated;
  const _ConsistencyPanel({required this.trainedDays, required this.gated});

  static String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final trainedThisMonth = trainedDays
        .where((k) => k.startsWith('${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}'))
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHead(question: 'Are you showing up?'),
        if (!gated)
          const _Gated(
              icon: Icons.event_available_outlined,
              title: 'Train a few times and your month fills in',
              blurb: 'The calendar needs some sessions before it says anything.')
        else
          V2Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('$trainedThisMonth',
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 30,
                            height: 1,
                            color: AppColors.textPrimary)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${trainedThisMonth == 1 ? 'session' : 'sessions'} in ${_months[now.month - 1]}',
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _MonthGrid(trainedDays: trainedDays, now: now, keyOf: _key),
              ],
            ),
          ),
      ],
    );
  }
}

/// The current month as day chips — filled = trained, ring = today, grey = not
/// trained, faint = future. Same visual language as the Train-tab calendar.
class _MonthGrid extends StatelessWidget {
  final Set<String> trainedDays;
  final DateTime now;
  final String Function(DateTime) keyOf;
  const _MonthGrid({required this.trainedDays, required this.now, required this.keyOf});

  @override
  Widget build(BuildContext context) {
    final today = DateTime(now.year, now.month, now.day);
    final first = DateTime(now.year, now.month, 1);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final lead = first.weekday - 1; // Mon=0 leading blanks
    final cells = <Widget>[];
    for (var i = 0; i < lead; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var d = 1; d <= daysInMonth; d++) {
      final date = DateTime(now.year, now.month, d);
      final trained = trainedDays.contains(keyOf(date));
      final isToday = date == today;
      final isFuture = date.isAfter(today);
      cells.add(_MonthCell(day: d, trained: trained, isToday: isToday, isFuture: isFuture));
    }
    // pad to a full final row
    while (cells.length % 7 != 0) {
      cells.add(const SizedBox.shrink());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (final l in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
              Expanded(
                child: Center(
                  child: Text(l,
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily, fontSize: 9, color: AppColors.textFaint)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        for (var r = 0; r < cells.length; r += 7)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.5),
                      child: cells[r + c],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MonthCell extends StatelessWidget {
  final int day;
  final bool trained;
  final bool isToday;
  final bool isFuture;
  const _MonthCell(
      {required this.day, required this.trained, required this.isToday, required this.isFuture});
  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (trained) {
      bg = AppColors.accent;
      fg = AppColors.onAccent;
    } else if (isFuture) {
      bg = AppColors.surfaceSunken;
      fg = AppColors.textFaint;
    } else {
      bg = AppColors.surfaceSunken;
      fg = AppColors.textDim;
    }
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: isToday ? Border.all(color: AppColors.accent, width: 1.5) : null,
        ),
        child: Text('$day',
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: trained ? FontWeight.w700 : FontWeight.w500,
                fontSize: 11,
                color: isToday && !trained ? AppColors.accent : fg)),
      ),
    );
  }
}

// ── panel 7: photos ──────────────────────────────────────────────────────────

/// Self-contained: fetches its own photos and refreshes only itself on
/// upload/delete, so the rest of the Progress screen never reloads.
class _PhotoPanel extends StatefulWidget {
  const _PhotoPanel();
  @override
  State<_PhotoPanel> createState() => _PhotoPanelState();
}

class _PhotoPanelState extends State<_PhotoPanel> {
  List<PhotoV2> _photos = const [];
  bool _loaded = false;
  bool _busy = false;
  int _page = 0;
  final _pc = PageController();
  // Signed URLs are cached by path so swiping doesn't re-request them.
  final _urls = <String, Future<String?>>{};

  @override
  void initState() {
    super.initState();
    _fetch(toNewest: true);
  }

  /// Reload just this widget's photos. [toNewest] jumps to the last slide
  /// (after an upload); otherwise the current page is clamped into range.
  Future<void> _fetch({bool toNewest = false}) async {
    final list = await SupabaseService.instance.fetchAllProgressPhotos();
    if (!mounted) return;
    setState(() {
      _photos = list;
      _loaded = true;
      _page = list.isEmpty
          ? 0
          : (toNewest ? list.length - 1 : _page.clamp(0, list.length - 1));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pc.hasClients) _pc.jumpToPage(_page);
    });
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<String?> _signed(String path) =>
      _urls.putIfAbsent(path, () => SupabaseService.instance.signedPhotoUrl(path));

  Future<void> _addPhoto() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.') ? picked.name.split('.').last.toLowerCase() : 'jpg';
      await SupabaseService.instance
          .uploadProgressPhoto(bytes: bytes, ext: ext == 'png' ? 'png' : 'jpg');
      if (!mounted) return;
      setState(() => _busy = false);
      await _fetch(toNewest: true); // refresh only this widget, land on the new one
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not add that photo.')));
    }
  }

  Future<void> _deleteCurrent() async {
    final photos = _photos;
    if (photos.isEmpty) return;
    final idx = _page.clamp(0, photos.length - 1);
    final photo = photos[idx];
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ConfirmSheet(
        title: 'Delete this photo?',
        body: 'Taken ${_fmtDayMonth(photo.takenOn)}. This can’t be undone.',
        confirmLabel: 'Delete',
      ),
    );
    if (ok != true) return;
    try {
      await SupabaseService.instance.deleteProgressPhoto(photo.storagePath);
      _urls.remove(photo.storagePath);
      if (!mounted) return;
      await _fetch(); // refresh only this widget, clamp the page
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not delete that photo.')));
    }
  }

  String _label(int i, int n) =>
      i == 0 ? 'First' : (i == n - 1 ? 'Latest' : 'Photo ${i + 1}');

  @override
  Widget build(BuildContext context) {
    final photos = _photos;
    final n = photos.length;
    final page = _page.clamp(0, n == 0 ? 0 : n - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PanelHead(
            question: 'Can you see it?',
            trailing: n > 0 ? _AddPhotoButton(busy: _busy, onTap: _addPhoto) : null),
        if (!_loaded)
          const AspectRatio(
            aspectRatio: 3 / 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surfaceSunken,
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
              child: Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textFaint))),
            ),
          )
        else if (n == 0)
          Pressable(
            onTap: _addPhoto,
            child: V2Card(
              color: AppColors.surfaceSunken,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_busy ? Icons.hourglass_top_rounded : Icons.add_a_photo_outlined,
                      size: 20, color: AppColors.accent),
                  const SizedBox(height: 10),
                  Text(_busy ? 'Adding…' : 'Add a photo to start the comparison',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 13.5,
                          color: AppColors.textSecondary)),
                  const SizedBox(height: 4),
                  const Text('One now, one in a month. That gap is where change shows.',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily, fontSize: 11.5, height: 1.4, color: AppColors.textMuted)),
                ],
              ),
            ),
          )
        else ...[
          // The main swipable frame — oldest on the left, newest on the right.
          AspectRatio(
            aspectRatio: 3 / 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _pc,
                  itemCount: n,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (_, i) =>
                      _GalleryPhoto(photo: photos[i], label: _label(i, n), url: _signed(photos[i].storagePath)),
                ),
                // delete (current photo)
                Positioned(
                  top: 10,
                  left: 10,
                  child: Pressable(
                    onTap: _deleteCurrent,
                    child: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.delete_outline_rounded, size: 17, color: Colors.white),
                    ),
                  ),
                ),
                // count chip
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('${page + 1} / $n',
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 10.5,
                            color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (n > 1)
            _Filmstrip(
              photos: photos,
              current: page,
              signed: _signed,
              onTap: (i) {
                setState(() => _page = i);
                _pc.animateToPage(i,
                    duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
              },
            )
          else
            const Text('Add another in a few weeks to see the change side by side.',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 11.5, color: AppColors.textMuted)),
        ],
      ],
    );
  }
}

class _AddPhotoButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _AddPhotoButton({required this.busy, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceSunken,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(busy ? Icons.hourglass_top_rounded : Icons.add_a_photo_outlined,
                size: 14, color: AppColors.accent),
            const SizedBox(width: 6),
            const Text('Add',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: AppColors.accent)),
          ],
        ),
      ),
    );
  }
}

/// One full-frame photo in the gallery, with a bottom caption.
class _GalleryPhoto extends StatelessWidget {
  final PhotoV2 photo;
  final String label;
  final Future<String?> url;
  const _GalleryPhoto({required this.photo, required this.label, required this.url});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceSunken,
          border: Border.all(color: AppColors.border),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<String?>(
              future: url,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textFaint)));
                }
                final u = snap.data;
                if (u == null) {
                  return const Center(
                      child: Icon(Icons.image_outlined, size: 26, color: AppColors.textFaint));
                }
                return Image.network(u,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined, size: 26, color: AppColors.textFaint)));
              },
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 26, 14, 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withValues(alpha: 0.72)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: Colors.white)),
                    Text(
                        '${_fmtDayMonth(photo.takenOn)}'
                        '${photo.weightKg != null ? ' · ${_n(photo.weightKg!)} kg' : ''}',
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.85))),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Thumbnail rail under the gallery — oldest → newest, tap to jump.
class _Filmstrip extends StatelessWidget {
  final List<PhotoV2> photos;
  final int current;
  final Future<String?> Function(String) signed;
  final ValueChanged<int> onTap;
  const _Filmstrip(
      {required this.photos, required this.current, required this.signed, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final selected = i == current;
          return Pressable(
            onTap: () => onTap(i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Container(
                width: 44,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.surfaceSunken,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: selected ? AppColors.accent : AppColors.border,
                    width: selected ? 1.5 : 1,
                  ),
                ),
                child: FutureBuilder<String?>(
                  future: signed(photos[i].storagePath),
                  builder: (context, snap) {
                    final u = snap.data;
                    if (u == null) {
                      return const Center(
                          child: Icon(Icons.image_outlined, size: 15, color: AppColors.textFaint));
                    }
                    return Opacity(
                      opacity: selected ? 1 : 0.55,
                      child: Image.network(u,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Center(
                              child: Icon(Icons.broken_image_outlined, size: 15, color: AppColors.textFaint))),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A compact confirm sheet for a destructive action — pops true on confirm.
class _ConfirmSheet extends StatelessWidget {
  final String title;
  final String body;
  final String confirmLabel;
  const _ConfirmSheet({required this.title, required this.body, required this.confirmLabel});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border(top: BorderSide(color: AppColors.border)),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: EdgeInsets.fromLTRB(22, 10, 22, 22 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: AppColors.borderStrong, borderRadius: BorderRadius.circular(3)),
            ),
          ),
          Text(title,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Text(body,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 13, height: 1.5, color: AppColors.textSecondary)),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Pressable(
                  onTap: () => Navigator.of(context).pop(false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.borderStrong),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Text('Keep it',
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: AppColors.textPrimary)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Pressable(
                  onTap: () => Navigator.of(context).pop(true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.warn,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Text(confirmLabel,
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: AppColors.onAccent)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── footer + misc ────────────────────────────────────────────────────────────

class _FooterNote extends StatelessWidget {
  const _FooterNote();
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle_outline_rounded, size: 14, color: AppColors.textFaint),
        const SizedBox(width: 6),
        Text("That's everything worth watching — you're all caught up.",
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily, fontSize: 11.5, color: AppColors.textFaint)),
      ],
    );
  }
}

// ── formatting ───────────────────────────────────────────────────────────────

String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _fmtDayMonth(DateTime d) => '${d.day} ${_months[d.month - 1]}';
