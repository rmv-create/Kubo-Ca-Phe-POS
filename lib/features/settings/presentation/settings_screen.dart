import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../shared/widgets/section_header.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _prefixController;
  late final TextEditingController _startController;

  /// The first number can only be chosen before the first sale: changing it
  /// afterwards would give two receipts the same number.
  bool _hasSold = true;

  Future<void> _checkIfSold() async {
    final bool sold =
        (await ref.read(salesServiceProvider).orders(limit: 1)).isNotEmpty;
    if (mounted) setState(() => _hasSold = sold);
  }

  @override
  void initState() {
    super.initState();
    final BusinessSettings settings = ref.read(settingsControllerProvider);
    _nameController = TextEditingController(text: settings.businessName);
    _prefixController = TextEditingController(text: settings.orderNumberPrefix);
    _startController = TextEditingController(
      text: '${settings.orderNumberStart}',
    );
    unawaited(_checkIfSold());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _prefixController.dispose();
    _startController.dispose();
    super.dispose();
  }

  Future<void> _save(BusinessSettings next) async {
    await ref.read(settingsControllerProvider.notifier).update(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Settings saved')));
  }

  @override
  Widget build(BuildContext context) {
    final BusinessSettings settings = ref.watch(settingsControllerProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
        children: <Widget>[
          const SectionHeader('Business'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Business name',
                helperText: 'Shown in the app and on every report and export',
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (String value) =>
                  _save(settings.copyWith(businessName: value.trim())),
            ),
          ),
          const SizedBox(height: KuboSpacing.md),
          ListTile(
            leading: const Icon(Icons.payments_outlined),
            title: const Text('Currency'),
            subtitle: Text(
              '${settings.currencyCode} · ${settings.currencySymbol} · 2 decimal places',
            ),
            trailing: Text('Fixed in V1', style: theme.textTheme.labelSmall),
          ),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('Trading day starts at'),
            subtitle: Text(
              '${settings.businessDayCutoffHour.toString().padLeft(2, '0')}:00 — '
              'a sale before this hour counts towards the previous day',
            ),
            trailing: DropdownButton<int>(
              value: settings.businessDayCutoffHour,
              underline: const SizedBox.shrink(),
              items: <DropdownMenuItem<int>>[
                for (int hour = 0; hour <= 11; hour++)
                  DropdownMenuItem<int>(
                    value: hour,
                    child: Text('${hour.toString().padLeft(2, '0')}:00'),
                  ),
              ],
              onChanged: (int? hour) {
                if (hour == null) return;
                unawaited(
                  _save(settings.copyWith(businessDayCutoffHour: hour)),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              KuboSpacing.sm,
              KuboSpacing.lg,
              0,
            ),
            child: TextField(
              controller: _prefixController,
              decoration: const InputDecoration(
                labelText: 'Order number prefix',
                helperText:
                    'Optional, e.g. KUBO — order numbers become KUBO-1001',
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (String value) =>
                  _save(settings.copyWith(orderNumberPrefix: value.trim())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              KuboSpacing.sm,
              KuboSpacing.lg,
              0,
            ),
            child: TextField(
              controller: _startController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'First order number',
                helperText:
                    'Where the counter starts. Fixed once you have '
                    'rung something up.',
              ),
              enabled: !_hasSold,
              textInputAction: TextInputAction.done,
              onSubmitted: (String value) {
                final int? start = int.tryParse(value.trim());
                if (start == null || start < 1) return;
                _save(settings.copyWith(orderNumberStart: start));
              },
            ),
          ),
          const SectionHeader('Costing'),
          RadioGroup<CostingMethod>(
            groupValue: settings.costingMethod,
            onChanged: (CostingMethod? method) {
              if (method == null) return;
              unawaited(_save(settings.copyWith(costingMethod: method)));
            },
            child: const Column(
              children: <Widget>[
                RadioListTile<CostingMethod>(
                  value: CostingMethod.latestCost,
                  title: Text('Latest cost'),
                  subtitle: Text(
                    'What it would cost to replace what the drink used — '
                    'the most recent price paid',
                  ),
                ),
                RadioListTile<CostingMethod>(
                  value: CostingMethod.weightedAverage,
                  title: Text('Weighted average'),
                  subtitle: Text(
                    'What the stock on the shelf cost — 6 L at ₱125 with 10 '
                    'more at ₱115 is ₱118.75 a litre',
                  ),
                ),
              ],
            ),
          ),
          const SectionHeader('Alerts'),
          SwitchListTile(
            value: settings.lowStockAlertsEnabled,
            title: const Text('Low and critical stock alerts'),
            subtitle: const Text('Warn when an ingredient runs down'),
            onChanged: (bool value) => unawaited(
              _save(settings.copyWith(lowStockAlertsEnabled: value)),
            ),
          ),
          const SectionHeader('Backup'),
          SwitchListTile(
            value: settings.autoBackupDaily,
            title: const Text('Automatic daily backup'),
            subtitle: const Text('One backup on the first use of each day'),
            onChanged: (bool value) =>
                unawaited(_save(settings.copyWith(autoBackupDaily: value))),
          ),
          ListTile(
            leading: const Icon(Icons.history_outlined),
            title: const Text('Backups kept'),
            subtitle: const Text(
              'Older ones are pruned, but the last backup and any taken before '
              'an upgrade are always kept',
            ),
            trailing: DropdownButton<int>(
              value: settings.backupRetentionCount,
              underline: const SizedBox.shrink(),
              items: const <DropdownMenuItem<int>>[
                DropdownMenuItem<int>(value: 7, child: Text('7')),
                DropdownMenuItem<int>(value: 14, child: Text('14')),
                DropdownMenuItem<int>(value: 30, child: Text('30')),
                DropdownMenuItem<int>(value: 60, child: Text('60')),
              ],
              onChanged: (int? value) => value == null
                  ? null
                  : unawaited(
                      _save(settings.copyWith(backupRetentionCount: value)),
                    ),
            ),
          ),
          const SectionHeader('Not in this version'),
          ListTile(
            leading: const Icon(Icons.percent_outlined),
            title: const Text('Discounts'),
            subtitle: const Text(
              'The database supports discounts, but they are switched off in '
              'V1 and the POS shows no discount control',
            ),
            trailing: Text('Off', style: theme.textTheme.labelSmall),
            enabled: false,
          ),
        ],
      ),
    );
  }
}
