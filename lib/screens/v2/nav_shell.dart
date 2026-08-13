import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'train_screen.dart';

/// v2 bottom nav: four tabs, the active one expands into a lime pill and
/// reveals its label. Inactive tabs are icon-only. Floats 30px above the edge.
class NavShell extends StatefulWidget {
  const NavShell({super.key});

  @override
  State<NavShell> createState() => _NavShellState();
}

class _NavShellState extends State<NavShell> {
  int _index = 0;

  static const _tabs = <_TabSpec>[
    _TabSpec('Train', Icons.fitness_center_rounded),
    _TabSpec('Progress', Icons.insights_rounded),
    _TabSpec('Trainer', Icons.chat_bubble_rounded),
    _TabSpec('Profile', Icons.person_rounded),
  ];

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
              children: const [
                TrainTab(),
                _Placeholder('Progress'),
                _Placeholder('Trainer'),
                _Placeholder('Profile'),
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
                          onTap: () => setState(() => _index = i),
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
  final VoidCallback onTap;
  const _NavTab({required this.spec, required this.active, required this.onTap});

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
              Icon(
                spec.icon,
                size: 21,
                color: active ? AppColors.onAccent : AppColors.textFaint,
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

class _Placeholder extends StatelessWidget {
  final String name;
  const _Placeholder(this.name);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(name, style: Theme.of(context).textTheme.headlineMedium),
    );
  }
}
