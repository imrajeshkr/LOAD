import 'package:flutter/material.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/pressable.dart';

/// Pick a different lift for the same muscle.
///
/// A list, not a grid of thumbnails: a bench-press swap offers 65 candidates
/// and only 6 of them have a guide image, so a grid would be mostly empty
/// placeholders. Name, equipment and mechanic are what a lifter actually scans.
///
/// Everything shown has already cleared the equipment, training-age and injury
/// filters server-side, so there is nothing here to warn about — Core and
/// Extended are both safe, they differ only in how much we know about them.
/// Returns true if a swap was applied.
Future<bool> showSwapSheet(BuildContext context, PlanExerciseV2 ex) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SwapSheet(ex: ex),
  );
  return result ?? false;
}

class _SwapSheet extends StatefulWidget {
  final PlanExerciseV2 ex;
  const _SwapSheet({required this.ex});
  @override
  State<_SwapSheet> createState() => _SwapSheetState();
}

class _SwapSheetState extends State<_SwapSheet> {
  List<SwapCandidateV2>? _all;
  String _query = '';
  String? _busyId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list =
          await SupabaseService.instance.fetchSwapCandidates(widget.ex.exerciseId);
      if (mounted) setState(() => _all = list);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load alternatives.');
    }
  }

  List<SwapCandidateV2> get _filtered {
    final all = _all ?? const <SwapCandidateV2>[];
    if (_query.trim().isEmpty) return all;
    final q = _query.toLowerCase();
    return all
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            (c.equipment ?? '').toLowerCase().contains(q))
        .toList();
  }

  Future<void> _apply(SwapCandidateV2 c) async {
    setState(() => _busyId = c.exerciseId);
    try {
      await SupabaseService.instance
          .swapExercise(widget.ex.exerciseId, c.exerciseId);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busyId = null;
          _error = 'That swap could not be applied.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final core = rows.where((c) => c.isCore).toList();
    final ext = rows.where((c) => !c.isCore).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
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
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Swap ${widget.ex.name}',
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 3),
                  Text(
                    _all == null
                        ? 'Finding alternatives…'
                        : '${_all!.length} lifts train the same muscle',
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 12,
                        color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 13.5,
                    color: AppColors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search by name or equipment',
                  hintStyle: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 13,
                      color: AppColors.textFaint),
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
                child: Text(_error!,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 12,
                        color: AppColors.accent)),
              ),
            Expanded(
              child: _all == null
                  ? const Center(
                      child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : rows.isEmpty
                      ? const Center(
                          child: Text('No alternatives match that search.',
                              style: TextStyle(
                                  fontFamily: AppTheme.fontFamily,
                                  fontSize: 13,
                                  color: AppColors.textMuted)))
                      : ListView(
                          controller: scrollController,
                          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
                          children: [
                            if (core.isNotEmpty) ...[
                              _sectionLabel('Recommended'),
                              for (final c in core)
                                _CandidateRow(
                                    c: c,
                                    busy: _busyId == c.exerciseId,
                                    onTap: () => _apply(c)),
                            ],
                            if (ext.isNotEmpty) ...[
                              _sectionLabel(core.isEmpty
                                  ? 'All options'
                                  : 'More options'),
                              for (final c in ext)
                                _CandidateRow(
                                    c: c,
                                    busy: _busyId == c.exerciseId,
                                    onTap: () => _apply(c)),
                            ],
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

class _CandidateRow extends StatelessWidget {
  final SwapCandidateV2 c;
  final bool busy;
  final VoidCallback onTap;
  const _CandidateRow({required this.c, required this.busy, required this.onTap});

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
                    Text(c.name,
                        style: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w500,
                            fontSize: 13.5,
                            color: AppColors.textPrimary)),
                    if (c.tags.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(c.tags.join(' · '),
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 11,
                              color: AppColors.textMuted)),
                    ],
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                const Icon(Icons.swap_horiz_rounded,
                    size: 17, color: AppColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}
