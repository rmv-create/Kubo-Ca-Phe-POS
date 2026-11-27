import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/responsive/form_factor.dart';
import '../../../app/router.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/customer.dart';
import '../../../domain/entities/menu.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/kubo_mark.dart';
import '../../../shared/widgets/section_header.dart';
import '../../access/presentation/rejoin_sheet.dart';
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
        _NotReachingTheOtherPhone(),
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
          const _NotReachingTheOtherPhone(),
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
    // Which order she is on, before she has committed it. Falls back to the
    // old wording while the number is being read, rather than flashing an
    // empty line where a number is about to be.
    final String? nextNumber = ref.watch(nextOrderNumberProvider).valueOrNull;
    // Changing an order she has already finished: it keeps its own number,
    // and the header says so rather than showing the number of the sale
    // that is not being rung up.
    final OrderDraft draft = ref.watch(cartProvider);
    final String? changing = draft.revisingOrderNo;

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
              subtitle: changing != null
                  ? 'Changing $changing'
                  : nextNumber == null
                  ? 'New order'
                  : 'New order · $nextNumber',
            ),
          ),
          // A way out that does not need her to empty the order by hand.
          if (changing != null)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Leave $changing as it was',
              onPressed: () {
                ref.read(cartProvider.notifier).clear();
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(content: Text('$changing left as it was')),
                  );
              },
            ),
          // Handing the phone to somebody, or putting it down: one tap
          // rather than waiting out the five-minute auto-lock.
          IconButton(
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Lock',
            onPressed: () => ref.read(signedInUserProvider.notifier).signOut(),
          ),
          // His way to the orders, when she has given him leave to put one
          // right. The owner reaches the same list through Manage.
          if (!ref.watch(canManageProvider) &&
              ref.watch(canCorrectOrdersProvider))
            IconButton(
              icon: const Icon(Icons.receipt_long_outlined),
              tooltip: 'Orders',
              onPressed: () => context.go(Routes.orders),
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

/// Says, on the till itself, when this phone's orders are going nowhere.
///
/// What this phone was told the last time it asked to be let in.
///
/// Written as `<when>|<what>`, or missing entirely when it has never
/// asked — which is itself worth saying out loud, because an invite that
/// was never typed and an invite that was refused are different problems
/// and have looked the same from the outside all week.
String _lastAsked(String? raw) {
  if (raw == null || raw.isEmpty) {
    return 'This phone has never asked to be let in.';
  }
  final int bar = raw.indexOf('|');
  if (bar < 0) return raw;
  final DateTime? when = DateTime.tryParse(raw.substring(0, bar))?.toLocal();
  final String what = raw.substring(bar + 1);
  if (when == null) return 'Last asked: $what';
  final String time =
      '${when.hour.toString().padLeft(2, '0')}:'
      '${when.minute.toString().padLeft(2, '0')}';
  return 'Last asked ${when.day}/${when.month} at $time: $what';
}

/// A till is let into the shop by its own sign-in id, and that id lives in
/// the browser's storage: clear the site data or reinstall from the home
/// screen and the phone goes on taking orders while the shop no longer
/// recognises it. Everything queues and nothing leaves.
///
/// That happened, and it was invisible — the only sign was a line on a
/// screen in the management area that nobody had reason to open, while the
/// owner's phone quietly showed three of the day's eight orders. So it is
/// said here, where whoever is serving will see it, and the way out is one
/// tap away.
///
/// It appears only when there is both a problem and something waiting: a
/// till that has simply not synced yet, or has nothing to say, is not a
/// till in trouble.
class _NotReachingTheOtherPhone extends ConsumerWidget {
  const _NotReachingTheOtherPhone();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SyncStanding? standing = ref.watch(syncStandingProvider).valueOrNull;
    if (standing == null || !standing.paired) return const SizedBox.shrink();
    if (standing.problem == null) return const SizedBox.shrink();

    // Something waiting is the plainest sign of trouble, but not the only
    // one: a phone shut out before it has sold anything has nothing queued
    // and is just as cut off. So a round that has been failing for a while,
    // or has never once succeeded, says so too.
    final DateTime? lastAt = standing.lastAt;
    final bool stale =
        lastAt == null ||
        DateTime.now().difference(lastAt) > const Duration(minutes: 15);
    if (standing.waiting == 0 && !stale) return const SizedBox.shrink();

    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        0,
        KuboSpacing.lg,
        KuboSpacing.md,
      ),
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(KuboRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(KuboRadius.lg),
          onTap: () => RejoinSheet.show(context),
          child: Padding(
            padding: const EdgeInsets.all(KuboSpacing.md),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.sync_problem,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: KuboSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        standing.waiting == 0
                            ? 'This phone is not reaching the other one'
                            : 'The other phone is not getting these orders',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                      Text(
                        standing.waiting == 0
                            ? 'Nothing has gone across. Tap to put it right.'
                            : '${standing.waiting} '
                                  '${standing.waiting == 1 ? 'thing is' : 'things are'} '
                                  'waiting to go. Nothing is lost \u2014 tap '
                                  'to put it right.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                      // What the shop actually said, in its own words.
                      // Without it, every report of this is a guessing game
                      // played by three people and a photograph.
                      Text(
                        standing.problem!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      // Whether anybody has actually asked this phone to be
                      // let in, and what it was told. "Never asked" and
                      // "asked and refused" look identical from outside,
                      // and days went into not knowing which this was.
                      const SizedBox(height: KuboSpacing.xs),
                      Text(
                        _lastAsked(standing.lastJoin),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
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
                        : <String>[
                            // Her note comes first, because this line is
                            // how she checks she picked the right James
                            // before the drink is made. It is never on a
                            // receipt — the customer sees their name
                            // and nothing she wrote about them.
                            if (customer.notes != null) customer.notes!,
                            '${customer.visitCount} '
                                'visit${customer.visitCount == 1 ? '' : 's'}',
                            'tap to change',
                          ].join(' · '),
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
