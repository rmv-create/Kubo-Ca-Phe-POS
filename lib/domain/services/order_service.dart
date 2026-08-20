import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/money/money.dart';
import '../../core/quantity/quantity.dart';
import '../../core/time/clock.dart';
import '../../data/db/app_database.dart';
import '../entities/business_settings.dart';
import '../entities/customer.dart';
import '../entities/ingredient.dart';
import '../entities/order_draft.dart';
import 'costing_engine.dart';
import 'inventory_engine.dart';

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
  }) : _db = database,
       _inventory = inventory,
       _clock = clock;

  final AppDatabase _db;
  final Clock _clock;
  final InventoryEngine _inventory;

  /// Commits [draft] and returns the record that was written.
  ///
  /// Throws a [BusinessRuleException] before touching the database if the
  /// order is not fit to complete — most importantly, a GCash order whose
  /// payment has not been confirmed.
  Future<CompletedOrder> complete(
    OrderDraft draft, {
    required BusinessSettings settings,
  }) async {
    final String? blocker = draft.whyNotComplete();
    if (blocker != null) throw BusinessRuleException(blocker);

    final PaymentMethod method = draft.paymentMethod!;
    final DateTime now = _clock.now();
    final String at = now.toUtc().toIso8601String();
    final String businessDate = BusinessDay(
      cutoffHour: settings.businessDayCutoffHour,
    ).dateOf(now);
    final Money total = draft.total;

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
        'subtotal_centavos': total.centavos,
        'discount_centavos': 0,
        'total_centavos': total.centavos,
        // Filled in below, once every line has been costed.
        'cogs_centavos': 0,
        'gross_profit_centavos': 0,
        'refunded_centavos': 0,
        'item_count': draft.drinkCount,
      });

      final CostingEngine costing = CostingEngine(txn);
      final List<PendingMovement> movements = <PendingMovement>[];
      int totalCogs = 0;
      int uncostedLines = 0;

      int lineNo = 1;
      for (final DraftItem item in draft.items) {
        // Cost against the recipe that is live *now*, and pin that version to
        // the line, so editing the recipe next month cannot rewrite this sale.
        final DrinkCost cost = await costing.costOf(
          item,
          method: settings.costingMethod,
          asOf: now,
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
          await txn.insert('order_item_customizations', <String, Object?>{
            'order_item_id': itemId,
            'group_id': option.group.id,
            'group_name_snapshot': option.group.name,
            'option_id': option.option.id,
            'option_name_snapshot': option.option.name,
            'price_delta_centavos': option.priceDelta.centavos,
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
                asOf: now,
              ),
            ),
          );
        }
      }

      await _inventory.post(txn, movements, at: at, businessDate: businessDate);

      await txn.update(
        'orders',
        <String, Object?>{
          'cogs_centavos': totalCogs,
          // Profit is only claimed on the lines that were actually costed.
          'gross_profit_centavos':
              _costedRevenue(draft, uncostedLines) - totalCogs,
        },
        where: 'id = ?',
        whereArgs: <Object?>[orderId],
      );

      await txn.insert('payments', <String, Object?>{
        'order_id': orderId,
        'method': method.code,
        'amount_centavos': total.centavos,
        // Cash is settled the moment it is in the tin. GCash reached this line
        // only because the owner ticked the confirmation.
        'status': 'confirmed',
        'reference_no': draft.gcashReference,
        'tendered_centavos': draft.tendered?.centavos,
        'change_centavos': draft.tendered == null
            ? null
            : draft.change.centavos,
        'created_at': at,
        'confirmed_at': at,
      });

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
        'at': at,
        'business_date': businessDate,
        'action': 'order_completed',
        'entity_type': 'order',
        'entity_id': orderId,
        'summary':
            '${number.formatted} · ${draft.drinkCount} '
            'drink${draft.drinkCount == 1 ? '' : 's'} · '
            '${total.format()} · ${method.label}',
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

  /// The next order number.
  ///
  /// The sequence is monotonic across the life of the business unless the
  /// owner has asked for a daily reset, because her worksheet said numbers run
  /// `K-0001` onwards and do not restart.
  Future<_OrderNumber> _nextOrderNumber(
    Transaction txn, {
    required BusinessSettings settings,
    required String businessDate,
  }) async {
    final List<Map<String, Object?>> rows = settings.orderNumberResetDaily
        ? await txn.rawQuery(
            'SELECT MAX(sequence_no) AS m FROM orders WHERE business_date = ?',
            <Object?>[businessDate],
          )
        : await txn.rawQuery('SELECT MAX(sequence_no) AS m FROM orders');

    final int next = ((rows.first['m'] as int?) ?? 0) + 1;
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

  Future<void> _updateCustomer(
    Transaction txn, {
    required Customer customer,
    required OrderDraft draft,
    required String at,
    required Money total,
  }) async {
    final int orders = customer.orderCount + 1;
    await txn.update(
      'customers',
      <String, Object?>{
        'first_visit_at':
            customer.firstVisitAt?.toUtc().toIso8601String() ?? at,
        'last_visit_at': at,
        'visit_count': customer.visitCount + 1,
        'order_count': orders,
        'item_count': customer.itemCount + draft.drinkCount,
        'total_spend_centavos': customer.totalSpend.centavos + total.centavos,
        'segment': CustomerSegment.fromOrderCount(orders).code,
        'updated_at': at,
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
int _costedRevenue(OrderDraft draft, int uncostedLines) {
  if (uncostedLines == 0) return draft.total.centavos;
  return 0;
}

class _OrderNumber {
  const _OrderNumber({required this.sequence, required this.formatted});

  final int sequence;
  final String formatted;
}
