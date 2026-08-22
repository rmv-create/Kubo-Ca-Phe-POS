import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money/money.dart';
import '../../../domain/entities/customer.dart';
import '../../../domain/entities/menu.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../domain/services/discount_engine.dart';

/// The order being built, held entirely in memory.
///
/// Nothing here writes to the database. That is the point: the owner can
/// build, change her mind, and rebuild an order without ever leaving a partial
/// sale behind, and the whole thing lands in one transaction at the end.
///
/// The iPhone and iPad layouts share this exact controller — the presentation
/// differs, the order does not.
class CartController extends Notifier<OrderDraft> {
  int _nextLineId = 1;

  @override
  OrderDraft build() => const OrderDraft();

  String _newLineId() => 'line-${_nextLineId++}';

  // ─────────────────────────────── items ───────────────────────────────

  /// Adds a drink. Returns the line it landed on, so the caller can show it.
  ///
  /// Two of the same drink, made the same way, are one line of two — not two
  /// lines of one. Ordering a second identical Spanish Latte therefore bumps
  /// the quantity of the line already there. Where the customer genuinely
  /// wants them tracked apart, [duplicateItem] still makes a separate line.
  DraftItem addItem({
    required Product product,
    required ProductSize size,
    required List<DraftOption> options,
    int quantity = 1,
  }) {
    final int wanted = quantity < 1 ? 1 : quantity;
    final DraftItem candidate = DraftItem(
      lineId: _newLineId(),
      product: product,
      size: size,
      quantity: wanted,
      options: options,
    );

    final DraftItem? existing = state.items
        .where((DraftItem i) => i.signature == candidate.signature)
        .lastOrNull;
    if (existing != null) {
      final DraftItem merged = existing.copyWith(
        quantity: existing.quantity + wanted,
      );
      replaceItem(existing.lineId, merged);
      return merged;
    }

    state = state.copyWith(items: <DraftItem>[...state.items, candidate]);
    return candidate;
  }

  void replaceItem(String lineId, DraftItem replacement) {
    state = state.copyWith(
      items: state.items
          .map((DraftItem i) => i.lineId == lineId ? replacement : i)
          .toList(),
    );
  }

  /// Same drink again, without rebuilding it.
  void duplicateItem(String lineId) {
    final DraftItem? source = itemById(lineId);
    if (source == null) return;
    final int index = state.items.indexOf(source);
    final List<DraftItem> next = List<DraftItem>.of(state.items)
      ..insert(index + 1, source.duplicatedAs(_newLineId()));
    state = state.copyWith(items: next);
  }

  void setQuantity(String lineId, int quantity) {
    if (quantity < 1) {
      removeItem(lineId);
      return;
    }
    final DraftItem? item = itemById(lineId);
    if (item == null) return;
    replaceItem(lineId, item.copyWith(quantity: quantity));
  }

  void increment(String lineId) {
    final DraftItem? item = itemById(lineId);
    if (item != null) setQuantity(lineId, item.quantity + 1);
  }

  void decrement(String lineId) {
    final DraftItem? item = itemById(lineId);
    if (item != null) setQuantity(lineId, item.quantity - 1);
  }

  void removeItem(String lineId) {
    state = state.copyWith(
      items: state.items.where((DraftItem i) => i.lineId != lineId).toList(),
    );
  }

  DraftItem? itemById(String lineId) {
    for (final DraftItem i in state.items) {
      if (i.lineId == lineId) return i;
    }
    return null;
  }

  // ────────────────────────────── customer ──────────────────────────────

  void setCustomer(Customer? customer) {
    state = customer == null
        ? state.copyWith(clearCustomer: true)
        : state.copyWith(customer: customer);
  }

  // ─────────────────────────────── payment ───────────────────────────────

  /// Choosing a method never marks an order paid — the confirmation is
  /// separate, and is cleared here so switching methods cannot carry one over.
  void setPaymentMethod(PaymentMethod? method) {
    if (method == null) {
      state = state.copyWith(
        clearPaymentMethod: true,
        paymentConfirmed: false,
        clearTendered: true,
      );
      return;
    }
    state = state.copyWith(
      paymentMethod: method,
      paymentConfirmed: false,
      paymentReference: '',
      clearTendered: true,
    );
  }

  void setPaymentConfirmed(bool confirmed) {
    state = state.copyWith(paymentConfirmed: confirmed);
  }

  void setPaymentReference(String reference) {
    state = state.copyWith(paymentReference: reference);
  }

  void setTendered(Money? amount) {
    state = amount == null
        ? state.copyWith(clearTendered: true)
        : state.copyWith(tendered: amount);
  }

  // ───────────────────────── discount & delivery ─────────────────────────

  /// Chooses a Senior Citizen or PWD discount, or clears it.
  ///
  /// The amount is never set here. It is derived from the order and the shop's
  /// VAT position every time it is read, so it cannot fall out of step with
  /// what was actually ordered.
  void setDiscount(
    DiscountKind? kind, {
    String? beneficiaryName,
    String? beneficiaryIdNo,
  }) {
    state = kind == null
        ? state.copyWith(clearDiscount: true)
        : state.copyWith(
            discountKind: kind,
            discountBeneficiaryName: beneficiaryName,
            discountBeneficiaryIdNo: beneficiaryIdNo,
          );
  }

  void setDeliveryFee(Money fee) {
    state = state.copyWith(deliveryFee: fee.isNegative ? Money.zero : fee);
  }

  /// Back to an empty order, ready for the next customer.
  void clear() {
    state = const OrderDraft();
  }
}

final NotifierProvider<CartController, OrderDraft> cartProvider =
    NotifierProvider<CartController, OrderDraft>(CartController.new);
