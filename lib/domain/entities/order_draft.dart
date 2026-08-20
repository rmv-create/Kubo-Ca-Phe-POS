import 'package:meta/meta.dart';

import '../../core/money/money.dart';
import 'customer.dart';
import 'menu.dart';

enum PaymentMethod {
  cash('cash', 'Cash'),
  gcash('gcash', 'GCash');

  const PaymentMethod(this.code, this.label);

  final String code;
  final String label;

  /// GCash arrives in an app the POS cannot see, so the owner has to confirm
  /// the money landed before an order counts as paid.
  bool get needsConfirmation => this == PaymentMethod.gcash;

  static PaymentMethod fromCode(String code) =>
      code == 'gcash' ? PaymentMethod.gcash : PaymentMethod.cash;
}

/// One chosen option, with the group it came from, so the order line can be
/// written down exactly as it was sold.
@immutable
class DraftOption {
  const DraftOption({required this.group, required this.option});

  final CustomizationGroup group;
  final CustomizationOption option;

  Money get priceDelta => option.priceDelta;
}

/// A drink in the order that has not been committed yet.
///
/// Draft items live only in memory. Nothing reaches the database until
/// COMPLETE ORDER, so a half-built order can never leave a half-written sale.
@immutable
class DraftItem {
  const DraftItem({
    required this.lineId,
    required this.product,
    required this.size,
    required this.quantity,
    required this.options,
  });

  /// Local identity, so the UI can edit and remove the right line even when
  /// two lines are otherwise identical.
  final String lineId;

  final Product product;
  final ProductSize size;
  final int quantity;
  final List<DraftOption> options;

  /// What the chosen options add to one drink.
  Money get unitCustomization =>
      options.map((DraftOption o) => o.priceDelta).sum();

  Money get unitPrice => size.price + unitCustomization;

  Money get lineTotal => unitPrice * quantity;

  /// Options worth showing on the order line. A free, pre-selected choice like
  /// "Regular ice" is noise; anything the customer actually asked for is not.
  List<DraftOption> get notableOptions => options
      .where((DraftOption o) => o.group.isProactive || !o.priceDelta.isZero)
      .toList();

  String get optionsLabel =>
      options.map((DraftOption o) => o.option.name).join(' · ');

  String get title => '${size.size.name} ${product.name}';

  DraftItem copyWith({
    int? quantity,
    List<DraftOption>? options,
    ProductSize? size,
  }) => DraftItem(
    lineId: lineId,
    product: product,
    size: size ?? this.size,
    quantity: quantity ?? this.quantity,
    options: options ?? this.options,
  );

  /// Same drink, new line identity — for the duplicate action.
  DraftItem duplicatedAs(String newLineId) => DraftItem(
    lineId: newLineId,
    product: product,
    size: size,
    quantity: quantity,
    options: options,
  );

  /// Stable identity of *what was ordered*, ignoring quantity and line id.
  /// Two lines with the same signature are the same drink.
  String get signature => orderSignature(
    productId: product.id,
    sizeId: size.size.id,
    optionIds: options.map((DraftOption o) => o.option.id),
  );
}

/// The order being built.
@immutable
class OrderDraft {
  const OrderDraft({
    this.customer,
    this.items = const <DraftItem>[],
    this.paymentMethod,
    this.gcashConfirmed = false,
    this.gcashReference,
    this.tendered,
  });

  /// Null means a guest. A sale is never blocked on a customer.
  final Customer? customer;

  final List<DraftItem> items;
  final PaymentMethod? paymentMethod;

  /// Set only when the owner has confirmed the GCash payment arrived.
  final bool gcashConfirmed;
  final String? gcashReference;

  /// Cash handed over, for change. Optional.
  final Money? tendered;

  bool get isEmpty => items.isEmpty;

  int get drinkCount =>
      items.fold(0, (int sum, DraftItem i) => sum + i.quantity);

  Money get total => items.map((DraftItem i) => i.lineTotal).sum();

  Money get change {
    final Money? paid = tendered;
    if (paid == null || paymentMethod != PaymentMethod.cash) return Money.zero;
    final Money diff = paid - total;
    return diff.isNegative ? Money.zero : diff;
  }

  /// True when COMPLETE ORDER may be pressed.
  bool get canComplete => whyNotComplete() == null;

  /// The single reason the order cannot be completed, in words the owner can
  /// act on — or null when it can.
  String? whyNotComplete() {
    if (items.isEmpty) return 'Add a drink first.';
    final PaymentMethod? method = paymentMethod;
    if (method == null) return 'Choose Cash or GCash.';
    if (method.needsConfirmation && !gcashConfirmed) {
      return 'Confirm the GCash payment arrived.';
    }
    return null;
  }

  OrderDraft copyWith({
    Customer? customer,
    bool clearCustomer = false,
    List<DraftItem>? items,
    PaymentMethod? paymentMethod,
    bool clearPaymentMethod = false,
    bool? gcashConfirmed,
    String? gcashReference,
    Money? tendered,
    bool clearTendered = false,
  }) => OrderDraft(
    customer: clearCustomer ? null : (customer ?? this.customer),
    items: items ?? this.items,
    paymentMethod: clearPaymentMethod
        ? null
        : (paymentMethod ?? this.paymentMethod),
    gcashConfirmed: gcashConfirmed ?? this.gcashConfirmed,
    gcashReference: gcashReference ?? this.gcashReference,
    tendered: clearTendered ? null : (tendered ?? this.tendered),
  );
}

/// A stable fingerprint of one drink configuration.
///
/// Option ids are sorted so that picking Oat then Vanilla and picking Vanilla
/// then Oat produce the same signature — otherwise a customer's usual would
/// never accumulate a count.
String orderSignature({
  required int productId,
  required int sizeId,
  required Iterable<int> optionIds,
}) {
  final List<int> sorted = optionIds.toList()..sort();
  return 'p$productId|s$sizeId|o${sorted.join(',')}';
}

/// What a completed order looks like coming back out of the database.
@immutable
class CompletedOrder {
  const CompletedOrder({
    required this.id,
    required this.orderNo,
    required this.createdAt,
    required this.businessDate,
    required this.total,
    required this.drinkCount,
    required this.paymentMethod,
    this.customerName,
  });

  final int id;
  final String orderNo;
  final DateTime createdAt;
  final String businessDate;
  final Money total;
  final int drinkCount;
  final PaymentMethod paymentMethod;
  final String? customerName;
}
