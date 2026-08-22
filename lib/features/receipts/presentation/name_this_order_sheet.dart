import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/customer.dart';
import '../../../domain/entities/reporting.dart';
import '../../../shared/widgets/async_view.dart';

/// Puts a completed order under a customer's name after the fact.
///
/// Someone tries a drink as a guest, likes it, and only then wants to be
/// remembered. Their visit, their spend and the drink they just had all count
/// from the moment they bought it, not from the moment they gave a name.
class NameThisOrderSheet extends ConsumerStatefulWidget {
  const NameThisOrderSheet({required this.order, super.key});

  final OrderRecord order;

  static Future<bool?> show(BuildContext context, OrderRecord order) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (BuildContext context) => DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (BuildContext context, ScrollController controller) =>
              NameThisOrderSheet(order: order),
        ),
      );

  @override
  ConsumerState<NameThisOrderSheet> createState() => _NameThisOrderSheetState();
}

class _NameThisOrderSheetState extends ConsumerState<NameThisOrderSheet> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  bool _saving = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            KuboSpacing.lg,
            KuboSpacing.sm,
            KuboSpacing.lg,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Who was this for?', style: theme.textTheme.headlineSmall),
              const SizedBox(height: KuboSpacing.xs),
              Text(
                '${widget.order.orderNo} · ${widget.order.total.format()}. '
                'The visit counts from when they bought it, and the drink goes '
                'towards their usual.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: KuboSpacing.md),
              TextField(
                controller: _search,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Name or mobile number',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: _onQueryChanged,
              ),
            ],
          ),
        ),
        Expanded(child: _results(theme)),
      ],
    );
  }

  Widget _results(ThemeData theme) {
    final String query = _query.trim();
    if (query.isEmpty) {
      return AsyncView<List<Customer>>(
        value: ref.watch(recentCustomersProvider),
        builder: (BuildContext context, List<Customer> customers) =>
            _list(customers, theme),
      );
    }
    return AsyncView<List<Customer>>(
      value: ref.watch(customerSearchProvider(query)),
      builder: (BuildContext context, List<Customer> customers) =>
          _list(customers, theme),
    );
  }

  Widget _list(List<Customer> customers, ThemeData theme) => ListView(
    padding: const EdgeInsets.fromLTRB(
      KuboSpacing.lg,
      KuboSpacing.md,
      KuboSpacing.lg,
      KuboSpacing.xxl,
    ),
    children: <Widget>[
      if (_query.trim().isNotEmpty)
        ListTile(
          leading: const Icon(Icons.person_add_alt),
          title: Text('New customer "${_search.text.trim()}"'),
          subtitle: const Text(
            'Adds them and puts this order under their name',
          ),
          onTap: _saving ? null : () => _createAndAttach(_search.text.trim()),
        ),
      for (final Customer customer in customers)
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: Text(customer.name),
          subtitle: Text(
            customer.mobile == null
                ? '${customer.orderCount} order'
                      '${customer.orderCount == 1 ? '' : 's'}'
                : '${customer.mobile} · ${customer.orderCount} order'
                      '${customer.orderCount == 1 ? '' : 's'}',
          ),
          onTap: _saving ? null : () => _attach(customer.id),
        ),
      if (customers.isEmpty && _query.trim().isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: KuboSpacing.xl),
          child: Text(
            'No customers yet. Type a name to add the first one.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
    ],
  );

  Future<void> _createAndAttach(String name) async {
    if (name.isEmpty) return;
    await _run(() async {
      final int id = await ref
          .read(customerRepositoryProvider)
          .create(name: name);
      await ref
          .read(salesServiceProvider)
          .attachCustomer(orderId: widget.order.id, customerId: id);
    });
  }

  Future<void> _attach(int customerId) => _run(
    () => ref
        .read(salesServiceProvider)
        .attachCustomer(orderId: widget.order.id, customerId: customerId),
  );

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _saving = true);
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      ref.read(salesRevisionProvider.notifier).bump();
      ref.read(customerRevisionProvider.notifier).bump();
      navigator.pop(true);
    } on AppException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
