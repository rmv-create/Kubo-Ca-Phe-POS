import 'package:sqflite_common/sqlite_api.dart';

import '../../core/time/clock.dart';
import '../../domain/entities/business_settings.dart';
import '../../domain/repositories/settings_repository.dart';
import '../db/app_database.dart';

class SettingsRepositoryImpl implements SettingsRepository {
  SettingsRepositoryImpl(this._database, this._clock);

  final AppDatabase _database;
  final Clock _clock;

  @override
  Future<BusinessSettings> load() async {
    final Map<String, String> values = await _readAll();
    const BusinessSettings d = BusinessSettings.defaults;
    return BusinessSettings(
      businessName: values[SettingKeys.businessName] ?? d.businessName,
      currencyCode: d.currencyCode,
      currencySymbol: d.currencySymbol,
      businessDayCutoffHour:
          int.tryParse(values[SettingKeys.businessDayCutoffHour] ?? '') ??
          d.businessDayCutoffHour,
      costingMethod: CostingMethod.fromCode(
        values[SettingKeys.costingMethod] ?? d.costingMethod.code,
      ),
      orderNumberPrefix:
          values[SettingKeys.orderNumberPrefix] ?? d.orderNumberPrefix,
      backupRetentionCount:
          int.tryParse(values[SettingKeys.backupRetentionCount] ?? '') ??
          d.backupRetentionCount,
      autoBackupDaily: _bool(
        values[SettingKeys.autoBackupDaily],
        d.autoBackupDaily,
      ),
      discountsEnabled: _bool(
        values[SettingKeys.discountsEnabled],
        d.discountsEnabled,
      ),
      lowStockAlertsEnabled: _bool(
        values[SettingKeys.lowStockAlertsEnabled],
        d.lowStockAlertsEnabled,
      ),
      orderNumberResetDaily: _bool(
        values[SettingKeys.orderNumberResetDaily],
        d.orderNumberResetDaily,
      ),
      showCustomerName: _bool(
        values[SettingKeys.showCustomerName],
        d.showCustomerName,
      ),
      pricesProvisional: _bool(
        values[SettingKeys.pricesProvisional],
        d.pricesProvisional,
      ),
    );
  }

  @override
  Future<void> save(BusinessSettings settings) async {
    await _database.transaction((Transaction txn) async {
      await _put(txn, SettingKeys.businessName, settings.businessName);
      await _put(
        txn,
        SettingKeys.businessDayCutoffHour,
        '${settings.businessDayCutoffHour}',
      );
      await _put(txn, SettingKeys.costingMethod, settings.costingMethod.code);
      await _put(
        txn,
        SettingKeys.orderNumberPrefix,
        settings.orderNumberPrefix,
      );
      await _put(
        txn,
        SettingKeys.backupRetentionCount,
        '${settings.backupRetentionCount}',
      );
      await _put(
        txn,
        SettingKeys.autoBackupDaily,
        settings.autoBackupDaily ? '1' : '0',
      );
      await _put(
        txn,
        SettingKeys.discountsEnabled,
        settings.discountsEnabled ? '1' : '0',
      );
      await _put(
        txn,
        SettingKeys.lowStockAlertsEnabled,
        settings.lowStockAlertsEnabled ? '1' : '0',
      );
    });
  }

  @override
  Future<String?> readRaw(String key) async {
    final List<Map<String, Object?>> rows = await _database.db.query(
      'app_settings',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<void> writeRaw(String key, String value) =>
      _put(_database.db, key, value);

  Future<Map<String, String>> _readAll() async {
    final List<Map<String, Object?>> rows = await _database.db.query(
      'app_settings',
    );
    return <String, String>{
      for (final Map<String, Object?> row in rows)
        row['key']! as String: row['value']! as String,
    };
  }

  Future<void> _put(DatabaseExecutor db, String key, String value) async {
    await db.insert('app_settings', <String, Object?>{
      'key': key,
      'value': value,
      'updated_at': _clock.nowIso(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static bool _bool(String? raw, bool fallback) {
    if (raw == null) return fallback;
    return raw == '1' || raw.toLowerCase() == 'true';
  }
}
