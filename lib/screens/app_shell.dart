import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'today/today_screen.dart';
import 'progress/progress_screen.dart';
import 'chat/chat_screen.dart';
import 'settings/settings_screen.dart';

/// Bottom-tab container.
///
/// Session flow (log / summary) and the form guide are pushed as real routes
/// on top of this shell rather than being rendered as sibling states. That
/// keeps the back stack honest and fixes the bug where the guide stayed
/// visible after switching tabs.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _tabs = <_TabSpec>[
    _TabSpec('Today', Icons.today_outlined, Icons.today_rounded),
    _TabSpec('Progress', Icons.insights_outlined, Icons.insights_rounded),
    _TabSpec('Coach', Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded),
    _TabSpec('Profile', Icons.person_outline_rounded, Icons.person_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: [
            TodayScreen(onOpenProfile: () => setState(() => _index = 3)),
            const ProgressScreen(),
            const ChatScreen(),
            const SettingsScreen(),
          ],
        ),
      ),
      bottomNavigationBar: _BottomBar(
        index: _index,
        tabs: _tabs,
        onSelect: (i) {
          if (i == _index) return;
          setState(() => _index = i);
          // Progress reads from the DB; refresh when the user lands on it.
          if (i == 1) context.read<AppState>().refreshProgress();
        },
      ),
    );
  }
}

class _TabSpec {
  final String label;
  final IconData icon;
  final IconData activeIcon;
  const _TabSpec(this.label, this.icon, this.activeIcon);
}

class _BottomBar extends StatelessWidget {
  final int index;
  final List<_TabSpec> tabs;
  final ValueChanged<int> onSelect;

  const _BottomBar({
    required this.index,
    required this.tabs,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: List.generate(tabs.length, (i) {
              final selected = i == index;
              final tab = tabs[i];
              return Expanded(
                child: InkWell(
                  onTap: () => onSelect(i),
                  borderRadius: BorderRadius.circular(AppRadii.card),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        selected ? tab.activeIcon : tab.icon,
                        size: 23,
                        color: selected ? AppColors.accent : AppColors.inactive,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tab.label,
                        style: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                          fontSize: 10.5,
                          color: selected ? AppColors.accent : AppColors.inactive,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
