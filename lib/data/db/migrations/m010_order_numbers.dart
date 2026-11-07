import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Order numbers run `KUBO-1001` onwards, as she has written on the app.
///
/// Two settings: the prefix, which was `K`, and the number the first order
/// takes, which was 1. Both are hers to change afterwards.
///
/// Only applied to a shop that has not rung anything up. Renumbering orders
/// that already exist would give two different receipts the same number, so
/// where there is history the sequence is left exactly where it is.
class M010OrderNumbers extends Migration {
  const M010OrderNumbers();

  @override
  int get version => 10;

  @override
  String get name => 'order_numbers';

  @override
  Future<void> up(DatabaseExecutor db) async {
    final List<Map<String, Object?>> sold = await db.rawQuery(
      'SELECT 1 FROM orders LIMIT 1',
    );
    if (sold.isNotEmpty) return;

    final String now = DateTime.now().toUtc().toIso8601String();
    for (final MapEntry<String, String> setting in <String, String>{
      'orders.number_prefix': 'KUBO',
      'orders.number_start': '1001',
    }.entries) {
      await db.insert('app_settings', <String, Object?>{
        'key': setting.key,
        'value': setting.value,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
}
