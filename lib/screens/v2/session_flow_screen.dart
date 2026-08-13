import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/v2_models.dart';
import '../../services/session_controller.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/v2_widgets.dart';

/// Phase 1 — the in-session flow. One lift per screen: guide, adjustable set
/// chips, per-lift effort, non-blocking rest, then a finish screen.
class SessionFlowScreen extends StatelessWidget {
  const SessionFlowScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SessionController>();
    return Scaffold(
      backgroundColor: AppColors.page,
      body: switch (c.screen) {
        FlowScreen.lift => _LiftScreen(c: c),
        FlowScreen.review => _ReviewScreen(c: c),
        FlowScreen.done => _DoneScreen(c: c),
      },
    );
  }
}

// ── lift ────────────────────────────────────────────────────────────────────
class _LiftScreen extends StatelessWidget {
  final SessionController c;
  const _LiftScreen({required this.c});

  @override
  Widget build(BuildContext context) {
    final e = c.ex;
    return SafeArea(
      child: Column(
        children: [
          _Header(c: c),
          _Rail(c: c),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              children: [
                _ExerciseHead(e: e, index: c.idx),
                const SizedBox(height: 12),
                _GuideMedia(e: e, cuesOpen: c.cuesOpen, onToggle: c.toggleCues),
                if (c.cuesOpen && e.cues.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  _Cues(cues: e.cues),
                ],
                const SizedBox(height: 16),
                _SetTable(c: c),
                if (c.askFeel) ...[const SizedBox(height: 9), _FeelCard(c: c)],
                if (c.exDone && !c.askFeel) ...[
                  const SizedBox(height: 12),
                  _ExDoneCard(c: c),
                ],
              ],
            ),
          ),
          _BottomBar(c: c),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final SessionController c;
  const _Header({required this.c});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          _CircleBtn(
            icon: Icons.close_rounded,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              children: [
                Text(c.label,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text('${c.elapsedLabel} · ${c.totalSets} sets',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 10,
                        color: AppColors.textFaint)),
              ],
            ),
          ),
          const SizedBox(width: 34),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  final SessionController c;
  const _Rail({required this.c});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        children: [
          for (var i = 0; i < c.exercises.length; i++) ...[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      for (var p = 0; p < c.exercises[i].setsTarget; p++)
                        Expanded(
                          child: Container(
                            height: 3,
                            margin: EdgeInsets.only(right: p == c.exercises[i].setsTarget - 1 ? 0 : 2),
                            decoration: BoxDecoration(
                              color: p < c.setsLogged(i) ? AppColors.accent : AppColors.border,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(c.exercises[i].name.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w500,
                          fontSize: 8.5,
                          letterSpacing: 0.4,
                          color: i == c.idx ? AppColors.accent : AppColors.textFaint)),
                ],
              ),
            ),
            if (i != c.exercises.length - 1) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

class _ExerciseHead extends StatelessWidget {
  final PlanExerciseV2 e;
  final int index;
  const _ExerciseHead({required this.e, required this.index});
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('EXERCISE ${index + 1}',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 10,
                      letterSpacing: 0.8,
                      color: AppColors.accent)),
              const SizedBox(height: 6),
              Text(e.name, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(e.prescription,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 3),
            Text('last time ${e.lastTimeLabel}',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 9.5, color: AppColors.textFaint)),
          ],
        ),
      ],
    );
  }
}

