import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/time/clock.dart';
import '../data/db/app_database.dart';
import '../data/db/backup_service.dart';
import '../data/repositories/menu_repository_impl.dart';
import '../data/repositories/settings_repository_impl.dart';
import '../domain/entities/business_settings.dart';
import '../domain/entities/menu.dart';
import '../domain/repositories/menu_repository.dart';
import '../domain/repositories/settings_repository.dart';

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
