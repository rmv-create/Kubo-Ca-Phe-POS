import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/menu.dart';
import '../../../domain/repositories/menu_repository.dart';
import '../../../shared/widgets/async_view.dart';
import '../state/menu_actions.dart';

class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ProductCategory>> categories = ref.watch(
      categoriesProvider,
    );
    final MenuRepository repo = ref.watch(menuRepositoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Categories'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add category',
            onPressed: () async {
              final String? name = await promptForText(
                context,
                title: 'New category',
                label: 'Category name',
                helper: 'A section of the menu, like Classics',
              );
              if (name == null || !context.mounted) return;
              await runMenuEdit(
                context,
                ref,
                () => repo.createCategory(name: name),
                successMessage: 'Category added',
              );
            },
          ),
        ],
      ),
      body: AsyncView<List<ProductCategory>>(
        value: categories,
        onRetry: () => ref.invalidate(categoriesProvider),
        builder: (BuildContext context, List<ProductCategory> data) {
          if (data.isEmpty) {
            return const EmptyState(
              icon: Icons.folder_outlined,
              title: 'No categories yet',
              message: 'Add one to start building the menu.',
            );
          }
          return Column(
            children: <Widget>[
              const _DragHint(what: 'categories'),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
                  itemCount: data.length,
                  // onReorderItem already accounts for the removed item, so
                  // no index adjustment is needed here.
                  onReorderItem: (int oldIndex, int newIndex) async {
                    final List<ProductCategory> next = List<ProductCategory>.of(
                      data,
                    );
                    next.insert(newIndex, next.removeAt(oldIndex));
                    await runMenuEdit(
                      context,
                      ref,
                      () => repo.reorderCategories(
                        next.map((ProductCategory c) => c.id).toList(),
                      ),
                    );
                  },
                  itemBuilder: (BuildContext context, int index) {
                    final ProductCategory category = data[index];
                    return _CategoryTile(
                      key: ValueKey<int>(category.id),
                      category: category,
                      index: index,
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CategoryTile extends ConsumerWidget {
  const _CategoryTile({required this.category, required this.index, super.key});

  final ProductCategory category;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MenuRepository repo = ref.watch(menuRepositoryProvider);
    return ListTile(
      leading: ReorderableDragStartListener(
        index: index,
        child: const Icon(Icons.drag_handle),
      ),
      title: Text(category.name),
      subtitle: category.isActive ? null : const Text('Hidden from the POS'),
      trailing: Switch(
        value: category.isActive,
        onChanged: (bool value) => runMenuEdit(
          context,
          ref,
          () => repo.updateCategory(category.copyWith(isActive: value)),
        ),
      ),
      onTap: () async {
        final String? name = await promptForText(
          context,
          title: 'Rename category',
          label: 'Category name',
          initial: category.name,
        );
        if (name == null || !context.mounted) return;
        await runMenuEdit(
          context,
          ref,
          () => repo.updateCategory(category.copyWith(name: name)),
          successMessage: 'Renamed',
        );
      },
    );
  }
}

class _DragHint extends StatelessWidget {
  const _DragHint({required this.what});

  final String what;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      KuboSpacing.lg,
      KuboSpacing.md,
      KuboSpacing.lg,
      KuboSpacing.sm,
    ),
    child: Text(
      'Tap to rename. Drag the handle to change the order they appear in '
      'on the POS. The switch hides $what without deleting anything.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}
