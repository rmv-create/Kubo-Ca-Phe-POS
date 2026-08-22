import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/money/money.dart';
import '../../core/quantity/measurement_unit.dart';
import '../../core/quantity/quantity.dart';
import '../../core/time/clock.dart';
import '../../data/db/app_database.dart';
import '../entities/business_settings.dart';
import '../entities/customer.dart';
import '../entities/ingredient.dart';
import '../entities/order_draft.dart';
import '../entities/reporting.dart';
import 'costing_engine.dart';
import 'inventory_engine.dart';

/// Reading sales back, and the two ways a sale can be undone.
///
/// Neither a refund nor a void ever deletes anything. The original sale stays
/// exactly as it was rung up; what changes is what it contributes.
class SalesService {
  const SalesService({
    required AppDatabase database,
    required Clock clock,
    required BusinessSettings Function() settings,
    InventoryEngine inventory = const InventoryEngine(),
  }) : _db = database,
       _clock = clock,
       _settings = settings,
       _inventory = inventory;

  final AppDatabase _db;
  final Clock _clock;
  final BusinessSettings Function() _settings;
  final InventoryEngine _inventory;

  String _businessDateOf(DateTime moment) =>
      BusinessDay(cutoffHour: _settings().businessDayCutoffHour).dateOf(moment);

  // ──────────────────────────── reading back ────────────────────────────

