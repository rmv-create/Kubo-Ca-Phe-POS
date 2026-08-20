import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/repositories/menu_repository_impl.dart';
import 'package:kubo_pos/domain/entities/menu.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late MenuRepositoryImpl menu;

  setUp(() async {
    database = await openTestDatabase();
    menu = MenuRepositoryImpl(database, testClock());
  });

  tearDown(() async => database.close());

  group('categories', () {
    test('are created, renamed and hidden without deleting anything', () async {
      final int id = await menu.createCategory(name: 'Classics');
      List<ProductCategory> all = await menu.categories();
      expect(all.single.name, 'Classics');
      expect(all.single.isActive, isTrue);

      await menu.updateCategory(
        all.single.copyWith(name: 'House Classics', isActive: false),
      );
      all = await menu.categories();
      expect(all.single.id, id, reason: 'renaming must not replace the row');
      expect(all.single.name, 'House Classics');
      expect(all.single.isActive, isFalse);
    });

    test('two categories cannot share a name', () async {
      await menu.createCategory(name: 'Classics');
      expect(
        () => menu.createCategory(name: 'classics'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('an empty name is refused with a sentence, not a crash', () async {
      expect(
        () => menu.createCategory(name: '   '),
        throwsA(
          isA<ValidationException>().having(
            (ValidationException e) => e.message,
            'message',
            contains('cannot be empty'),
          ),
        ),
      );
    });

    test('reordering sets the order the POS reads', () async {
      final int a = await menu.createCategory(name: 'Alpha');
      final int b = await menu.createCategory(name: 'Beta');
      await menu.reorderCategories(<int>[b, a]);
      final List<ProductCategory> all = await menu.categories();
      expect(all.map((ProductCategory c) => c.name), <String>['Beta', 'Alpha']);
    });
  });

  group('sizes', () {
    test(
      'store the customer name and the physical volume separately',
      () async {
        await menu.createSize(code: 'grande', name: 'Grande', volumeOz: 16);
        final DrinkSize size = (await menu.sizes()).single;
        expect(size.name, 'Grande');
        expect(size.volumeOz, 16);
        expect(size.volumeLabel, '16 oz');
      },
    );

    test('a third size can be added without touching code', () async {
      await menu.createSize(code: 'small', name: 'Small', volumeOz: 12);
      await menu.createSize(code: 'grande', name: 'Grande', volumeOz: 16);
      await menu.createSize(code: 'venti', name: 'Venti', volumeOz: 20);
      expect((await menu.sizes()).length, 3);
    });

    test('a size needs a real volume', () async {
      expect(
        () => menu.createSize(code: 'x', name: 'Nothing', volumeOz: 0),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('products and prices', () {
    late int categoryId;
    late int smallId;
    late int grandeId;

    setUp(() async {
      categoryId = await menu.createCategory(name: 'Classics');
      smallId = await menu.createSize(
        code: 'small',
        name: 'Small',
        volumeOz: 12,
      );
      grandeId = await menu.createSize(
        code: 'grande',
        name: 'Grande',
        volumeOz: 16,
      );
    });

    test('each size carries its own price', () async {
      final int id = await menu.createProduct(
        categoryId: categoryId,
        name: 'Spanish Latte',
      );
      await menu.setProductSize(
        productId: id,
        sizeId: smallId,
        priceCentavos: 12900,
        isAvailable: true,
        isDefaultSize: false,
      );
      await menu.setProductSize(
        productId: id,
        sizeId: grandeId,
        priceCentavos: 13900,
        isAvailable: true,
        isDefaultSize: true,
      );

      final Product product = (await menu.productById(id))!;
      expect(product.sizes.length, 2);
      expect(
        product.sizes.firstWhere((ProductSize s) => s.size.id == smallId).price,
        Money.of(129),
      );
      expect(
        product.sizes
            .firstWhere((ProductSize s) => s.size.id == grandeId)
            .price,
        Money.of(139),
      );
      expect(product.lowestPrice, Money.of(129));
      expect(product.defaultSize!.size.id, grandeId);
    });

    test('setting a price twice updates rather than duplicating', () async {
      final int id = await menu.createProduct(
        categoryId: categoryId,
        name: 'Black',
      );
      await menu.setProductSize(
        productId: id,
        sizeId: grandeId,
        priceCentavos: 13900,
        isAvailable: true,
        isDefaultSize: true,
      );
      await menu.setProductSize(
        productId: id,
        sizeId: grandeId,
        priceCentavos: 14900,
        isAvailable: true,
        isDefaultSize: true,
      );
      final Product product = (await menu.productById(id))!;
      expect(product.sizes.length, 1);
      expect(product.sizes.single.price, Money.of(149));
    });

    test('only one size can be the default', () async {
      final int id = await menu.createProduct(
        categoryId: categoryId,
        name: 'Matcha Latte',
      );
      for (final int sizeId in <int>[smallId, grandeId]) {
        await menu.setProductSize(
          productId: id,
          sizeId: sizeId,
          priceCentavos: 12900,
          isAvailable: true,
          isDefaultSize: true,
        );
      }
      final Product product = (await menu.productById(id))!;
      expect(product.sizes.where((ProductSize s) => s.isDefaultSize).length, 1);
      expect(product.defaultSize!.size.id, grandeId);
    });

    test('a negative price is refused', () async {
      final int id = await menu.createProduct(
        categoryId: categoryId,
        name: 'Free Coffee',
      );
      expect(
        () => menu.setProductSize(
          productId: id,
          sizeId: smallId,
          priceCentavos: -1,
          isAvailable: true,
          isDefaultSize: false,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('archiving hides a drink but never deletes it', () async {
      final int id = await menu.createProduct(
        categoryId: categoryId,
        name: 'Seasonal Drink',
      );
      await menu.archiveProduct(id);

      expect(await menu.products(), isEmpty);
      final List<Product> withArchived = await menu.products(
        includeArchived: true,
      );
      expect(withArchived.single.id, id);
      expect(withArchived.single.isArchived, isTrue);
      expect(withArchived.single.isActive, isFalse);

      await menu.restoreProduct(id);
      expect((await menu.products()).single.isArchived, isFalse);
    });

    test('a size that has been sold cannot be deleted', () async {
      final int id = await menu.createProduct(
        categoryId: categoryId,
        name: 'Spanish Latte',
      );
      await menu.setProductSize(
        productId: id,
        sizeId: grandeId,
        priceCentavos: 13900,
        isAvailable: true,
        isDefaultSize: true,
      );

      final int orderId = await database.db.insert('orders', <String, Object?>{
        'order_no': 'K-0001',
        'created_at': '2026-03-15T00:00:00Z',
        'business_date': '2026-03-15',
        'status': 'completed',
      });
      await database.db.insert('order_items', <String, Object?>{
        'order_id': orderId,
        'line_no': 1,
        'product_id': id,
        'product_name_snapshot': 'Spanish Latte',
        'size_id': grandeId,
        'size_name_snapshot': 'Grande',
        'size_volume_oz_snapshot': 16.0,
        'quantity': 1,
        'unit_base_price_centavos': 13900,
        'unit_price_centavos': 13900,
        'line_total_centavos': 13900,
      });

      await expectLater(
        menu.removeProductSize(productId: id, sizeId: grandeId),
        throwsA(
          isA<BusinessRuleException>().having(
            (BusinessRuleException e) => e.message,
            'message',
            contains('already been sold'),
          ),
        ),
      );
    });
  });

  group('customisations', () {
    late int milkId;

    setUp(() async {
      milkId = await menu.createCustomizationGroup(
        code: 'milk',
        name: 'Milk',
        selectionType: SelectionType.single,
        isRequired: true,
        isProactive: true,
      );
    });

    test(
      'an option that is out of stock is switched off, not deleted',
      () async {
        final int oatId = await menu.createCustomizationOption(
          groupId: milkId,
          name: 'Oat',
          priceDeltaCentavos: 2000,
        );
        CustomizationGroup group = (await menu.customizationGroups()).single;
        expect(group.activeOptions.length, 1);

        await menu.updateCustomizationOption(
          group.options.single.copyWith(isActive: false),
        );
        group = (await menu.customizationGroups()).single;
        expect(group.options.length, 1, reason: 'the row must survive');
        expect(group.activeOptions, isEmpty);
        expect(group.options.single.id, oatId);
      },
    );

    test(
      'a free option and an unpriced one are both zero, and that is fine',
      () async {
        await menu.createCustomizationOption(
          groupId: milkId,
          name: 'Full Cream',
          priceDeltaCentavos: 0,
        );
        final CustomizationGroup group =
            (await menu.customizationGroups()).single;
        expect(group.options.single.priceDelta, Money.zero);
        expect(group.options.single.priceDelta.isZero, isTrue);
      },
    );

    test('two choices in one group cannot share a name', () async {
      await menu.createCustomizationOption(
        groupId: milkId,
        name: 'Oat',
        priceDeltaCentavos: 2000,
      );
      expect(
        () => menu.createCustomizationOption(
          groupId: milkId,
          name: 'oat',
          priceDeltaCentavos: 0,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
