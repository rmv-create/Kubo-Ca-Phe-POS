import 'package:meta/meta.dart';

import '../../core/money/money.dart';
import '../../core/quantity/quantity.dart';

@immutable
class Supplier {
  const Supplier({
    required this.id,
    required this.name,
    required this.isActive,
    this.contactPerson,
    this.contactDetails,
    this.notes,
    this.ingredientCount = 0,
  });

  final int id;
  final String name;
  final String? contactPerson;
  final String? contactDetails;
  final String? notes;
  final bool isActive;
  final int ingredientCount;

  Supplier copyWith({
    String? name,
    String? contactPerson,
    String? contactDetails,
    String? notes,
    bool? isActive,
  }) => Supplier(
    id: id,
    name: name ?? this.name,
    contactPerson: contactPerson ?? this.contactPerson,
    contactDetails: contactDetails ?? this.contactDetails,
    notes: notes ?? this.notes,
    isActive: isActive ?? this.isActive,
    ingredientCount: ingredientCount,
  );
}

/// One line of a delivery: what came in, how much, and what it cost.
@immutable
class PurchaseLine {
  const PurchaseLine({
    required this.ingredientId,
    required this.ingredientName,
    required this.quantityInPurchaseUnits,
    required this.quantity,
    required this.totalCost,
  });

  final int ingredientId;
  final String ingredientName;

  /// As she entered it — 2 cartons, 1.5 kg.
  final double quantityInPurchaseUnits;

  /// The same amount in base units.
  final Quantity quantity;

  final Money totalCost;
}

@immutable
class Purchase {
  const Purchase({
    required this.id,
    required this.purchasedAt,
    required this.businessDate,
    required this.total,
    required this.lines,
    this.supplierId,
    this.supplierName,
    this.notes,
  });

  final int id;
  final int? supplierId;
  final String? supplierName;
  final DateTime purchasedAt;
  final String businessDate;
  final Money total;
  final List<PurchaseLine> lines;
  final String? notes;
}
