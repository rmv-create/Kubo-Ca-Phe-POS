import 'package:meta/meta.dart';

import '../../core/money/money.dart';

/// A section of the menu. Fully editable by the owner — add, rename, reorder,
/// switch off — without a code change.
@immutable
class ProductCategory {
  const ProductCategory({
    required this.id,
    required this.name,
    required this.displayOrder,
    required this.isActive,
  });

  final int id;
  final String name;
  final int displayOrder;
  final bool isActive;

  ProductCategory copyWith({String? name, int? displayOrder, bool? isActive}) =>
      ProductCategory(
        id: id,
        name: name ?? this.name,
        displayOrder: displayOrder ?? this.displayOrder,
        isActive: isActive ?? this.isActive,
      );
}

/// A cup size. The customer-facing [name] and the physical [volumeOz] are kept
/// apart on purpose: the name drives the POS button, the volume drives recipes,
/// costing and reporting.
@immutable
class DrinkSize {
  const DrinkSize({
    required this.id,
    required this.code,
    required this.name,
    required this.volumeOz,
    required this.displayOrder,
    required this.isActive,
  });

  final int id;
  final String code;
  final String name;
  final double volumeOz;
  final int displayOrder;
  final bool isActive;

  /// `12 oz`, `16 oz` — trailing zeros trimmed.
  String get volumeLabel {
    final String v = volumeOz.toStringAsFixed(1);
    return '${v.endsWith('.0') ? v.substring(0, v.length - 2) : v} oz';
  }

  DrinkSize copyWith({
    String? name,
    double? volumeOz,
    int? displayOrder,
    bool? isActive,
  }) => DrinkSize(
    id: id,
    code: code,
    name: name ?? this.name,
    volumeOz: volumeOz ?? this.volumeOz,
    displayOrder: displayOrder ?? this.displayOrder,
    isActive: isActive ?? this.isActive,
  );
}

/// One drink, at one size, at one price.
@immutable
class ProductSize {
  const ProductSize({
    required this.id,
    required this.productId,
    required this.size,
    required this.price,
    required this.isAvailable,
    required this.isDefaultSize,
  });

  final int id;
  final int productId;
  final DrinkSize size;
  final Money price;
  final bool isAvailable;

  /// Pre-selected when the drink is opened, so the common order is one tap.
  final bool isDefaultSize;

  ProductSize copyWith({
    Money? price,
    bool? isAvailable,
    bool? isDefaultSize,
  }) => ProductSize(
    id: id,
    productId: productId,
    size: size,
    price: price ?? this.price,
    isAvailable: isAvailable ?? this.isAvailable,
    isDefaultSize: isDefaultSize ?? this.isDefaultSize,
  );
}

@immutable
class Product {
  const Product({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.description,
    required this.displayOrder,
    required this.isActive,
    required this.isArchived,
    this.sizes = const <ProductSize>[],
  });

  final int id;
  final int categoryId;
  final String name;
  final String? description;
  final int displayOrder;
  final bool isActive;

  /// Archived products stay in the database forever so historical orders keep
  /// their meaning; they simply stop appearing on the POS.
  final bool isArchived;

  final List<ProductSize> sizes;

  bool get isSellable => isActive && !isArchived && availableSizes.isNotEmpty;

  List<ProductSize> get availableSizes =>
      sizes.where((ProductSize s) => s.isAvailable).toList();

  /// The size pre-selected when the drink is tapped: whichever is marked
  /// default, else the cheapest available, else nothing.
  ProductSize? get defaultSize {
    final List<ProductSize> available = availableSizes;
    if (available.isEmpty) return null;
    for (final ProductSize s in available) {
      if (s.isDefaultSize) return s;
    }
    return available.reduce(
      (ProductSize a, ProductSize b) => a.price <= b.price ? a : b,
    );
  }

  /// What the POS tile shows when a drink has more than one price.
  Money? get lowestPrice {
    final List<ProductSize> available = availableSizes;
    if (available.isEmpty) return null;
    return available
        .map((ProductSize s) => s.price)
        .reduce((Money a, Money b) => a <= b ? a : b);
  }

  Product copyWith({
    int? categoryId,
    String? name,
    String? description,
    int? displayOrder,
    bool? isActive,
    bool? isArchived,
    List<ProductSize>? sizes,
  }) => Product(
    id: id,
    categoryId: categoryId ?? this.categoryId,
    name: name ?? this.name,
    description: description ?? this.description,
    displayOrder: displayOrder ?? this.displayOrder,
    isActive: isActive ?? this.isActive,
    isArchived: isArchived ?? this.isArchived,
    sizes: sizes ?? this.sizes,
  );
}

enum SelectionType {
  single('single', 'Pick one'),
  multi('multi', 'Pick any number');

  const SelectionType(this.code, this.label);

  final String code;
  final String label;

  static SelectionType fromCode(String code) =>
      code == 'multi' ? SelectionType.multi : SelectionType.single;
}

/// A reusable set of choices — Milk, Ice, Syrup, Extras.
@immutable
class CustomizationGroup {
  const CustomizationGroup({
    required this.id,
    required this.code,
    required this.name,
    required this.selectionType,
    required this.minSelect,
    required this.maxSelect,
    required this.isRequired,
    required this.isProactive,
    required this.displayOrder,
    required this.isActive,
    this.options = const <CustomizationOption>[],
  });

