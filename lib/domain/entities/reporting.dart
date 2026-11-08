import 'package:meta/meta.dart';

import '../../core/money/money.dart';
import 'order_draft.dart';

/// A completed sale as it reads back out of the database.
@immutable
class OrderRecord {
  const OrderRecord({
    required this.id,
    required this.orderNo,
    required this.createdAt,
    required this.businessDate,
    required this.status,
    required this.total,
    required this.cogs,
    required this.grossProfit,
    required this.refunded,
    required this.itemCount,
    required this.uncostedLines,
    required this.lines,
    this.subtotal = Money.zero,
    this.discount = Money.zero,
    this.deliveryFee = Money.zero,
    this.vat = Money.zero,
    this.vatRateBp = 0,
    this.discountLabel,
    this.discountRateBp = 0,
    this.discountVatExempt = Money.zero,
    this.discountBeneficiaryName,
    this.discountBeneficiaryIdNo,
    this.customerId,
    this.customerName,
    this.paymentMethod,
    this.paymentReference,
    this.tendered,
    this.change,
    this.voidReason,
    this.paymentState = 'paid',
    this.note,
  });

  final int id;
  final String orderNo;
  final DateTime createdAt;
  final String businessDate;

  /// `completed` or `voided`.
  final String status;

  final Money total;
  final Money cogs;
  final Money grossProfit;
  final Money refunded;
  final int itemCount;

  /// Lines that could not be costed, because there is no recipe or an
  /// ingredient has no price.
  final int uncostedLines;

  final List<OrderLineRecord> lines;

  /// The menu total of the drinks, before anything was taken off or added.
  final Money subtotal;

  /// What the discount took off, and what kind it was.
  final Money discount;
  final String? discountLabel;
  final int discountRateBp;

  /// The VAT the customer did not pay because the sale was exempt.
  final Money discountVatExempt;
  final String? discountBeneficiaryName;
  final String? discountBeneficiaryIdNo;

  final Money deliveryFee;

  /// VAT inside this sale, and the rate assumed when it was rung.
  final Money vat;
  final int vatRateBp;

  final int? customerId;
  final String? customerName;
  final PaymentMethod? paymentMethod;
  final String? paymentReference;
  final Money? tendered;
  final Money? change;
  final String? voidReason;

  /// `paid` or `unpaid`. An unpaid order is a real sale whose money has not
  /// arrived; it carries no payment method until it does.
  final String paymentState;

  /// Whatever the owner wrote on this one order, printed on the receipt.
  final String? note;

  bool get isUnpaid => paymentState == 'unpaid';

  bool get hasDiscount => discount.isPositive;

  bool get isVoided => status == 'voided';
  bool get isRefunded => refunded.isPositive;
  bool get isFullyRefunded => refunded >= total;
  bool get isCosted => uncostedLines == 0;

  /// What this order actually contributed, after anything given back.
  Money get netTotal => isVoided ? Money.zero : total - refunded;
}

@immutable
class OrderLineRecord {
  const OrderLineRecord({
    required this.id,
    required this.productName,
    required this.sizeName,
    required this.quantity,
    required this.refundedQuantity,
    required this.unitBasePrice,
    required this.unitPrice,
    required this.lineTotal,
    required this.lineCogs,
    required this.options,
    required this.isCosted,
  });

  final int id;
  final String productName;
  final String sizeName;
  final int quantity;
  final int refundedQuantity;

  /// The drink's own price for this size, before anything was added to it.
  final Money unitBasePrice;

  /// What one of these cost in the end — base plus every modification.
  final Money unitPrice;

  final Money lineTotal;
  final Money lineCogs;
  final List<OrderLineOption> options;
  final bool isCosted;

  int get remainingQuantity => quantity - refundedQuantity;
  String get title => '$sizeName $productName';

  /// Just the names, for the places that only list them.
  List<String> get optionNames =>
      options.map((OrderLineOption o) => o.name).toList();

  /// The drink before its modifications, times how many were sold.
  Money get baseTotal => unitBasePrice * quantity;
}

/// One modification as it was sold, with what it added.
@immutable
class OrderLineOption {
  const OrderLineOption({required this.name, required this.priceDelta});

  final String name;

  /// What this added to *one* drink. Zero for the many that are free.
  final Money priceDelta;

  bool get isCharged => priceDelta.isPositive;

  /// What it added to the whole line.
  Money totalFor(int quantity) => priceDelta * quantity;
}

