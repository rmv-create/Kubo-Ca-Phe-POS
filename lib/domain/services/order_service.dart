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
import 'costing_engine.dart';
import 'discount_engine.dart';
import 'inventory_engine.dart';
import 'who_is_working.dart';

/// Turns a finished draft into a permanent record, in one transaction.
///
/// When COMPLETE ORDER is pressed the owner should have to do nothing else.
/// This does all of it: numbers the order, writes the sale with its historical
/// snapshots, records the payment, updates the customer's history, learns the
/// drink configuration for their usual, and logs the whole thing — or writes
/// nothing at all.
class OrderService {
  const OrderService({
    required AppDatabase database,
    required Clock clock,
    InventoryEngine inventory = const InventoryEngine(),
    WhoIsWorking who = nobody,
  }) : _db = database,
       _inventory = inventory,
       _clock = clock,
       _who = who;

  final AppDatabase _db;
  final Clock _clock;
  final InventoryEngine _inventory;
  final WhoIsWorking _who;

  /// Commits [draft] and returns the record that was written.
  ///
  /// Throws a [BusinessRuleException] before touching the database if the
  /// order is not fit to complete — most importantly, an order paid by a
  /// method whose money has not been confirmed as arrived.
  Future<CompletedOrder> complete(
    OrderDraft draft, {
    required BusinessSettings settings,
    int? takenByUserId,
  }) async {
    final String? blocker = draft.whyNotComplete();
    if (blocker != null) throw BusinessRuleException(blocker);

    final PaymentMethod? method = draft.unpaid ? null : draft.paymentMethod!;
    final DateTime now = _clock.now();
    final String at = now.toUtc().toIso8601String();
    final String businessDate = BusinessDay(
      cutoffHour: settings.businessDayCutoffHour,
    ).dateOf(now);

    // Computed once, here, and written down. Recomputing a discount later —
    // after the shop registers for VAT, or after the statutory rate changes —
    // would silently rewrite what the customer was charged.
    final DiscountBreakdown discount = draft.discountWith(settings);
    final Money subtotal = draft.subtotal;
    final Money total = discount.amountDue + draft.deliveryFee;

    return _db.transaction<CompletedOrder>((Transaction txn) async {
      final _OrderNumber number = await _nextOrderNumber(
        txn,
        settings: settings,
        businessDate: businessDate,
      );

      final int orderId = await txn.insert('orders', <String, Object?>{
        'order_no': number.formatted,
        'sequence_no': number.sequence,
        'created_at': at,
        'business_date': businessDate,
        'customer_id': draft.customer?.id,
        'customer_name_snapshot': draft.customer?.name,
        'status': 'completed',
        'payment_state': draft.unpaid ? 'unpaid' : 'paid',
        'note': draft.note,
        'subtotal_centavos': subtotal.centavos,
        'discount_centavos': discount.discountAmount.centavos,
        'total_centavos': total.centavos,
        'vat_rate_bp': settings.effectiveVatRateBp,
        // A VAT-exempt sale carries no VAT at all; an ordinary sale in a
        // VAT-registered shop carries the VAT already inside the menu price.
        'vat_centavos': discount.isEmpty
            ? _vatWithin(subtotal, settings.effectiveVatRateBp)
            : 0,
        'vat_exempt_sales_centavos': discount.isEmpty
            ? 0
            : discount.discountableBase.centavos,
        'net_of_vat_centavos': discount.discountableBase.centavos,
        'delivery_fee_centavos': draft.deliveryFee.centavos,
        'taken_by_user_id': takenByUserId,
        // Filled in below, once every line has been costed.
        'cogs_centavos': 0,
        'gross_profit_centavos': 0,
        'refunded_centavos': 0,
        'item_count': draft.drinkCount,
      });

      await _writeDrinks(
        txn,
        orderId: orderId,
        draft: draft,
        settings: settings,
        discount: discount,
        costAsOf: now,
        at: at,
        businessDate: businessDate,
      );

      if (!discount.isEmpty) {
        await txn.insert('order_discounts', <String, Object?>{
          'order_id': orderId,
          'kind': discount.kind!.code,
          'name': draft.discountReason?.trim().isNotEmpty ?? false
              ? draft.discountReason!.trim()
              : discount.kind!.label,
          'rate_bp': discount.rateBp,
          'amount_centavos': discount.discountAmount.centavos,
          'vat_exempt_centavos': discount.vatRemoved.centavos,
          'beneficiary_name': draft.discountBeneficiaryName,
          'beneficiary_id_no': draft.discountBeneficiaryIdNo,
          'created_at': at,
        });
      }

      // An unpaid order writes no payment at all. A zero or pending row would
      // put a method on a receipt that nobody has paid with yet, and would
      // have to be unpicked when the money does arrive.
      if (method != null) {
        await txn.insert('payments', <String, Object?>{
          'order_id': orderId,
          'method': method.code,
          'method_name_snapshot': method.label,
          'amount_centavos': total.centavos,
          // Cash is settled the moment it is in the tin. A method that needs
          // confirming reached this line only because the owner ticked it.
          'status': 'confirmed',
          'reference_no': draft.paymentReference,
          'tendered_centavos': draft.tendered?.centavos,
          'change_centavos': draft.tendered == null
              ? null
              : draft.changeFrom(total).centavos,
          'created_at': at,
          'confirmed_at': at,
        });
      }

      final Customer? customer = draft.customer;
      if (customer != null) {
        await _updateCustomer(
          txn,
          customer: customer,
          draft: draft,
          at: at,
          total: total,
        );
        await _learnPatterns(
          txn,
          customerId: customer.id,
          draft: draft,
          at: at,
        );
      }

      await txn.insert('audit_log', <String, Object?>{
        'actor': _who(),
        'at': at,
        'business_date': businessDate,
        'action': 'order_completed',
        'entity_type': 'order',
        'entity_id': orderId,
        'summary':
            '${number.formatted} · ${draft.drinkCount} '
            'drink${draft.drinkCount == 1 ? '' : 's'} · '
            '${total.format()} · ${method?.label ?? 'UNPAID'}',
      });

      return CompletedOrder(
        id: orderId,
        orderNo: number.formatted,
        createdAt: now,
        businessDate: businessDate,
        total: total,
        drinkCount: draft.drinkCount,
        paymentMethod: method,
        customerName: customer?.name,
      );
    });
  }