class _GuideMedia extends StatelessWidget {
  final PlanExerciseV2 e;
  final bool cuesOpen;
  final VoidCallback onToggle;
  const _GuideMedia({required this.e, required this.cuesOpen, required this.onToggle});
  @override
  Widget build(BuildContext context) {
    final url = SupabaseService.instance.demoUrl(e.demoPath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 196,
        color: const Color(0xFFF1EDE7),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url != null)
              Image.network(url, fit: BoxFit.contain,
                  errorBuilder: (_, e, s) => const SizedBox())
            else
              const Center(
                  child: Icon(Icons.fitness_center_rounded, color: Color(0xFFB9B0A6), size: 40)),
            Positioned(
              bottom: 10,
              right: 10,
              child: GestureDetector(
                onTap: onToggle,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xD1100E0D),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(cuesOpen ? Icons.expand_less_rounded : Icons.menu_book_rounded,
                        size: 14, color: AppColors.accent),
                    const SizedBox(width: 6),
                    Text(cuesOpen ? 'Hide cues' : 'How to',
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w500,
                            fontSize: 10.5,
                            color: AppColors.textPrimary)),
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cues extends StatelessWidget {
  final List<String> cues;
  const _Cues({required this.cues});
  @override
  Widget build(BuildContext context) {
    return V2Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final cue in cues)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(top: 6, right: 9),
                    decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                  ),
                  Expanded(
                    child: Text(cue,
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 11.5,
                            height: 1.5,
                            color: AppColors.textSecondary)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SetTable extends StatelessWidget {
  final SessionController c;
  const _SetTable({required this.c});
  @override
  Widget build(BuildContext context) {
    final e = c.ex;
    final rows = <Widget>[];
    final total = target0(c);
    for (var n = 0; n < total; n++) {
      final done = n < c.sets.length;
      final isNext = n == c.sets.length && c.entry == EntryModeV2.live;
      rows.add(_SetChip(c: c, n: n, done: done, isNext: isNext, e: e));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: [
              const SizedBox(width: 22),
              if (!e.isBodyweight)
                const Expanded(child: _ColHead('WEIGHT (KG)')),
              const Expanded(child: _ColHead('REPS')),
              const SizedBox(width: 30),
            ],
          ),
        ),
        ...rows.map((w) => Padding(padding: const EdgeInsets.only(bottom: 6), child: w)),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Target ${e.prescription}',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.inactiveFill)),
              GestureDetector(
                onTap: c.addSet,
                child: const Text('+ add a set',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textDim)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static int target0(SessionController c) {
    final done = c.sets.length;
    final t = c.target(c.idx);
    return done > t ? done : t;
  }
}

class _ColHead extends StatelessWidget {
  final String text;
  const _ColHead(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      textAlign: TextAlign.center,
      style: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontWeight: FontWeight.w500,
          fontSize: 9,
          letterSpacing: 0.9,
          color: AppColors.textDim));
}

class _SetChip extends StatelessWidget {
  final SessionController c;
  final int n;
  final bool done;
  final bool isNext;
  final PlanExerciseV2 e;
  const _SetChip(
      {required this.c, required this.n, required this.done, required this.isNext, required this.e});

  @override
  Widget build(BuildContext context) {
    final editable = done || isNext;
    final Color bg = done
        ? const Color(0xFF14170D)
        : isNext
            ? AppColors.surface
            : AppColors.surfaceSunken;
    final Color border = done
        ? const Color(0x33C8F751)
        : isNext
            ? AppColors.borderStrong
            : AppColors.borderFaint;

    double kg;
    int reps;
    if (done) {
      kg = c.sets[n].kg ?? 0;
      reps = c.sets[n].reps;
    } else {
      final s = c.staged();
      kg = s.$1;
      reps = s.$2;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 9, 8),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: done ? AppColors.accent : AppColors.surface,
              shape: BoxShape.circle,
            ),
            child: done
                ? const Icon(Icons.check_rounded, size: 14, color: AppColors.onAccent)
                : Text('${n + 1}',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 10,
                        color: isNext ? AppColors.accent : AppColors.textFaint)),
          ),
          const SizedBox(width: 9),
          if (editable) ...[
            if (!e.isBodyweight) ...[
              Expanded(
                child: _Stepper(
                  value: _n(kg),
                  onDown: () => done ? c.adjustSet(n, dKg: -e.step) : c.adjustStagedWeight(-e.step),
                  onUp: () => done ? c.adjustSet(n, dKg: e.step) : c.adjustStagedWeight(e.step),
                ),
              ),
              Container(width: 1, height: 18, color: border),
            ] else
              const Expanded(
                  child: Padding(
                padding: EdgeInsets.only(left: 2),
                child: Text('Bodyweight',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textFaint)),
              )),
            Expanded(
              child: _Stepper(
                value: '$reps',
                onDown: () => done ? c.adjustSet(n, dReps: -1) : c.adjustStagedReps(-1),
                onUp: () => done ? c.adjustSet(n, dReps: 1) : c.adjustStagedReps(1),
              ),
            ),
          ] else
            Expanded(
              child: Text('Set ${n + 1}',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textDim)),
            ),
          GestureDetector(
            onTap: () => c.removeSet(n),
            child: const SizedBox(
              width: 30,
              height: 30,
              child: Icon(Icons.close_rounded, size: 16, color: AppColors.inactiveFill),
            ),
          ),
        ],
      ),
    );
  }

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

