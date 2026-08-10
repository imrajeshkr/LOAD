import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../theme/app_colors.dart';
import 'today/today_screen.dart';
import 'today/log_screen.dart';
import 'today/summary_screen.dart';
import 'today/guide_overlay.dart';
import 'progress/progress_screen.dart';
import 'chat/chat_screen.dart';
import 'settings/settings_screen.dart';

enum _MainView { today, log, summary }

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int tabIndex = 0;
  _MainView view = _MainView.today;

  void goToLog() => setState(() => view = _MainView.log);
  void goToSummary() => setState(() => view = _MainView.summary);
  void goToToday() => setState(() {
        view = _MainView.today;
        tabIndex = 0;
      });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    final tabs = [
      TodayScreen(onStartSession: goToLog, onOpenExercise: goToLog),
      const ProgressScreen(),
      const ChatScreen(),
      const SettingsScreen(),
    ];

    Widget body;
    if (view == _MainView.log) {
      body = LogScreen(onBackToToday: goToToday, onFinish: goToSummary);
    } else if (view == _MainView.summary) {
      body = SummaryScreen(onDone: goToToday);
    } else {
      body = tabs[tabIndex];
    }

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(bottom: false, child: body),
          if (state.guideExerciseIndex != null) const GuideOverlay(),
        ],
      ),
      bottomNavigationBar: view != _MainView.today
          ? null
          : _BottomTabBar(
              index: tabIndex,
              onSelect: (i) => setState(() => tabIndex = i),
            ),
    );
  }
}

class _BottomTabBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  const _BottomTabBar({required this.index, required this.onSelect});

  static const _labels = ['TODAY', 'PROGRESS', 'CHAT', 'SETTINGS'];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(_labels.length, (i) {
            final selected = i == index;
            return GestureDetector(
              onTap: () => onSelect(i),
              behavior: HitTestBehavior.opaque,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _labels[i],
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      color: selected ? AppColors.textPrimary : AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(width: 20, height: 2, color: selected ? AppColors.accent : Colors.transparent),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}
