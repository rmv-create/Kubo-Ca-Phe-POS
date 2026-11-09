import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/customer.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import 'customers_screen.dart';

/// Regulars who have stopped coming.
///
/// The report a small shop cannot get any other way. Nobody announces that
/// they have stopped buying coffee from you — they simply are not there,
/// and a week later you have not noticed because you were busy.
///
/// "Stopped" is judged against each person's own rhythm rather than one
/// rule for everybody. Somebody who came every Tuesday for a year is
/// missed after a fortnight; somebody who comes once a month is not. Worth
/// most first, because that is who it costs most to lose.
class LapsedScreen extends ConsumerWidget {
  const LapsedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<LapsedCustomer>> lapsed = ref.watch(
      lapsedCustomersProvider,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Who stopped coming')),
      body: AsyncView<List<LapsedCustomer>>(
        value: lapsed,
        builder: (BuildContext context, List<LapsedCustomer> list) =>
            ListView(
              padding: const EdgeInsets.only(bottom: KuboSpacing.xxl),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(KuboSpacing.lg),
                  child: Text(
                    list.isEmpty
                        ? 'Nobody is missing. Everyone who comes regularly '
                              'has been in recently — which is the '
                              'answer you want from this page.'
                        : 'People who used to come regularly and have not '
                              'been in for noticeably longer than usual. '
                              'Worth most first.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                for (final LapsedCustomer gone in list)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: theme.colorScheme.surfaceContainerHigh,
                      child: Text(
                        gone.customer.initials,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    title: Text(gone.customer.name),
                    subtitle: Text(
                      '${_away(gone.daysAway)} · ${gone.rhythm} · '
                      '${gone.customer.orderCount} orders',
                    ),
                    trailing: MoneyText(gone.customer.totalSpend),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            CustomerDetailScreen(customerId: gone.customer.id),
                      ),
                    ),
                  ),
                if (list.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(KuboSpacing.lg),
                    child: Text(
                      'Their mobile number is on their page, and so is what '
                      'they usually order — which is most of a message, '
                      'already written.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
      ),
    );
  }

  static String _away(int days) {
    if (days < 14) return 'Away $days days';
    if (days < 60) return 'Away ${(days / 7).round()} weeks';
    return 'Away ${(days / 30).round()} months';
  }
}
