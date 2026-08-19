import '../entities/business_settings.dart';

abstract class SettingsRepository {
  Future<BusinessSettings> load();

  Future<void> save(BusinessSettings settings);

  Future<String?> readRaw(String key);

  Future<void> writeRaw(String key, String value);
}
