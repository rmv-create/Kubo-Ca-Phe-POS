import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/migrations/m016_no_milk_on_specialty.dart';
import 'package:kubo_pos/data/db/seed/menu_seeder.dart';

import '../support/test_database.dart';

/// Phones that already linked a milk choice to the Vietnamese coffees.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the migration takes milk off a shop that already had it', () async {
    final AppDatabase db = await openTestDatabase();
    await MenuSeeder(db, testClock()).seedIfEmpty();

    // Put the old, wrong state back: Ca Phe Muoi and Ca Phe Trung offering
    // a milk, exactly as a phone seeded before this fix has it.
    final int milk =
        (await db.db.query(
              'customization_groups',
              columns: <String>['id'],
              where: 'code = ?',
              whereArgs: <Object?>['milk'],
            )).first['id']!
            as int;
    for (final String name in <String>['Ca Phe Muoi', 'Ca Phe Trung']) {
      final int id =
          (await db.db.query(
                'products',
                columns: <String>['id'],
                where: 'name = ?',
                whereArgs: <Object?>[name],
              )).first['id']!
              as int;
      await db.db.insert('product_customization_groups', <String, Object?>{
        'product_id': id,
        'size_id': null,
        'group_id': milk,
        'is_visible': 1,
        'display_order': 0,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
    }

    Future<int> milkLinks() async =>
        (await db.db.rawQuery('''
          SELECT COUNT(*) n FROM product_customization_groups pcg
          JOIN products p ON p.id = pcg.product_id
          JOIN product_categories c ON c.id = p.category_id
          JOIN customization_groups g ON g.id = pcg.group_id
          WHERE g.code = 'milk' AND c.name = 'Specialty Coffee'
        ''')).first['n']!
            as int;

    expect(await milkLinks(), 2);

    await const M016NoMilkOnSpecialty().up(db.db);

    expect(await milkLinks(), 0);

    // The lattes are untouched.
    final int stillAsk =
        (await db.db.rawQuery('''
          SELECT COUNT(*) n FROM product_customization_groups pcg
          JOIN customization_groups g ON g.id = pcg.group_id
          WHERE g.code = 'milk'
        ''')).first['n']!
            as int;
    expect(stillAsk, 5);

    await db.close();
  });
}
