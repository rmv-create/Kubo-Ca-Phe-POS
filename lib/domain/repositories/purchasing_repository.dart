import '../../core/money/money.dart';
import '../entities/purchasing.dart';

abstract class PurchasingRepository {
  Future<List<Supplier>> suppliers({bool includeInactive = false});

  Future<int> createSupplier({
    required String name,
    String? contactPerson,
    String? contactDetails,
    String? notes,
  });

  Future<void> updateSupplier(Supplier supplier);

  /// Records a delivery. Stock goes up, and each line's price is added to the
  /// ingredient's cost history so future drinks cost what she actually paid.
  Future<int> recordPurchase({
    int? supplierId,
    required List<PurchaseDraftLine> lines,
    String? notes,
  });

  Future<List<Purchase>> purchases({int limit = 50});
}

/// One line of a delivery being entered.
class PurchaseDraftLine {
  const PurchaseDraftLine({
    required this.ingredientId,
    required this.quantityInPurchaseUnits,
    required this.totalCost,
  });

  final int ingredientId;

  /// As she buys it — 2 cartons, 1.5 kg.
  final double quantityInPurchaseUnits;

  final Money totalCost;
}