  /// Changes an order that is already finished, in place.
  ///
  /// The customer changed their mind after the order was marked complete —
  /// a second drink, a size swapped, one taken off. The owner should be able
  /// to put that right without the order losing its identity, so this keeps
  /// the **same order number, the same date and the same receipt**: it is
  /// still order 1111, taken when it was taken. Only its contents change.
  ///
  /// Nothing is voided and no reversal appears on the day's takings, because
  /// nothing was cancelled. What the old drinks took off the shelf goes back
  /// as a correction and the new drinks take theirs, so the stock ledger
  /// still adds up and still says why it moved.
  ///
  /// Recipes and ingredient costs are read as of when the order was
  /// originally taken, not today: an edit corrects the record of that
  /// morning's sale, and a recipe changed since then has nothing to do with
  /// it. The drinks' *prices* are whatever the till has now, because that is
  /// what the customer is being charged.
  Future<CompletedOrder> revise({
    required int orderId,
    required OrderDraft draft,
    required BusinessSettings settings,
  }) async {
    final String? blocker = draft.whyNotComplete();
    if (blocker != null) throw BusinessRuleException(blocker);

    final List<Map<String, Object?>> rows = await _db.db.query(
      'orders',
      where: 'id = ?',
      whereArgs: <Object?>[orderId],
      limit: 1,
    );
    if (rows.isEmpty) throw const NotFoundException('That order is gone.');
    final Map<String, Object?> was = rows.first;

    if (was['status'] == 'voided') {
      throw const BusinessRuleException(
        'That order was voided. Ring it up again rather than editing it.',
      );
    }
    if (((was['refunded_centavos'] as int?) ?? 0) > 0) {
      throw const BusinessRuleException(
        'Part of this order has been refunded, so changing it would leave '
        'the money given back pointing at drinks that are no longer on it. '
        'Void it and ring up what they are having instead.',
      );
    }

    final String orderNo = was['order_no']! as String;
    final String takenAt = was['created_at']! as String;
    final String businessDate = was['business_date']! as String;
    // Costed against the recipes and prices of the day it was sold.
    final DateTime costAsOf = DateTime.parse(takenAt).toLocal();

    final DateTime now = _clock.now();
    final String at = now.toUtc().toIso8601String();
    final PaymentMethod? method = draft.unpaid ? null : draft.paymentMethod!;
    final DiscountBreakdown discount = draft.discountWith(settings);
    final Money subtotal = draft.subtotal;
    final Money total = discount.amountDue + draft.deliveryFee;

    return _db.transaction<CompletedOrder>((Transaction txn) async {
      // ── everything the old drinks did, undone ──
      final CostingEngine costing = CostingEngine(txn);
      final List<Map<String, Object?>> consumed = await txn.rawQuery(
        'SELECT m.ingredient_id AS id, SUM(m.qty_milli_delta) AS delta, '
        'i.base_unit AS unit '
        'FROM inventory_movements m '
        'JOIN ingredients i ON i.id = m.ingredient_id '
        // Every movement this order has caused, not only the original
        // sale: an order changed twice must put back what is still out,
        // not what the first version took.
        'WHERE m.order_id = ? '
        'GROUP BY m.ingredient_id '
        'HAVING SUM(m.qty_milli_delta) <> 0',
        <Object?>[orderId],
      );
      final List<PendingMovement> back = <PendingMovement>[];
      for (final Map<String, Object?> row in consumed) {
        final int ingredientId = row['id']! as int;
        back.add(
          PendingMovement(
            ingredientId: ingredientId,
            delta: Quantity(
              -(row['delta']! as int),
              BaseUnit.fromCode(row['unit']! as String),
            ),
            type: MovementType.correction,
            reason: 'Changed · $orderNo',
            orderId: orderId,
            // At what it cost when it was sold, not at today's price.
            unitCost: await costing.costOfIngredient(
              ingredientId,
              method: settings.costingMethod,
              asOf: costAsOf,
            ),
          ),
        );
      }
      await _inventory.post(txn, back, at: at, businessDate: businessDate);

      // ── the customer's history, as it stood before ──
      final int? wasCustomerId = was['customer_id'] as int?;
      if (wasCustomerId != null) {
        await txn.rawUpdate(
          'UPDATE customers SET '
          'order_count = MAX(0, order_count - 1), '
          'visit_count = MAX(0, visit_count - 1), '
          'item_count = MAX(0, item_count - ?), '
          'total_spend_centavos = MAX(0, total_spend_centavos - ?), '
          'updated_at = ? WHERE id = ?',
          <Object?>[
            (was['item_count'] as int?) ?? 0,
            (was['total_centavos'] as int?) ?? 0,
            at,
            wasCustomerId,
          ],
        );
        await _forgetPatterns(txn, orderId: orderId, customerId: wasCustomerId);
      }

      // ── the old contents, cleared ──
      await txn.rawDelete(
        'DELETE FROM order_item_customizations WHERE order_item_id IN '
        '(SELECT id FROM order_items WHERE order_id = ?)',
        <Object?>[orderId],
      );
      await txn.delete(
        'order_items',
        where: 'order_id = ?',
        whereArgs: <Object?>[orderId],
      );
      await txn.delete(
        'order_discounts',
        where: 'order_id = ?',
        whereArgs: <Object?>[orderId],
      );
      await txn.delete(
        'payments',
        where: 'order_id = ?',
        whereArgs: <Object?>[orderId],
      );

      // ── the order itself: same number, same day, new contents ──
      await txn.update(
        'orders',
        <String, Object?>{
          'customer_id': draft.customer?.id,
          'customer_name_snapshot': draft.customer?.name,
          'payment_state': draft.unpaid ? 'unpaid' : 'paid',
          'note': draft.note,
          'subtotal_centavos': subtotal.centavos,
          'discount_centavos': discount.discountAmount.centavos,
          'total_centavos': total.centavos,
          'vat_rate_bp': settings.effectiveVatRateBp,
          'vat_centavos': discount.isEmpty
              ? _vatWithin(subtotal, settings.effectiveVatRateBp)
              : 0,
          'vat_exempt_sales_centavos': discount.isEmpty
              ? 0
              : discount.discountableBase.centavos,
          'net_of_vat_centavos': discount.discountableBase.centavos,
          'delivery_fee_centavos': draft.deliveryFee.centavos,
          'item_count': draft.drinkCount,
          'cogs_centavos': 0,
          'gross_profit_centavos': 0,
          // When this correction was made. The other phone keeps the latest
          // one, which is the only way two tills can both be right about an
          // order that has been changed.
          'edited_at': at,
        },
        where: 'id = ?',
        whereArgs: <Object?>[orderId],
      );

      await _writeDrinks(
        txn,
        orderId: orderId,
        draft: draft,
        settings: settings,
        discount: discount,
        costAsOf: costAsOf,
        at: at,
        businessDate: businessDate,
      );

      if (!discount.isEmpty) {
        await txn.insert('order_discounts', <String, Object?>{
          'order_id': orderId,
          'kind': discount.kind!.code,
          'name': draft.discountReason?.trim().isNotEmpty ?? false
              ? draft.discountReason!.trim()
              : discount.kind!.label,
          'rate_bp': discount.rateBp,
          'amount_centavos': discount.discountAmount.centavos,
          'vat_exempt_centavos': discount.vatRemoved.centavos,
          'beneficiary_name': draft.discountBeneficiaryName,
          'beneficiary_id_no': draft.discountBeneficiaryIdNo,
          // The discount belongs to the sale, which happened when it
          // happened.
          'created_at': takenAt,
        });
      }

      if (method != null) {
        await txn.insert('payments', <String, Object?>{
          'order_id': orderId,
          'method': method.code,
          'method_name_snapshot': method.label,
          'amount_centavos': total.centavos,
          'status': 'confirmed',
          'reference_no': draft.paymentReference,
          'tendered_centavos': draft.tendered?.centavos,
          'change_centavos': draft.tendered == null
              ? null
              : draft.changeFrom(total).centavos,
          'created_at': takenAt,
          'confirmed_at': at,
        });
      }

      final Customer? customer = draft.customer;
      if (customer != null) {
        await _updateCustomer(
          txn,
          customer: customer,
          draft: draft,
          at: at,
          total: total,
        );
        await _learnPatterns(
          txn,
          customerId: customer.id,
          draft: draft,
          at: at,
        );
      }

      await txn.insert('audit_log', <String, Object?>{
        'actor': _who(),
        'at': at,
        'business_date': businessDate,
        'action': 'order_edited',
        'entity_type': 'order',
        'entity_id': orderId,
        'summary':
            '$orderNo changed · ${draft.drinkCount} '
            'drink${draft.drinkCount == 1 ? '' : 's'} · '
            '${total.format()} · ${method?.label ?? 'UNPAID'}',
      });

      return CompletedOrder(
        id: orderId,
        orderNo: orderNo,
        createdAt: DateTime.parse(takenAt).toLocal(),
        businessDate: businessDate,
        total: total,
        drinkCount: draft.drinkCount,
        paymentMethod: method,
        customerName: customer?.name,
      );
    });
  }