/// One trading day or month, summed.
@immutable
class SalesSummary {
  const SalesSummary({
    required this.label,
    required this.orderCount,
    required this.drinkCount,
    required this.revenue,
    required this.cash,
    required this.gcash,
    this.deliveryCollected = Money.zero,
    this.byMethod = const <String, Money>{},
    required this.cogs,
    required this.grossProfit,
    required this.waste,
    required this.refunds,
    required this.voids,
    required this.uncostedOrders,
    this.unpaid = Money.zero,
    this.unpaidOrderCount = 0,
  });

  static const SalesSummary empty = SalesSummary(
    label: '',
    orderCount: 0,
    drinkCount: 0,
    revenue: Money.zero,
    cash: Money.zero,
    gcash: Money.zero,
    cogs: Money.zero,
    grossProfit: Money.zero,
    waste: Money.zero,
    refunds: Money.zero,
    voids: Money.zero,
    uncostedOrders: 0,
  );

  final String label;
  final int orderCount;
  final int drinkCount;
  final Money revenue;
  final Money cash;

  /// Kept for the screens that have always shown it. It is GCash alone now;
  /// everything else is in [byMethod].
  final Money gcash;

  /// Collected from the customer for the rider and handed straight over.
  ///
  /// Never hers. It is on the receipt because the customer paid it, it is
  /// in the cash because the cash came through her hands, and it is in
  /// neither the sales nor the profit because none of it stayed.
  final Money deliveryCollected;

  /// What came in, by the way it came in: `cash`, `gcash`, `maya`,
  /// `maribank`, `bpi`. Used to lump everything that was not cash under
  /// GCash, which quietly told her she had taken money on GCash that she
  /// had actually taken on Maya.
  final Map<String, Money> byMethod;
  final Money cogs;
  final Money grossProfit;
  final Money waste;
  final Money refunds;
  final Money voids;

  /// Orders containing at least one line that could not be costed. Reported
  /// rather than hidden: profit here is understated by whatever they cost.
  final int uncostedOrders;

  /// Sales in this period whose money has not arrived.
  ///
  /// Counted in [revenue], because the drinks were made and sold, but in
  /// neither [cash] nor [gcash], because nothing has been received. This is
  /// the figure that explains the difference between the two, so it is stated
  /// rather than left for her to work out.
  final Money unpaid;
  final int unpaidOrderCount;

  /// What actually came in: everything taken, less what is still owed.
  /// What the coffee earned. The delivery money was never hers, so it is
  /// not in here — counting it as revenue would flatter every margin in
  /// the app by whatever the rider charged.
  Money get salesRevenue => revenue - deliveryCollected;

  Money get collected => byMethod.isEmpty
      ? cash + gcash
      : byMethod.values.fold(Money.zero, (Money a, Money b) => a + b);

  Money get netRevenue => revenue - refunds;

  Money get averageOrderValue =>
      orderCount == 0 ? Money.zero : Money(revenue.centavos ~/ orderCount);

  /// Basis points; null when there is nothing to divide by.
  int? get grossMarginBasisPoints {
    if (revenue.isZero) return null;
    return (grossProfit.centavos * 10000) ~/ revenue.centavos;
  }

  String get marginLabel {
    final int? bp = grossMarginBasisPoints;
    return bp == null ? '—' : '${(bp / 100).toStringAsFixed(1)}%';
  }

  bool get isEmpty => orderCount == 0 && waste.isZero;
}

/// How one drink performed over a period.
@immutable
class ProductPerformance {
  const ProductPerformance({
    required this.productName,
    required this.sizeName,
    required this.unitsSold,
    required this.revenue,
    required this.cogs,
    required this.isCosted,
  });

  final String productName;
  final String sizeName;
  final int unitsSold;
  final Money revenue;
  final Money cogs;

  /// False when some of these sales had no recipe — margin is not meaningful.
  final bool isCosted;

  Money get grossProfit => revenue - cogs;

  int? get grossMarginBasisPoints {
    if (!isCosted || revenue.isZero) return null;
    return (grossProfit.centavos * 10000) ~/ revenue.centavos;
  }

  String get marginLabel {
    final int? bp = grossMarginBasisPoints;
    return bp == null ? '—' : '${(bp / 100).toStringAsFixed(1)}%';
  }

  String get title => '$sizeName $productName';
}

/// A trading day that has been closed off.
@immutable
class DailyClosing {
  const DailyClosing({
    required this.id,
    required this.businessDate,
    required this.closedAt,
    required this.summary,
  });

  final int id;
  final String businessDate;
  final DateTime closedAt;
  final SalesSummary summary;
}
