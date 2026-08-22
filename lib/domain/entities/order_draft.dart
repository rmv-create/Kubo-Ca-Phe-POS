import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../core/money/money.dart';
import '../services/discount_engine.dart';
import 'business_settings.dart';
import 'customer.dart';
import 'menu.dart';

/// A way of taking money, as the owner has configured it.
///
/// This was an enum in V1, when Cash and GCash were the only two and both were
/// hard-coded. The owner now adds and retires methods herself, so a method is
/// a row in `payment_methods` — but it stays a value type here so the domain
/// never reaches for the database mid-order. [cash] and [gcash] remain as the
/// two the app ships with.
@immutable
class PaymentMethod {
  const PaymentMethod({
    required this.code,
    required this.label,
    this.id,
    this.needsConfirmation = false,
    this.takesReference = false,
    this.takesTendered = false,
    this.isActive = true,
    this.displayOrder = 0,
  });

  /// Money in the tin. Settled the moment it is handed over, and the only
  /// method that can work out change.
  static const PaymentMethod cash = PaymentMethod(
    code: 'cash',
    label: 'Cash',
    takesTendered: true,
    displayOrder: 1,
  );

  /// Money that lands in an app the POS cannot see, so the owner has to
  /// confirm it arrived before the order counts as paid.
  static const PaymentMethod gcash = PaymentMethod(
    code: 'gcash',
    label: 'GCash',
    needsConfirmation: true,
    takesReference: true,
    displayOrder: 2,
  );

  /// The two the app ships with, used before any have been loaded.
  static const List<PaymentMethod> builtIn = <PaymentMethod>[cash, gcash];

  /// Row id, null for the built-in constants.
  final int? id;

  /// Stable identifier written to `payments.method`. Never renamed.
  final String code;

  /// What the button says. The owner can change this; past receipts keep the
  /// name they were printed with.
  final String label;

  /// Whether the owner must confirm the money actually arrived.
  final bool needsConfirmation;

  /// Whether the method can carry a reference number.
  final bool takesReference;

  /// Whether the POS asks what was handed over and works out the change.
  final bool takesTendered;

  final bool isActive;
  final int displayOrder;

  PaymentMethod copyWith({
    String? label,
    bool? needsConfirmation,
    bool? takesReference,
    bool? takesTendered,
    bool? isActive,
    int? displayOrder,
  }) => PaymentMethod(
    id: id,
    code: code,
    label: label ?? this.label,
    needsConfirmation: needsConfirmation ?? this.needsConfirmation,
    takesReference: takesReference ?? this.takesReference,
    takesTendered: takesTendered ?? this.takesTendered,
    isActive: isActive ?? this.isActive,
    displayOrder: displayOrder ?? this.displayOrder,
  );

  /// The same method once the database has given it an id.
  PaymentMethod withId(int id, String code) => PaymentMethod(
    id: id,
    code: code,
    label: label,
    needsConfirmation: needsConfirmation,
    takesReference: takesReference,
    takesTendered: takesTendered,
    isActive: isActive,
    displayOrder: displayOrder,
  );

  /// Rebuilds a method from a stored payment row. [name] is the snapshot taken
  /// when the sale was rung, so an old receipt still reads as it was printed.
  static PaymentMethod fromRow(String code, [String? name]) {
    final PaymentMethod? known = builtIn
        .where((PaymentMethod m) => m.code == code)
        .firstOrNull;
    if (name == null || name.isEmpty) {
      return known ?? PaymentMethod(code: code, label: code);
    }
    return (known ?? PaymentMethod(code: code, label: name)).copyWith(
      label: name,
    );
  }

  /// Two methods are the same method when they share a code.
  @override
  bool operator ==(Object other) =>
      other is PaymentMethod && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'PaymentMethod($code)';
}

/// One chosen option, with the group it came from, so the order line can be
/// written down exactly as it was sold.
@immutable
class DraftOption {
  const DraftOption({
    required this.group,
    required this.option,
    this.isDefault = false,
  });

  final CustomizationGroup group;
  final CustomizationOption option;

  /// Whether this is what the drink comes with anyway.
  ///
  /// A default that was left alone is not a modification and does not belong
  /// on the order line. Anything the customer actually asked for does — free
  /// or not, and whether or not the group was one the POS offered up front.
  final bool isDefault;

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