  /// Takes an order's drinks back out of what a customer is known to order.
  ///
  /// The same drink made the same way is one habit, counted by how often it
  /// happens, so the count comes down by the quantity that was on the line
  /// and a habit that falls to nothing stops being a habit.
  Future<void> _forgetPatterns(
    Transaction txn, {
    required int orderId,
    required int customerId,
  }) async {
    final List<Map<String, Object?>> items = await txn.query(
      'order_items',
      columns: <String>['id', 'product_id', 'size_id', 'quantity'],
      where: 'order_id = ?',
      whereArgs: <Object?>[orderId],
    );

    for (final Map<String, Object?> item in items) {
      final int? productId = item['product_id'] as int?;
      final int? sizeId = item['size_id'] as int?;
      if (productId == null || sizeId == null) continue;

      final List<Map<String, Object?>> optionRows = await txn.query(
        'order_item_customizations',
        columns: <String>['option_id'],
        where: 'order_item_id = ? AND option_id IS NOT NULL',
        whereArgs: <Object?>[item['id']],
        orderBy: 'display_order',
      );

      await txn.rawUpdate(
        'UPDATE customer_order_patterns '
        'SET occurrence_count = MAX(0, occurrence_count - ?) '
        'WHERE customer_id = ? AND signature = ?',
        <Object?>[
          item['quantity']! as int,
          customerId,
          orderSignature(
            productId: productId,
            sizeId: sizeId,
            optionIds: optionRows
                .map((Map<String, Object?> o) => o['option_id']! as int)
                .toList(),
          ),
        ],
      );
    }

    await txn.delete(
      'customer_order_patterns',
      where: 'customer_id = ? AND occurrence_count <= 0',
      whereArgs: <Object?>[customerId],
    );
  }

