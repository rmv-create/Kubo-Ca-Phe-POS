import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/responsive/form_factor.dart';
import '../../../app/router.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../shared/widgets/section_header.dart';

class ManagementEntry {
  const ManagementEntry({
    required this.label,
    required this.description,
    required this.icon,
    required this.route,
    this.isReady = true,
  });

  final String label;
  final String description;
  final IconData icon;
  final String route;

  /// True once the screen genuinely works, so the list never overstates what
  /// is finished.
  final bool isReady;
}

const List<ManagementEntry> managementEntries = <ManagementEntry>[
  ManagementEntry(
    label: 'Orders',
    description: 'Every completed, refunded and voided order',
    icon: Icons.receipt_long_outlined,
    route: Routes.orders,
  ),
  ManagementEntry(
    label: 'Customers',
    description: 'Profiles, history, usual orders and segments',
    icon: Icons.people_outline,
    route: Routes.customers,
  ),
  ManagementEntry(
    label: 'Menu',
    description: 'Categories, products, sizes, prices, customisations',
    icon: Icons.local_cafe_outlined,
    route: Routes.menu,
  ),
  ManagementEntry(
    label: 'Recipes',
    description: 'Independent Small and Grande recipes, with versions',
    icon: Icons.science_outlined,
    route: Routes.recipes,
  ),
  ManagementEntry(
    label: 'Ingredients',
    description: 'Units, costs, thresholds and suppliers',
    icon: Icons.grass_outlined,
    route: Routes.ingredients,
  ),
  ManagementEntry(
    label: 'Inventory',
    description: 'Stock on hand, movements, counts and alerts',
    icon: Icons.inventory_2_outlined,
    route: Routes.inventory,
  ),
  ManagementEntry(
    label: 'Waste',
    description: 'Record spills, spoilage and mistakes',
    icon: Icons.delete_outline,
    route: Routes.waste,
  ),
  ManagementEntry(
    label: 'Suppliers',
    description: 'Who you buy from',
    icon: Icons.local_shipping_outlined,
    route: Routes.suppliers,
  ),
  ManagementEntry(
    label: 'Purchases',
    description: 'Deliveries in, and what they cost',
    icon: Icons.shopping_basket_outlined,
    route: Routes.purchases,
  ),
  ManagementEntry(
    label: 'Reports',
    description: 'Daily, monthly, profitability and Excel exports',
    icon: Icons.insights_outlined,
    route: Routes.reports,
  ),
  ManagementEntry(
    label: 'Daily closing',
    description: 'Close the day and lock the numbers',
    icon: Icons.nightlight_outlined,
    route: Routes.closing,
  ),
  ManagementEntry(
    label: 'Payment methods',
    description: 'Add, rename or retire how the shop takes money',
    icon: Icons.credit_card_outlined,
    route: Routes.paymentMethods,
  ),
  ManagementEntry(
    label: 'Receipt',
    description: 'Footer picture, VAT registration, delivery fee',
    icon: Icons.receipt_outlined,
    route: Routes.receiptSettings,
  ),
  ManagementEntry(
    label: 'Who can sign in',
    description: 'You, your barista, and what each of you sees',
    icon: Icons.badge_outlined,
    route: Routes.staff,
  ),
  ManagementEntry(
    label: 'Settings',
    description: 'Business name, trading day, costing method',
    icon: Icons.settings_outlined,
    route: Routes.settings,
  ),
  ManagementEntry(
    label: 'Backup',
    description: 'Create, verify and restore backups',
    icon: Icons.backup_outlined,
    route: Routes.backup,
  ),
];

class ManagementHomeScreen extends ConsumerWidget {
  const ManagementHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final String businessName = ref
        .watch(settingsControllerProvider)
        .businessName;
    final bool compact = context.formFactor.isCompact;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Management'),
        leading: compact
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back to POS',
                onPressed: () => context.go(Routes.pos),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              0,
              KuboSpacing.lg,
              KuboSpacing.md,
            ),
            child: Text(businessName, style: theme.textTheme.headlineSmall),
          ),
          const SectionHeader('Sections'),
          for (final ManagementEntry entry in managementEntries)
            _EntryTile(entry: entry),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final ManagementEntry entry;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(entry.icon),
      title: Text(entry.label),
      subtitle: Text(entry.description),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.go(entry.route),
    );
  }
}