class _Stepper extends StatelessWidget {
  final String value;
  final VoidCallback onDown;
  final VoidCallback onUp;
  const _Stepper({required this.value, required this.onDown, required this.onUp});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _round(Icons.remove_rounded, onDown),
        Expanded(
          child: Text(value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.textPrimary)),
        ),
        _round(Icons.add_rounded, onUp),
      ],
    );
  }

  Widget _round(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: AppColors.surfaceSunken, shape: BoxShape.circle),
          child: Icon(icon, size: 15, color: AppColors.textMuted),
        ),
      );
}

class _FeelCard extends StatelessWidget {
  final SessionController c;
  const _FeelCard({required this.c});
  static const _opts = [
    (EffortV2.easy, Icons.trending_flat_rounded, 'Yes, three or more', 'It felt smooth — the bar moved fast'),
    (EffortV2.right, Icons.check_rounded, 'Maybe one or two', 'Hard, but the form held'),
    (EffortV2.all, Icons.local_fire_department_rounded, 'No, that was everything', 'The last rep was a fight'),
  ];
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: const Color(0x66C8F751)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Could you have done another rep?',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w500,
                  fontSize: 12.5,
                  height: 1.4,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 12),
          for (final o in _opts) ...[
            GestureDetector(
              onTap: () => c.setEffort(o.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSunken,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(o.$2, size: 17, color: o.$1 == EffortV2.all ? AppColors.warn : AppColors.textMuted),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(o.$3,
                              style: const TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 12.5,
                                  color: AppColors.textPrimary)),
                          const SizedBox(height: 2),
                          Text(o.$4,
                              style: const TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontSize: 10.5,
                                  height: 1.35,
                                  color: AppColors.textMuted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 7),
          ],
          const Text('Asked once per lift, and only because the answer changes the next set.',
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily, fontSize: 10, height: 1.5, color: AppColors.textFaint)),
        ],
      ),
    );
  }
}

class _ExDoneCard extends StatelessWidget {
  final SessionController c;
  const _ExDoneCard({required this.c});
  @override
  Widget build(BuildContext context) {
    final e = c.ex;
    final vol = c.sets.fold(0.0, (s, r) => s + (r.kg ?? 0) * r.reps);
    final reps = c.sets.fold(0, (s, r) => s + r.reps);
    final meta = e.isBodyweight
        ? '$reps reps total'
        : '${vol.round()} kg moved · best set ${c.sets.map((r) => r.kg ?? 0).fold(0.0, (a, b) => a > b ? a : b).round()} kg';
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x24C8F751), Color(0x08C8F751)],
        ),
        border: Border.all(color: const Color(0x66C8F751)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
            child: const Icon(Icons.done_all_rounded, size: 18, color: AppColors.onAccent),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${e.name} done',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(meta,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 10.5,
                        height: 1.4,
                        color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final SessionController c;
  const _BottomBar({required this.c});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c.resting) _RestBar(c: c),
          if (c.entry == null && c.sets.isEmpty)
            _PrimaryBtn(
              label: 'Start this lift',
              onTap: c.startLive,
            )
          else if (c.exDone)
            _PrimaryBtn(
              label: c.idx >= c.exercises.length - 1 ? 'Finish session' : 'Next exercise',
              onTap: c.advance,
            )
          else if (c.entry == EntryModeV2.live && !c.resting)
            Column(
              children: [
                _PrimaryBtn(
                  label: 'Log set ${c.sets.length + 1}',
                  onTap: () => c.logSet(true),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _SecondaryBtn(icon: Icons.done_all_rounded, label: 'Done all sets', onTap: c.fillRemaining)),
                    const SizedBox(width: 8),
                    Expanded(child: _SecondaryBtn(icon: Icons.schedule_rounded, label: 'Log at the end', onTap: c.deferLift)),
                  ],
                ),
              ],
            )
          else if (c.entry == EntryModeV2.deferred)
            _PrimaryBtn(
              label: c.idx >= c.exercises.length - 1 ? 'Finish session' : 'Next exercise',
              onTap: c.advance,
            ),
        ],
      ),
    );
  }
}