  /// Writes an order's drinks: what was chosen, what it cost to make, and
  /// what came off the shelf for it.
  ///
  /// Shared by ringing a sale up and by changing one afterwards, so that an
  /// edited order is costed and stocked by exactly the same arithmetic as a
  /// new one. [costAsOf] is the moment the recipes and prices are read at:
  /// for a new sale that is now, and for an edit it is when the order was
  /// originally taken, so that changing a recipe since then cannot rewrite
  /// what that morning's coffee cost.
  Future<void> _writeDrinks(
    Transaction txn, {
    required int orderId,
    required OrderDraft draft,
    required BusinessSettings settings,
    required DiscountBreakdown discount,
    required DateTime costAsOf,
    required String at,
    required String businessDate,
  }) async {
    final CostingEngine costing = CostingEngine(txn);
    final List<PendingMovement> movements = <PendingMovement>[];
    // What was chosen on each line is written in one go at the end: a
    // drink carries five or six of these, and on a phone's browser each
    // one written separately is a separate errand.
    final Batch chosen = txn.batch();
    bool anyChosen = false;
    int totalCogs = 0;
    int uncostedLines = 0;

    int lineNo = 1;
    for (final DraftItem item in draft.items) {
      // Cost against the recipe that is live *now*, and pin that version to
      // the line, so editing the recipe next month cannot rewrite this sale.
      final DrinkCost cost = await costing.costOf(
        item,
        method: settings.costingMethod,
        asOf: costAsOf,
      );
      final int unitCogs = cost.cost?.centavos ?? 0;
      final int lineCogs = unitCogs * item.quantity;
      if (cost.isCosted) {
        totalCogs += lineCogs;
      } else {
        uncostedLines++;
      }

      final int itemId = await txn.insert('order_items', <String, Object?>{
        'order_id': orderId,
        'line_no': lineNo++,
        'product_id': item.product.id,
        // Snapshots, so this order still reads correctly in a year even if
        // the drink is renamed, re-priced or archived.
        'product_name_snapshot': item.product.name,
        'size_id': item.size.size.id,
        'size_name_snapshot': item.size.size.name,
        'size_volume_oz_snapshot': item.size.size.volumeOz,
        'quantity': item.quantity,
        'unit_base_price_centavos': item.size.price.centavos,
        'unit_customization_centavos': item.unitCustomization.centavos,
        'unit_price_centavos': item.unitPrice.centavos,
        'line_total_centavos': item.lineTotal.centavos,
        // Null means this line could not be costed — deliberately not a
        // claim that the drink was free to make.
        'recipe_version_id': cost.isCosted ? cost.recipeVersionId : null,
        'unit_cogs_centavos': unitCogs,
        'line_cogs_centavos': lineCogs,
        'refunded_quantity': 0,
      });

      int optionOrder = 0;
      for (final DraftOption option in item.options) {
        anyChosen = true;
        chosen.insert('order_item_customizations', <String, Object?>{
          'order_item_id': itemId,
          'group_id': option.group.id,
          'group_name_snapshot': option.group.name,
          'option_id': option.option.id,
          'option_name_snapshot': option.option.name,
          'price_delta_centavos': option.priceDelta.centavos,
          // Whether this is simply what the drink comes with. The receipt
          // prints what was different, not what was never chosen.
          'was_default_snapshot': option.isDefault ? 1 : 0,
          'display_order': optionOrder++,
        });
      }

      // Stock comes out for what was actually used, whether or not a price
      // is known for it.
      for (final MapEntry<int, Quantity> used in cost.consumption.entries) {
        movements.add(
          PendingMovement(
            ingredientId: used.key,
            delta: -(used.value * item.quantity),
            type: MovementType.sale,
            orderId: orderId,
            orderItemId: itemId,
            reason: '${item.title} x${item.quantity}',
            unitCost: await costing.costOfIngredient(
              used.key,
              method: settings.costingMethod,
              asOf: costAsOf,
            ),
          ),
        );
      }
    }

    if (anyChosen) await chosen.commit(noResult: true);

    await _inventory.post(txn, movements, at: at, businessDate: businessDate);

    await txn.update(
      'orders',
      <String, Object?>{
        'cogs_centavos': totalCogs,
        // Profit is only claimed on the lines that were actually costed, and
        // is measured against what the drinks actually earned —
        // after any discount, and excluding the delivery fee, which is not
        // margin on coffee.
        'gross_profit_centavos':
            _costedRevenue(discount.amountDue, uncostedLines) - totalCogs,
      },
      where: 'id = ?',
      whereArgs: <Object?>[orderId],
    );
  }

