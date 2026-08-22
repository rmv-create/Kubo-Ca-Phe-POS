import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/reporting.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/widgets/section_header.dart';
import '../../menu/state/menu_actions.dart';
import '../../receipts/presentation/name_this_order_sheet.dart';
import '../../receipts/presentation/receipt_screen.dart';

/// Every sale, and the two ways to undo one.
class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  String? _day;
  bool _todayOnly = true;

  @override
  Widget build(BuildContext context) {
    _day ??= ref.read(todayBusinessDateProvider);
    final AsyncValue<List<OrderRecord>> orders = ref.watch(
      ordersProvider(_todayOnly ? _day : null),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Orders'),
        actions: <Widget>[
          TextButton(
            onPressed: () => setState(() => _todayOnly = !_todayOnly),
            child: Text(_todayOnly ? 'Today' : 'All'),
          ),
        ],
      ),
      body: AsyncView<List<OrderRecord>>(
        value: orders,
        onRetry: () => ref.invalidate(ordersProvider),
        builder: (BuildContext context, List<OrderRecord> data) {
          if (data.isEmpty) {
            return EmptyState(
              icon: Icons.receipt_long_outlined,
              title: _todayOnly ? 'Nothing sold today yet' : 'No orders yet',
              message: _todayOnly
                  ? 'Tap Today to see every order instead.'
                  : 'Completed orders appear here.',
            );
          }
          return ListView.separated(
            itemCount: data.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) =>
                _OrderTile(order: data[index]),
          );
        },
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});

  final OrderRecord order;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        order.isVoided
            ? Icons.block
            : order.isRefunded
            ? Icons.undo
            : Icons.receipt_long_outlined,
        color: order.isVoided || order.isRefunded
            ? theme.colorScheme.error
            : null,
      ),
      title: Row(
        children: <Widget>[
          Text(order.orderNo),
          const SizedBox(width: KuboSpacing.sm),
          if (order.isVoided)
            _Tag(label: 'Voided', color: theme.colorScheme.error)
          else if (order.isFullyRefunded)
            _Tag(label: 'Refunded', color: theme.colorScheme.error)
          else if (order.isRefunded)
            _Tag(label: 'Part refunded', color: theme.colorScheme.error),
        ],
      ),
      subtitle: Text(
        <String>[
          '${order.itemCount} drink${order.itemCount == 1 ? '' : 's'}',
          if (order.customerName != null) order.customerName!,
          if (order.paymentMethod != null) order.paymentMethod!.label,
          order.createdAt.toLocal().toString().substring(11, 16),
        ].join(' · '),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          MoneyText(
            order.total,
            style: order.isVoided
                ? theme.textTheme.bodyLarge?.copyWith(
                    decoration: TextDecoration.lineThrough,
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
          if (order.isRefunded && !order.isVoided)
            Text(
              '−${order.refunded.format()}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              OrderDetailScreen(orderId: order.id),
        ),
      ),
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

class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({required this.orderId, super.key});

  final int orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<OrderRecord>> orders = ref.watch(
      ordersProvider(null),
    );

    return AsyncView<List<OrderRecord>>(
      value: orders,
      builder: (BuildContext context, List<OrderRecord> data) {
        final OrderRecord? order = data
            .where((OrderRecord o) => o.id == orderId)
            .firstOrNull;
        if (order == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.search_off,
              title: 'Order not found',
              message: 'It may be outside the range being shown.',
            ),
          );
        }

        final ThemeData theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: Text(order.orderNo)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              if (order.isVoided)
                _Banner(
                  title: 'This order was voided',
                  body: order.voidReason ?? '',
                  isError: true,
                ),
              if (!order.isCosted)
                _Banner(
                  title: 'Not fully costed',
                  body:
                      '${order.uncostedLines} '
                      'line${order.uncostedLines == 1 ? '' : 's'} had no recipe '
                      'or an ingredient with no price, so the profit on this '
                      'order is understated rather than guessed.',
                  isError: false,
                ),
              const SectionHeader('Drinks'),
              for (final OrderLineRecord line in order.lines)
                ListTile(
                  title: Text('${line.quantity}× ${line.title}'),
                  subtitle: Text(
                    <String>[
                      for (final OrderLineOption option in line.options)
                        option.isCharged
                            ? '${option.name} '
                                  '+${option.totalFor(line.quantity).format()}'
                            : option.name,
                      if (line.refundedQuantity > 0)
                        '${line.refundedQuantity} refunded',
                    ].join(' · '),
                  ),
                  trailing: MoneyText(line.lineTotal),
                ),
              const SectionHeader('Money'),
              _Row(label: 'Total', value: order.total.format()),
              if (order.isRefunded)
                _Row(
                  label: 'Refunded',
                  value: '−${order.refunded.format()}',
                  emphasise: true,
                ),
              _Row(label: 'Kept', value: order.netTotal.format()),
              _Row(
                label: 'Cost to make',
                value: order.isCosted ? order.cogs.format() : 'partly unknown',
              ),
              _Row(
                label: 'Gross profit',
                value: order.isCosted ? order.grossProfit.format() : '—',
              ),
              _Row(label: 'Paid by', value: order.paymentMethod?.label ?? '—'),
              if (order.hasDiscount)
                _Row(
                  label: order.discountLabel ?? 'Discount',
                  value: '−${order.discount.format()}',
                ),
              if (order.deliveryFee.isPositive)
                _Row(label: 'Delivery', value: order.deliveryFee.format()),
              if (order.customerName != null)
                _Row(label: 'Customer', value: order.customerName!),

              const SectionHeader('Receipt'),
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('Print or send the receipt'),
                subtitle: const Text('PDF, JPEG, or straight to a printer'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) =>
                        ReceiptScreen(orderId: order.id),
                  ),
                ),
              ),
              if (order.customerName == null && !order.isVoided)
                ListTile(
                  leading: const Icon(Icons.person_add_alt),
                  title: const Text('Put this under a customer'),
                  subtitle: const Text(
                    'For someone who decided afterwards that they want to be '
                    'remembered. Their visit counts from when they bought it.',
                  ),
                  onTap: () async {
                    await NameThisOrderSheet.show(context, order);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              if (!order.isVoided) ...<Widget>[
                const SectionHeader('Put it right'),
                ListTile(
                  leading: Icon(Icons.undo, color: theme.colorScheme.error),
                  title: const Text('Refund'),
                  subtitle: const Text(
                    'Give money back for part or all of it. The sale stays on '
                    'the record.',
                  ),
                  enabled: !order.isFullyRefunded,
                  onTap: order.isFullyRefunded
                      ? null
                      : () => _refund(context, ref, order),
                ),
                ListTile(
                  leading: Icon(Icons.block, color: theme.colorScheme.error),
                  title: const Text('Void'),
                  subtitle: const Text(
                    'Rung up by mistake, never handed over. It stops counting '
                    'and the ingredients go back on the shelf.',
                  ),
                  enabled: !order.isRefunded,
                  onTap: order.isRefunded
                      ? null
                      : () => _voidOrder(context, ref, order),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _refund(
    BuildContext context,
    WidgetRef ref,
    OrderRecord order,
  ) async {
    final Map<int, int> quantities = <int, int>{
      for (final OrderLineRecord l in order.lines)
        if (l.remainingQuantity > 0) l.id: l.remainingQuantity,
    };
    if (quantities.isEmpty) return;

    final String? reason = await promptForText(
      context,
      title: 'Refund ${order.orderNo}',
      label: 'Why?',
      helper: 'Kept on the record, so the day still adds up',
      confirmLabel: 'Next',
    );
    if (reason == null || reason.trim().isEmpty || !context.mounted) return;

    final bool restock = await confirm(
      context,
      title: 'Put the ingredients back?',
      message:
          'Only if the drinks were never made. If they were made and '
          'handed over, leave this — the milk is gone either way.',
      confirmLabel: 'Yes, put back',
    );
    if (!context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    try {
      await ref
          .read(salesServiceProvider)
          .refund(
            orderId: order.id,
            quantitiesByLineId: quantities,
            reason: reason,
            restockIngredients: restock,
          );
      ref.read(salesRevisionProvider.notifier).bump();
      ref.read(stockRevisionProvider.notifier).bump();
      messenger
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Refunded')));
      navigator.pop();
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _voidOrder(
    BuildContext context,
    WidgetRef ref,
    OrderRecord order,
  ) async {
    final String? reason = await promptForText(
      context,
      title: 'Void ${order.orderNo}',
      label: 'Why?',
      helper: 'The order stays on the record, marked voided',
      confirmLabel: 'Void it',
    );
    if (reason == null || reason.trim().isEmpty || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    try {
      await ref
          .read(salesServiceProvider)
          .voidOrder(orderId: order.id, reason: reason);
      ref.read(salesRevisionProvider.notifier).bump();
      ref.read(stockRevisionProvider.notifier).bump();
      messenger
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Voided')));
      navigator.pop();
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: KuboSpacing.lg,
        vertical: KuboSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              color: emphasise ? theme.colorScheme.error : null,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.title,
    required this.body,
    required this.isError,
  });

  final String title;
  final String body;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.all(KuboSpacing.lg),
      padding: const EdgeInsets.all(KuboSpacing.lg),
      decoration: BoxDecoration(
        color: isError
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(KuboRadius.md),
        border: Border(
          left: BorderSide(
            color: isError
                ? theme.colorScheme.error
                : theme.colorScheme.secondary,
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title.toUpperCase(), style: theme.textTheme.labelSmall),
          if (body.isNotEmpty) ...<Widget>[
            const SizedBox(height: KuboSpacing.xs),
            Text(body, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
