import 'package:flutter/material.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/pressable.dart';
import 'create_exercise_sheet.dart';

/// Add an exercise to today's plan beyond what the generator prescribed. The
/// generator's 4-6 lift cap is a rule about what we prescribe, not a limit on
/// what a lifter may do — appending is theirs.
///
/// Built on `browse_exercises`, deliberately styled after the swap picker
/// (`swap_sheet.dart`) — search, a muscle chip row, a Core/More options split
/// — so it reads as the same component, not a different screen.
///
/// Returns true if an exercise was added to [programDayId].
Future<bool> showAddExerciseSheet(BuildContext context, String programDayId) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AddExerciseSheet(programDayId: programDayId),
  );
  return result ?? false;
}

class _AddExerciseSheet extends StatefulWidget {
  final String programDayId;
  const _AddExerciseSheet({required this.programDayId});
  @override
  State<_AddExerciseSheet> createState() => _AddExerciseSheetState();
}

class _AddExerciseSheetState extends State<_AddExerciseSheet> {
  List<BrowseExerciseV2>? _all;
  String _query = '';
  String? _muscle;
  String? _busyId;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await SupabaseService.instance.browseExercises();
      if (mounted) setState(() => _all = list);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load exercises.');
    }
  }

  /// Distinct muscles present in the loaded rows, in first-appearance order —
  /// same rule swap_sheet uses, there is no natural alphabetical grouping.
  List<String> get _muscles {
    final seen = <String>{};
    for (final c in _all ?? const <BrowseExerciseV2>[]) {
      if (c.muscle.isNotEmpty) seen.add(c.muscle);
    }
    return seen.toList();
  }

  List<BrowseExerciseV2> get _filtered {
    var rows = _all ?? const <BrowseExerciseV2>[];
    if (_muscle != null) {
      rows = rows.where((c) => c.muscle == _muscle).toList();
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.toLowerCase();
      rows = rows
          .where((c) =>
              c.name.toLowerCase().contains(q) ||
              (c.equipment ?? '').toLowerCase().contains(q))
          .toList();
    }
    return rows;
  }

  Future<void> _add(BrowseExerciseV2 c) async {
    setState(() => _busyId = c.exerciseId);
    try {
      await SupabaseService.instance.addDayExercise(widget.programDayId, c.exerciseId);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busyId = null;
          _error = "That couldn't be added.";
        });
      }
    }
  }

  /// "Can't find it? Create one" — describe a private exercise, then add it
  /// straight to today's day: the whole reason to create one here is that the
  /// picker came up empty, so the natural next step is having it on the plan.
  Future<void> _createAndAdd() async {
    final id = await showCreateExerciseSheet(context);
    if (id == null || !mounted) return;
    setState(() => _creating = true);
    try {
      await SupabaseService.instance.addDayExercise(widget.programDayId, id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = 'Saved, but could not add it to today — try from the list.';
        });
      }
      _load(); // the new exercise now shows up under "mine" in the list
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final core = rows.where((c) => c.isCore).toList();
    final ext = rows.where((c) => !c.isCore).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.page,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.border, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Add an exercise',
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 3),
                  Text(
                    _all == null ? 'Loading the catalogue…' : '${_all!.length} exercises to pick from',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 13.5, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search by name or equipment',
                  hintStyle: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 13, color: AppColors.textFaint),
                  prefixIcon:
                      const Icon(Icons.search_rounded, size: 18, color: AppColors.textFaint),
                  filled: true,
                  fillColor: AppColors.surface,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                ),
              ),
            ),
            if (_muscles.length > 1)
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                  children: [
                    for (final m in _muscles)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _FilterChip(
                          label: m,
                          selected: _muscle == m,
                          onTap: () => setState(() => _muscle = _muscle == m ? null : m),
                        ),
                      ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
                child: Text(_error!,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.accent)),
              ),
            Expanded(
              child: _all == null
                  ? const Center(
                      child: SizedBox(
                          width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                  : ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                      children: [
                        if (rows.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Text('No exercises match that search.',
                                style: TextStyle(
                                    fontFamily: AppTheme.fontFamily,
                                    fontSize: 13,
                                    color: AppColors.textMuted)),
                          ),
                        if (core.isNotEmpty) ...[
                          _sectionLabel('Recommended'),
                          for (final c in core)
                            _ExerciseRow(
                                c: c, busy: _busyId == c.exerciseId, onTap: () => _add(c)),
                        ],
                        if (ext.isNotEmpty) ...[
                          _sectionLabel(core.isEmpty ? 'All options' : 'More options'),
                          for (final c in ext)
                            _ExerciseRow(
                                c: c, busy: _busyId == c.exerciseId, onTap: () => _add(c)),
                        ],
                        const SizedBox(height: 6),
                        _CreateOwnRow(busy: _creating, onTap: _creating ? () {} : _createAndAdd),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 10.5,
                letterSpacing: 0.7,
                color: AppColors.textFaint)),
      );
}

class _ExerciseRow extends StatelessWidget {
  final BrowseExerciseV2 c;
  final bool busy;
  final VoidCallback onTap;
  const _ExerciseRow({required this.c, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Pressable(
        haptic: PressFx.medium,
        onTap: busy ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(c.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 13.5,
                                  color: AppColors.textPrimary)),
                        ),
                        if (c.isMine) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('MINE',
                                style: TextStyle(
                                    fontFamily: AppTheme.fontFamily,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 8.5,
                                    letterSpacing: 0.4,
                                    color: AppColors.accent)),
                          ),
                        ],
                      ],
                    ),
                    if (c.tags.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(c.tags.join(' · '),
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
                    ],
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                    width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
              else
                const Icon(Icons.add_circle_outline_rounded, size: 18, color: AppColors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateOwnRow extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _CreateOwnRow({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      haptic: PressFx.light,
      onTap: busy ? null : onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(color: AppColors.borderStrong),
          borderRadius: BorderRadius.circular(24),
        ),
        child: busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_rounded, size: 17, color: AppColors.accent),
                  SizedBox(width: 6),
                  Text("Can't find it? Create one",
                      style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: AppColors.accent)),
                ],
              ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      haptic: PressFx.light,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.accent : AppColors.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w500,
                fontSize: 12,
                color: selected ? AppColors.onAccent : AppColors.textMuted)),
      ),
    );
  }
}