  final int id;
  final String code;
  final String name;
  final SelectionType selectionType;
  final int minSelect;
  final int? maxSelect;
  final bool isRequired;

  /// Whether the operator is shown this group as soon as the drink opens, or
  /// only when she taps "More options" because the customer asked.
  final bool isProactive;

  final int displayOrder;
  final bool isActive;
  final List<CustomizationOption> options;

  List<CustomizationOption> get activeOptions =>
      options.where((CustomizationOption o) => o.isActive).toList();

  CustomizationGroup copyWith({
    String? name,
    SelectionType? selectionType,
    int? minSelect,
    int? maxSelect,
    bool? clearMaxSelect,
    bool? isRequired,
    bool? isProactive,
    int? displayOrder,
    bool? isActive,
    List<CustomizationOption>? options,
  }) => CustomizationGroup(
    id: id,
    code: code,
    name: name ?? this.name,
    selectionType: selectionType ?? this.selectionType,
    minSelect: minSelect ?? this.minSelect,
    maxSelect: (clearMaxSelect ?? false) ? null : (maxSelect ?? this.maxSelect),
    isRequired: isRequired ?? this.isRequired,
    isProactive: isProactive ?? this.isProactive,
    displayOrder: displayOrder ?? this.displayOrder,
    isActive: isActive ?? this.isActive,
    options: options ?? this.options,
  );
}

@immutable
class CustomizationOption {
  const CustomizationOption({
    required this.id,
    required this.groupId,
    required this.name,
    required this.priceDelta,
    required this.displayOrder,
    required this.isActive,
    this.description,
  });

  final int id;
  final int groupId;
  final String name;

  /// What choosing this adds to the price. Zero is a real, common answer.
  final Money priceDelta;

  final int displayOrder;

  /// An option the shop does not currently stock is switched off, not deleted —
  /// past orders that used it must still read correctly.
  final bool isActive;

  final String? description;

  CustomizationOption copyWith({
    String? name,
    Money? priceDelta,
    int? displayOrder,
    bool? isActive,
    String? description,
  }) => CustomizationOption(
    id: id,
    groupId: groupId,
    name: name ?? this.name,
    priceDelta: priceDelta ?? this.priceDelta,
    displayOrder: displayOrder ?? this.displayOrder,
    isActive: isActive ?? this.isActive,
    description: description ?? this.description,
  );
}

/// How one product treats one customisation group.
///
/// A group can be attached but hidden — that is how "ice is always Regular, do
/// not ask me" is expressed: the group is invisible, but its default still
/// applies to the drink.
@immutable
class ProductCustomizationRule {
  const ProductCustomizationRule({
    required this.id,
    required this.productId,
    required this.groupId,
    required this.isVisible,
    required this.displayOrder,
    this.sizeId,
    this.isRequiredOverride,
    this.isProactiveOverride,
    this.minSelectOverride,
    this.maxSelectOverride,
  });

  final int id;
  final int productId;

  /// `null` means the rule applies at every size.
  final int? sizeId;

  final int groupId;
  final bool isVisible;
  final int displayOrder;
  final bool? isRequiredOverride;
  final bool? isProactiveOverride;
  final int? minSelectOverride;
  final int? maxSelectOverride;

  bool requiredFor(CustomizationGroup group) =>
      isRequiredOverride ?? group.isRequired;

  bool proactiveFor(CustomizationGroup group) =>
      isProactiveOverride ?? group.isProactive;
}

/// A group as it applies to one product, with the overrides already resolved
/// and the pre-selected options attached. This is what the POS renders.
@immutable
class ResolvedCustomizationGroup {
  const ResolvedCustomizationGroup({
    required this.group,
    required this.isVisible,
    required this.isRequired,
    required this.isProactive,
    required this.displayOrder,
    required this.defaultOptionIds,
  });

  final CustomizationGroup group;
  final bool isVisible;
  final bool isRequired;
  final bool isProactive;
  final int displayOrder;
  final Set<int> defaultOptionIds;

  List<CustomizationOption> get defaults => group.activeOptions
      .where((CustomizationOption o) => defaultOptionIds.contains(o.id))
      .toList();
}

/// Everything the POS needs to draw the menu, read once.
@immutable
class MenuSnapshot {
  const MenuSnapshot({
    required this.categories,
    required this.sizes,
    required this.productsByCategory,
    required this.groups,
  });

  final List<ProductCategory> categories;
  final List<DrinkSize> sizes;
  final Map<int, List<Product>> productsByCategory;
  final List<CustomizationGroup> groups;

  bool get isEmpty => productsByCategory.values.every(
    (List<Product> products) => products.isEmpty,
  );

  List<ProductCategory> get sellableCategories => categories
      .where(
        (ProductCategory c) =>
            c.isActive &&
            (productsByCategory[c.id] ?? const <Product>[]).any(
              (Product p) => p.isSellable,
            ),
      )
      .toList();

  List<Product> sellableIn(int categoryId) =>
      (productsByCategory[categoryId] ?? const <Product>[])
          .where((Product p) => p.isSellable)
          .toList();
}
