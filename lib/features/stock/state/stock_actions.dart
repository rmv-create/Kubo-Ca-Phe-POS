import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/money/money.dart';
import '../../../core/quantity/measurement_unit.dart';
import '../../../core/quantity/quantity.dart';

/// Runs a stock or recipe edit, refreshes everything that reads it, and puts
/// any failure in front of the owner in words she can act on.
Future<bool> runStockEdit(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action, {
  String? successMessage,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    ref.read(stockRevisionProvider.notifier).bump();
    if (successMessage != null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(successMessage)));
    }
    return true;
  } on AppException catch (error) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(error.message)));
    return false;
  }
}

/// Asks for an amount in an ingredient's own unit.
Future<Quantity?> promptForQuantity(
  BuildContext context, {
  required String title,
  required BaseUnit unit,
  Quantity? initial,
  String? helper,
}) async {
  final TextEditingController controller = TextEditingController(
    text: initial == null || initial.isZero ? '' : _trim(initial.inBaseUnits),
  );
  final String? raw = await showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Amount in ${unit.code}',
          helperText: helper,
          suffixText: unit.code,
        ),
        onSubmitted: (String v) => Navigator.of(context).pop(v),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);

  if (raw == null) return null;
  final double? value = double.tryParse(raw.trim());
  if (value == null) return null;
  return Quantity.fromBase(value, unit);
}

/// Asks for a peso amount, rejecting anything that is not one.
Future<Money?> promptForMoney(
  BuildContext context, {
  required String title,
  required String label,
  Money? initial,
  String? helper,
}) async {
  final TextEditingController controller = TextEditingController(
    text: initial == null ? '' : initial.toPlainString(),
  );
  final String? raw = await showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          prefixText: '₱ ',
        ),
        onSubmitted: (String v) => Navigator.of(context).pop(v),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);

  if (raw == null) return null;
  return Money.tryParse(raw);
}

String _trim(double value) {
  final String fixed = value.toStringAsFixed(3);
  return fixed.contains('.')
      ? fixed.replaceFirst(RegExp(r'\.?0+$'), '')
      : fixed;
}
