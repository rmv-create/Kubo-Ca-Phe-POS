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
    this.customerMobile,
    this.paymentMethod,
    this.paymentReference,
    this.tendered,
    this.change,
    this.voidReason,
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
  final String? customerMobile;
  final PaymentMethod? paymentMethod;
  final String? paymentReference;
  final Money? tendered;
  final Money? change;
  final String? voidReason;

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
  final Money unitPrice;
  final Money lineTotal;
  final Money lineCogs;
  final List<String> options;
  final bool isCosted;

  int get remainingQuantity => quantity - refundedQuantity;
  String get title => '$sizeName $productName';
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
    required this.cogs,
    required this.grossProfit,
    required this.waste,
    required this.refunds,
    required this.voids,
    required this.uncostedOrders,
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
  final Money gcash;
  final Money cogs;
  final Money grossProfit;
  final Money waste;
  final Money refunds;
  final Money voids;

  /// Orders containing at least one line that could not be costed. Reported
  /// rather than hidden: profit here is understated by whatever they cost.
  final int uncostedOrders;

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
