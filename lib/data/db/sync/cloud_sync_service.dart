import 'dart:math';

import '../../../core/time/clock.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../domain/repositories/settings_repository.dart';
import 'sync_change.dart';
import 'sync_engine.dart';
import 'sync_transport.dart';

/// One round of telling and being told.
///
/// Everything that decides whether a merge is *correct* is in [SyncEngine]
/// and is tested without a network. This is the errand: say what we did,
/// hear what they did, remember where we got to.
class CloudSyncService {
  CloudSyncService({
    required SyncEngine engine,
    required SettingsRepository settings,
    required Clock clock,
    SyncTransport? transport,
  }) : _engine = engine,
       _settings = settings,
       _clock = clock,
       _transport = transport;

  final SyncEngine _engine;
  final SettingsRepository _settings;
  final Clock _clock;
  final SyncTransport? _transport;

  SyncTransport? get transport => _transport;

  Future<String?> shopId() async =>
      _nonEmpty(await _settings.readRaw(SettingKeys.syncShopId));

  Future<bool> isPaired() async => await shopId() != null;

  Future<DateTime?> lastSyncAt() async {
    final String? raw = await _settings.readRaw(SettingKeys.syncLastAt);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<String?> lastError() async =>
      _nonEmpty(await _settings.readRaw(SettingKeys.syncLastError));

  Future<int> waitingToGoUp() => _engine.pendingCount();

  /// Makes this till the first one of a new shop.
  ///
  /// The id is long and random because it is also the only thing standing
  /// between a stranger and the front door of the shop's log — the rules
  /// then ask for a code on top of it.
  Future<String> startShop() async {
    final String existing =
        await _settings.readRaw(SettingKeys.syncShopId) ?? '';
    if (existing.isNotEmpty) return existing;

    final Random random = Random.secure();
    final String id = List<String>.generate(
      32,
      (_) => '0123456789abcdef'[random.nextInt(16)],
    ).join();
    await _settings.writeRaw(SettingKeys.syncShopId, id);
    return id;
  }

  /// A six-digit code for the other till, good for ten minutes.
  ///
  /// Short because it is read aloud across a counter, and short-lived
  /// because a code that never expires is a password that was shouted once.
  String newJoinCode() {
    final Random random = Random.secure();
    return (random.nextInt(900000) + 100000).toString();
  }

  /// Tells and is told, once.
  ///
  /// Never throws: a till with no signal must carry on selling coffee. What
  /// went wrong is written down and shown on the sync screen.
  Future<SyncReport> syncNow({String label = 'Till'}) async {
    final SyncTransport? transport = _transport;
    if (transport == null || !await isPaired()) {
      return const SyncReport.notPaired();
    }

    try {
      if (!await transport.isReady()) {
        return await _fail('This till has not been let into the shop yet.');
      }

      // Ours first. If the signal dies halfway, the other till has at least
      // heard about the orders we took.
      final List<SyncChange> mine = await _engine.collect();
      if (mine.isNotEmpty) {
        await transport.publish(mine);
        await _engine.markSent(mine);
      }

      final String? cursor = _nonEmpty(
        await _settings.readRaw(SettingKeys.syncCursor),
      );
      final SyncFetch incoming = await transport.fetch(afterCursor: cursor);
      final SyncApplied applied = await _engine.apply(incoming.changes);

      // Only after they are safely applied: a cursor moved too early is a
      // change nobody ever hears about again.
      final String? next = incoming.cursor;
      if (next != null && next != cursor) {
        await _settings.writeRaw(SettingKeys.syncCursor, next);
      }

      await transport.heartbeat(label: label);
      await _settings.writeRaw(
        SettingKeys.syncLastAt,
        _clock.now().toUtc().toIso8601String(),
      );
      await _settings.writeRaw(SettingKeys.syncLastError, '');

      return SyncReport(sent: mine.length, applied: applied);
    } on Object catch (error) {
      return _fail(_readable(error));
    }
  }

  Future<SyncReport> _fail(String message) async {
    await _settings.writeRaw(SettingKeys.syncLastError, message);
    return SyncReport.failed(message);
  }

  /// Firebase's own messages are written for programmers.
  static String _readable(Object error) {
    final String raw = error.toString();
    if (raw.contains('permission-denied')) {
      return 'This till has not been let into the shop yet.';
    }
    if (raw.contains('unavailable') || raw.contains('network')) {
      return 'No connection. Nothing is lost — it will go up next time.';
    }
    return raw.length > 160 ? '${raw.substring(0, 157)}…' : raw;
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
}

/// How a round went, in terms the sync screen can show.
class SyncReport {
  const SyncReport({required this.sent, required this.applied})
    : error = null,
      isPaired = true;

  const SyncReport.notPaired()
    : sent = 0,
      applied = null,
      error = null,
      isPaired = false;

  const SyncReport.failed(this.error)
    : sent = 0,
      applied = null,
      isPaired = true;

  final int sent;
  final SyncApplied? applied;
  final String? error;
  final bool isPaired;

  bool get ok => error == null && isPaired;

  int get received => applied?.applied ?? 0;

  String describe() {
    if (!isPaired) return 'Not connected to another till';
    final String? problem = error;
    if (problem != null) return problem;
    if (sent == 0 && received == 0) return 'Up to date';
    return <String>[
      if (sent > 0) 'sent $sent',
      if (received > 0) 'received $received',
    ].join(', ');
  }
}
