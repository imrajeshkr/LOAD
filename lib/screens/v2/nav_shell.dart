import 'package:flutter/material.dart';
import '../../services/haptics.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'train_screen.dart';
import 'progress_screen.dart';
import 'profile_screen.dart';
import 'trainer_screen.dart';

/// v2 bottom nav: four tabs, the active one expands into a lime pill and
/// reveals its label. Inactive tabs are icon-only. Floats 30px above the edge.
class NavShell extends StatefulWidget {
  const NavShell({super.key});

  @override
  State<NavShell> createState() => _NavShellState();
}

class _NavShellState extends State<NavShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _coachUnread = false;
  final _pendingAsk = ValueNotifier<String?>(null);

  static const _trainerIndex = 2;

  static const _tabs = <_TabSpec>[
    _TabSpec('Train', Icons.fitness_center_rounded),
    _TabSpec('Progress', Icons.insights_rounded),
    _TabSpec('Trainer', Icons.chat_bubble_rounded),
    _TabSpec('Profile', Icons.person_rounded),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshUnread();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pendingAsk.dispose();
    super.dispose();
  }

  /// Progress's stall cards call this to open the Trainer tab with a
  /// pre-filled, ready-to-review question rather than sending it blind.
  void _askTrainer(String question) {
    _pendingAsk.value = question;
    _onTab(_trainerIndex);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app might mean a note arrived (e.g. a morning note).
    if (state == AppLifecycleState.resumed && _index != _trainerIndex) {
      _refreshUnread();
    }
  }

  int _lastUnreadCount = 0;

  Future<void> _refreshUnread() async {
    try {
      final n = await SupabaseService.instance.unreadCoachCount();
      if (!mounted) return;
      // A genuinely new note arrived (not just re-confirming an existing
      // one) while the app is open and the user isn't already looking at
      // it — this is the one thing worth an audible ping (house decision:
      // in-app sound only, no real push notification).
      if (n > _lastUnreadCount) Haptics.alert();
      _lastUnreadCount = n;
      setState(() => _coachUnread = n > 0);
    } catch (_) {/* a missing badge is harmless */}
  }

  static const _trainIndex = 0;

  void _onTab(int i) {
    if (i != _index) Haptics.selection();
    // Leaving Train dismisses the post-session "next time these go up" card
    // for the rest of the day (it shows right after finishing, then gets out
    // of the way).
    if (_index == _trainIndex && i != _trainIndex) {
      trainProgressionDismissedOn = DateTime.now();
    }
    final leavingTrainer = _index == _trainerIndex && i != _trainerIndex;
    setState(() {
      _index = i;
      // Opening the Trainer tab reads the thread, so drop the badge at once.
      if (i == _trainerIndex) {
        _coachUnread = false;
        _lastUnreadCount = 0;
      }
    });
    // Any time the user lands on a non-Trainer tab, re-check the DB — this is
    // what surfaces a note written while they were elsewhere (a session
    // debrief the moment they finish, say). Skipped when opening Trainer so the
    // optimistic clear above doesn't flicker back before the read lands.
    if (i != _trainerIndex) {
      // On the way out of Trainer, persist "read" for the whole thread first,
      // THEN recount. The Trainer tab is kept alive in the IndexedStack and
      // only self-marks on scroll/first-load, so a note that arrived while it
      // sat open would otherwise still count as unread and re-light the dot.
      leavingTrainer ? _markReadThenRefresh() : _refreshUnread();
    }
  }

  Future<void> _markReadThenRefresh() async {
    try {
      await SupabaseService.instance.markCoachThreadRead();
    } catch (_) {/* recount below still self-corrects */}
    await _refreshUnread();
  }

  @override
  Widget build(BuildContext context) {
    // The pill floats over the body (design), but it must be the ONLY thing
    // hit-testable at the bottom — a full-width bottomNavigationBar slot with
    // extendBody swallows taps in the empty space above the pill. So stack it
    // and let taps pass through everywhere except the pill's own box.
    return Scaffold(
      backgroundColor: AppColors.page,
      body: Stack(
        children: [
          // Reserve the floating pill's footprint so screen content never
          // sits behind it (the pill is drawn on top and would eat those taps).
          Padding(
            padding: const EdgeInsets.only(bottom: 96),
            child: IndexedStack(
              index: _index,
              children: [
                const TrainTab(),
                ProgressTab(onAskTrainer: _askTrainer),
                TrainerTab(pendingAsk: _pendingAsk),
                const ProfileTab(),
              ],
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 30),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadii.pill + 4),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      for (var i = 0; i < _tabs.length; i++)
                        _NavTab(
                          spec: _tabs[i],
                          active: i == _index,
                          badge: i == _trainerIndex && _coachUnread && i != _index,
                          onTap: () => _onTab(i),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabSpec {
  final String label;
  final IconData icon;
  const _TabSpec(this.label, this.icon);
}

class _NavTab extends StatelessWidget {
  final _TabSpec spec;
  final bool active;
  final bool badge;
  final VoidCallback onTap;
  const _NavTab({
    required this.spec,
    required this.active,
    required this.onTap,
    this.badge = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: active ? 19 : 10,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: const Cubic(0.22, 1, 0.36, 1),
          height: 48,
          decoration: BoxDecoration(
            color: active ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    spec.icon,
                    size: 21,
                    color: active ? AppColors.onAccent : AppColors.textFaint,
                  ),
                  if (badge)
                    Positioned(
                      top: -3,
                      right: -4,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: AppColors.warn,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.surface, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              if (active) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    spec.label,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      color: AppColors.onAccent,
                    ),
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