  /// The next order number.
  ///
  /// The sequence is monotonic across the life of the business unless the
  /// owner has asked for a daily reset, because her worksheet said numbers run
  /// `K-0001` onwards and do not restart.
  Future<_OrderNumber> _nextOrderNumber(
    DatabaseExecutor txn, {
    required BusinessSettings settings,
    required String businessDate,
  }) async {
    final List<Map<String, Object?>> rows = settings.orderNumberResetDaily
        ? await txn.rawQuery(
            'SELECT MAX(sequence_no) AS m FROM orders WHERE business_date = ?',
            <Object?>[businessDate],
          )
        : await txn.rawQuery('SELECT MAX(sequence_no) AS m FROM orders');

    // The first order of the shop's life takes the number she chose — hers
    // start at 1001 — and every one after it follows the last. A counter
    // that restarts each morning is a count of the day, so it starts at 1
    // and the date in the number keeps it unique.
    final int last = (rows.first['m'] as int?) ?? 0;
    final int start = settings.orderNumberStart < 1
        ? 1
        : settings.orderNumberStart;
    // The first order of the shop's life takes the number she chose, and
    // every one after it follows the last — unless she has since set the
    // counter higher, which is how she moves it on without clearing the
    // books. It can only ever go forward: a start below what has already
    // been rung up would hand a second receipt a number that is taken.
    final int next = settings.orderNumberResetDaily
        ? last + 1
        : (start > last ? start : last + 1);
    final String digits = next.toString().padLeft(4, '0');
    final String prefix = settings.orderNumberPrefix.trim();

    // A daily-reset sequence produces "0001" again every morning, which is
    // ambiguous on a receipt and collides with the unique order number. When
    // the counter restarts, the day has to be part of the number.
    final String body = settings.orderNumberResetDaily
        ? '${businessDate.substring(5).replaceAll('-', '')}-$digits'
        : digits;

    return _OrderNumber(
      sequence: next,
      formatted: prefix.isEmpty ? body : '$prefix-$body',
    );
  }

