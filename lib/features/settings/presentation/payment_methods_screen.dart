import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../shared/widgets/async_view.dart';

/// The ways the shop takes money, and who decides what they are.
///
/// A method that has never taken a payment can be deleted outright. One that
/// has can only be switched off: its button disappears from the POS and every
/// past sale keeps pointing at it.
class PaymentMethodsScreen extends ConsumerWidget {
  const PaymentMethodsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Payment methods')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _edit(context, ref, null),
      icon: const Icon(Icons.add),
      label: const Text('ADD'),
    ),
    body: AsyncView<List<PaymentMethod>>(
      value: ref.watch(allPaymentMethodsProvider),
      builder: (BuildContext context, List<PaymentMethod> methods) =>
          ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: methods.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final PaymentMethod method = methods[index];
              return ListTile(
                title: Text(method.label),
                subtitle: Text(_describe(method)),
                leading: Icon(
                  method.takesTendered
                      ? Icons.payments_outlined
                      : Icons.smartphone_outlined,
                ),
                trailing: Switch(
                  value: method.isActive,
                  onChanged: (bool value) => _run(
                    context,
                    ref,
                    () => ref
                        .read(paymentMethodRepositoryProvider)
                        .update(method.copyWith(isActive: value)),
                  ),
                ),
                onTap: () => _edit(context, ref, method),
              );
            },
          ),
    ),
  );

  String _describe(PaymentMethod method) {
    final List<String> parts = <String>[
      if (method.needsConfirmation) 'confirmed by hand',
      if (method.takesReference) 'takes a reference',
      if (method.takesTendered) 'works out change',
      if (!method.isActive) 'not offered',
    ];
    return parts.isEmpty ? 'Offered on the POS' : parts.join(' · ');
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    PaymentMethod? existing,
  ) async {
    final PaymentMethod? result = await showModalBottomSheet<PaymentMethod>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => _MethodSheet(existing: existing),
    );
    if (result == null || !context.mounted) return;

    await _run(context, ref, () async {
      final repository = ref.read(paymentMethodRepositoryProvider);
      if (existing == null) {
        await repository.add(result);
      } else {
        await repository.update(result);
      }
    });
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      ref.read(paymentMethodRevisionProvider.notifier).bump();
    } on AppException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

class _MethodSheet extends ConsumerStatefulWidget {
  const _MethodSheet({required this.existing});

  final PaymentMethod? existing;

  @override
  ConsumerState<_MethodSheet> createState() => _MethodSheetState();
}

class _MethodSheetState extends ConsumerState<_MethodSheet> {
  late final TextEditingController _name;
  late bool _needsConfirmation;
  late bool _takesReference;
  late bool _takesTendered;

  @override
  void initState() {
    super.initState();
    final PaymentMethod? m = widget.existing;
    _name = TextEditingController(text: m?.label ?? '');
    // A new method is most likely another e-wallet, so it starts shaped like
    // one: money she has to see land before the order counts as paid.
    _needsConfirmation = m?.needsConfirmation ?? true;
    _takesReference = m?.takesReference ?? true;
    _takesTendered = m?.takesTendered ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PaymentMethod? existing = widget.existing;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          KuboSpacing.lg,
          KuboSpacing.lg,
          KuboSpacing.lg,
          KuboSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              existing == null ? 'New payment method' : existing.label,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: KuboSpacing.lg),
            TextField(
              controller: _name,
              autofocus: existing == null,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name on the button',
                hintText: 'Maya, Bank transfer, …',
              ),
            ),
            const SizedBox(height: KuboSpacing.md),
            SwitchListTile(
              value: _needsConfirmation,
              contentPadding: EdgeInsets.zero,
              title: const Text('I confirm the money arrived'),
              subtitle: const Text(
                'For money that lands somewhere the POS cannot see. The order '
                'stays unpaid until you tick it.',
              ),
              onChanged: (bool v) => setState(() => _needsConfirmation = v),
            ),
            SwitchListTile(
              value: _takesReference,
              contentPadding: EdgeInsets.zero,
              title: const Text('Can record a reference number'),
              onChanged: (bool v) => setState(() => _takesReference = v),
            ),
            SwitchListTile(
              value: _takesTendered,
              contentPadding: EdgeInsets.zero,
              title: const Text('Counts change'),
              subtitle: const Text('Asks what was handed over. Cash only.'),
              onChanged: (bool v) => setState(() => _takesTendered = v),
            ),
            const SizedBox(height: KuboSpacing.md),
            if (existing != null) _DeleteRow(method: existing),
            const SizedBox(height: KuboSpacing.sm),
            FilledButton(
              onPressed: _name.text.trim().isEmpty ? null : _save,
              child: const Text('SAVE'),
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    final PaymentMethod? existing = widget.existing;
    Navigator.of(context).pop(
      existing == null
          ? PaymentMethod(
              code: '',
              label: _name.text.trim(),
              needsConfirmation: _needsConfirmation,
              takesReference: _takesReference,
              takesTendered: _takesTendered,
            )
          : existing.copyWith(
              label: _name.text.trim(),
              needsConfirmation: _needsConfirmation,
              takesReference: _takesReference,
              takesTendered: _takesTendered,
            ),
    );
  }
}

/// Deleting is offered only while it is genuinely safe.
class _DeleteRow extends ConsumerWidget {
  const _DeleteRow({required this.method});

  final PaymentMethod method;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<int>(
    future: ref.read(paymentMethodRepositoryProvider).paymentCount(method.code),
    builder: (BuildContext context, AsyncSnapshot<int> snapshot) {
      final int? taken = snapshot.data;
      if (taken == null) return const SizedBox.shrink();
      if (taken > 0) {
        return Text(
          'Used on $taken order${taken == 1 ? '' : 's'}, so it cannot be '
          'deleted. Switch it off instead and it stops appearing on the POS.',
          style: Theme.of(context).textTheme.bodySmall,
        );
      }
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () async {
            final NavigatorState navigator = Navigator.of(context);
            await ref.read(paymentMethodRepositoryProvider).delete(method.code);
            ref.read(paymentMethodRevisionProvider.notifier).bump();
            navigator.pop();
          },
          icon: const Icon(Icons.delete_outline),
          label: const Text('Delete'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
      );
    },
  );
}
