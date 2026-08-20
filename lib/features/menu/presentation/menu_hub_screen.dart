import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../data/db/seed/menu_seed.dart';
import '../../../domain/entities/menu.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/section_header.dart';
import '../state/menu_actions.dart';

/// The way in to everything the owner can change about her menu.
class MenuHubScreen extends ConsumerWidget {
  const MenuHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<MenuSnapshot> menu = ref.watch(fullMenuProvider);
    final bool provisional = ref
        .watch(settingsControllerProvider)
        .pricesProvisional;

    return Scaffold(
      appBar: AppBar(title: const Text('Menu')),
      body: AsyncView<MenuSnapshot>(
        value: menu,
        onRetry: () => ref.invalidate(fullMenuProvider),
        builder: (BuildContext context, MenuSnapshot data) {
          final int drinkCount = data.productsByCategory.values.fold(
            0,
            (int sum, List<Product> p) => sum + p.length,
          );
          return ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              if (provisional) const _ProvisionalPricesBanner(),
              const SectionHeader('Set up'),
              _HubTile(
                icon: Icons.local_cafe_outlined,
                title: 'Drinks',
                subtitle: '$drinkCount on the menu · prices and sizes',
                route: Routes.menuProducts,
              ),
              _HubTile(
                icon: Icons.folder_outlined,
                title: 'Categories',
                subtitle: data.categories
                    .map((ProductCategory c) => c.name)
                    .join(' · '),
                route: Routes.menuCategories,
              ),
              _HubTile(
                icon: Icons.straighten_outlined,
                title: 'Sizes',
                subtitle: data.sizes
                    .map((DrinkSize s) => '${s.name} ${s.volumeLabel}')
                    .join(' · '),
                route: Routes.menuSizes,
              ),
              _HubTile(
                icon: Icons.tune_outlined,
                title: 'Customisations',
                subtitle: data.groups
                    .map((CustomizationGroup g) => g.name)
                    .join(' · '),
                route: Routes.menuCustomisations,
              ),
              if (MenuSeed.unpricedOptions.isNotEmpty)
                const _UnpricedOptionsNote(),
            ],
          );
        },
      ),
    );
  }
}

/// The owner's worksheet said the prices were tentative. Until she says
/// otherwise the app says so too, rather than presenting a guess as settled.
class _ProvisionalPricesBanner extends ConsumerWidget {
  const _ProvisionalPricesBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        KuboSpacing.md,
        KuboSpacing.lg,
        0,
      ),
      padding: const EdgeInsets.all(KuboSpacing.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(KuboRadius.md),
        border: Border(
          left: BorderSide(color: theme.colorScheme.error, width: 3),
          top: BorderSide(
            color: theme.colorScheme.error.withValues(alpha: .25),
          ),
          right: BorderSide(
            color: theme.colorScheme.error.withValues(alpha: .25),
          ),
          bottom: BorderSide(
            color: theme.colorScheme.error.withValues(alpha: .25),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.pending_outlined,
                size: 18,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: KuboSpacing.sm),
              Text(
                'PRICES NOT CONFIRMED',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: KuboSpacing.sm),
          Text(
            'These came from the setup sheet, where they were marked as '
            'tentative. Sales will still be recorded correctly, but check '
            'every price before you rely on the profit figures.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: KuboSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, KuboTouch.minTarget),
                foregroundColor: theme.colorScheme.onErrorContainer,
                side: BorderSide(color: theme.colorScheme.error),
              ),
              onPressed: () async {
                final bool ok = await confirm(
                  context,
                  title: 'Prices confirmed?',
                  message:
                      'This only removes the warning. It does not change any '
                      'price — you can still edit them at any time.',
                  confirmLabel: 'They are correct',
                );
                if (!ok || !context.mounted) return;
                await ref
                    .read(settingsControllerProvider.notifier)
                    .update(
                      ref
                          .read(settingsControllerProvider)
                          .copyWith(pricesProvisional: false),
                    );
              },
              child: const Text('I have checked these'),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnpricedOptionsNote extends StatelessWidget {
  const _UnpricedOptionsNote();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        KuboSpacing.xl,
        KuboSpacing.lg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('STILL NEED A PRICE', style: theme.textTheme.labelSmall),
          const SizedBox(height: KuboSpacing.sm),
          Text(
            'These choices were left blank on the setup sheet, so they are '
            'currently free. Set a price, or leave them free on purpose.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: KuboSpacing.sm),
          for (final String name in MenuSeed.unpricedOptions)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('· $name', style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  const _HubTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String route;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => context.go(route),
  );
}
