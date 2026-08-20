import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/time/clock.dart';
import '../data/db/app_database.dart';
import '../data/db/backup_service.dart';
import '../data/export/excel_export_service.dart';
import '../data/repositories/customer_repository_impl.dart';
import '../data/repositories/inventory_repository_impl.dart';
import '../data/repositories/menu_repository_impl.dart';
import '../data/repositories/purchasing_repository_impl.dart';
import '../data/repositories/recipe_repository_impl.dart';
import '../data/repositories/settings_repository_impl.dart';
import '../domain/entities/business_settings.dart';
import '../domain/entities/customer.dart';
import '../domain/entities/ingredient.dart';
import '../domain/entities/menu.dart';
import '../domain/entities/purchasing.dart';
import '../domain/entities/recipe.dart';
import '../domain/entities/reporting.dart';
import '../domain/repositories/customer_repository.dart';
import '../domain/repositories/inventory_repository.dart';
import '../domain/repositories/menu_repository.dart';
import '../domain/repositories/purchasing_repository.dart';
import '../domain/repositories/recipe_repository.dart';
import '../domain/repositories/settings_repository.dart';
import '../domain/services/order_service.dart';
import '../domain/services/reporting_service.dart';
import '../domain/services/sales_service.dart';

/// Infrastructure providers.
///
/// Each of these is overridden at startup (with the real database) or in tests
/// (with an in-memory one). Nothing below constructs its own dependencies, so
/// any layer can be tested in isolation.

final Provider<AppDatabase> databaseProvider = Provider<AppDatabase>(
  (Ref ref) => throw UnimplementedError(
    'databaseProvider must be overridden by bootstrapApp() or a test harness.',
  ),
);

final Provider<BackupService> backupServiceProvider = Provider<BackupService>(
  (Ref ref) => throw UnimplementedError(
    'backupServiceProvider must be overridden by bootstrapApp() or a test harness.',
  ),
);

final Provider<Clock> clockProvider = Provider<Clock>(
  (Ref ref) => const SystemClock(),
);

/// Settings as they were when the app started, so the first frame has real
/// values and never flashes defaults.
final Provider<BusinessSettings> initialSettingsProvider =
    Provider<BusinessSettings>((Ref ref) => BusinessSettings.defaults);

final Provider<SettingsRepository> settingsRepositoryProvider =
    Provider<SettingsRepository>(
      (Ref ref) => SettingsRepositoryImpl(
        ref.watch(databaseProvider),
        ref.watch(clockProvider),
      ),
    );

/// The live settings the UI reads. Writing through [SettingsController] keeps
/// the database and the in-memory copy in step.
final NotifierProvider<SettingsController, BusinessSettings>
settingsControllerProvider =
    NotifierProvider<SettingsController, BusinessSettings>(
      SettingsController.new,
    );

class SettingsController extends Notifier<BusinessSettings> {
  @override
  BusinessSettings build() => ref.watch(initialSettingsProvider);

  Future<void> update(BusinessSettings settings) async {
    await ref.read(settingsRepositoryProvider).save(settings);
    state = settings;
  }

  Future<void> reload() async {
    state = await ref.read(settingsRepositoryProvider).load();
  }
}

/// Business-day resolver, derived from the configured cutoff hour.
final Provider<BusinessDay> businessDayProvider = Provider<BusinessDay>(
  (Ref ref) => BusinessDay(
    cutoffHour: ref.watch(settingsControllerProvider).businessDayCutoffHour,
  ),
);

/// Today's trading date as `YYYY-MM-DD`.
final Provider<String> todayBusinessDateProvider = Provider<String>(
  (Ref ref) =>
      ref.watch(businessDayProvider).dateOf(ref.watch(clockProvider).now()),
);

// ─────────────────────────────── menu ───────────────────────────────

final Provider<MenuRepository> menuRepositoryProvider =
    Provider<MenuRepository>(
      (Ref ref) => MenuRepositoryImpl(
        ref.watch(databaseProvider),
        ref.watch(clockProvider),
      ),
    );

/// Bumped after any menu edit so every screen showing menu data refetches.
/// Cheaper and far easier to follow than threading invalidations by hand
/// through a dozen providers.
final NotifierProvider<MenuRevision, int> menuRevisionProvider =
    NotifierProvider<MenuRevision, int>(MenuRevision.new);

class MenuRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

/// The whole menu, as the POS sees it: active only.
final FutureProvider<MenuSnapshot> menuProvider = FutureProvider<MenuSnapshot>((
  Ref ref,
) {
  ref.watch(menuRevisionProvider);
  return ref.watch(menuRepositoryProvider).loadMenu();
});

/// The whole menu including archived and switched-off items, for management.
final FutureProvider<MenuSnapshot> fullMenuProvider =
    FutureProvider<MenuSnapshot>((Ref ref) {
      ref.watch(menuRevisionProvider);
      return ref.watch(menuRepositoryProvider).loadMenu(includeInactive: true);
    });

