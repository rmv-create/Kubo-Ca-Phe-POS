import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/services/activity_log.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/section_header.dart';

/// Everything that has happened, newest first.
///
/// The shop has been writing this down since the first version and nothing
/// ever read it back. It answers "when did that happen, and who did it" —
/// a question an owner starts asking the day somebody else is allowed near
/// the till.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  String? _day;
  bool _notableOnly = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<ActivityEntry>> entries = ref.watch(
      activityProvider(_day),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Everything that happened'),
        actions: <Widget>[
          TextButton(onPressed: _pickDay, child: Text(_day ?? 'All')),
        ],
      ),
      body: AsyncView<List<ActivityEntry>>(
        value: entries,
        builder: (BuildContext context, List<ActivityEntry> all) {
          final List<ActivityEntry> shown = _notableOnly
              ? all.where((ActivityEntry e) => e.isNotable).toList()
              : all;

          return ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxl),
            children: <Widget>[
              SwitchListTile(
                value: _notableOnly,
                title: const Text('Only the things worth noticing'),
                subtitle: const Text(
                  'Voids, refunds, recipe changes and stock counts',
                ),
                onChanged: (bool v) => setState(() => _notableOnly = v),
              ),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(KuboSpacing.lg),
                  child: Text(
                    all.isEmpty
                        ? 'Nothing has happened yet.'
                        : 'Nothing of that kind on this day.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              for (int i = 0; i < shown.length; i++) ...<Widget>[
                if (i == 0 ||
                    shown[i].businessDate != shown[i - 1].businessDate)
                  SectionHeader(shown[i].businessDate),
                ListTile(
                  dense: true,
                  leading: Icon(
                    _icon(shown[i].action),
                    size: 20,
                    color: shown[i].isNotable ? theme.colorScheme.error : null,
                  ),
                  title: Text(shown[i].label),
                  subtitle: Text(shown[i].summary),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        _time(shown[i].at),
                        style: theme.textTheme.bodySmall,
                      ),
                      if (shown[i].actor != null)
                        Text(
                          shown[i].actor!,
                          style: theme.textTheme.labelSmall,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  static String _time(DateTime at) {
    final DateTime local = at.toLocal();
    final String h = local.hour.toString().padLeft(2, '0');
    final String m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static IconData _icon(String action) => switch (action) {
    'order_completed' => Icons.local_cafe_outlined,
    'order_voided' => Icons.block,
    'refund_issued' => Icons.undo,
    'payment_recorded' => Icons.payments_outlined,
    'waste_recorded' => Icons.delete_outline,
    'purchase_recorded' => Icons.local_shipping_outlined,
    'stock_count_applied' => Icons.fact_check_outlined,
    'recipe_version_saved' => Icons.menu_book_outlined,
    'day_closed' => Icons.nightlight_outlined,
    _ => Icons.circle_outlined,
  };

  Future<void> _pickDay() async {
    final List<String> days = await ActivityLog(
      ref.read(databaseProvider),
    ).days();
    if (!mounted) return;
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => ListView(
        children: <Widget>[
          const SectionHeader('Which day?'),
          ListTile(
            title: const Text('All of it'),
            selected: _day == null,
            onTap: () => Navigator.of(context).pop(''),
          ),
          for (final String d in days)
            ListTile(
              title: Text(d),
              selected: d == _day,
              onTap: () => Navigator.of(context).pop(d),
            ),
        ],
      ),
    );
    if (picked != null) {
      setState(() => _day = picked.isEmpty ? null : picked);
    }
  }
}