  /// The number the next order will be given, without taking it.
  ///
  /// Shown on the POS while she is ringing one up, so that the receipt in
  /// her hand and the screen agree before she has committed anything. It
  /// reads the same counter the sale will, so it cannot disagree with it
  /// unless another till takes the number first — which is exactly what the
  /// number is for.
  Future<String> nextOrderNumber({
    required BusinessSettings settings,
    DateTime? now,
  }) async {
    final DateTime at = now ?? _clock.now();
    final _OrderNumber number = await _nextOrderNumber(
      _db.db,
      settings: settings,
      businessDate: BusinessDay(
        cutoffHour: settings.businessDayCutoffHour,
      ).dateOf(at),
    );
    return number.formatted;
  }

  Future<void> _updateCustomer(
    Transaction txn, {
    required Customer customer,
    required OrderDraft draft,
    required String at,
    required Money total,
  }) async {
    // Counted from the row as it stands, not from the copy the till is
    // holding. That copy was loaded when she picked the customer, so two
    // orders for the same person without reselecting them in between both
    // wrote "order number one" and the history stopped growing.
    await txn.rawUpdate(
      '''
      UPDATE customers SET
        first_visit_at       = IFNULL(first_visit_at, ?),
        last_visit_at        = ?,
        visit_count          = visit_count + 1,
        order_count          = order_count + 1,
        item_count           = item_count + ?,
        total_spend_centavos = total_spend_centavos + ?,
        updated_at           = ?
      WHERE id = ?
      ''',
      <Object?>[at, at, draft.drinkCount, total.centavos, at, customer.id],
    );

    // The segment follows the order count, except where she has marked
    // somebody VIP herself. A judgement she made by hand should not be
    // undone by the next cup they buy.
    final List<Map<String, Object?>> row = await txn.query(
      'customers',
      columns: <String>['order_count', 'segment'],
      where: 'id = ?',
      whereArgs: <Object?>[customer.id],
      limit: 1,
    );
    if (row.isEmpty) return;
    if (row.first['segment'] == CustomerSegment.vip.code) return;
    await txn.update(
      'customers',
      <String, Object?>{
        'segment': CustomerSegment.fromOrderCount(
          row.first['order_count']! as int,
        ).code,
      },
      where: 'id = ?',
      whereArgs: <Object?>[customer.id],
    );
  }

