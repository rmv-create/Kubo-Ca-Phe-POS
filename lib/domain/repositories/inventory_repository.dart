import '../../core/money/unit_cost.dart';
import '../../core/quantity/measurement_unit.dart';
import '../../core/quantity/quantity.dart';
import '../entities/ingredient.dart';

/// Ingredients, what they cost, how much is left, and every change to it.
abstract class InventoryRepository {
  Future<List<Ingredient>> ingredients({
    bool includeInactive = false,
    bool withStockAndCost = true,
  });

  Future<Ingredient?> ingredientById(int id, {bool withStockAndCost = true});

  Future<int> createIngredient({
    required String name,
    required BaseUnit baseUnit,
    required String purchaseUnitCode,
    required String purchaseUnitLabel,
    required Quantity purchaseUnitSize,
    String? category,
    bool isInventoryTracked = true,
  });

  Future<void> updateIngredient(Ingredient ingredient);

  /// Records a new price, effective from now. Never overwrites the old one:
  /// historical orders keep the cost they were sold at.
  Future<void> recordCost({
    required int ingredientId,
    required UnitCost cost,
    String source = 'manual',
    String? note,
  });

  Future<List<IngredientCost>> costHistory(int ingredientId);

  /// Ingredients at or below a threshold, worst first.
  Future<List<Ingredient>> stockAlerts();

  Future<List<InventoryMovement>> movements({
    int? ingredientId,
    String? businessDate,
    int limit = 100,
  });

  // ── waste ──
  Future<int> recordWaste({
    required int ingredientId,
    required Quantity quantity,
    required WasteReason reason,
    String? notes,
  });

  Future<List<WasteEntry>> waste({String? businessDate, int limit = 100});

  // ── physical counts ──

  /// What the ledger says should be on the shelf right now.
  Future<List<StockVariance>> expectedAgainst(Map<int, Quantity> counted);

  /// Applies a count. Nothing moves until this is called, so a count can be
  /// reviewed and abandoned.
  Future<int> applyStockCount({
    required Map<int, Quantity> counted,
    String? note,
  });

  /// Puts the cached balances back in step with the ledger.
  Future<int> rebuildBalances();
}
