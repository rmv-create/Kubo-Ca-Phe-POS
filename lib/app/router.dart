import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/backup/presentation/backup_screen.dart';
import '../features/management/presentation/management_home_screen.dart';
import '../features/management/presentation/management_section_screens.dart';
import '../features/pos/presentation/pos_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import 'shell/app_shell.dart';

abstract final class Routes {
  static const String pos = '/';
  static const String manage = '/manage';
  static const String orders = '/manage/orders';
  static const String customers = '/manage/customers';
  static const String menu = '/manage/menu';
  static const String recipes = '/manage/recipes';
  static const String ingredients = '/manage/ingredients';
  static const String inventory = '/manage/inventory';
  static const String waste = '/manage/waste';
  static const String suppliers = '/manage/suppliers';
  static const String purchases = '/manage/purchases';
  static const String reports = '/manage/reports';
  static const String closing = '/manage/closing';
  static const String settings = '/manage/settings';
  static const String backup = '/manage/backup';
}

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);

/// Two branches, each with its own navigator.
///
/// The POS branch keeps its state when the owner steps into Management: an
/// in-progress order must still be there when she comes back.
GoRouter createRouter() => GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: Routes.pos,
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder:
          (
            BuildContext context,
            GoRouterState state,
            StatefulNavigationShell shell,
          ) => AppShell(shell: shell),
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: Routes.pos,
              builder: (BuildContext context, GoRouterState state) =>
                  const PosScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: Routes.manage,
              builder: (BuildContext context, GoRouterState state) =>
                  const ManagementHomeScreen(),
              routes: <RouteBase>[
                _section('orders', const OrdersScreen()),
                _section('customers', const CustomersScreen()),
                _section('menu', const MenuManagementScreen()),
                _section('recipes', const RecipesScreen()),
                _section('ingredients', const IngredientsScreen()),
                _section('inventory', const InventoryScreen()),
                _section('waste', const WasteScreen()),
                _section('suppliers', const SuppliersScreen()),
                _section('purchases', const PurchasesScreen()),
                _section('reports', const ReportsScreen()),
                _section('closing', const DailyClosingScreen()),
                _section('settings', const SettingsScreen()),
                _section('backup', const BackupScreen()),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

GoRoute _section(String path, Widget child) => GoRoute(
  path: path,
  builder: (BuildContext context, GoRouterState state) => child,
);