final FutureProvider<List<ProductCategory>> categoriesProvider =
    FutureProvider<List<ProductCategory>>((Ref ref) {
      ref.watch(menuRevisionProvider);
      return ref.watch(menuRepositoryProvider).categories();
    });

final FutureProvider<List<DrinkSize>> sizesProvider =
    FutureProvider<List<DrinkSize>>((Ref ref) {
      ref.watch(menuRevisionProvider);
      return ref.watch(menuRepositoryProvider).sizes();
    });

final FutureProvider<List<Product>> productsProvider =
    FutureProvider<List<Product>>((Ref ref) {
      ref.watch(menuRevisionProvider);
      return ref.watch(menuRepositoryProvider).products(includeArchived: true);
    });

final FutureProvider<List<CustomizationGroup>> customizationGroupsProvider =
    FutureProvider<List<CustomizationGroup>>((Ref ref) {
      ref.watch(menuRevisionProvider);
      return ref.watch(menuRepositoryProvider).customizationGroups();
    });

/// One drink with its rules and defaults resolved, for the drink editor.
final FutureProviderFamily<ProductEditorData, int> productEditorProvider =
    FutureProvider.family<ProductEditorData, int>((
      Ref ref,
      int productId,
    ) async {
      ref.watch(menuRevisionProvider);
      final MenuRepository repo = ref.watch(menuRepositoryProvider);
      return ProductEditorData(
        product: await repo.productById(productId),
        allSizes: await repo.sizes(),
        allGroups: await repo.customizationGroups(),
        rules: await repo.rulesFor(productId),
        defaultOptionIds: await repo.defaultOptionIdsFor(productId),
        categories: await repo.categories(),
      );
    });

class ProductEditorData {
  const ProductEditorData({
    required this.product,
    required this.allSizes,
    required this.allGroups,
    required this.rules,
    required this.defaultOptionIds,
    required this.categories,
  });

  final Product? product;
  final List<DrinkSize> allSizes;
  final List<CustomizationGroup> allGroups;
  final List<ProductCustomizationRule> rules;
  final Set<int> defaultOptionIds;
  final List<ProductCategory> categories;

  ProductCustomizationRule? ruleFor(int groupId) {
    for (final ProductCustomizationRule r in rules) {
      if (r.groupId == groupId && r.sizeId == null) return r;
    }
    return null;
  }
}

// ───────────────────────── customers and orders ─────────────────────────

final Provider<CustomerRepository> customerRepositoryProvider =
    Provider<CustomerRepository>(
      (Ref ref) => CustomerRepositoryImpl(
        ref.watch(databaseProvider),
        ref.watch(clockProvider),
      ),
    );

