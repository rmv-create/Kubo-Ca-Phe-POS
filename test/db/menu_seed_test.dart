import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/seed/menu_seeder.dart';
import 'package:kubo_pos/data/repositories/menu_repository_impl.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/menu.dart';

import '../support/test_database.dart';

/// These assert the seeded menu against the owner's own setup worksheet.
///
/// If one of these fails, the app is showing something she did not say.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late MenuRepositoryImpl menu;

  setUp(() async {
    database = await openSeededDatabase();
    menu = MenuRepositoryImpl(database, testClock());
  });

  tearDown(() async => database.close());

  group('the seeded menu matches the worksheet', () {
    test('two categories, in the order the card prints them', () async {
      final List<ProductCategory> categories = await menu.categories();
      expect(categories.map((ProductCategory c) => c.name), <String>[
        'Classics',
        'Specialty Coffee',
      ]);
    });

    test('two sizes, Small 12 oz and Grande 16 oz', () async {
      final List<DrinkSize> sizes = await menu.sizes();
      expect(sizes.map((DrinkSize s) => s.name), <String>['Small', 'Grande']);
      expect(sizes.map((DrinkSize s) => s.volumeOz), <double>[12, 16]);
    });

    test('all seven drinks, each priced at both sizes', () async {
      final List<Product> products = await menu.products();
      expect(products.length, 7);
      for (final Product p in products) {
        expect(
          p.sizes.length,
          2,
          reason: '${p.name} should be sold Small and Grande (answer B)',
        );
        expect(p.availableSizes.length, 2);
        expect(
          p.sizes.where((ProductSize s) => s.isDefaultSize).length,
          1,
          reason: '${p.name} needs exactly one default size',
        );
      }
    });

    test('the prices she wrote down, to the centavo', () async {
      final Map<String, List<int>> expected = <String, List<int>>{
        // drink: [small, grande] in centavos
        'Black': <int>[12900, 13900],
        'Spanish Latte': <int>[12900, 13900],
        'Caramel Macchiato with Cold Foam': <int>[12900, 13900],
        // Priced above the other Classics: it is made with oat.
        'Matcha Oat Latte': <int>[13900, 14900],
        'Vietnamese Coffee': <int>[12900, 13900],
        'Vietnamese Sea Salt Cream': <int>[13900, 15900],
        'Vietnamese Egg Coffee': <int>[13900, 15900],
      };

      final List<Product> products = await menu.products();
      for (final MapEntry<String, List<int>> entry in expected.entries) {
        final Product product = products.firstWhere(
          (Product p) => p.name == entry.key,
        );
        final ProductSize small = product.sizes.firstWhere(
          (ProductSize s) => s.size.name == 'Small',
        );
        final ProductSize grande = product.sizes.firstWhere(
          (ProductSize s) => s.size.name == 'Grande',
        );
        expect(
          small.price,
          Money(entry.value[0]),
          reason: '${entry.key} Small',
        );
        expect(
          grande.price,
          Money(entry.value[1]),
          reason: '${entry.key} Grande',
        );
      }
    });

    test(
      'Vietnamese Coffee defaults to Small — the card prints it at 12 oz',
      () async {
        final Product product = (await menu.products()).firstWhere(
          (Product p) => p.name == 'Vietnamese Coffee',
        );
        expect(product.defaultSize!.size.name, 'Small');
      },
    );

    test('every other drink defaults to Grande', () async {
      final List<Product> products = await menu.products();
      for (final Product p in products) {
        if (p.name == 'Vietnamese Coffee') continue;
        expect(p.defaultSize!.size.name, 'Grande', reason: p.name);
      }
    });
  });

  group('customisations as she configured them', () {
    test(
      'the milks she stocks are on; the rest are off, not deleted',
      () async {
        final CustomizationGroup milk = (await menu.customizationGroups())
            .firstWhere((CustomizationGroup g) => g.code == 'milk');

        expect(milk.options.length, 5);
        expect(
          milk.activeOptions.map((CustomizationOption o) => o.name),
          <String>['Full Cream', 'Oat'],
          reason: 'her sheet: only two milks available at the moment',
        );
        // "not available yet" — kept so past orders and a future restock work.
        expect(
          milk.options
              .where((CustomizationOption o) => !o.isActive)
              .map((CustomizationOption o) => o.name),
          <String>['Low Fat', 'Skimmed', 'Coconut'],
        );
      },
    );

    test('oat milk costs ₱20 and full cream is free', () async {
      final CustomizationGroup milk = (await menu.customizationGroups())
          .firstWhere((CustomizationGroup g) => g.code == 'milk');
      expect(
        milk.options
            .firstWhere((CustomizationOption o) => o.name == 'Oat')
            .priceDelta,
        Money.of(20),
      );
      expect(
        milk.options
            .firstWhere((CustomizationOption o) => o.name == 'Full Cream')
            .priceDelta,
        Money.zero,
      );
    });

    test('every syrup is ₱30, as written on the sheet', () async {
      final CustomizationGroup syrup = (await menu.customizationGroups())
          .firstWhere((CustomizationGroup g) => g.code == 'syrup');
      for (final String name in <String>['Vanilla', 'Caramel', 'Hazelnut']) {
        expect(
          syrup.options
              .firstWhere((CustomizationOption o) => o.name == name)
              .priceDelta,
          Money.of(30),
          reason: name,
        );
      }
      expect(
        syrup.options
            .firstWhere((CustomizationOption o) => o.name == 'None')
            .priceDelta,
        Money.zero,
      );
    });

    test(
      'Sea Salt Cream and Cold Foam are ₱20 — the card and the sheet',
      () async {
        final CustomizationGroup extras = (await menu.customizationGroups())
            .firstWhere((CustomizationGroup g) => g.code == 'extras');
        expect(
          extras.options
              .firstWhere((CustomizationOption o) => o.name == 'Sea Salt Cream')
              .priceDelta,
          Money.of(20),
        );
        expect(
          extras.options
              .firstWhere((CustomizationOption o) => o.name == 'Cold Foam')
              .priceDelta,
          Money.of(20),
        );
      },
    );

    test('extras can be combined; milk cannot', () async {
      final List<CustomizationGroup> groups = await menu.customizationGroups();
      expect(
        groups
            .firstWhere((CustomizationGroup g) => g.code == 'extras')
            .selectionType,
        SelectionType.multi,
      );
      expect(
        groups
            .firstWhere((CustomizationGroup g) => g.code == 'milk')
            .selectionType,
        SelectionType.single,
      );
    });

    test(
      'only milk is asked up front — "not proactively asking" for the rest',
      () async {
        final List<CustomizationGroup> groups = await menu
            .customizationGroups();
        expect(
          groups
              .where((CustomizationGroup g) => g.isProactive)
              .map((CustomizationGroup g) => g.code),
          <String>['milk'],
        );
      },
    );

    test(
      'choices left blank on the sheet are flagged, not silently free',
      () async {
        final List<CustomizationGroup> groups = await menu
            .customizationGroups();
        final List<CustomizationOption> flagged = <CustomizationOption>[
          for (final CustomizationGroup g in groups)
            ...g.options.where(
              (CustomizationOption o) => o.description == 'Price not set yet',
            ),
        ];
        expect(flagged.map((CustomizationOption o) => o.name).toSet(), <String>{
          'Extra Sweet',
          'Chocolate',
          'White Mocha',
          'Caramel',
          'Extra Shot',
          'Extra Syrup',
          'Extra Sauce',
        });
      },
    );
  });

  group('per-drink rules', () {
    test('Black and Vietnamese Coffee offer no milk at all', () async {
      for (final String name in <String>['Black', 'Vietnamese Coffee']) {
        final Product product = (await menu.products()).firstWhere(
          (Product p) => p.name == name,
        );
        final List<ResolvedCustomizationGroup> groups = await menu
            .resolvedGroupsFor(product.id);
        expect(
          groups.any((ResolvedCustomizationGroup g) => g.group.code == 'milk'),
          isFalse,
          reason: '$name is not made with a milk choice',
        );
      }
    });

    test('the milk drinks offer milk, pre-set to Full Cream', () async {
      const List<String> milkDrinks = <String>[
        'Spanish Latte',
        'Caramel Macchiato with Cold Foam',
        'Vietnamese Sea Salt Cream',
        'Vietnamese Egg Coffee',
      ];
      for (final String name in milkDrinks) {
        final Product product = (await menu.products()).firstWhere(
          (Product p) => p.name == name,
        );
        final ResolvedCustomizationGroup milk = (await menu.resolvedGroupsFor(
          product.id,
        )).firstWhere((ResolvedCustomizationGroup g) => g.group.code == 'milk');
        expect(milk.isVisible, isTrue, reason: name);
        expect(milk.isProactive, isTrue, reason: name);
        expect(milk.defaults.map((CustomizationOption o) => o.name), <String>[
          'Full Cream',
        ], reason: name);
      }
    });

    test(
      'the Matcha Oat Latte comes with oat, and oat costs nothing on it',
      () async {
        final Product product = (await menu.products()).firstWhere(
          (Product p) => p.name == 'Matcha Oat Latte',
        );
        final ResolvedCustomizationGroup milk = (await menu.resolvedGroupsFor(
          product.id,
        )).firstWhere((ResolvedCustomizationGroup g) => g.group.code == 'milk');

        expect(milk.defaults.map((CustomizationOption o) => o.name), <String>[
          'Oat',
        ]);
        // Oat is a ₱20 upgrade elsewhere. On the drink named after it, it is
        // what the drink is, and charging for it would double-charge.
        final CustomizationOption oat = milk.group.activeOptions.firstWhere(
          (CustomizationOption o) => o.name == 'Oat',
        );
        expect(oat.priceDelta, Money.zero);
      },
    );

    test('oat is still a paid upgrade on the other drinks', () async {
      final Product product = (await menu.products()).firstWhere(
        (Product p) => p.name == 'Spanish Latte',
      );
      final ResolvedCustomizationGroup milk = (await menu.resolvedGroupsFor(
        product.id,
      )).firstWhere((ResolvedCustomizationGroup g) => g.group.code == 'milk');
      final CustomizationOption oat = milk.group.activeOptions.firstWhere(
        (CustomizationOption o) => o.name == 'Oat',
      );

      expect(oat.priceDelta, Money.of(20));
    });

    test(
      'ice is never asked, but every drink still defaults to Regular',
      () async {
        for (final Product product in await menu.products()) {
          final ResolvedCustomizationGroup ice =
              (await menu.resolvedGroupsFor(product.id)).firstWhere(
                (ResolvedCustomizationGroup g) => g.group.code == 'ice',
              );
          expect(
            ice.isVisible,
            isFalse,
            reason: '${product.name}: "Show ice? No"',
          );
          expect(ice.defaults.map((CustomizationOption o) => o.name), <String>[
            'Regular',
          ], reason: '${product.name}: "always regular for now"');
        }
      },
    );

    test(
      'nothing is required except milk, so a drink adds in two taps',
      () async {
        final Product latte = (await menu.products()).firstWhere(
          (Product p) => p.name == 'Spanish Latte',
        );
        final List<ResolvedCustomizationGroup> groups = await menu
            .resolvedGroupsFor(latte.id);
        final List<ResolvedCustomizationGroup> blocking = groups
            .where(
              (ResolvedCustomizationGroup g) =>
                  g.isRequired && g.defaults.isEmpty,
            )
            .toList();
        expect(
          blocking,
          isEmpty,
          reason: 'a required group with no default would stop a fast add',
        );
      },
    );
  });

  group('settings from the worksheet', () {
    test(
      'order numbers are K-0001 onwards and do not reset each day',
      () async {
        final List<Map<String, Object?>> rows = await database.db.query(
          'app_settings',
          where: 'key IN (?, ?)',
          whereArgs: <Object?>[
            SettingKeys.orderNumberPrefix,
            SettingKeys.orderNumberResetDaily,
          ],
        );
        final Map<String, String> settings = <String, String>{
          for (final Map<String, Object?> r in rows)
            r['key']! as String: r['value']! as String,
        };
        expect(settings[SettingKeys.orderNumberPrefix], 'K');
        expect(settings[SettingKeys.orderNumberResetDaily], '0');
      },
    );

    test('prices are marked provisional, because she said they are', () async {
      final List<Map<String, Object?>> rows = await database.db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: <Object?>[SettingKeys.pricesProvisional],
      );
      expect(rows.single['value'], '1');
    });
  });

  group('seeding is safe to re-run', () {
    test('it never runs twice', () async {
      final bool again = await MenuSeeder(database, testClock()).seedIfEmpty();
      expect(again, isFalse);
      expect((await menu.products()).length, 7);
    });

    test("it refuses to overwrite the owner's edits", () async {
      final Product product = (await menu.products()).first;
      await menu.updateProduct(product.copyWith(name: 'Renamed by the owner'));

      await MenuSeeder(database, testClock()).seedIfEmpty();

      final List<Product> after = await menu.products();
      expect(after.length, 7, reason: 'no duplicate menu was inserted');
      expect(
        after.any((Product p) => p.name == 'Renamed by the owner'),
        isTrue,
      );
    });
  });
}
