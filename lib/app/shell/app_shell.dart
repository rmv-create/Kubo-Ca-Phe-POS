import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../responsive/form_factor.dart';
import '../theme/kubo_tokens.dart';

/// The frame around every screen.
///
/// On iPhone the POS owns the entire screen and Management is reached from the
/// header — no bottom bar stealing 68pt from the order list. On iPad a slim
/// rail is always visible, because there is room for it and it saves a tap.
class AppShell extends StatelessWidget {
  const AppShell({required this.shell, super.key});

  final StatefulNavigationShell shell;

  static const List<_Destination> _destinations = <_Destination>[
    _Destination(
      label: 'POS',
      icon: Icons.point_of_sale_outlined,
      selectedIcon: Icons.point_of_sale,
    ),
    _Destination(
      label: 'Manage',
      icon: Icons.tune_outlined,
      selectedIcon: Icons.tune,
    ),
  ];

  void _goToBranch(int index) =>
      shell.goBranch(index, initialLocation: index == shell.currentIndex);

  @override
  Widget build(BuildContext context) => AppLayout(
    child: Builder(
      builder: (BuildContext context) {
        if (context.formFactor.isCompact) {
          return Scaffold(body: shell);
        }
        return Scaffold(
          body: Row(
            children: <Widget>[
              _Rail(
                destinations: _destinations,
                selectedIndex: shell.currentIndex,
                onSelected: _goToBranch,
              ),
              const VerticalDivider(width: 1),
              Expanded(child: shell),
            ],
          ),
        );
      },
    ),
  );
}

class _Destination {
  const _Destination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_Destination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      labelType: NavigationRailLabelType.all,
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: KuboSpacing.xl),
        child: Column(
          children: <Widget>[
            Icon(Icons.coffee, color: theme.colorScheme.primary),
            const SizedBox(height: KuboSpacing.xs),
            Text('Kubo', style: theme.textTheme.labelSmall),
          ],
        ),
      ),
      destinations: <NavigationRailDestination>[
        for (final _Destination d in destinations)
          NavigationRailDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon),
            label: Text(d.label),
          ),
      ],
    );
  }
}
