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
import '../state/menu_actions.dart';

class CustomisationsScreen extends ConsumerWidget {
  const CustomisationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<CustomizationGroup>> groups = ref.watch(
      customizationGroupsProvider,
    );
    final MenuRepository repo = ref.watch(menuRepositoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Customisations'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add group',
            onPressed: () async {
              final String? name = await promptForText(
                context,
                title: 'New group',
                label: 'Group name',
                helper: 'A set of related choices, like Milk or Syrup',
              );
              if (name == null || name.trim().isEmpty || !context.mounted) {
                return;
              }
              await runMenuEdit(
                context,
                ref,
                () => repo.createCustomizationGroup(
                  code: name.trim().toLowerCase().replaceAll(
                    RegExp(r'[^a-z0-9]+'),
                    '_',
                  ),
                  name: name,
                  selectionType: SelectionType.single,
                  isRequired: false,
                  isProactive: false,
                ),
                successMessage: 'Group added',
              );
            },
          ),
        ],
      ),
      body: AsyncView<List<CustomizationGroup>>(
        value: groups,
        onRetry: () => ref.invalidate(customizationGroupsProvider),
        builder: (BuildContext context, List<CustomizationGroup> data) {
          if (data.isEmpty) {
            return const EmptyState(
              icon: Icons.tune_outlined,
              title: 'No customisations yet',
              message: 'Add a group like Milk, then add the choices in it.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(KuboSpacing.lg),
                child: Text(
                  'Groups are shared across drinks. Which drink offers which '
                  'group is set on the drink itself.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final CustomizationGroup group in data)
                ListTile(
                  leading: Icon(
                    group.selectionType == SelectionType.single
                        ? Icons.radio_button_checked
                        : Icons.checklist,
                  ),
                  title: Text(group.name),
                  subtitle: Text(_summary(group)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      context.go('${Routes.menuCustomisations}/${group.id}'),
                ),
            ],
          );
        },
      ),
    );
  }

  static String _summary(CustomizationGroup group) {
    final int active = group.activeOptions.length;
    final int hidden = group.options.length - active;
    return <String>[
      group.selectionType.label,
      '$active choice${active == 1 ? '' : 's'}',
      if (hidden > 0) '$hidden off',
      if (group.isRequired) 'required',
      group.isProactive ? 'asked every time' : 'only if asked',
      if (!group.isActive) 'group switched off',
    ].join(' · ');
  }
}

/// One group and the choices inside it.
class CustomizationGroupScreen extends ConsumerWidget {
  const CustomizationGroupScreen({required this.groupId, super.key});

  final int groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<CustomizationGroup>> groups = ref.watch(
      customizationGroupsProvider,
    );
    final MenuRepository repo = ref.watch(menuRepositoryProvider);

    return AsyncView<List<CustomizationGroup>>(
      value: groups,
      onRetry: () => ref.invalidate(customizationGroupsProvider),
      builder: (BuildContext context, List<CustomizationGroup> data) {
        final CustomizationGroup? group = data
            .where((CustomizationGroup g) => g.id == groupId)
            .firstOrNull;
        if (group == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.search_off,
              title: 'Group not found',
              message: 'It may have been deleted.',
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(group.name),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Add choice',
                onPressed: () => _addOption(context, ref, repo, group),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              SwitchListTile(
                value: group.selectionType == SelectionType.multi,
                title: const Text('Customer can pick more than one'),
                subtitle: Text(
                  group.selectionType == SelectionType.multi
                      ? 'Any number of these can be added together'
                      : 'Only one of these at a time',
                ),
                onChanged: (bool value) => runMenuEdit(
                  context,
                  ref,
                  () => repo.updateCustomizationGroup(
                    group.copyWith(
                      selectionType: value
                          ? SelectionType.multi
                          : SelectionType.single,
                      maxSelect: value ? null : 1,
                      clearMaxSelect: value,
                    ),
                  ),
                ),
              ),
              SwitchListTile(
                value: group.isRequired,
                title: const Text('A choice is required'),
                subtitle: const Text(
                  'The drink cannot be added until one is picked',
                ),
                onChanged: (bool value) => runMenuEdit(
                  context,
                  ref,
                  () => repo.updateCustomizationGroup(
                    group.copyWith(isRequired: value),
                  ),
                ),
              ),
              SwitchListTile(
                value: group.isProactive,
                title: const Text('Ask every time'),
                subtitle: const Text(
                  'Off keeps orders fast: it folds behind More options and '
                  'the default applies',
                ),
                onChanged: (bool value) => runMenuEdit(
                  context,
                  ref,
                  () => repo.updateCustomizationGroup(
                    group.copyWith(isProactive: value),
                  ),
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  KuboSpacing.lg,
                  KuboSpacing.lg,
                  KuboSpacing.lg,
                  KuboSpacing.sm,
                ),
                child: Text(
                  'CHOICES',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              for (final CustomizationOption option in group.options)
                _OptionTile(option: option),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addOption(
    BuildContext context,
    WidgetRef ref,
    MenuRepository repo,
    CustomizationGroup group,
  ) async {
    final String? name = await promptForText(
      context,
      title: 'New choice in ${group.name}',
      label: 'Choice name',
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;

    final String? raw = await promptForText(
      context,
      title: 'What does $name add?',
      label: 'Extra charge in pesos',
      initial: '0',
      helper: 'Enter 0 if it is free',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    if (raw == null || !context.mounted) return;
    final Money? delta = Money.tryParse(raw);
    if (delta == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Enter an amount like 20 or 0')),
        );
      return;
    }

    await runMenuEdit(
      context,
      ref,
      () => repo.createCustomizationOption(
        groupId: group.id,
        name: name,
        priceDeltaCentavos: delta.centavos,
      ),
      successMessage: 'Choice added',
    );
  }
}

class _OptionTile extends ConsumerWidget {
  const _OptionTile({required this.option});

  final CustomizationOption option;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MenuRepository repo = ref.watch(menuRepositoryProvider);
    final ThemeData theme = Theme.of(context);

    return ListTile(
      title: Text(option.name),
      subtitle: Text(
        <String>[
          option.priceDelta.isZero
              ? 'Free'
              : 'Adds ${option.priceDelta.format()}',
          if (option.description != null) option.description!,
          if (!option.isActive) 'Not currently offered',
        ].join(' · '),
        style: option.description != null
            ? theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              )
            : null,
      ),
      trailing: Switch(
        value: option.isActive,
        onChanged: (bool value) => runMenuEdit(
          context,
          ref,
          () =>
              repo.updateCustomizationOption(option.copyWith(isActive: value)),
        ),
      ),
      onTap: () async {
        final String? raw = await promptForText(
          context,
          title: option.name,
          label: 'Extra charge in pesos',
          initial: option.priceDelta.toPlainString(),
          helper: 'Enter 0 if it is free',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        );
        if (raw == null || !context.mounted) return;
        final Money? delta = Money.tryParse(raw);
        if (delta == null) return;
        await runMenuEdit(
          context,
          ref,
          () => repo.updateCustomizationOption(
            option.copyWith(
              priceDelta: delta,
              // Once she sets a price, the "not set yet" note is gone.
              description: '',
            ),
          ),
          successMessage: '${option.name} · ${delta.format()}',
        );
      },
    );
  }
}
