import 'package:meta/meta.dart';

import '../../core/money/money.dart';

/// A rough read on how a customer is doing, for the owner's information only.
///
/// V1 gives nothing away automatically — no points, no free drinks. These
/// labels exist so the data is there when loyalty is built.
enum CustomerSegment {
  newCustomer('new', 'New'),
  regular('regular', 'Regular'),
  frequent('frequent', 'Frequent'),
  vip('vip', 'VIP'),
  atRisk('at_risk', 'At risk');

  const CustomerSegment(this.code, this.label);

  final String code;
  final String label;

  static CustomerSegment fromCode(String code) =>
      CustomerSegment.values.firstWhere(
        (CustomerSegment s) => s.code == code,
        orElse: () => CustomerSegment.newCustomer,
      );

  /// Bands based on how many orders a customer has placed.
  ///
  /// Counts only — no spend thresholds, because the owner has not set any and
  /// inventing one would put a made-up number in front of her.
  static CustomerSegment fromOrderCount(int orders) {
    if (orders >= 15) return CustomerSegment.vip;
    if (orders >= 6) return CustomerSegment.frequent;
    if (orders >= 2) return CustomerSegment.regular;
    return CustomerSegment.newCustomer;
  }
}

@immutable
class Customer {
  const Customer({
    required this.id,
    required this.name,
    required this.mobile,
    required this.createdAt,
    required this.firstVisitAt,
    required this.lastVisitAt,
    required this.visitCount,
    required this.orderCount,
    required this.itemCount,
    required this.totalSpend,
    required this.storedSegment,
    required this.isActive,
    this.savedUsualPatternId,
    this.notes,
  });

  final int id;
  final String name;
  final String? mobile;
  final DateTime createdAt;
  final DateTime? firstVisitAt;
  final DateTime? lastVisitAt;
  final int visitCount;
  final int orderCount;
  final int itemCount;
  final Money totalSpend;

  /// The usual the owner saved by hand, which always beats the calculated one.
  final int? savedUsualPatternId;

  final CustomerSegment storedSegment;
  final bool isActive;
  final String? notes;

  /// Days without a visit before a returning customer reads as "at risk".
  ///
  /// A display heuristic, not a business rule the owner has set. It is a
  /// single constant so it becomes a setting the moment she wants one.
  static const int atRiskAfterDays = 30;

  /// [storedSegment] with "at risk" applied, which depends on today and so
  /// cannot be written once and left.
  CustomerSegment segmentAt(DateTime now) {
    final DateTime? last = lastVisitAt;
    if (orderCount >= 2 &&
        last != null &&
        now.difference(last).inDays >= atRiskAfterDays) {
      return CustomerSegment.atRisk;
    }
    return storedSegment;
  }

  Money get averageOrderValue =>
      orderCount == 0 ? Money.zero : Money(totalSpend.centavos ~/ orderCount);

  /// `0917 123 4567` → `0917 ••• 4567`. The owner recognises her customers by
  /// name; the full number only appears where she opens it deliberately.
  String get maskedMobile {
    final String? m = mobile;
    if (m == null || m.length < 7) return m ?? '';
    return '${m.substring(0, 4)} ••• ${m.substring(m.length - 4)}';
  }

  String get initials {
    final List<String> parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((String p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final String first = parts.first;
      return (first.length >= 2 ? first.substring(0, 2) : first).toUpperCase();
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

/// A drink configuration a customer has ordered before, and how often.
@immutable
class CustomerOrderPattern {
  const CustomerOrderPattern({
    required this.id,
    required this.customerId,
    required this.signature,
    required this.productId,
    required this.sizeId,
    required this.optionIds,
    required this.occurrenceCount,
    required this.firstOrderedAt,
    required this.lastOrderedAt,
  });

  final int id;
  final int customerId;
  final String signature;
  final int productId;
  final int sizeId;
  final List<int> optionIds;
  final int occurrenceCount;
  final DateTime firstOrderedAt;
  final DateTime lastOrderedAt;
}

/// The customer's usual, resolved and ready to drop into an order.
@immutable
class UsualOrder {
  const UsualOrder({
    required this.pattern,
    required this.isSaved,
    required this.productName,
    required this.sizeName,
    required this.optionNames,
    required this.price,
  });

  final CustomerOrderPattern pattern;

  /// True when the owner saved this by hand rather than it being worked out
  /// from repeat orders.
  final bool isSaved;

  final String productName;
  final String sizeName;
  final List<String> optionNames;
  final Money price;

  String get title => '$sizeName $productName';
  String get subtitle => optionNames.join(' · ');
}
