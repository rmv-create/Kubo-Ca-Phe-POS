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

  /// The highest order number already rung up, or zero on a shop that has
  /// not sold anything.
  ///
  /// The counter can be moved on at any time, but never back: a start at or
  /// below this would hand a second receipt a number that is already taken.
  /// It used to be locked outright after the first sale, which left her
  /// unable to set it at all — and unable to tidy it up after an evening of
  /// practice orders.
  int _highestSoFar = 0;

  Future<void> _checkHighest() async {
    final int highest = await ref
        .read(salesServiceProvider)
        .highestOrderSequence();
    if (mounted) setState(() => _highestSoFar = highest);
  }

  /// Typed settings used to save only when she pressed the keyboard's done
  /// key. Typing 1111 and tapping away looked as though it had been taken,
  /// and then the screen came back saying 1001, because nothing had been
  /// written at all. Leaving a field now saves it, the same as finishing it.
  late final FocusNode _nameFocus;
  late final FocusNode _prefixFocus;
  late final FocusNode _startFocus;

  @override
  void initState() {
    super.initState();
    final BusinessSettings settings = ref.read(settingsControllerProvider);
    _nameController = TextEditingController(text: settings.businessName);
    _prefixController = TextEditingController(text: settings.orderNumberPrefix);
    _startController = TextEditingController(
      text: '${settings.orderNumberStart}',
    );
    _nameFocus = FocusNode()..addListener(_onNameLeft);
    _prefixFocus = FocusNode()..addListener(_onPrefixLeft);
    _startFocus = FocusNode()..addListener(_onStartLeft);
    unawaited(_checkHighest());
  }

  void _onNameLeft() {
    if (_nameFocus.hasFocus) return;
    _saveName(_nameController.text);
  }

  void _onPrefixLeft() {
    if (_prefixFocus.hasFocus) return;
    _savePrefix(_prefixController.text);
  }

  void _onStartLeft() {
    if (_startFocus.hasFocus) return;
    unawaited(_saveStart(_startController.text));
  }

  void _saveName(String value) {
    final BusinessSettings settings = ref.read(settingsControllerProvider);
    final String name = value.trim();
    if (name.isEmpty || name == settings.businessName) return;
    unawaited(_save(settings.copyWith(businessName: name)));
  }

  void _savePrefix(String value) {
    final BusinessSettings settings = ref.read(settingsControllerProvider);
    final String prefix = value.trim();
    if (prefix == settings.orderNumberPrefix) return;
    unawaited(_save(settings.copyWith(orderNumberPrefix: prefix)));
  }

  /// The counter can be moved on at any time, but never back onto a number
  /// that is already on a receipt.
  Future<void> _saveStart(String value) async {
    final BusinessSettings settings = ref.read(settingsControllerProvider);
    final int? start = int.tryParse(value.trim());
    if (start == settings.orderNumberStart) return;
    if (start == null || start < 1) {
      _say('That is not a number the counter can start at.');
      _startController.text = '${settings.orderNumberStart}';
      return;
    }
    if (start <= _highestSoFar) {
      _say(
        'Order $_highestSoFar has already been used. The counter can go to '
        '${_highestSoFar + 1} or higher.',
      );
      _startController.text = '${settings.orderNumberStart}';
      return;
    }
    await _save(settings.copyWith(orderNumberStart: start));
  }

  @override
  void dispose() {
    // The listeners read the controllers, so they go first.
    _nameFocus
      ..removeListener(_onNameLeft)
      ..dispose();
    _prefixFocus
      ..removeListener(_onPrefixLeft)
      ..dispose();
    _startFocus
      ..removeListener(_onStartLeft)
      ..dispose();
    _nameController.dispose();
    _prefixController.dispose();
    _startController.dispose();
    super.dispose();
  }

  /// Tells her why something was not saved, in the same place a save is
  /// confirmed.
  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
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
              focusNode: _nameFocus,
              textInputAction: TextInputAction.done,
              onSubmitted: _saveName,
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
              focusNode: _prefixFocus,
              textInputAction: TextInputAction.done,
              onSubmitted: _savePrefix,
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
              decoration: InputDecoration(
                labelText: 'Next order number',
                helperText: _highestSoFar == 0
                    ? 'Where the counter starts.'
                    : 'Where the counter goes next. It can be moved on, '
                          'never back \u2014 ${_highestSoFar + 1} or higher, '
                          'so no two receipts share a number.',
              ),
              focusNode: _startFocus,
              textInputAction: TextInputAction.done,
              onSubmitted: (String value) => unawaited(_saveStart(value)),
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
