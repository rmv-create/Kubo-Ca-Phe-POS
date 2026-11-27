import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_transport.dart';

/// A till deadlocked by its own posted changes.
///
/// The shop's log is append-only: a second write to an entry is refused,
/// and a batch is all or nothing. So one change that is already up there
/// takes the whole batch down with it — and it stays up there, so the next
/// round dies in the same place, and the next, while the queue behind it
/// grows without limit.
///
/// A till posts a batch and loses signal before it can write down that it
/// did. From then on it is deadlocked for good, and the only sign of it is
/// a refusal, which reads exactly like a phone that was never let into the
/// shop. Jaja's phone sat like that for a week with seventeen hundred
/// orders behind it, admitted the whole time, while we made him invites.
void main() {
  late _Log log;
  late PostingToTheLog posting;

  setUp(() {
    log = _Log();
    posting = PostingToTheLog(
      commit: log.commit,
      postOne: log.postOne,
      alreadyThere: log.alreadyThere,
      lotSize: 3,
    );
  });

  List<SyncChange> changes(int n) => <SyncChange>[
    for (int i = 1; i <= n; i++)
      SyncChange(
        changeId: 'c$i',
        deviceId: 'his-phone',
        table: 'orders',
        rowUid: 'r$i',
        op: SyncOp.upsert,
        at: '2026-11-27T00:00:0$i.000Z',
        data: const <String, Object?>{},
      ),
  ];

  test('everything goes up when nothing is up there yet', () async {
    await posting(changes(7));

    expect(log.holds.length, 7);
    expect(log.oneByOne, 0, reason: 'no need to go the slow way');
  });

  test(
    'one change already up does not hold back the rest of its lot',
    () async {
      log.holds.add('c2');

      await posting(changes(7));

      expect(log.holds.length, 7, reason: 'the other six still got there');
      expect(log.turnedAway, <String>[
        'c2',
      ], reason: 'the one already up was refused, and forgiven for it');
    },
  );

  test('a lot that is entirely already up is simply stepped over', () async {
    log.holds.addAll(<String>['c1', 'c2', 'c3']);

    await posting(changes(3));

    expect(log.holds.length, 3);
  });

  test('a till the shop genuinely refuses is not quietly forgiven', () async {
    // Nothing of this till's is in the log, so a refusal is a refusal.
    log.refuseEverything = true;

    await expectLater(
      posting(changes(2)),
      throwsA(isA<RefusedByTheShop>()),
      reason: 'a change written off as sent is a sale nobody else hears of',
    );
  });

  test('and is still refused when some of its changes are up there', () async {
    log
      ..holds.add('c1')
      ..refuseEverything = true;

    await expectLater(posting(changes(3)), throwsA(isA<RefusedByTheShop>()));
  });
}

/// An append-only log: it will not take a second write to an entry, and a
/// batch goes in whole or not at all.
class _Log {
  final Set<String> holds = <String>{};

  /// Changes it refused a second write of. Nothing is ever written over:
  /// that is the whole point of an append-only log.
  final List<String> turnedAway = <String>[];
  bool refuseEverything = false;
  int oneByOne = 0;

  Future<void> commit(List<SyncChange> lot) async {
    if (refuseEverything) throw const RefusedByTheShop();
    if (lot.any((SyncChange c) => holds.contains(c.changeId))) {
      throw const RefusedByTheShop();
    }
    holds.addAll(lot.map((SyncChange c) => c.changeId));
  }

  Future<void> postOne(SyncChange change) async {
    oneByOne++;
    if (refuseEverything) throw const RefusedByTheShop();
    if (!holds.add(change.changeId)) {
      turnedAway.add(change.changeId);
      throw const RefusedByTheShop();
    }
  }

  Future<bool> alreadyThere(String changeId) async => holds.contains(changeId);
}
