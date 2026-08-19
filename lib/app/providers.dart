import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/time/clock.dart';
import '../data/db/app_database.dart';
import '../data/db/backup_service.dart';
import '../data/repositories/settings_repository_impl.dart';
import '../domain/entities/business_settings.dart';
import '../domain/repositories/settings_repository.dart';

/// Infrastructure providers.
///
/// Each of these is overridden at startup (with the real database) or in tests
/// (with an in-memory one). Nothing below constructs its own dependencies, so
/// any layer can be tested in isolation.

final Provider<AppDatabase> databaseProvider = Provider<AppDatabase>(
  (Ref ref) => throw UnimplementedError(
    'databaseProvider must be overridden by bootstrapApp() or a test harness.',
  ),
);

final Provider<BackupService> backupServiceProvider = Provider<BackupService>(
  (Ref ref) => throw UnimplementedError(
    'backupServiceProvider must be overridden by bootstrapApp() or a test harness.',
  ),
);

final Provider<Clock> clockProvider = Provider<Clock>(
  (Ref ref) => const SystemClock(),
);

/// Settings as they were when the app started, so the first frame has real
/// values and never flashes defaults.
final Provider<BusinessSettings> initialSettingsProvider =
    Provider<BusinessSettings>((Ref ref) => BusinessSettings.defaults);

final Provider<SettingsRepository> settingsRepositoryProvider =
    Provider<SettingsRepository>(
      (Ref ref) => SettingsRepositoryImpl(
        ref.watch(databaseProvider),
        ref.watch(clockProvider),
      ),
    );

/// The live settings the UI reads. Writing through [SettingsController] keeps
/// the database and the in-memory copy in step.
final NotifierProvider<SettingsController, BusinessSettings>
settingsControllerProvider =
    NotifierProvider<SettingsController, BusinessSettings>(
      SettingsController.new,
    );

class SettingsController extends Notifier<BusinessSettings> {
  @override
  BusinessSettings build() => ref.watch(initialSettingsProvider);

  Future<void> update(BusinessSettings settings) async {
    await ref.read(settingsRepositoryProvider).save(settings);
    state = settings;
  }

  Future<void> reload() async {
    state = await ref.read(settingsRepositoryProvider).load();
  }
}

/// Business-day resolver, derived from the configured cutoff hour.
final Provider<BusinessDay> businessDayProvider = Provider<BusinessDay>(
  (Ref ref) => BusinessDay(
    cutoffHour: ref.watch(settingsControllerProvider).businessDayCutoffHour,
  ),
);

/// Today's trading date as `YYYY-MM-DD`.
final Provider<String> todayBusinessDateProvider = Provider<String>(
  (Ref ref) =>
      ref.watch(businessDayProvider).dateOf(ref.watch(clockProvider).now()),
);
