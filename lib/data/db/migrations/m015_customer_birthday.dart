import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// A birthday, for the customers she wants to make a fuss of.
///
/// Stored as `MM-DD` and nothing else. Asking a regular for the year she
/// was born to put a free coffee on her calendar is a strange thing to do,
/// and storing it would be a worse one — this is a coffee shop's notebook,
/// not a government form. The month and the day are the whole of what the
/// shop needs.
///
/// Optional, and expected to stay empty for almost everybody. It exists so
/// that on the day she decides to do something for a regular, the place to
/// write it down is already there.
class M015CustomerBirthday extends Migration {
  const M015CustomerBirthday();

  @override
  int get version => 15;

  @override
  String get name => 'customer_birthday';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute('ALTER TABLE customers ADD COLUMN birthday TEXT');
    await db.execute('CREATE INDEX idx_customers_birthday ON customers(birthday)');
  }
}
