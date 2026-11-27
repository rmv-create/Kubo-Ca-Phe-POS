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

  /// How much this till has heard and cannot use yet, for want of the row it
  /// points at.
  Future<int> waitingToComeIn() => _engine.waitingCount();

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
        return await _fail(await _whyRefused(transport));
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

      // What this till is still holding goes in with the new page, so a
      // change that arrived before the row it belongs to gets another
      // chance every round. Held first: the page may well be carrying the
      // parent it has been waiting for.
      final List<SyncChange> held = await _engine.waitingRoom();
      final SyncApplied applied = await _engine.apply(<SyncChange>[
        ...held,
        ...incoming.changes,
      ]);
      await _engine.keepWaiting(applied.stillWaiting);

      // The cursor may now move. It could before, too — past changes that
      // had not been applied and were about to be forgotten, which is how
      // an order on one phone never reached the other with nothing in the
      // log to show for it.
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
      // A refusal is the one error worth taking apart, and it does not
      // only arrive before the round starts. A phone signed in to
      // *something* gets past the readiness check and is turned away at
      // the post box instead — which is exactly where his was being
      // turned away, and where the plain sentence told nobody anything.
      if (error.toString().contains('permission-denied')) {
        return _fail(await _whyRefused(transport));
      }
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
      if (last.sent == 0 &&
          tookIn == 0 &&
          (last.applied?.waitingForParent ?? 0) == 0) {
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

  /// Which of three quite different things is keeping this till out.
  ///
  /// They were all reported as "this till has not been let into the shop
  /// yet", which is true of only one of them and sends everybody off to
  /// make another invite. A phone whose sign-in has changed since it
  /// joined will be refused for ever by codes, however many are typed,
  /// because the shop admitted an id the phone is no longer holding.
  Future<String> _whyRefused(SyncTransport transport) async {
    final String? now = transport.identity;
    final String? joined = _nonEmpty(
      await _settings.readRaw(SettingKeys.syncTillUid),
    );

    if (now == null) {
      return 'This phone is not signed in to anything, so the shop cannot '
          'know it. Close the app and open it again.';
    }
    if (joined == null) {
      return 'This till has not been let into the shop yet. It is signed in '
          '(${_short(now)}) but the shop has no record of letting it in.';
    }
    if (joined != now) {
      return 'This phone was let in as ${_short(joined)} and is now '
          '${_short(now)}. Its sign-in has changed, so the shop no longer '
          'knows it — it needs a fresh invite, and this will keep '
          'happening until that stops.';
    }
    return 'The shop is refusing this phone (${_short(now)}) even though it '
        'was let in. This is not the code — a new one will not help.';
  }

  /// Enough of an id to compare two by eye, in a photograph.
  static String _short(String uid) =>
      uid.length <= 8 ? uid : '${uid.substring(0, 8)}…';

  Future<SyncReport> _fail(String message) async {
    await _settings.writeRaw(SettingKeys.syncLastError, message);
    return SyncReport.failed(message);
  }

  /// Firebase's own messages are written for programmers.
  static String _readable(Object error) {
    final String raw = error.toString();
    if (raw.contains('permission-denied')) {
      return 'The shop would not take this phone\u2019s orders '
          '(permission-denied).';
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
