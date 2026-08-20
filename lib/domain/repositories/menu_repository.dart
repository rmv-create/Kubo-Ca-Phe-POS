import '../entities/menu.dart';

/// Everything the owner can change about her menu.
///
/// Nothing here needs a code change to use: adding a drink, renaming a
/// category, changing a price, switching an oat-milk option off because the
/// supplier ran out — all of it is data.
abstract class MenuRepository {
  /// The whole menu in one read, for the POS.
  Future<MenuSnapshot> loadMenu({bool includeInactive = false});

  // ── categories ──
  Future<List<ProductCategory>> categories({bool includeInactive = true});
  Future<int> createCategory({required String name});
  Future<void> updateCategory(ProductCategory category);
  Future<void> reorderCategories(List<int> idsInOrder);

  // ── sizes ──
  Future<List<DrinkSize>> sizes({bool includeInactive = true});
  Future<int> createSize({
    required String code,
    required String name,
    required double volumeOz,
  });
  Future<void> updateSize(DrinkSize size);
  Future<void> reorderSizes(List<int> idsInOrder);

  // ── products ──
  Future<List<Product>> products({bool includeArchived = false});
  Future<Product?> productById(int id);
  Future<int> createProduct({
    required int categoryId,
    required String name,
    String? description,
  });
  Future<void> updateProduct(Product product);
  Future<void> reorderProducts(int categoryId, List<int> idsInOrder);

  /// Archives rather than deletes: historical orders must keep their meaning.
  Future<void> archiveProduct(int productId);
  Future<void> restoreProduct(int productId);

  /// Adds a size to a product, or updates its price and availability.
  Future<void> setProductSize({
    required int productId,
    required int sizeId,
    required int priceCentavos,
    required bool isAvailable,
    required bool isDefaultSize,
  });
  Future<void> removeProductSize({required int productId, required int sizeId});

  // ── customisations ──
  Future<List<CustomizationGroup>> customizationGroups({
    bool includeInactive = true,
  });
  Future<int> createCustomizationGroup({
    required String code,
    required String name,
    required SelectionType selectionType,
    required bool isRequired,
    required bool isProactive,
    int minSelect = 0,
    int? maxSelect,
  });
  Future<void> updateCustomizationGroup(CustomizationGroup group);
  Future<int> createCustomizationOption({
    required int groupId,
    required String name,
    required int priceDeltaCentavos,
    String? description,
  });
  Future<void> updateCustomizationOption(CustomizationOption option);
  Future<void> reorderCustomizationOptions(int groupId, List<int> idsInOrder);

  // ── which groups a product shows, and what is pre-selected ──
  Future<List<ProductCustomizationRule>> rulesFor(int productId);
  Future<void> setProductRule({
    required int productId,
    required int groupId,
    int? sizeId,
    required bool isVisible,
    bool? isRequiredOverride,
    bool? isProactiveOverride,
    int? displayOrder,
  });
  Future<void> removeProductRule({
    required int productId,
    required int groupId,
    int? sizeId,
  });

  Future<Set<int>> defaultOptionIdsFor(int productId, {int? sizeId});
  Future<void> setDefaultOption({
    required int productId,
    required int optionId,
    int? sizeId,
  });
  Future<void> clearDefaultOption({
    required int productId,
    required int optionId,
    int? sizeId,
  });

  /// Groups for one product with every override resolved and defaults
  /// attached — what the POS actually draws.
  Future<List<ResolvedCustomizationGroup>> resolvedGroupsFor(
    int productId, {
    int? sizeId,
  });
}
