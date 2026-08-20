import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/errors/app_exception.dart';

/// Runs a menu edit, refreshes every screen showing menu data, and reports the
/// outcome to the operator.
///
/// Menu edits are frequent and small — rename a drink, switch a milk off,
/// change a price. Each one funnels through here so none of them can silently
/// fail, and so the failure the owner sees is the sentence written for her
/// rather than a SQLite error code.
Future<bool> runMenuEdit(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action, {
  String? successMessage,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    ref.read(menuRevisionProvider.notifier).bump();
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

/// A single-field prompt — the shape almost every menu edit takes.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String confirmLabel = 'Save',
  String? helper,
  TextInputType? keyboardType,
}) {
  final TextEditingController controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: keyboardType,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: label, helperText: helper),
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Continue',
  bool destructive = false,
}) async {
  final bool? answer = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return answer ?? false;
}