final Provider<OrderService> orderServiceProvider = Provider<OrderService>(
  (Ref ref) => OrderService(
    database: ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// Bumped after every completed order, so customer lists and usuals refresh.
final NotifierProvider<SalesRevision, int> salesRevisionProvider =
    NotifierProvider<SalesRevision, int>(SalesRevision.new);

class SalesRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

/// Customer search. An empty query returns recent visitors.
final FutureProviderFamily<List<Customer>, String> customerSearchProvider =
    FutureProvider.family<List<Customer>, String>((Ref ref, String query) {
      ref.watch(salesRevisionProvider);
      return ref.watch(customerRepositoryProvider).search(query);
    });

final FutureProviderFamily<UsualOrder?, int> usualOrderProvider =
    FutureProvider.family<UsualOrder?, int>((Ref ref, int customerId) {
      ref.watch(salesRevisionProvider);
      ref.watch(menuRevisionProvider);
      return ref.watch(customerRepositoryProvider).usualFor(customerId);
    });

// ───────────────────── ingredients, recipes, stock ─────────────────────

final Provider<InventoryRepository> inventoryRepositoryProvider =
    Provider<InventoryRepository>(
      (Ref ref) => InventoryRepositoryImpl(
        ref.watch(databaseProvider),
        ref.watch(clockProvider),
        settings: () => ref.read(settingsControllerProvider),
      ),
    );

final Provider<RecipeRepository> recipeRepositoryProvider =
    Provider<RecipeRepository>(
      (Ref ref) => RecipeRepositoryImpl(
        ref.watch(databaseProvider),
        ref.watch(clockProvider),
        ref.watch(inventoryRepositoryProvider),
      ),
    );

final Provider<PurchasingRepository> purchasingRepositoryProvider =
    Provider<PurchasingRepository>(
      (Ref ref) => PurchasingRepositoryImpl(
        ref.watch(databaseProvider),
        ref.watch(clockProvider),
        settings: () => ref.read(settingsControllerProvider),
      ),
    );

final Provider<SalesService> salesServiceProvider = Provider<SalesService>(
  (Ref ref) => SalesService(
    database: ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
    settings: () => ref.read(settingsControllerProvider),
  ),
);

final Provider<ReportingService> reportingServiceProvider =
    Provider<ReportingService>(
      (Ref ref) => ReportingService(
        database: ref.watch(databaseProvider),
        clock: ref.watch(clockProvider),
        settings: () => ref.read(settingsControllerProvider),
      ),
    );

/// Bumped after anything that changes stock, cost or a recipe.
final NotifierProvider<StockRevision, int> stockRevisionProvider =
    NotifierProvider<StockRevision, int>(StockRevision.new);

class StockRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final FutureProvider<List<Ingredient>> ingredientsProvider =
    FutureProvider<List<Ingredient>>((Ref ref) {
      ref.watch(stockRevisionProvider);
      return ref.watch(inventoryRepositoryProvider).ingredients();
    });

final FutureProvider<List<Ingredient>> stockAlertsProvider =
    FutureProvider<List<Ingredient>>((Ref ref) {
      ref.watch(stockRevisionProvider);
      return ref.watch(inventoryRepositoryProvider).stockAlerts();
    });

final FutureProvider<List<InventoryMovement>> movementsProvider =
    FutureProvider<List<InventoryMovement>>((Ref ref) {
      ref.watch(stockRevisionProvider);
      return ref.watch(inventoryRepositoryProvider).movements();
    });

final FutureProvider<List<WasteEntry>> wasteProvider =
    FutureProvider<List<WasteEntry>>((Ref ref) {
      ref.watch(stockRevisionProvider);
      return ref.watch(inventoryRepositoryProvider).waste();
    });

final FutureProvider<List<Recipe>> recipesProvider =
    FutureProvider<List<Recipe>>((Ref ref) {
      ref.watch(stockRevisionProvider);
      ref.watch(menuRevisionProvider);
      return ref.watch(recipeRepositoryProvider).recipes();
    });

final FutureProvider<List<Supplier>> suppliersProvider =
    FutureProvider<List<Supplier>>((Ref ref) {
      ref.watch(stockRevisionProvider);
      return ref.watch(purchasingRepositoryProvider).suppliers();
    });

final FutureProvider<List<Purchase>> purchasesProvider =
    FutureProvider<List<Purchase>>((Ref ref) {
      ref.watch(stockRevisionProvider);
      return ref.watch(purchasingRepositoryProvider).purchases();
    });

// ─────────────────────────── sales and reports ───────────────────────────

final FutureProviderFamily<List<OrderRecord>, String?> ordersProvider =
    FutureProvider.family<List<OrderRecord>, String?>((Ref ref, String? day) {
      ref.watch(salesRevisionProvider);
      return ref.watch(salesServiceProvider).orders(businessDate: day);
    });

final FutureProviderFamily<SalesSummary, String> dailySummaryProvider =
    FutureProvider.family<SalesSummary, String>((Ref ref, String day) {
      ref.watch(salesRevisionProvider);
      ref.watch(stockRevisionProvider);
      return ref.watch(reportingServiceProvider).forDay(day);
    });

final FutureProviderFamily<SalesSummary, String> monthlySummaryProvider =
    FutureProvider.family<SalesSummary, String>((Ref ref, String month) {
      ref.watch(salesRevisionProvider);
      ref.watch(stockRevisionProvider);
      return ref.watch(reportingServiceProvider).forMonth(month);
    });

final FutureProviderFamily<List<ProductPerformance>, String>
productPerformanceProvider =
    FutureProvider.family<List<ProductPerformance>, String>((
      Ref ref,
      String month,
    ) {
      ref.watch(salesRevisionProvider);
      return ref
          .watch(reportingServiceProvider)
          .productPerformance(month: month);
    });

final FutureProviderFamily<List<ProductPerformance>, String>
mostProfitableProvider =
    FutureProvider.family<List<ProductPerformance>, String>((
      Ref ref,
      String month,
    ) {
      ref.watch(salesRevisionProvider);
      return ref.watch(reportingServiceProvider).mostProfitable(month: month);
    });

final FutureProviderFamily<DailyClosing?, String> closingProvider =
    FutureProvider.family<DailyClosing?, String>((Ref ref, String day) {
      ref.watch(salesRevisionProvider);
      return ref.watch(reportingServiceProvider).closingFor(day);
    });

/// Where exports are written. Overridden at startup with the real Documents
/// folder; tests point it at a temporary directory.
final Provider<Directory> exportDirectoryProvider = Provider<Directory>(
  (Ref ref) => throw UnimplementedError(
    'exportDirectoryProvider must be overridden by bootstrapApp() or a test.',
  ),
);

final Provider<ExcelExportService> excelExportProvider =
    Provider<ExcelExportService>(
      (Ref ref) => ExcelExportService(
        directory: ref.watch(exportDirectoryProvider),
        reporting: ref.watch(reportingServiceProvider),
        inventory: ref.watch(inventoryRepositoryProvider),
        purchasing: ref.watch(purchasingRepositoryProvider),
        customers: ref.watch(customerRepositoryProvider),
      ),
    );