class _RestBar extends StatelessWidget {
  final SessionController c;
  const _RestBar({required this.c});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          const Icon(Icons.timer_rounded, size: 19, color: AppColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(c.restClock,
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 20,
                            color: AppColors.textPrimary)),
                    const SizedBox(width: 7),
                    const Text('rest',
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textMuted)),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: c.restPct,
                    minHeight: 4,
                    backgroundColor: AppColors.surfaceSunken,
                    valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: c.addRest,
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: AppColors.surfaceSunken, shape: BoxShape.circle),
              child: const Text('+30',
                  style: TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 10, color: AppColors.textMuted)),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: c.skipRest,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
              decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(20)),
              child: const Text('Skip',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 11.5,
                      color: AppColors.onAccent)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── review ──────────────────────────────────────────────────────────────────
class _ReviewScreen extends StatelessWidget {
  final SessionController c;
  const _ReviewScreen({required this.c});
  @override
  Widget build(BuildContext context) {
    final deferred = [
      for (var i = 0; i < c.exercises.length; i++)
        if (c.exerciseDeferred(i)) i
    ];
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('BEFORE WE CLOSE IT OUT',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 10, letterSpacing: 0.8, color: AppColors.accent)),
                const SizedBox(height: 7),
                Text('The bits you saved for later', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('Prefilled at the plan. Open the ones that went differently — the rest you can leave as they are.',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 12, height: 1.55, color: AppColors.textMuted)),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              children: [
                for (final i in deferred)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: V2Card(
                      child: Row(
                        children: [
                          Container(
                            width: 24,
                            height: 24,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(color: AppColors.surfaceSunken, shape: BoxShape.circle),
                            child: const Icon(Icons.schedule_rounded, size: 15, color: AppColors.textMuted),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.exercises[i].name,
                                    style: const TextStyle(
                                        fontFamily: AppTheme.fontFamily,
                                        fontWeight: FontWeight.w500,
                                        fontSize: 13,
                                        color: AppColors.textPrimary)),
                                const SizedBox(height: 2),
                                Text('Prefilled ${c.exercises[i].prescription} at the plan',
                                    style: const TextStyle(
                                        fontFamily: AppTheme.fontFamily,
                                        fontSize: 10.5,
                                        height: 1.4,
                                        color: AppColors.textMuted)),
                              ],
                            ),
                          ),
                          const Text('Keep as is',
                              style: TextStyle(
                                  fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.accent)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
            child: Column(
              children: [
                const Text('Anything you leave alone gets saved exactly as planned.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 10.5, height: 1.5, color: AppColors.textDim)),
                const SizedBox(height: 10),
                _PrimaryBtn(label: 'Save and finish', onTap: c.finishReview),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── done ────────────────────────────────────────────────────────────────────
class _DoneScreen extends StatelessWidget {
  final SessionController c;
  const _DoneScreen({required this.c});
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 54, 26, 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(22)),
              child: const Icon(Icons.check_rounded, size: 34, color: AppColors.onAccent),
            ),
            const SizedBox(height: 24),
            Text('${c.label}, done',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 30,
                    height: 1.1,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            Text('${c.totalSets} sets, every lift finished. Nothing dramatic — that is what progress actually looks like.',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 13, height: 1.6, color: AppColors.textMuted)),
            const SizedBox(height: 24),
            _DoneTiles(c: c),
            const SizedBox(height: 22),
            _PrimaryBtn(
              label: "See today's summary",
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DoneTiles extends StatelessWidget {
  final SessionController c;
  const _DoneTiles({required this.c});
  @override
  Widget build(BuildContext context) {
    final tiles = [
      ('${c.totalSets}', 'sets logged'),
      (c.totalVolume.round().toString(), 'kg moved'),
      ('${c.elapsedMin} min', 'in the gym'),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: AppColors.border,
        child: Row(
          children: [
            for (var i = 0; i < tiles.length; i++)
              Expanded(
                child: Container(
                  margin: EdgeInsets.only(right: i == tiles.length - 1 ? 0 : 1),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  color: AppColors.surface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tiles[i].$1,
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 18,
                              color: AppColors.accent)),
                      const SizedBox(height: 5),
                      Text(tiles[i].$2,
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 9.5,
                              height: 1.3,
                              color: AppColors.textMuted)),
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

// ── shared ──────────────────────────────────────────────────────────────────
class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle),
          child: Icon(icon, size: 19, color: AppColors.textMuted),
        ),
      );
}

class _PrimaryBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PrimaryBtn({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 17),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(26)),
          child: Text(label,
              style: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.onAccent)),
        ),
      );
}

class _SecondaryBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SecondaryBtn({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: AppColors.textMuted),
              const SizedBox(width: 7),
              Text(label,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 11.5,
                      color: AppColors.textSecondary)),
            ],
          ),
        ),
      );
}
