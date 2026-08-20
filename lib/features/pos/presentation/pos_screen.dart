import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/responsive/form_factor.dart';
import '../../../app/router.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/customer.dart';
import '../../../domain/entities/menu.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/kubo_mark.dart';
import '../../../shared/widgets/section_header.dart';
import '../state/cart_controller.dart';
import 'customer_sheet.dart';
import 'order_pane.dart';
import 'payment_block.dart';
import 'product_config_sheet.dart';

/// Which category is showing. Kept outside the widget so switching layouts —
/// rotating an iPad — does not reset it.
final NotifierProvider<SelectedCategory, int?> selectedCategoryProvider =
    NotifierProvider<SelectedCategory, int?>(SelectedCategory.new);

class SelectedCategory extends Notifier<int?> {
  @override
  int? build() => null;

  void select(int? id) => state = id;
}

/// The order screen. This is the app.
class PosScreen extends ConsumerWidget {
  const PosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ResponsiveBuilder(
    compact: (BuildContext context) => const _CompactPos(),
    medium: (BuildContext context) => const _WidePos(threePane: false),
    expanded: (BuildContext context) => const _WidePos(threePane: true),
  );
}

// ─────────────────────────────── iPhone ───────────────────────────────

/// One column. The drink grid is the only thing that scrolls; the total and
/// COMPLETE ORDER never move.
class _CompactPos extends StatelessWidget {
  const _CompactPos();

  @override
  Widget build(BuildContext context) => const SafeArea(
    bottom: false,
    child: Column(
      children: <Widget>[
        _PosHeader(),
        _CustomerStrip(),
        Expanded(child: _MenuPane()),
        _BottomBar(),
      ],
    ),
  );
}

// ─────────────────────────────── iPad ───────────────────────────────

/// Landscape gets three panes, so a whole order happens without one sheet or
/// navigation. Portrait drops the middle pane rather than squeezing three.
class _WidePos extends ConsumerWidget {
  const _WidePos({required this.threePane});

  final bool threePane;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: Column(
        children: <Widget>[
          const _PosHeader(),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  flex: threePane ? 4 : 6,
                  child: const Column(
                    children: <Widget>[
                      _CustomerStrip(),
                      Expanded(child: _MenuPane()),
                    ],
                  ),
                ),
                if (threePane) ...<Widget>[
                  const VerticalDivider(width: 1),
                  const Expanded(flex: 4, child: _ConfigurePane()),
                ],
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 340,
                  child: Container(
                    color: theme.colorScheme.surfaceContainerLow,
                    child: const Column(
                      children: <Widget>[
                        SectionHeader('Current order'),
                        Expanded(child: OrderLines()),
                        Divider(height: 1),
                        Padding(
                          padding: EdgeInsets.all(KuboSpacing.lg),
                          child: PaymentBlock(showOrderButton: false),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// iPad landscape only: the drink being configured, in place of a sheet.
class _ConfigurePane extends ConsumerWidget {
  const _ConfigurePane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Product? product = ref.watch(_configuringProductProvider);
    if (product == null) {
      final ThemeData theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionHeader('Configure'),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(KuboSpacing.xl),
                child: Text(
                  'Pick a drink to choose its size and options.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return ProductConfigSheet(key: ValueKey<int>(product.id), product: product);
  }
}

/// The drink open in the iPad configuration pane.
final NotifierProvider<ConfiguringProduct, Product?>
_configuringProductProvider = NotifierProvider<ConfiguringProduct, Product?>(
  ConfiguringProduct.new,
);

class ConfiguringProduct extends Notifier<Product?> {
  @override
  Product? build() => null;

  void select(Product? product) => state = product;
}

// ─────────────────────────────── pieces ───────────────────────────────

class _PosHeader extends ConsumerWidget {
  const _PosHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String businessName = ref
        .watch(settingsControllerProvider)
        .businessName;
    final bool compact = context.formFactor.isCompact;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        KuboSpacing.md,
        KuboSpacing.sm,
        KuboSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: KuboWordmark(
              businessName: businessName,
              subtitle: 'New order',
            ),
          ),
          if (compact)
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Management',
              onPressed: () => context.go(Routes.manage),
            ),
        ],
      ),
    );
  }
}

/// Optional, and always skippable.
class _CustomerStrip extends ConsumerWidget {
  const _CustomerStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Customer? customer = ref.watch(cartProvider).customer;
    final bool showName = ref
        .watch(settingsControllerProvider)
        .showCustomerName;

