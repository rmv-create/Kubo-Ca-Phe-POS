import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Takes the milk question off the Vietnamese coffees.
///
/// Ca Phe Sua Da never offered one, but Ca Phe Muoi and Ca Phe Trung did,
/// which was wrong in the same way: all three are made with condensed milk
/// as part of the recipe, and the salt cream and the egg cream are the
/// drink rather than a choice on top of it. Asking which milk she wants
/// is a question with no answer, and every question on the ordering screen
/// is time at the counter.
///
/// The seed no longer links them, which settles it for a phone that starts
/// fresh. This is for the phones that already did.
///
/// Only the link is removed, never an order. What a drink was actually made
/// with is written onto the order when it is sold, so everything already
/// rung up keeps the milk it was rung up with — the menu changes from here
/// on, and the books do not change at all.
class M016NoMilkOnSpecialty extends Migration {
  const M016NoMilkOnSpecialty();

  @override
  int get version => 16;

  @override
  String get name => 'no_milk_on_specialty';

  @override
  Future<void> up(DatabaseExecutor db) async {
    // Matched by what things are called rather than by id, because the ids
    // differ on every phone that seeded its own menu.
    const String specialtyMilk = '''
      SELECT pcg.id FROM product_customization_groups pcg
      JOIN products p ON p.id = pcg.product_id
      JOIN product_categories c ON c.id = p.category_id
      JOIN customization_groups g ON g.id = pcg.group_id
      WHERE g.code = 'milk' AND c.name = 'Specialty Coffee'
    ''';

    await db.execute(
      'DELETE FROM product_default_options WHERE option_id IN ('
      '  SELECT o.id FROM customization_options o'
      "  JOIN customization_groups g ON g.id = o.group_id AND g.code = 'milk'"
      ') AND product_id IN ('
      '  SELECT p.id FROM products p'
      '  JOIN product_categories c ON c.id = p.category_id'
      "  WHERE c.name = 'Specialty Coffee'"
      ')',
    );

    await db.execute(
      'DELETE FROM product_customization_groups WHERE id IN ($specialtyMilk)',
    );
  }
}