  /// Records what this customer ordered, so their usual can be worked out from
  /// repetition rather than from whatever they bought last.
  Future<void> _learnPatterns(
    Transaction txn, {
    required int customerId,
    required OrderDraft draft,
    required String at,
  }) async {
    // Two identical lines in one order are two orders of that drink.
    final Map<String, int> counts = <String, int>{};
    final Map<String, DraftItem> bySignature = <String, DraftItem>{};
    for (final DraftItem item in draft.items) {
      counts.update(
        item.signature,
        (int c) => c + item.quantity,
        ifAbsent: () => item.quantity,
      );
      bySignature[item.signature] = item;
    }

    for (final MapEntry<String, int> entry in counts.entries) {
      final DraftItem item = bySignature[entry.key]!;
      final List<int> optionIds =
          item.options.map((DraftOption o) => o.option.id).toList()..sort();

      final int changed = await txn.rawUpdate(
        'UPDATE customer_order_patterns '
        'SET occurrence_count = occurrence_count + ?, last_ordered_at = ? '
        'WHERE customer_id = ? AND signature = ?',
        <Object?>[entry.value, at, customerId, entry.key],
      );
      if (changed == 0) {
        await txn.insert('customer_order_patterns', <String, Object?>{
          'customer_id': customerId,
          'signature': entry.key,
          'product_id': item.product.id,
          'size_id': item.size.size.id,
          'option_ids_json': optionIds.join(','),
          'occurrence_count': entry.value,
          'first_ordered_at': at,
          'last_ordered_at': at,
        });
      }
    }
  }
}

/// Revenue from the lines that could be costed.
///
/// Gross profit is only claimed against those: counting an uncosted drink's
/// full price as profit would flatter every report that reads this number.
int _costedRevenue(Money drinksRevenue, int uncostedLines) {
  if (uncostedLines == 0) return drinksRevenue.centavos;
  return 0;
}

/// The VAT already inside a VAT-inclusive amount.
int _vatWithin(Money inclusive, int rateBp) {
  if (rateBp <= 0) return 0;
  final int net =
      ((inclusive.centavos * 10000) + (10000 + rateBp) ~/ 2) ~/
      (10000 + rateBp);
  return inclusive.centavos - net;
}

class _OrderNumber {
  const _OrderNumber({required this.sequence, required this.formatted});

  final int sequence;
  final String formatted;
}
