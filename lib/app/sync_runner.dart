import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/sync/cloud_sync_service.dart';
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
/// None of it blocks anything. A round that fails is written down and
/// tried again; a till with no signal sells coffee all day and catches up
/// when the signal comes back.
class SyncRunner {
  SyncRunner(this._ref);

  final Ref _ref;

  Timer? _afterOrder;
  Timer? _idle;
  bool _running = false;

  /// Long enough that a queue of customers is one round, short enough that
  /// the other till is never far behind.
  static const Duration _settle = Duration(seconds: 20);
  static const Duration _everySoOften = Duration(minutes: 5);

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
    _running = true;
    try {
      final CloudSyncService sync = await _ref.read(cloudSyncProvider.future);
      final String label = await _label();
      await sync.syncNow(label: label);
      _ref.read(syncTickProvider.notifier).bump();
    } on Object {
      // syncNow does not throw; this is for the provider itself failing to
      // build, which is not a reason to interrupt anybody.
    } finally {
      _running = false;
    }
  }

  Future<String> _label() =>
      _ref.read(shopAccessServiceProvider).deviceLabel();
}

final Provider<SyncRunner> syncRunnerProvider = Provider<SyncRunner>((Ref ref) {
  final SyncRunner runner = SyncRunner(ref);
  ref.onDispose(runner.stop);
  return runner;
});
