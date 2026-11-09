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

  /// Remembers which shop this till belongs to, once it has been let in.
  Future<void> rememberShop(String id) async =>
      _settings.writeRaw(SettingKeys.syncShopId, id);

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

  /// Rounds until there is nothing left to hear.
  ///
  /// One round takes a page of changes. A till joining an established shop
  /// has a year of them waiting, so asking once would leave it holding the
  /// first five hundred and nothing else — a shop with half its orders in
  /// it, which is worse than an empty one because it looks finished.
  ///
  /// Stops when a round brings nothing new, or at [rounds] — a bound
  /// rather than a `while (true)`, so a transport that keeps handing back
  /// the same cursor cannot spin here for ever.
  Future<SyncReport> catchUp({
    String label = 'Till',
    int rounds = 200,
    void Function(int applied)? onProgress,
  }) async {
    int sent = 0;
    int applied = 0;
    SyncReport last = const SyncReport(sent: 0, applied: null);

    for (int round = 0; round < rounds; round++) {
      last = await syncNow(label: label);
      if (!last.isPaired || last.error != null) return last;

      sent += last.sent;
      final int tookIn = last.applied?.applied ?? 0;
      applied += tookIn;
      onProgress?.call(applied);

      // Nothing sent, nothing taken in, nothing waiting: we are level.
      if (last.sent == 0 && tookIn == 0 && (last.applied?.waitingForParent ?? 0) == 0) {
        break;
      }
    }

    return SyncReport(
      sent: sent,
      applied: SyncApplied(
        applied: applied,
        alreadyKnown: last.applied?.alreadyKnown ?? 0,
        waitingForParent: last.applied?.waitingForParent ?? 0,
        ignoredAsOlder: last.applied?.ignoredAsOlder ?? 0,
      ),
    );
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
