import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Puts ice back on the order screen.
///
/// Her setup worksheet said "Show ice? No", so the group was attached to
/// every drink with a default of Regular and hidden outright. That read as
/// "do not ask me about ice", and it was taken as "never offer it" — which
/// left no way to ring up a no-ice drink at all, however plainly the
/// customer asked for one.
///
/// It is visible now, and still not proactive: she is not asked while
/// taking an order, and it waits under More options with strength and
/// sweetness for the times somebody does ask.
///
/// Only the groups left exactly as the seed wrote them are touched. If she
/// has since hidden or shown ice on a particular drink herself, that is her
/// decision and it stands.
class M021IceCanBeAskedFor extends Migration {
  const M021IceCanBeAskedFor();

  @override
  int get version => 21;

  @override
  String get name => 'ice_can_be_asked_for';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute('''
      UPDATE product_customization_groups
      SET is_visible = 1
      WHERE is_visible = 0
        AND group_id IN (
          SELECT id FROM customization_groups WHERE code = 'ice'
        )
    ''');
  }
}
