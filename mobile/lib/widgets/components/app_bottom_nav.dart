import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

class AppNavDestination {
  const AppNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Space a tab's scrollable/dock must leave at the bottom so nothing sits
/// under the floating nav. The shell uses `extendBody: true`, so Scaffold
/// reports the nav's full height (bar + safe-area inset) as the body's
/// bottom padding — this reads that live value instead of guessing.
double bottomNavClearance(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom + 12;

/// Floating dark-glass navigation pill: rounded, blurred, with a soft blue
/// glow behind the active item. Sits above the bottom safe area; pair with
/// `extendBody: true` so content scrolls beneath it.
class AppBottomNavigation extends StatelessWidget {
  const AppBottomNavigation({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  static const double barHeight = 68;

  final List<AppNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      // Chrome labels stay bounded so the fixed-height pill never overflows;
      // content text elsewhere keeps the user's full text-size setting.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              height: barHeight,
              decoration: BoxDecoration(
                color: AppColors.bg1.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    Expanded(
                      child: _NavItem(
                        destination: destinations[i],
                        selected: i == selectedIndex,
                        onTap: () => onSelected(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final AppNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : AppColors.textTertiary;
    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: selected
                    ? AppColors.primaryBlue.withValues(alpha: 0.28)
                    : Colors.transparent,
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: AppColors.primaryBlue.withValues(alpha: 0.45),
                          blurRadius: 18,
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                selected ? destination.selectedIcon : destination.icon,
                color: color,
                size: 24,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              destination.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                height: 1.2,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