  /// Every modification, for the order line and the receipt.
  ///
  /// "Regular ice" on a drink that always comes with regular ice is noise, so
  /// untouched defaults are left out. Everything else is in: *less sweet* costs
  /// nothing and was never asked for up front, and it is exactly the thing a
  /// customer checks the cup for.
  List<DraftOption> get notableOptions => options
      .where((DraftOption o) => !o.isDefault || !o.priceDelta.isZero)
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
    this.paymentConfirmed = false,
    this.paymentReference,
    this.tendered,
    this.discountKind,
    this.discountBeneficiaryName,
    this.discountBeneficiaryIdNo,
    this.deliveryFee = Money.zero,
  });

  /// Null means a guest. A sale is never blocked on a customer.
  final Customer? customer;

  final List<DraftItem> items;
  final PaymentMethod? paymentMethod;

  /// Set only when the owner has confirmed the money arrived. Only methods
  /// that ask for it — GCash and anything like it — need this.
  final bool paymentConfirmed;
  final String? paymentReference;

  /// Cash handed over, for change. Optional.
  final Money? tendered;

  /// Senior Citizen, PWD, or nothing. The amount is never typed in; it is
  /// computed by the discount engine from this and the shop's VAT position.
  final DiscountKind? discountKind;

  /// Who claimed the statutory discount. RA 9994 and RA 10754 make the shop
  /// record this; a blank never blocks the sale, but the receipt shows the gap.
  final String? discountBeneficiaryName;
  final String? discountBeneficiaryIdNo;

  /// Charged on top, after any discount. Never discounted itself.
  final Money deliveryFee;

  bool get isEmpty => items.isEmpty;

  int get drinkCount =>
      items.fold(0, (int sum, DraftItem i) => sum + i.quantity);

  /// The menu total of the drinks, before any discount or delivery fee.
  Money get subtotal => items.map((DraftItem i) => i.lineTotal).sum();

  /// What the discount, if any, does to [subtotal]. Pure arithmetic — call it
  /// as often as you like.
  DiscountBreakdown discountWith(BusinessSettings settings) =>
      DiscountEngine(settings).apply(kind: discountKind, grossSales: subtotal);

  /// What the customer actually pays, discount and delivery included.
  Money totalWith(BusinessSettings settings) =>
      discountWith(settings).amountDue + deliveryFee;

  Money changeFrom(Money total) {
    final Money? paid = tendered;
    if (paid == null || !(paymentMethod?.takesTendered ?? false)) {
      return Money.zero;
    }
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
    if (method == null) return 'Choose how it was paid.';
    if (method.needsConfirmation && !paymentConfirmed) {
      return 'Confirm the ${method.label} payment arrived.';
    }
    return null;
  }

  OrderDraft copyWith({
    Customer? customer,
    bool clearCustomer = false,
    List<DraftItem>? items,
    PaymentMethod? paymentMethod,
    bool clearPaymentMethod = false,
    bool? paymentConfirmed,
    String? paymentReference,
    Money? tendered,
    bool clearTendered = false,
    DiscountKind? discountKind,
    bool clearDiscount = false,
    String? discountBeneficiaryName,
    String? discountBeneficiaryIdNo,
    Money? deliveryFee,
  }) => OrderDraft(
    customer: clearCustomer ? null : (customer ?? this.customer),
    items: items ?? this.items,
    paymentMethod: clearPaymentMethod
        ? null
        : (paymentMethod ?? this.paymentMethod),
    paymentConfirmed: paymentConfirmed ?? this.paymentConfirmed,
    paymentReference: paymentReference ?? this.paymentReference,
    tendered: clearTendered ? null : (tendered ?? this.tendered),
    discountKind: clearDiscount ? null : (discountKind ?? this.discountKind),
    discountBeneficiaryName: clearDiscount
        ? null
        : (discountBeneficiaryName ?? this.discountBeneficiaryName),
    discountBeneficiaryIdNo: clearDiscount
        ? null
        : (discountBeneficiaryIdNo ?? this.discountBeneficiaryIdNo),
    deliveryFee: deliveryFee ?? this.deliveryFee,
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
