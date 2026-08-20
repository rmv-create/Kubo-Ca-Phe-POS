import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/menu.dart';
import '../../../domain/repositories/menu_repository.dart';
import '../../../shared/widgets/async_view.dart';
import '../state/menu_actions.dart';

/// Sizes are data, so a third size can be added the day it is needed.
///
/// The customer-facing name and the physical volume are edited separately
/// because they do different jobs: the name is the button, the volume drives
/// recipes and reporting.
class SizesScreen extends ConsumerWidget {
  const SizesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DrinkSize>> sizes = ref.watch(sizesProvider);
    final MenuRepository repo = ref.watch(menuRepositoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sizes'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add size',
            onPressed: () => _addSize(context, ref, repo),
          ),
        ],
      ),
      body: AsyncView<List<DrinkSize>>(
        value: sizes,
        onRetry: () => ref.invalidate(sizesProvider),
        builder: (BuildContext context, List<DrinkSize> data) => ListView(
          padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(KuboSpacing.lg),
              child: Text(
                'Every drink can be priced separately at each size, and each '
                'size gets its own recipe — a Grande is never a Small times '
                'two.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final DrinkSize size in data)
              ListTile(
                leading: const Icon(Icons.local_drink_outlined),
                title: Text(size.name),
                subtitle: Text(
                  size.isActive
                      ? size.volumeLabel
                      : '${size.volumeLabel} · hidden from the POS',
                ),
                trailing: Switch(
                  value: size.isActive,
                  onChanged: (bool value) => runMenuEdit(
                    context,
                    ref,
                    () => repo.updateSize(size.copyWith(isActive: value)),
                  ),
                ),
                onTap: () => _editSize(context, ref, repo, size),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _addSize(
    BuildContext context,
    WidgetRef ref,
    MenuRepository repo,
  ) async {
    final String? name = await promptForText(
      context,
      title: 'New size',
      label: 'Size name',
      helper: 'What the customer calls it, e.g. Grande',
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;

    final String? oz = await promptForText(
      context,
      title: 'How big is a $name?',
      label: 'Volume in ounces',
      helper: 'Used for recipes and reporting',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    if (oz == null || !context.mounted) return;
    final double? volume = double.tryParse(oz.trim());
    if (volume == null || volume <= 0) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Enter the volume in ounces, e.g. 16')),
        );
      return;
    }

    await runMenuEdit(
      context,
      ref,
      () => repo.createSize(
        code: name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_'),
        name: name,
        volumeOz: volume,
      ),
      successMessage: 'Size added',
    );
  }

  Future<void> _editSize(
    BuildContext context,
    WidgetRef ref,
    MenuRepository repo,
    DrinkSize size,
  ) async {
    final String? name = await promptForText(
      context,
      title: 'Rename size',
      label: 'Size name',
      initial: size.name,
    );
    if (name == null || !context.mounted) return;

    final String? oz = await promptForText(
      context,
      title: 'Volume',
      label: 'Ounces',
      initial: size.volumeOz.toString(),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    if (oz == null || !context.mounted) return;
    final double volume = double.tryParse(oz.trim()) ?? size.volumeOz;

    await runMenuEdit(
      context,
      ref,
      () => repo.updateSize(size.copyWith(name: name, volumeOz: volume)),
      successMessage: 'Size updated',
    );
  }
}
