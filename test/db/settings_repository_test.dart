import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late SettingsRepositoryImpl repository;

  setUp(() async {
    database = await openTestDatabase();
    repository = SettingsRepositoryImpl(database, testClock());
  });

  tearDown(() async {
    await database.close();
  });

  test('an empty database returns the defaults', () async {
    final BusinessSettings settings = await repository.load();
    expect(settings.businessName, BusinessSettings.defaults.businessName);
    expect(settings.currencyCode, 'PHP');
    expect(settings.currencySymbol, '₱');
    expect(settings.businessDayCutoffHour, 4);
    expect(settings.costingMethod, CostingMethod.latestCost);
    expect(settings.discountsEnabled, isFalse);
  });

  test('saved settings come back unchanged', () async {
    await repository.save(
      BusinessSettings.defaults.copyWith(
        businessName: 'Sample Shop Name',
        businessDayCutoffHour: 6,
        costingMethod: CostingMethod.weightedAverage,
        orderNumberPrefix: 'K',
        backupRetentionCount: 30,
        autoBackupDaily: false,
        lowStockAlertsEnabled: false,
      ),
    );

    final BusinessSettings loaded = await repository.load();
    expect(loaded.businessName, 'Sample Shop Name');
    expect(loaded.businessDayCutoffHour, 6);
    expect(loaded.costingMethod, CostingMethod.weightedAverage);
    expect(loaded.orderNumberPrefix, 'K');
    expect(loaded.backupRetentionCount, 30);
    expect(loaded.autoBackupDaily, isFalse);
    expect(loaded.lowStockAlertsEnabled, isFalse);
  });

  test('saving twice updates rather than duplicating', () async {
    await repository.save(
      BusinessSettings.defaults.copyWith(businessName: 'First'),
    );
    await repository.save(
      BusinessSettings.defaults.copyWith(businessName: 'Second'),
    );

    final List<Map<String, Object?>> rows = await database.db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: <Object?>[SettingKeys.businessName],
    );
    expect(rows.length, 1);
    expect(rows.first['value'], 'Second');
  });

  test('currency stays Philippine Peso whatever else changes', () async {
    await repository.save(
      BusinessSettings.defaults.copyWith(businessName: 'Anything'),
    );
    final BusinessSettings loaded = await repository.load();
    expect(loaded.currencyCode, 'PHP');
    expect(loaded.currencySymbol, '₱');
  });

  test('raw values round-trip for internal bookkeeping', () async {
    expect(await repository.readRaw(SettingKeys.lastAutoBackupDate), isNull);
    await repository.writeRaw(SettingKeys.lastAutoBackupDate, '2026-03-15');
    expect(
      await repository.readRaw(SettingKeys.lastAutoBackupDate),
      '2026-03-15',
    );
  });
}
