import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/money/unit_cost.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/core/time/clock.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/repositories/customer_repository_impl.dart';
import 'package:kubo_pos/data/repositories/inventory_repository_impl.dart';
import 'package:kubo_pos/data/repositories/menu_repository_impl.dart';
import 'package:kubo_pos/data/repositories/purchasing_repository_impl.dart';
import 'package:kubo_pos/data/repositories/recipe_repository_impl.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/menu.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/services/order_service.dart';
import 'package:kubo_pos/domain/services/reporting_service.dart';
import 'package:kubo_pos/domain/services/sales_service.dart';

import 'test_database.dart';

/// A running shop, seeded with the owner's real menu, ready to take orders.
class PosFixture {
  PosFixture._(this.db, this.clock)
    : menu = MenuRepositoryImpl(db, clock),
      customers = CustomerRepositoryImpl(db, clock),
      orders = OrderService(database: db, clock: clock);

  late final InventoryRepositoryImpl stock = InventoryRepositoryImpl(
    db,
    clock,
    settings: () => settings,
  );

  late final RecipeRepositoryImpl recipeBook = RecipeRepositoryImpl(
    db,
    clock,
    stock,
  );

  late final PurchasingRepositoryImpl purchasing = PurchasingRepositoryImpl(
    db,
    clock,
    settings: () => settings,
  );

  late final SalesService sales = SalesService(
    database: db,
    clock: clock,
    settings: () => settings,
  );

  late final ReportingService reports = ReportingService(
    database: db,
    clock: clock,
    settings: () => settings,
  );

  /// Adds an ingredient with a price and, optionally, opening stock.
  ///
  /// SAMPLE figures — the owner has not supplied real ingredient costs, so
  /// nothing here is presented as her data.
  Future<Ingredient> addIngredient(
    String name, {
    BaseUnit unit = BaseUnit.gram,
    String purchaseUnit = 'kg',
    double perPurchaseUnit = 1000,
    Money? price,
    double openingStock = 0,
    bool tracked = true,
  }) async {
    final int id = await stock.createIngredient(
      name: name,
      baseUnit: unit,
      purchaseUnitCode: purchaseUnit,
      purchaseUnitLabel: purchaseUnit,
      purchaseUnitSize: Quantity.fromBase(perPurchaseUnit, unit),
      isInventoryTracked: tracked,
    );
    if (price != null) {
      await stock.recordCost(
        ingredientId: id,
        cost: UnitCost.perPurchaseUnit(
          price: price,
          baseUnitsPerPurchaseUnit: perPurchaseUnit,
          unit: unit,
        ),
        source: 'seed',
      );
    }
    if (openingStock > 0) {
      await stock.applyStockCount(
        counted: <int, Quantity>{id: Quantity.fromBase(openingStock, unit)},
        note: 'Opening stock',
      );
    }
    return (await stock.ingredientById(id))!;
  }

  /// Writes a recipe for one drink at one size.
  Future<int> setRecipe(
    String productName,
    String sizeName,
    Map<Ingredient, double> lines,
  ) async {
    final Product p = await product(productName);
    final ProductSize s = await size(productName, sizeName);
    return recipeBook.saveVersion(
      productId: p.id,
      sizeId: s.size.id,
      lines: <int, Quantity>{
        for (final MapEntry<Ingredient, double> e in lines.entries)
          e.key.id: Quantity.fromBase(e.value, e.key.baseUnit),
      },
    );
  }

  Future<Quantity?> stockOf(int ingredientId) async =>
      (await stock.ingredientById(ingredientId))?.onHand;

  static Future<PosFixture> open({FixedClock? clock}) async {
    final FixedClock c = clock ?? testClock();
    final AppDatabase db = await openSeededDatabase(clock: c);
    return PosFixture._(db, c);
  }

  final AppDatabase db;
  final FixedClock clock;
  final MenuRepositoryImpl menu;
  final CustomerRepositoryImpl customers;
  final OrderService orders;

  BusinessSettings settings = BusinessSettings.defaults.copyWith(
    orderNumberPrefix: 'K',
    orderNumberResetDaily: false,
  );

  Future<void> close() => db.close();

  Future<Product> product(String name) async {
    final List<Product> all = await menu.products();
    return all.firstWhere((Product p) => p.name == name);
  }

  Future<ProductSize> size(String productName, String sizeName) async {
    final Product p = await product(productName);
    return p.sizes.firstWhere((ProductSize s) => s.size.name == sizeName);
  }

  Future<CustomizationOption> option(String groupCode, String name) async {
    final CustomizationGroup group = (await menu.customizationGroups())
        .firstWhere((CustomizationGroup g) => g.code == groupCode);
    return group.options.firstWhere((CustomizationOption o) => o.name == name);
  }

  Future<DraftOption> draftOption(String groupCode, String name) async {
    final CustomizationGroup group = (await menu.customizationGroups())
        .firstWhere((CustomizationGroup g) => g.code == groupCode);
    return DraftOption(
      group: group,
      option: group.options.firstWhere(
        (CustomizationOption o) => o.name == name,
      ),
    );
  }

  /// One drink, ready to drop into a draft.
  Future<DraftItem> item(
    String productName,
    String sizeName, {
    List<DraftOption> options = const <DraftOption>[],
    int quantity = 1,
    String lineId = 'line-1',
  }) async => DraftItem(
    lineId: lineId,
    product: await product(productName),
    size: await size(productName, sizeName),
    quantity: quantity,
    options: options,
  );

  Future<CompletedOrder> sell(OrderDraft draft, {BusinessSettings? using}) =>
      orders.complete(draft, settings: using ?? settings);

  /// Total of one order, straight from the database.
  Future<Money> storedTotal(int orderId) async {
    final List<Map<String, Object?>> rows = await db.db.query(
      'orders',
      columns: <String>['total_centavos'],
      where: 'id = ?',
      whereArgs: <Object?>[orderId],
    );
    return Money(rows.first['total_centavos']! as int);
  }

  Future<int> countOf(String table) async {
    final List<Map<String, Object?>> rows = await db.db.rawQuery(
      'SELECT COUNT(*) AS c FROM $table',
    );
    return rows.first['c']! as int;
  }
}
