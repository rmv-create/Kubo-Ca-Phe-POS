import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/backup/presentation/backup_screen.dart';
import '../features/customers/presentation/customers_screen.dart';
import '../features/management/presentation/management_home_screen.dart';
import '../features/menu/presentation/categories_screen.dart';
import '../features/menu/presentation/customisations_screen.dart';
import '../features/menu/presentation/menu_hub_screen.dart';
import '../features/menu/presentation/product_editor_screen.dart';
import '../features/menu/presentation/products_screen.dart';
import '../features/menu/presentation/sizes_screen.dart';
import '../features/pos/presentation/pos_screen.dart';
import '../features/receipts/presentation/receipt_screen.dart';
import '../features/sales/presentation/closing_screen.dart';
import '../features/sales/presentation/orders_screen.dart';
import '../features/sales/presentation/reports_screen.dart';
import '../features/settings/presentation/management_gate.dart';
import '../features/settings/presentation/payment_methods_screen.dart';
import '../features/settings/presentation/receipt_settings_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/settings/presentation/staff_screen.dart';
import '../features/stock/presentation/ingredients_screen.dart';
import '../features/stock/presentation/inventory_screen.dart';
import '../features/stock/presentation/purchasing_screens.dart';
import '../features/stock/presentation/recipes_screen.dart';
import 'shell/app_shell.dart';

abstract final class Routes {
  static const String pos = '/';
  static const String manage = '/manage';
  static const String orders = '/manage/orders';
  static const String customers = '/manage/customers';
  static const String menu = '/manage/menu';
  static const String menuProducts = '/manage/menu/drinks';
  static const String menuCategories = '/manage/menu/categories';
  static const String menuSizes = '/manage/menu/sizes';
  static const String menuCustomisations = '/manage/menu/customisations';
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
  static const String paymentMethods = '/manage/payment-methods';
  static const String receiptSettings = '/manage/receipt';
  static const String staff = '/manage/staff';
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
                  const ManagementGate(child: ManagementHomeScreen()),
              routes: <RouteBase>[
                _section('orders', const OrdersScreen()),
                _section('customers', const CustomersScreen()),
                GoRoute(
                  path: 'menu',
                  builder: (BuildContext context, GoRouterState state) =>
                      const ManagementGate(child: MenuHubScreen()),
                  routes: <RouteBase>[
                    GoRoute(
                      path: 'drinks',
                      builder: (BuildContext context, GoRouterState state) =>
                          const ManagementGate(child: ProductsScreen()),
                      routes: <RouteBase>[
                        GoRoute(
                          path: ':id',
                          builder:
                              (BuildContext context, GoRouterState state) =>
                                  ManagementGate(
                                    child: ProductEditorScreen(
                                      productId: int.parse(
                                        state.pathParameters['id']!,
                                      ),
                                    ),
                                  ),
                        ),
                      ],
                    ),
                    _section('categories', const CategoriesScreen()),
                    _section('sizes', const SizesScreen()),
                    GoRoute(
                      path: 'customisations',
                      builder: (BuildContext context, GoRouterState state) =>
                          const ManagementGate(child: CustomisationsScreen()),
                      routes: <RouteBase>[
                        GoRoute(
                          path: ':id',
                          builder:
                              (BuildContext context, GoRouterState state) =>
                                  ManagementGate(
                                    child: CustomizationGroupScreen(
                                      groupId: int.parse(
                                        state.pathParameters['id']!,
                                      ),
                                    ),
                                  ),
                        ),
                      ],
                    ),
                  ],
                ),
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
                _section('payment-methods', const PaymentMethodsScreen()),
                _section('receipt', const ReceiptSettingsScreen()),
                _section('staff', const StaffScreen()),
                GoRoute(
                  path: 'orders/:id/receipt',
                  // A receipt is the one thing in here a barista must be
                  // able to reach: she prints it for the customer in front of
                  // her, and it shows nothing about cost or margin.
                  builder: (BuildContext context, GoRouterState state) =>
                      ReceiptScreen(
                        orderId: int.parse(state.pathParameters['id']!),
                      ),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

/// One Management screen, behind the owner's PIN.
///
/// The gate is applied per route rather than once around the branch, because
/// a deep link — a receipt sent to someone, a bookmarked report — must land on
/// the same check as tapping through would.
GoRoute _section(String path, Widget child) => GoRoute(
  path: path,
  builder: (BuildContext context, GoRouterState state) =>
      ManagementGate(child: child),
);
