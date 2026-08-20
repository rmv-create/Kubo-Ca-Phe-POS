import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../domain/entities/menu.dart';
import '../../../domain/repositories/menu_repository.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/widgets/section_header.dart';
import '../state/menu_actions.dart';

class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<MenuSnapshot> menu = ref.watch(fullMenuProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Drinks'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add drink',
            onPressed: () => _addProduct(context, ref),
          ),
        ],
      ),
      body: AsyncView<MenuSnapshot>(
        value: menu,
        onRetry: () => ref.invalidate(fullMenuProvider),
        builder: (BuildContext context, MenuSnapshot data) {
          if (data.categories.isEmpty) {
            return const EmptyState(
              icon: Icons.folder_outlined,
              title: 'Add a category first',
              message: 'Every drink belongs to a section of the menu.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              for (final ProductCategory category
                  in data.categories) ...<Widget>[
                SectionHeader(category.name),
                ...(data.productsByCategory[category.id] ?? const <Product>[])
                    .map((Product p) => _ProductTile(product: p)),
                if ((data.productsByCategory[category.id] ?? const <Product>[])
                    .isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      KuboSpacing.lg,
                      0,
                      KuboSpacing.lg,
                      KuboSpacing.md,
                    ),
                    child: Text(
                      'Nothing in this category yet.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _addProduct(BuildContext context, WidgetRef ref) async {
    final MenuRepository repo = ref.read(menuRepositoryProvider);
    final List<ProductCategory> categories = await repo.categories();
    if (categories.isEmpty || !context.mounted) return;

    final ProductCategory? category = categories.length == 1
        ? categories.first
        : await showDialog<ProductCategory>(
            context: context,
            builder: (BuildContext context) => SimpleDialog(
              title: const Text('Which category?'),
              children: <Widget>[
                for (final ProductCategory c in categories)
                  SimpleDialogOption(
                    onPressed: () => Navigator.of(context).pop(c),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(c.name),
                    ),
                  ),
              ],
            ),
          );
    if (category == null || !context.mounted) return;

    final String? name = await promptForText(
      context,
      title: 'New drink',
      label: 'Drink name',
      helper: 'Exactly as it should read on the POS',
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;

    late int newId;
    final bool ok = await runMenuEdit(context, ref, () async {
      newId = await repo.createProduct(categoryId: category.id, name: name);
    });
    if (ok && context.mounted) {
      context.go('${Routes.menuProducts}/$newId');
    }
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<ProductSize> sizes = product.sizes;
    final Money? lowest = product.lowestPrice;

    return ListTile(
      title: Row(
        children: <Widget>[
          Flexible(child: Text(product.name)),
          if (product.isArchived) ...<Widget>[
            const SizedBox(width: KuboSpacing.sm),
            _Tag(label: 'Archived', color: theme.colorScheme.error),
          ] else if (!product.isActive) ...<Widget>[
            const SizedBox(width: KuboSpacing.sm),
            _Tag(label: 'Hidden', color: theme.colorScheme.onSurfaceVariant),
          ],
        ],
      ),
      subtitle: Text(
        sizes.isEmpty
            ? 'No sizes or prices yet'
            : sizes
                  .map(
                    (ProductSize s) =>
                        '${s.size.name} ${s.size.volumeLabel} ${s.price.format()}',
                  )
                  .join('  ·  '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (lowest != null && sizes.length > 1)
            Text('from ', style: theme.textTheme.bodySmall),
          if (lowest != null) MoneyText(lowest),
          const SizedBox(width: KuboSpacing.xs),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => context.go('${Routes.menuProducts}/${product.id}'),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(KuboRadius.pill),
    ),
    child: Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    ),
  );
}
