import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/v2_models.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../services/session_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'session_flow_screen.dart';

/// Temporary Phase 1 entry point: enough of a Train tab to load today's plan
/// and launch the session flow. Replaced properly in Phase 2.
class TrainPlaceholder extends StatefulWidget {
  const TrainPlaceholder({super.key});
  @override
  State<TrainPlaceholder> createState() => _TrainPlaceholderState();
}

class _TrainPlaceholderState extends State<TrainPlaceholder> {
  TrainScreenV2? _plan;
  String? _error;
  bool _loading = true;

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
      final p = await SupabaseService.instance.fetchTrainScreen();
      if (!mounted) return;
      setState(() {
        _plan = p;
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

  Future<void> _generate() async {
    setState(() => _loading = true);
    try {
      await SupabaseService.instance.generateProgram();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    await _load();
  }

  Future<void> _start() async {
    final plan = _plan;
    if (plan == null || plan.exercises.isEmpty) {
      return;
    }
    String? sessionId;
    try {
      sessionId = await SupabaseService.instance.openSession(title: plan.label);
    } catch (e) {
      return;
    }
    if (sessionId == null) {
      return;
    }
    if (!mounted) return;
    final controller = SessionController(
      sessionId: sessionId,
      label: plan.label ?? 'Session',
      exercises: plan.exercises,
      startedAt: plan.startedAt,
    );
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider.value(
        value: controller,
        child: const SessionFlowScreen(),
      ),
    ));
    controller.dispose();
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load plan',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textMuted)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final plan = _plan;
    if (plan == null) {
      return _NoPlan(onGenerate: _generate, label: 'Not signed in, or no plan yet.');
    }
    if (plan.exercises.isEmpty) {
      return _NoPlan(
        onGenerate: _generate,
        label: plan.isRest ? 'Rest day — nothing scheduled today.' : 'No exercises today.',
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(plan.isRest ? 'Rest day' : (plan.label ?? 'Train'),
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text('${plan.exercises.length} exercises',
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 20),
            Expanded(
              child: ListView(
                children: [
                  for (final e in plan.exercises)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          border: Border.all(color: AppColors.border),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(e.name,
                                  style: const TextStyle(
                                      fontFamily: AppTheme.fontFamily,
                                      fontWeight: FontWeight.w500,
                                      fontSize: 14,
                                      color: AppColors.textPrimary)),
                            ),
                            Text(e.prescription,
                                style: const TextStyle(
                                    fontFamily: AppTheme.fontFamily,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    color: AppColors.accent)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            GestureDetector(
              onTap: _start,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 17),
                alignment: Alignment.center,
                decoration:
                    BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(26)),
                child: Text(
                  plan.sessionStatus == 'in_progress' ? 'Continue session' : 'Start session',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.onAccent),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: GestureDetector(
                onTap: _generate,
                child: const Text('Regenerate plan (dev)',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily, fontSize: 11, color: AppColors.textDim)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoPlan extends StatelessWidget {
  final VoidCallback onGenerate;
  final String label;
  const _NoPlan({required this.onGenerate, required this.label});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 13, color: AppColors.textMuted)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onGenerate, child: const Text('Generate today\'s plan')),
          ],
        ),
      ),
    );
  }
}
