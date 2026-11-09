import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/time/clock.dart';
import 'package:kubo_pos/data/cloud/shop_backup_store.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/database_archive.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/services/nightly_backup_service.dart';

import '../support/test_database.dart';

/// The copy that goes off the phone every night, by itself.
///
/// The shop lives in one browser on one phone. A lost signal costs nothing;
/// a lost phone costs everything, and this is the only thing between her
/// and that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FixedClock clock;
  late SettingsRepositoryImpl settings;
  late _Store store;
  late NightlyBackupService nightly;

  setUp(() async {
    clock = testClock();
    db = await openSeededDatabase(clock: clock);
    settings = SettingsRepositoryImpl(db, clock);
    store = _Store();
    nightly = NightlyBackupService(
      archive: DatabaseArchive(db.db, clock),
      settings: settings,
      clock: clock,
      store: store,
    );
    await settings.writeRaw(SettingKeys.syncShopId, 'her-shop');
    await settings.writeRaw(SettingKeys.syncDeviceLabel, 'Owner’s phone');
  });

  tearDown(() async => db.close());

  group('closing the day', () {
    test('sends the whole shop up, squeezed', () async {
      final BackupRound round = await nightly.run(day: '2026-11-08');

      expect(round.sent, isTrue);
      expect(store.kept.keys, contains('2026-11-08'));
      expect(round.bytes, greaterThan(0));

      // It is really the shop, and it really is compressed.
      final String sql = utf8.decode(
        GZipDecoder().decodeBytes(store.kept['2026-11-08']!),
      );
      expect(sql, contains('Kubo'));
      expect(sql, contains('Spanish Latte'));
      expect(
        round.bytes,
        lessThan(utf8.encode(sql).length ~/ 2),
        reason: 'squeezing is the point; it crosses a mobile connection',
      );
    });

    test('does not send the same day twice', () async {
      await nightly.run(day: '2026-11-08');
      final BackupRound again = await nightly.run(day: '2026-11-08');

      expect(again.outcome, BackupOutcome.alreadyDone);
      expect(store.puts, 1);
    });

    test('"back up now" sends it again anyway', () async {
      await nightly.run(day: '2026-11-08');
      final BackupRound forced = await nightly.run(
        day: '2026-11-08',
        force: true,
      );

      expect(forced.sent, isTrue);
      expect(store.puts, 2);
    });

    test('a new day is a new backup', () async {
      await nightly.run(day: '2026-11-08');
      await nightly.run(day: '2026-11-09');

      expect(
        store.kept.keys,
        containsAll(<String>['2026-11-08', '2026-11-09']),
      );
    });
  });

  group('when it cannot go', () {
    test('no signal never stops her closing, and is remembered', () async {
      store.ready = false;

      final BackupRound round = await nightly.run(day: '2026-11-08');

      expect(round.sent, isFalse);
      expect(round.message, contains('Nothing is lost'));
      expect(await nightly.lastProblem(), contains('Nothing is lost'));
      expect(await nightly.isDoneFor('2026-11-08'), isFalse);
    });

    test('it goes up on the next try, for the day it was missed', () async {
      store.ready = false;
      await nightly.run(day: '2026-11-08');
      store.ready = true;

      final BackupRound later = await nightly.run(day: '2026-11-08');

      expect(later.sent, isTrue);
      expect(await nightly.lastProblem(), isNull);
    });

    test(
      'a shop with no owner says so, rather than failing silently',
      () async {
        await settings.writeRaw(SettingKeys.syncShopId, '');

        final BackupRound round = await nightly.run(day: '2026-11-08');

        expect(round.outcome, BackupOutcome.skipped);
        expect(round.message, contains('no owner yet'));
      },
    );

    test('a refusal reads as a refusal, not as weather', () async {
      store.throwWith = Exception('permission-denied: not a till');

      final BackupRound round = await nightly.run(day: '2026-11-08');

      expect(round.message, contains('not allowed'));
    });
  });

  group('keeping the storage from filling up', () {
    test('thirty nights are kept and the rest go', () async {
      for (int i = 1; i <= 35; i++) {
        final String day = '2026-10-${i.toString().padLeft(2, '0')}';
        await nightly.run(day: day);
      }

      expect(store.kept.length, NightlyBackupService.keepDays);
      // The newest survive; the oldest are the ones dropped.
      expect(store.kept.keys, contains('2026-10-35'.replaceAll('35', '30')));
      expect(store.kept.keys, isNot(contains('2026-10-01')));
    });

    test('nothing is pruned before the new one is safely up', () async {
      for (int i = 1; i <= 31; i++) {
        await nightly.run(day: '2026-10-${i.toString().padLeft(2, '0')}');
      }
      expect(store.kept.length, 30);

      // A failed night must not cost her a copy she still had.
      store.ready = false;
      await nightly.run(day: '2026-11-01');
      expect(store.kept.length, 30);
    });
  });

  group('getting it back', () {
    test('what went up comes back down as the same shop', () async {
      await nightly.run(day: '2026-11-08');

      final String? sql = await nightly.fetch('2026-11-08');

      expect(sql, isNotNull);
      expect(DatabaseArchive.describe(sql!), isNotNull);
      expect(sql, contains('Spanish Latte'));
    });

    test('a night that never went up comes back as nothing', () async {
      expect(await nightly.fetch('2026-01-01'), isNull);
    });
  });
}

/// Somewhere to put a backup, on the table rather than in the cloud.
class _Store implements ShopBackupStore {
  final Map<String, Uint8List> kept = <String, Uint8List>{};
  final Map<String, DateTime> at = <String, DateTime>{};
  bool ready = true;
  Exception? throwWith;
  int puts = 0;

  void _check() {
    final Exception? failure = throwWith;
    if (failure != null) throw failure;
  }

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<void> put({
    required String shopId,
    required String day,
    required Uint8List data,
    required String device,
  }) async {
    _check();
    puts++;
    kept[day] = data;
    at[day] = DateTime.now();
  }

  @override
  Future<List<CloudBackup>> list(String shopId) async {
    final List<String> days = kept.keys.toList()
      ..sort((String a, String b) => b.compareTo(a));
    return <CloudBackup>[
      for (final String day in days)
        CloudBackup(
          day: day,
          takenAt: at[day]!,
          bytes: kept[day]!.length,
          device: 'A till',
        ),
    ];
  }

  @override
  Future<Uint8List?> get({required String shopId, required String day}) async =>
      kept[day];

  @override
  Future<void> remove({required String shopId, required String day}) async {
    kept.remove(day);
    at.remove(day);
  }
}