    return InkWell(
      onTap: () => CustomerSheet.show(context),
      child: Container(
        margin: const EdgeInsets.fromLTRB(
          KuboSpacing.lg,
          0,
          KuboSpacing.lg,
          KuboSpacing.md,
        ),
        padding: const EdgeInsets.all(KuboSpacing.md),
        decoration: BoxDecoration(
          color: customer == null
              ? theme.colorScheme.surfaceContainer
              : theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(KuboRadius.lg),
          border: Border.all(
            color: customer == null
                ? theme.colorScheme.outline
                : theme.colorScheme.primary,
          ),
        ),
        child: Row(
          children: <Widget>[
            CircleAvatar(
              radius: 18,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: customer == null
                  ? Icon(
                      Icons.person_outline,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    )
                  : Text(customer.initials, style: theme.textTheme.labelMedium),
            ),
            const SizedBox(width: KuboSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    customer == null || !showName ? 'Guest' : customer.name,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    customer == null
                        ? 'Search or add a customer'
                        : '${customer.visitCount} '
                              'visit${customer.visitCount == 1 ? '' : 's'} · '
                              'tap to change',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (customer != null)
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Continue as guest',
                onPressed: () =>
                    ref.read(cartProvider.notifier).setCustomer(null),
              )
            else
              const Icon(Icons.search),
          ],
        ),
      ),
    );
  }
}

class _MenuPane extends ConsumerWidget {
  const _MenuPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<MenuSnapshot> menu = ref.watch(menuProvider);

    return AsyncView<MenuSnapshot>(
      value: menu,
      onRetry: () => ref.invalidate(menuProvider),
      builder: (BuildContext context, MenuSnapshot data) {
        final List<ProductCategory> categories = data.sellableCategories;
        if (categories.isEmpty) {
          return EmptyState(
            icon: Icons.local_cafe_outlined,
            title: 'No drinks on the menu',
            message: 'Add drinks and prices in Management → Menu.',
            action: FilledButton(
              onPressed: () => context.go(Routes.menu),
              child: const Text('Open the menu'),
            ),
          );
        }

        final int? selected = ref.watch(selectedCategoryProvider);
        final ProductCategory active = categories.firstWhere(
          (ProductCategory c) => c.id == selected,
          orElse: () => categories.first,
        );
        final List<Product> products = data.sellableIn(active.id);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: KuboTouch.chip + KuboSpacing.md,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
                itemCount: categories.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: KuboSpacing.sm),
                itemBuilder: (BuildContext context, int index) {
                  final ProductCategory category = categories[index];
                  return Center(
                    child: ChoiceChip(
                      label: Text(category.name.toUpperCase()),
                      selected: category.id == active.id,
                      onSelected: (_) => ref
                          .read(selectedCategoryProvider.notifier)
                          .select(category.id),
                    ),
                  );
                },
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(
                  KuboSpacing.lg,
                  0,
                  KuboSpacing.lg,
                  KuboSpacing.lg,
                ),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 260,
                  mainAxisSpacing: KuboSpacing.sm,
                  crossAxisSpacing: KuboSpacing.sm,
                  mainAxisExtent: context.formFactor.isCompact
                      ? 108
                      : KuboTouch.productTile,
                ),
                itemCount: products.length,
                itemBuilder: (BuildContext context, int index) =>
                    _ProductTile(product: products[index]),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ProductTile extends ConsumerWidget {
  const _ProductTile({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ProductSize? defaultSize = product.defaultSize;

    return InkWell(
      borderRadius: BorderRadius.circular(KuboRadius.lg),
      onTap: () {
        // On iPad the configuration pane is already on screen, so opening a
        // sheet over it would be a step backwards.
        if (context.formFactor.isExpanded) {
          ref.read(_configuringProductProvider.notifier).select(product);
        } else {
          ProductConfigSheet.show(context, product: product);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(KuboSpacing.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(KuboRadius.lg),
          border: Border.all(color: theme.colorScheme.outline, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Text(
                product.name.toUpperCase(),
                style: theme.textTheme.titleSmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: KuboSpacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: Text(
                    defaultSize == null
                        ? ''
                        : '${defaultSize.size.name} ${defaultSize.size.volumeLabel}',
                    style: theme.textTheme.labelMedium,
                    // One line, always: a wrapping label used to push the
                    // price out of the tile.
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // The price of the size named beside it — the one that is
                // pre-selected when the tile is tapped. Showing the cheapest
                // size's price under the default size's name reads as a lie.
                Text(
                  defaultSize?.price.format() ?? '',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: const SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            KuboSpacing.lg,
            KuboSpacing.md,
            KuboSpacing.lg,
            KuboSpacing.md,
          ),
          child: PaymentBlock(),
        ),
      ),
    );
  }
}
