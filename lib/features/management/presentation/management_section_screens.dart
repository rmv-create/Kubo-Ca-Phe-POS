import 'package:flutter/material.dart';

import '../../../shared/widgets/phase_placeholder.dart';

/// Management sections that are scheduled but not yet built.
///
/// Each says which phase it belongs to and what it will contain, so the app
/// never implies that unfinished work is done.
class _SectionScaffold extends StatelessWidget {
  const _SectionScaffold({required this.title, required this.body});

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: body,
  );
}

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Orders',
    body: PhasePlaceholder(
      title: 'Order history',
      phase: 'Phase 3 · Phase 7',
      summary:
          'Every order the POS completes, with its items, customisations, '
          'payment, COGS and gross profit. Refunds and voids attach here '
          'and never delete the original sale.',
      bullets: <String>[
        'Filter by trading day, customer and payment method',
        'Open an order to refund or void it, with a reason',
        'Voided orders drop out of sales totals but stay on the record',
      ],
      icon: Icons.receipt_long_outlined,
    ),
  );
}

class CustomersScreen extends StatelessWidget {
  const CustomersScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Customers',
    body: PhasePlaceholder(
      title: 'Customer profiles',
      phase: 'Phase 4',
      summary:
          'Search by name or mobile, see visits, spend and history, and '
          'manage the saved usual order.',
      bullets: <String>[
        'The usual is worked out from repeated orders, not the last one',
        'Save as usual is always explicit — nothing is overwritten silently',
        'Loyalty data is collected; no rewards are given in V1',
      ],
      icon: Icons.people_outline,
    ),
  );
}

class RecipesScreen extends StatelessWidget {
  const RecipesScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Recipes',
    body: PhasePlaceholder(
      title: 'Recipes and versions',
      phase: 'Phase 5',
      summary:
          'One recipe per product and size, each with its own version '
          'history so past orders keep the cost they were actually sold at.',
      bullets: <String>[
        'Grande is never calculated from Small by a multiplier',
        'Editing a recipe creates a new version with an effective date',
        'Packaging (cups, lids, straws) is consumed by the recipe too',
      ],
      icon: Icons.science_outlined,
    ),
  );
}

class IngredientsScreen extends StatelessWidget {
  const IngredientsScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Ingredients',
    body: PhasePlaceholder(
      title: 'Ingredient master and costs',
      phase: 'Phase 5',
      summary:
          'Units, purchase sizes, current cost, cost history, thresholds '
          'and supplier for every ingredient and packaging item.',
      bullets: <String>[
        'Costs are kept as history, so old orders keep their old cost',
        'Ice can start untracked and be switched on later without code changes',
      ],
      icon: Icons.grass_outlined,
    ),
  );
}

class InventoryScreen extends StatelessWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Inventory',
    body: PhasePlaceholder(
      title: 'Stock, movements and alerts',
      phase: 'Phase 6',
      summary:
          'Stock on hand, every movement that changed it, physical counts '
          'with variance, and low or critical stock alerts.',
      bullets: <String>[
        'Sales deduct ingredients automatically — never by hand',
        'Every change is a ledger entry with before and after quantities',
        'A count never changes stock until it is confirmed',
      ],
      icon: Icons.inventory_2_outlined,
    ),
  );
}

class WasteScreen extends StatelessWidget {
  const WasteScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Waste',
    body: PhasePlaceholder(
      title: 'Record waste',
      phase: 'Phase 6',
      summary:
          'Log a spill, spoilage, expiry, mistake or damage. Waste reduces '
          'stock and shows up in reporting at cost.',
      icon: Icons.delete_outline,
    ),
  );
}

class SuppliersScreen extends StatelessWidget {
  const SuppliersScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Suppliers',
    body: PhasePlaceholder(
      title: 'Suppliers',
      phase: 'Phase 6',
      summary:
          'Name, contact and notes, linked to the ingredients they supply.',
      icon: Icons.local_shipping_outlined,
    ),
  );
}

class PurchasesScreen extends StatelessWidget {
  const PurchasesScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Purchases',
    body: PhasePlaceholder(
      title: 'Purchases',
      phase: 'Phase 6',
      summary:
          'Record what came in and what it cost. Purchases add stock and '
          'feed ingredient cost history.',
      icon: Icons.shopping_basket_outlined,
    ),
  );
}

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Reports',
    body: PhasePlaceholder(
      title: 'Reports and Excel exports',
      phase: 'Phase 8',
      summary:
          'Daily and monthly sales, product profitability, inventory, '
          'waste, customers and purchases — on screen and as .xlsx.',
      bullets: <String>[
        'Best sellers and most profitable are reported separately',
        'Exports are formatted reports, not raw table dumps',
        'SQLite stays the database; Excel is only an export',
      ],
      icon: Icons.insights_outlined,
    ),
  );
}

class DailyClosingScreen extends StatelessWidget {
  const DailyClosingScreen({super.key});

  @override
  Widget build(BuildContext context) => const _SectionScaffold(
    title: 'Daily closing',
    body: PhasePlaceholder(
      title: 'Close the day',
      phase: 'Phase 7',
      summary:
          'Orders, revenue, cash, GCash, COGS, gross profit and margin, '
          'waste, refunds and voids — reviewed, confirmed, then locked.',
      icon: Icons.nightlight_outlined,
    ),
  );
}
