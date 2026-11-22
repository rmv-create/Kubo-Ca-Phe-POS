import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/sync/cloud_sync_service.dart';
import '../domain/entities/order_draft.dart';
import '../features/pos/state/cart_controller.dart';
import 'providers.dart';

/// Keeps the tills level with each other, without anybody pressing
/// anything.
///
/// Three moments, and they are the three that matter in a coffee shop:
///
///  * **Opening the app**, because whatever the other till did while this
///    one was in a pocket is what she most needs to see.
///  * **Shortly after each order**, debounced, so a run of three customers
///    is one round rather than three. The delay is also what keeps the POS
///    feeling instant — the sync happens behind the order, never in front
///    of it.
///  * **Every few minutes while it sits there**, for the till that is open
///    on the counter all afternoon taking nothing.
///
/// And one moment it deliberately stays out of: while there is an order on
/// the screen. A round is a lot of reading and writing, and the database is
/// one thing shared with the order she is taking — so if there are drinks
/// in the order, the round waits for the sale to finish rather than making
/// her wait for it. Nothing is lost by waiting: it goes a few seconds
/// later, which is what a debounce is for.
///
/// None of it blocks anything. A round that fails is written down and
/// tried again; a till with no signal sells coffee all day and catches up
/// when the signal comes back.
class SyncRunner {
  SyncRunner(this._ref);

  final Ref _ref;

  Timer? _afterOrder;
  Timer? _idle;
  bool _running = false;

  /// When this round first stood aside for an order on the screen.
  DateTime? _putOff;

  /// Long enough that a queue of customers is one round, short enough that
  /// the other till is never far behind.
  static const Duration _settle = Duration(seconds: 20);
  static const Duration _everySoOften = Duration(minutes: 5);

  /// Longer than any real order takes to ring up, short enough that a
  /// forgotten one cannot hold the two tills apart.
  static const Duration longestStandDown = Duration(minutes: 2);

  void start() {
    _idle ??= Timer.periodic(_everySoOften, (_) => runNow());
    unawaited(runNow());
  }

  void stop() {
    _afterOrder?.cancel();
    _idle?.cancel();
    _idle = null;
  }

  /// Something was sold, changed, or voided.
  void somethingHappened() {
    _afterOrder?.cancel();
    _afterOrder = Timer(_settle, runNow);
  }

  Future<void> runNow() async {
    // One at a time. Two rounds at once would publish the same outbox rows
    // twice and race each other to move the cursor.
    if (_running) return;

    // Not in front of a customer, if that can be helped. An order on the
    // screen means she is at the till, so the round waits for her to finish.
    //
    // But only for so long. A till with a drink left in the order and the
    // phone put down is not serving anybody, and the first version of this
    // would have waited for that order for ever — the other phone's sales
    // never arriving, the number on screen falling further behind, all day.
    // So after [longestStandDown] the round goes anyway: a moment's wait
    // for her is better than a till that quietly stops listening.
    if (waitForTheTill(
      serving: _sheIsServing,
      putOffSince: _putOff,
      now: DateTime.now(),
    )) {
      _putOff ??= DateTime.now();
      _afterOrder?.cancel();
      _afterOrder = Timer(_settle, runNow);
      return;
    }
    _putOff = null;
    _running = true;
    try {
      final CloudSyncService sync = await _ref.read(cloudSyncProvider.future);
      final String label = await _label();
      final SyncReport report = await sync.syncNow(label: label);
      _ref.read(syncTickProvider.notifier).bump();
      if ((report.applied?.applied ?? 0) > 0) _tellTheScreens();
    } on Object {
      // syncNow does not throw; this is for the provider itself failing to
      // build, which is not a reason to interrupt anybody.
    } finally {
      _running = false;
    }
  }

  /// Lets the screens know that the world changed underneath them.
  ///
  /// A round writes the other till's orders, customers and settings straight
  /// into the database, and nothing on screen was watching the database —
  /// every list in the app refreshes when *this* phone does something, and a
  /// round is the one case where something happens that this phone did not
  /// do. So the owner's phone could hold order 1217 and still show 1216 as
  /// the next one, and a barista given leave to correct an order would not
  /// be given it until he restarted the app.
  ///
  /// Cheap: each of these is a counter, and the lists hanging off them are
  /// only rebuilt if a screen is actually watching.
  void _tellTheScreens() {
    _ref.read(salesRevisionProvider.notifier).heard();
    _ref.read(customerRevisionProvider.notifier).bump();
    _ref.read(menuRevisionProvider.notifier).bump();
    _ref.read(stockRevisionProvider.notifier).bump();
    _ref.read(userRevisionProvider.notifier).bump();
    _ref.read(paymentMethodRevisionProvider.notifier).bump();
    // The shop's own settings travel too — what the receipt says, and who
    // may put an order right — and they are held in memory, so they are the
    // one thing a counter cannot refresh.
    unawaited(_ref.read(settingsControllerProvider.notifier).reload());
  }

  /// Whether there is an order being taken right now.
  bool get _sheIsServing {
    try {
      final OrderDraft draft = _ref.read(cartProvider);
      return !draft.isEmpty;
    } on Object {
      // No till on screen at all — a background round is welcome.
      return false;
    }
  }

  Future<String> _label() => _ref.read(shopAccessServiceProvider).deviceLabel();
}

final Provider<SyncRunner> syncRunnerProvider = Provider<SyncRunner>((Ref ref) {
  final SyncRunner runner = SyncRunner(ref);
  ref.onDispose(runner.stop);
  return runner;
});

/// Whether a round should stand aside for the person at the till.
///
/// Yes while she is ringing something up — a round is a lot of reading and
/// writing, and the database is the one thing it shares with the order in
/// front of her.
///
/// No once it has waited [SyncRunner.longestStandDown], however. A till with
/// a drink left in the order and the phone put down is not serving anybody,
/// and waiting for that order for ever is how one phone ends up a number
/// behind the other all day.
bool waitForTheTill({
  required bool serving,
  required DateTime? putOffSince,
  required DateTime now,
}) =>
    serving &&
    (putOffSince == null ||
        now.difference(putOffSince) < SyncRunner.longestStandDown);
