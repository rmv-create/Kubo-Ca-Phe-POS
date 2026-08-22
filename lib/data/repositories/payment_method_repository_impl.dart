import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/order_draft.dart';
import '../../domain/repositories/payment_method_repository.dart';
import '../db/app_database.dart';

class PaymentMethodRepositoryImpl implements PaymentMethodRepository {
  PaymentMethodRepositoryImpl(this._database, this._clock);

  final AppDatabase _database;
  final Clock _clock;

  @override
  Future<List<PaymentMethod>> all({bool includeInactive = false}) async {
    final List<Map<String, Object?>> rows = await _database.db.query(
      'payment_methods',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: 'display_order, id',
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<PaymentMethod> add(PaymentMethod method) async {
    final String code = method.code.isEmpty
        ? codeFromName(method.label)
        : method.code;
    if (code.isEmpty) {
      throw const BusinessRuleException('Give the payment method a name.');
    }
    final String now = _clock.nowIso();
    final int nextOrder = await _nextDisplayOrder();

    try {
      final int id = await _database.db
          .insert('payment_methods', <String, Object?>{
            'code': code,
            'name': method.label.trim(),
            'needs_confirmation': method.needsConfirmation ? 1 : 0,
            'takes_reference': method.takesReference ? 1 : 0,
            'takes_tendered': method.takesTendered ? 1 : 0,
            'is_active': method.isActive ? 1 : 0,
            'display_order': nextOrder,
            'created_at': now,
            'updated_at': now,
          });
      return method.copyWith(displayOrder: nextOrder).withId(id, code);
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw BusinessRuleException(
          '"${method.label.trim()}" is already a payment method.',
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> update(PaymentMethod method) async {
    await _database.db.update(
      'payment_methods',
      <String, Object?>{
        'name': method.label.trim(),
        'needs_confirmation': method.needsConfirmation ? 1 : 0,
        'takes_reference': method.takesReference ? 1 : 0,
        'takes_tendered': method.takesTendered ? 1 : 0,
        'is_active': method.isActive ? 1 : 0,
        'display_order': method.displayOrder,
        'updated_at': _clock.nowIso(),
      },
      where: 'code = ?',
      whereArgs: <Object?>[method.code],
    );
  }

  @override
  Future<void> delete(String code) async {
    final int taken = await paymentCount(code);
    if (taken > 0) {
      throw BusinessRuleException(
        'This method has already taken $taken payment${taken == 1 ? '' : 's'}. '
        'Switch it off instead — deleting it would break those records.',
      );
    }
    await _database.db.delete(
      'payment_methods',
      where: 'code = ?',
      whereArgs: <Object?>[code],
    );
  }

  @override
  Future<int> paymentCount(String code) async {
    final List<Map<String, Object?>> rows = await _database.db.rawQuery(
      'SELECT COUNT(*) AS n FROM payments WHERE method = ?',
      <Object?>[code],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<int> _nextDisplayOrder() async {
    final List<Map<String, Object?>> rows = await _database.db.rawQuery(
      'SELECT MAX(display_order) AS m FROM payment_methods',
    );
    return ((rows.first['m'] as int?) ?? 0) + 1;
  }

  PaymentMethod _fromRow(Map<String, Object?> row) => PaymentMethod(
    id: row['id'] as int?,
    code: row['code']! as String,
    label: row['name']! as String,
    needsConfirmation: (row['needs_confirmation']! as int) == 1,
    takesReference: (row['takes_reference']! as int) == 1,
    takesTendered: (row['takes_tendered']! as int) == 1,
    isActive: (row['is_active']! as int) == 1,
    displayOrder: row['display_order']! as int,
  );
}

/// Turns a name the owner typed into a stable code.
///
/// The code is what every payment row points at forever, so it is derived once
/// and never touched again — renaming "Maya" to "Maya (business)" leaves the
/// code alone.
String codeFromName(String name) => name
    .trim()
    .toLowerCase()
    .replaceAll(RegExp('[^a-z0-9]+'), '_')
    .replaceAll(RegExp('^_+|_+\$'), '');
