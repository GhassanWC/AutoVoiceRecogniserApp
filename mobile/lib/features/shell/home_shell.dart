import 'package:flutter/material.dart';

import '../../widgets/components/app_background.dart';
import '../../widgets/components/app_bottom_nav.dart';
import '../history/history_screen.dart';
import '../live_translation/live_translation_screen.dart';
import '../profile/profile_screen.dart';

/// The signed-in app frame: midnight background, three tabs, floating glass
/// navigation. Tabs live in an IndexedStack so the live translation session
/// keeps running untouched while the user browses History or Profile.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _destinations = [
    AppNavDestination(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
      label: 'Home',
    ),
    AppNavDestination(
      icon: Icons.history_rounded,
      selectedIcon: Icons.history_rounded,
      label: 'History',
    ),
    AppNavDestination(
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: 'Profile',
    ),
  ];

  static const _tabs = <Widget>[
    LiveTranslationScreen(),
    HistoryScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: AppBackground(
        child: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: _index,
            children: [
              // IndexedStack only excludes focus for hidden tabs; tickers
              // (the orb animation) must be paused explicitly.
              for (var i = 0; i < _tabs.length; i++)
                TickerMode(enabled: i == _index, child: _tabs[i]),
            ],
          ),
        ),
      ),
      bottomNavigationBar: AppBottomNavigation(
        destinations: _destinations,
        selectedIndex: _index,
        onSelected: (index) => setState(() => _index = index),
      ),
    );
  }
}
