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

  /// [separate] gives this shop a database of its own rather than the
  /// shared in-memory one — what two tills in the same test need.
  /// A phone with the app on it and no shop in it: migrated, and not a
  /// single drink. What a barista's phone looks like before it is let in.
  static Future<PosFixture> openBlank({
    FixedClock? clock,
    bool separate = false,
  }) async {
    final FixedClock c = clock ?? testClock();
    final AppDatabase db = separate
        ? await openSeparateTestDatabase()
        : await openTestDatabase();
    return PosFixture._(db, c);
  }

  static Future<PosFixture> open({
    FixedClock? clock,
    bool separate = false,
  }) async {
    final FixedClock c = clock ?? testClock();
    final AppDatabase db = await openSeededDatabase(
      clock: c,
      separate: separate,
    );
    return PosFixture._(db, c);
  }

  final AppDatabase db;
  final FixedClock clock;
  final MenuRepositoryImpl menu;
  final CustomerRepositoryImpl customers;
  final OrderService orders;

  BusinessSettings settings = BusinessSettings.defaults.copyWith(
    orderNumberPrefix: 'KUBO',
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

  /// A chosen option **as that drink prices it**.
  ///
  /// Oat costs ₱20 on a Spanish Latte and nothing on a Matcha Oat Latte, and
  /// the difference lives on the product. [draftOption] reads the group's own
  /// price and is fine where no drink overrides it; this is what the POS
  /// actually does.
  Future<DraftOption> optionOn(
    String productName,
    String sizeName,
    String groupCode,
    String optionName,
  ) async {
    final Product p = await product(productName);
    final ProductSize s = await size(productName, sizeName);
    final List<ResolvedCustomizationGroup> groups = await menu
        .resolvedGroupsFor(p.id, sizeId: s.size.id);
    final CustomizationGroup group = groups
        .firstWhere((ResolvedCustomizationGroup g) => g.group.code == groupCode)
        .group;
    return DraftOption(
      group: group,
      option: group.options.firstWhere(
        (CustomizationOption o) => o.name == optionName,
      ),
    );
  }

  /// One drink, ready to drop into a draft.
  ///
  /// Each chosen option is marked as a default or not, exactly as the POS
  /// marks it while she is taking the order — defaults belong to the drink,
  /// not to the group, so this is the first place that can know. The
  /// receipt leans on it to print only what was different about the drink.
  Future<DraftItem> item(
    String productName,
    String sizeName, {
    List<DraftOption> options = const <DraftOption>[],
    int quantity = 1,
    String lineId = 'line-1',
  }) async {
    final Product p = await product(productName);
    final ProductSize s = await size(productName, sizeName);
    final List<ResolvedCustomizationGroup> groups = await menu
        .resolvedGroupsFor(p.id, sizeId: s.size.id);

    final Set<int> defaults = <int>{
      for (final ResolvedCustomizationGroup g in groups) ...g.defaultOptionIds,
    };

    return DraftItem(
      lineId: lineId,
      product: p,
      size: s,
      quantity: quantity,
      options: <DraftOption>[
        for (final DraftOption o in options)
          DraftOption(
            group: o.group,
            option: o.option,
            isDefault: defaults.contains(o.option.id),
          ),
      ],
    );
  }

  Future<CompletedOrder> sell(OrderDraft draft, {BusinessSettings? using}) =>
      orders.complete(draft, settings: using ?? settings);

  /// Rings up one drink with somebody named as being at the till, so the
  /// activity trail has an actor to record.
  Future<CompletedOrder> sellAs(String person) async =>
      OrderService(database: db, clock: clock, who: () => person).complete(
        OrderDraft(
          items: <DraftItem>[await item('Spanish Latte', 'Large')],
          paymentMethod: PaymentMethod.cash,
        ),
        settings: settings,
      );

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
