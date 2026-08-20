import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money/money.dart';
import '../../../domain/entities/customer.dart';
import '../../../domain/entities/menu.dart';
import '../../../domain/entities/order_draft.dart';

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

  /// Adds a drink. Returns the line so the caller can scroll to it.
  DraftItem addItem({
    required Product product,
    required ProductSize size,
    required List<DraftOption> options,
    int quantity = 1,
  }) {
    final DraftItem item = DraftItem(
      lineId: _newLineId(),
      product: product,
      size: size,
      quantity: quantity < 1 ? 1 : quantity,
      options: options,
    );
    state = state.copyWith(items: <DraftItem>[...state.items, item]);
    return item;
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

  /// Choosing GCash never marks an order paid — the confirmation is separate,
  /// and is cleared here so switching methods cannot carry one over.
  void setPaymentMethod(PaymentMethod? method) {
    if (method == null) {
      state = state.copyWith(
        clearPaymentMethod: true,
        gcashConfirmed: false,
        clearTendered: true,
      );
      return;
    }
    state = state.copyWith(
      paymentMethod: method,
      gcashConfirmed: false,
      gcashReference: '',
      clearTendered: true,
    );
  }

  void setGcashConfirmed(bool confirmed) {
    state = state.copyWith(gcashConfirmed: confirmed);
  }

  void setGcashReference(String reference) {
    state = state.copyWith(gcashReference: reference);
  }

  void setTendered(Money? amount) {
    state = amount == null
        ? state.copyWith(clearTendered: true)
        : state.copyWith(tendered: amount);
  }

  /// Back to an empty order, ready for the next customer.
  void clear() {
    state = const OrderDraft();
  }
}

final NotifierProvider<CartController, OrderDraft> cartProvider =
    NotifierProvider<CartController, OrderDraft>(CartController.new);