  Future<List<OrderRecord>> orders({
    String? businessDate,
    int? customerId,
    int limit = 100,
  }) async {
    final List<String> where = <String>[];
    final List<Object?> args = <Object?>[];
    if (businessDate != null) {
      where.add('o.business_date = ?');
      args.add(businessDate);
    }
    if (customerId != null) {
      where.add('o.customer_id = ?');
      args.add(customerId);
    }

    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT o.*,
             (SELECT method FROM payments WHERE order_id = o.id LIMIT 1)
               AS method,
             (SELECT method_name_snapshot FROM payments WHERE order_id = o.id LIMIT 1)
               AS method_name,
             (SELECT reference_no FROM payments WHERE order_id = o.id LIMIT 1)
               AS payment_reference,
             (SELECT tendered_centavos FROM payments WHERE order_id = o.id LIMIT 1)
               AS tendered_centavos,
             (SELECT change_centavos FROM payments WHERE order_id = o.id LIMIT 1)
               AS change_centavos,
             (SELECT reason FROM order_voids WHERE order_id = o.id LIMIT 1)
               AS void_reason,
             (SELECT COUNT(*) FROM order_items
               WHERE order_id = o.id AND recipe_version_id IS NULL)
               AS uncosted
      FROM orders o
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY o.created_at DESC, o.id DESC
      LIMIT ?
      ''',
      <Object?>[...args, limit],
    );

    final List<OrderRecord> records = <OrderRecord>[];
    for (final Map<String, Object?> row in rows) {
      records.add(await _record(row));
    }
    return records;
  }

  Future<OrderRecord?> orderById(int id) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT o.*,
             (SELECT method FROM payments WHERE order_id = o.id LIMIT 1)
               AS method,
             (SELECT method_name_snapshot FROM payments WHERE order_id = o.id LIMIT 1)
               AS method_name,
             (SELECT reference_no FROM payments WHERE order_id = o.id LIMIT 1)
               AS payment_reference,
             (SELECT tendered_centavos FROM payments WHERE order_id = o.id LIMIT 1)
               AS tendered_centavos,
             (SELECT change_centavos FROM payments WHERE order_id = o.id LIMIT 1)
               AS change_centavos,
             (SELECT reason FROM order_voids WHERE order_id = o.id LIMIT 1)
               AS void_reason,
             (SELECT COUNT(*) FROM order_items
               WHERE order_id = o.id AND recipe_version_id IS NULL)
               AS uncosted
      FROM orders o WHERE o.id = ?
      ''',
      <Object?>[id],
    );
    return rows.isEmpty ? null : _record(rows.first);
  }

  Future<OrderRecord> _record(Map<String, Object?> row) async {
    final int id = row['id']! as int;
    final List<Map<String, Object?>> lineRows = await _db.db.query(
      'order_items',
      where: 'order_id = ?',
      whereArgs: <Object?>[id],
      orderBy: 'line_no',
    );

    final List<OrderLineRecord> lines = <OrderLineRecord>[];
    for (final Map<String, Object?> line in lineRows) {
      final List<Map<String, Object?>> optionRows = await _db.db.query(
        'order_item_customizations',
        columns: <String>['option_name_snapshot'],
        where: 'order_item_id = ?',
        whereArgs: <Object?>[line['id']],
        orderBy: 'display_order',
      );
      lines.add(
        OrderLineRecord(
          id: line['id']! as int,
          productName: line['product_name_snapshot']! as String,
          sizeName: line['size_name_snapshot']! as String,
          quantity: line['quantity']! as int,
          refundedQuantity: line['refunded_quantity']! as int,
          unitPrice: Money(line['unit_price_centavos']! as int),
          lineTotal: Money(line['line_total_centavos']! as int),
          lineCogs: Money(line['line_cogs_centavos']! as int),
          isCosted: line['recipe_version_id'] != null,
          options: optionRows
              .map(
                (Map<String, Object?> o) =>
                    o['option_name_snapshot']! as String,
              )
              .toList(),
        ),
      );
    }

    // The statutory discount, if one was applied. Read from its own table
    // rather than recomputed: the rate or the shop's VAT position may have
    // changed since, and the receipt has to say what was actually charged.
    final List<Map<String, Object?>> discountRows = await _db.db.query(
      'order_discounts',
      where: 'order_id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    final Map<String, Object?>? discountRow = discountRows.isEmpty
        ? null
        : discountRows.first;

    return OrderRecord(
      id: id,
      orderNo: row['order_no']! as String,
      createdAt: DateTime.parse(row['created_at']! as String),
      businessDate: row['business_date']! as String,
      status: row['status']! as String,
      total: Money(row['total_centavos']! as int),
      cogs: Money(row['cogs_centavos']! as int),
      grossProfit: Money(row['gross_profit_centavos']! as int),
      refunded: Money(row['refunded_centavos']! as int),
      itemCount: row['item_count']! as int,
      uncostedLines: (row['uncosted'] as int?) ?? 0,
      customerId: row['customer_id'] as int?,
      customerName: row['customer_name_snapshot'] as String?,
      paymentMethod: row['method'] == null
          ? null
          // The snapshot, so a receipt reprinted after the owner renames a
          // method still reads the way it was handed to the customer.
          : PaymentMethod.fromRow(
              row['method']! as String,
              row['method_name'] as String?,
            ),
      voidReason: row['void_reason'] as String?,
      subtotal: Money((row['subtotal_centavos'] as int?) ?? 0),
      discount: Money((row['discount_centavos'] as int?) ?? 0),
      deliveryFee: Money((row['delivery_fee_centavos'] as int?) ?? 0),
      vat: Money((row['vat_centavos'] as int?) ?? 0),
      vatRateBp: (row['vat_rate_bp'] as int?) ?? 0,
      discountLabel: discountRow?['name'] as String?,
      discountRateBp: (discountRow?['rate_bp'] as int?) ?? 0,
      discountVatExempt: Money(
        (discountRow?['vat_exempt_centavos'] as int?) ?? 0,
      ),
      discountBeneficiaryName: discountRow?['beneficiary_name'] as String?,
      discountBeneficiaryIdNo: discountRow?['beneficiary_id_no'] as String?,
      paymentReference: row['payment_reference'] as String?,
      tendered: row['tendered_centavos'] == null
          ? null
          : Money(row['tendered_centavos']! as int),
      change: row['change_centavos'] == null
          ? null
          : Money(row['change_centavos']! as int),
      lines: lines,
    );
  }

  // ────────────────────────── naming an order ──────────────────────────

  /// Attaches a customer to an order that was rung as a guest.
  ///
  /// This happens constantly at a small counter: someone tries a drink, likes
  /// it, and only then wants to be remembered. Their first visit should count,
  /// and the drink they just had should count towards their usual, so this
  /// does everything completing the order with a customer would have done —
  /// the visit, the spend, and the order pattern.
  ///
  /// Refuses to move an order that already belongs to someone: reassigning a
  /// sale would corrupt two customers' histories at once. Detach it first if
  /// it really was rung against the wrong person.
  Future<void> attachCustomer({
    required int orderId,
    required int customerId,
  }) async {
    await _db.transaction<void>((Transaction txn) async {
      final List<Map<String, Object?>> orderRows = await txn.query(
        'orders',
        where: 'id = ?',
        whereArgs: <Object?>[orderId],
        limit: 1,
      );
      if (orderRows.isEmpty) {
        throw const NotFoundException('That order is no longer here.');
      }
      final Map<String, Object?> order = orderRows.first;
      if (order['customer_id'] != null) {
        throw const BusinessRuleException(
          'This order is already under a customer.',
        );
      }
      if (order['status'] != 'completed') {
        throw const BusinessRuleException(
          'A voided order cannot be put under a customer.',
        );
      }

      final List<Map<String, Object?>> customerRows = await txn.query(
        'customers',
        where: 'id = ?',
        whereArgs: <Object?>[customerId],
        limit: 1,
      );
      if (customerRows.isEmpty) {
        throw const NotFoundException('That customer is no longer here.');
      }
      final Map<String, Object?> customer = customerRows.first;

      final String at = _clock.nowIso();
      final String orderedAt = order['created_at']! as String;
      final int total = order['total_centavos']! as int;
      final int items = order['item_count']! as int;
      final int orders = (customer['order_count']! as int) + 1;

      await txn.update(
        'orders',
        <String, Object?>{
          'customer_id': customerId,
          'customer_name_snapshot': customer['name'],
        },
        where: 'id = ?',
        whereArgs: <Object?>[orderId],
      );

      // The visit happened when the drink was bought, not when the name was
      // given, so the customer's first and last visit are stamped from the
      // order itself.
      final String? firstVisit = customer['first_visit_at'] as String?;
      final String? lastVisit = customer['last_visit_at'] as String?;
      await txn.update(
        'customers',
        <String, Object?>{
          'first_visit_at':
              firstVisit == null || orderedAt.compareTo(firstVisit) < 0
              ? orderedAt
              : firstVisit,
          'last_visit_at':
              lastVisit == null || orderedAt.compareTo(lastVisit) > 0
              ? orderedAt
              : lastVisit,
          'visit_count': (customer['visit_count']! as int) + 1,
          'order_count': orders,
          'item_count': (customer['item_count']! as int) + items,
          'total_spend_centavos':
              (customer['total_spend_centavos']! as int) + total,
          'segment': CustomerSegment.fromOrderCount(orders).code,
          'updated_at': at,
        },
        where: 'id = ?',
        whereArgs: <Object?>[customerId],
      );

      await _learnPatternsFromOrder(
        txn,
        orderId: orderId,
        customerId: customerId,
        at: orderedAt,
      );

      await txn.insert('audit_log', <String, Object?>{
        'at': at,
        'business_date': order['business_date'],
        'action': 'order_customer_attached',
        'entity_type': 'order',
        'entity_id': orderId,
        'summary': '${order['order_no']} put under ${customer['name']}',
      });
    });
  }

  /// Rebuilds the customer's usual-order counts from an order already written.
  ///
  /// The same arithmetic [OrderService] does at completion, but reading the
  /// saved lines rather than a draft.
  Future<void> _learnPatternsFromOrder(
    Transaction txn, {
    required int orderId,
    required int customerId,
    required String at,
  }) async {
    final List<Map<String, Object?>> items = await txn.query(
      'order_items',
      where: 'order_id = ?',
      whereArgs: <Object?>[orderId],
    );

    for (final Map<String, Object?> item in items) {
      final int? productId = item['product_id'] as int?;
      final int? sizeId = item['size_id'] as int?;
      // A line whose product or size has since been deleted cannot be turned
      // back into a pattern, and guessing would put the wrong drink in
      // somebody's usual.
      if (productId == null || sizeId == null) continue;

      final List<Map<String, Object?>> optionRows = await txn.query(
        'order_item_customizations',
        columns: <String>['option_id'],
        where: 'order_item_id = ? AND option_id IS NOT NULL',
        whereArgs: <Object?>[item['id']],
      );
      final List<int> optionIds =
          optionRows
              .map((Map<String, Object?> o) => o['option_id']! as int)
              .toList()
            ..sort();
      final String signature = orderSignature(
        productId: productId,
        sizeId: sizeId,
        optionIds: optionIds,
      );
      final int quantity = item['quantity']! as int;

      final int changed = await txn.rawUpdate(
        'UPDATE customer_order_patterns '
        'SET occurrence_count = occurrence_count + ?, last_ordered_at = ? '
        'WHERE customer_id = ? AND signature = ?',
        <Object?>[quantity, at, customerId, signature],
      );
      if (changed == 0) {
        await txn.insert('customer_order_patterns', <String, Object?>{
          'customer_id': customerId,
          'signature': signature,
          'product_id': productId,
          'size_id': sizeId,
          'option_ids_json': optionIds.join(','),
          'occurrence_count': quantity,
          'first_ordered_at': at,
          'last_ordered_at': at,
        });
      }
    }
  }

  // ─────────────────────────────── refunds ───────────────────────────────

  /// Gives money back for part or all of an order.
  ///
  /// The sale is not deleted and not edited: a refund is its own record that
  /// nets off against it. Stock is only put back if the drink genuinely came
  /// back — a spilled latte that was refunded was still made.
  Future<void> refund({
    required int orderId,
    required Map<int, int> quantitiesByLineId,
    required String reason,
    bool restockIngredients = false,
    String? note,
  }) async {
    if (reason.trim().isEmpty) {
      throw const ValidationException('Say why this is being refunded.');
    }
    final OrderRecord? order = await orderById(orderId);
    if (order == null) throw const NotFoundException('That order is gone.');
    if (order.isVoided) {
      throw const BusinessRuleException(
        'This order was voided, so there is nothing to refund.',
      );
    }

    final DateTime now = _clock.now();
    final String at = now.toUtc().toIso8601String();
    final String date = _businessDateOf(now);

    await _db.transaction((Transaction txn) async {
      int refundTotal = 0;
      int refundCogs = 0;
      final List<PendingMovement> movements = <PendingMovement>[];
      final CostingEngine costing = CostingEngine(txn);

      final int refundId = await txn.insert('refunds', <String, Object?>{
        'order_id': orderId,
        'at': at,
        'business_date': date,
        // Filled in below once the lines are known.
        'amount_centavos': 1,
        'cogs_centavos': 0,
        'reason': reason.trim(),
        'restock_inventory': restockIngredients ? 1 : 0,
        'note': note,
      });

      for (final MapEntry<int, int> entry in quantitiesByLineId.entries) {
        if (entry.value <= 0) continue;
        final OrderLineRecord? line = order.lines
            .where((OrderLineRecord l) => l.id == entry.key)
            .firstOrNull;
        if (line == null) continue;
        if (entry.value > line.remainingQuantity) {
          throw BusinessRuleException(
            'Only ${line.remainingQuantity} of ${line.title} can still be '
            'refunded.',
          );
        }

        final int amount = line.unitPrice.centavos * entry.value;
        final int cogs = line.quantity == 0
            ? 0
            : (line.lineCogs.centavos ~/ line.quantity) * entry.value;
        refundTotal += amount;
        refundCogs += cogs;

        await txn.insert('refund_items', <String, Object?>{
          'refund_id': refundId,
          'order_item_id': line.id,
          'quantity': entry.value,
          'amount_centavos': amount,
          'cogs_centavos': cogs,
        });
        await txn.rawUpdate(
          'UPDATE order_items SET refunded_quantity = refunded_quantity + ? '
          'WHERE id = ?',
          <Object?>[entry.value, line.id],
        );

        if (restockIngredients) {
          final List<Map<String, Object?>> consumed = await txn.rawQuery(
            'SELECT m.ingredient_id AS id, m.qty_milli_delta AS delta, '
            'i.base_unit AS unit '
            'FROM inventory_movements m '
            'JOIN ingredients i ON i.id = m.ingredient_id '
            "WHERE m.order_item_id = ? AND m.movement_type = 'sale'",
            <Object?>[line.id],
          );
          for (final Map<String, Object?> row in consumed) {
            final BaseUnit unit = BaseUnit.fromCode(row['unit']! as String);
            // The sale took the whole line out; put back only the share
            // being refunded.
            final int perUnit =
                (-(row['delta']! as int)) ~/
                (line.quantity == 0 ? 1 : line.quantity);
            movements.add(
              PendingMovement(
                ingredientId: row['id']! as int,
                delta: Quantity(perUnit * entry.value, unit),
                type: MovementType.refundReversal,
                reason: 'Refund · ${reason.trim()}',
                orderId: orderId,
                orderItemId: line.id,
                unitCost: await costing.costOfIngredient(
                  row['id']! as int,
                  method: _settings().costingMethod,
                  asOf: now,
                ),
              ),
            );
          }
        }
      }

      if (refundTotal <= 0) {
        throw const ValidationException('Choose what to refund.');
      }

      await txn.update(
        'refunds',
        <String, Object?>{
          'amount_centavos': refundTotal,
          'cogs_centavos': refundCogs,
        },
        where: 'id = ?',
        whereArgs: <Object?>[refundId],
      );
      await txn.rawUpdate(
        'UPDATE orders SET refunded_centavos = refunded_centavos + ? '
        'WHERE id = ?',
        <Object?>[refundTotal, orderId],
      );

      await _inventory.post(txn, movements, at: at, businessDate: date);

      await txn.insert('audit_log', <String, Object?>{
        'at': at,
        'business_date': date,
        'action': 'refund_issued',
        'entity_type': 'order',
        'entity_id': orderId,
        'summary':
            '${order.orderNo} · ${Money(refundTotal).format()} '
            'refunded · ${reason.trim()}',
      });
    });
  }

  // ──────────────────────────────── voids ────────────────────────────────

  /// Takes a whole order out of the day's sales.
  ///
  /// For a mistake — rung up wrong, never handed over. The row stays, marked
  /// voided, and every ingredient it consumed goes back on the shelf.
  Future<void> voidOrder({
    required int orderId,
    required String reason,
    String? note,
  }) async {
    if (reason.trim().isEmpty) {
      throw const ValidationException('Say why this is being voided.');
    }
    final OrderRecord? order = await orderById(orderId);
    if (order == null) throw const NotFoundException('That order is gone.');
    if (order.isVoided) {
      throw const BusinessRuleException('That order is already voided.');
    }
    if (order.isRefunded) {
      throw const BusinessRuleException(
        'This order has already been refunded. Refund the rest instead of '
        'voiding it, so the money given back stays on the record.',
      );
    }

    final DateTime now = _clock.now();
    final String at = now.toUtc().toIso8601String();
    final String date = _businessDateOf(now);

    await _db.transaction((Transaction txn) async {
      await txn.update(
        'orders',
        <String, Object?>{'status': 'voided'},
        where: 'id = ?',
        whereArgs: <Object?>[orderId],
      );
      await txn.insert('order_voids', <String, Object?>{
        'order_id': orderId,
        'at': at,
        'business_date': date,
        'amount_centavos': order.total.centavos,
        'reason': reason.trim(),
        'note': note,
      });

      // Everything the order consumed goes back.
      final CostingEngine costing = CostingEngine(txn);
      final List<Map<String, Object?>> consumed = await txn.rawQuery(
        'SELECT m.ingredient_id AS id, SUM(m.qty_milli_delta) AS delta, '
        'i.base_unit AS unit '
        'FROM inventory_movements m '
        'JOIN ingredients i ON i.id = m.ingredient_id '
        "WHERE m.order_id = ? AND m.movement_type = 'sale' "
        'GROUP BY m.ingredient_id',
        <Object?>[orderId],
      );
      final List<PendingMovement> movements = <PendingMovement>[];
      for (final Map<String, Object?> row in consumed) {
        movements.add(
          PendingMovement(
            ingredientId: row['id']! as int,
            delta: Quantity(
              -(row['delta']! as int),
              BaseUnit.fromCode(row['unit']! as String),
            ),
            type: MovementType.voidReversal,
            reason: 'Void · ${reason.trim()}',
            orderId: orderId,
            unitCost: await costing.costOfIngredient(
              row['id']! as int,
              method: _settings().costingMethod,
              asOf: now,
            ),
          ),
        );
      }
      await _inventory.post(txn, movements, at: at, businessDate: date);

      // A customer who never got their drink should not be credited with it.
      final int? customerId = order.customerId;
      if (customerId != null) {
        await txn.rawUpdate(
          'UPDATE customers SET '
          'order_count = MAX(0, order_count - 1), '
          'visit_count = MAX(0, visit_count - 1), '
          'item_count = MAX(0, item_count - ?), '
          'total_spend_centavos = MAX(0, total_spend_centavos - ?), '
          'updated_at = ? WHERE id = ?',
          <Object?>[order.itemCount, order.total.centavos, at, customerId],
        );
      }

      await txn.insert('audit_log', <String, Object?>{
        'at': at,
        'business_date': date,
        'action': 'order_voided',
        'entity_type': 'order',
        'entity_id': orderId,
        'summary':
            '${order.orderNo} · ${order.total.format()} voided · '
            '${reason.trim()}',
      });
    });
  }
}
