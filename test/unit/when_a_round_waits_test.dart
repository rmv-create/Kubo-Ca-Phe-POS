import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/sync_runner.dart';

/// When the two tills may talk to each other.
///
/// A round is a lot of reading and writing, and the database is the one
/// thing it shares with the order she is taking, so it stands aside while
/// there are drinks on the screen.
///
/// The first version of that stood aside for ever. A drink left in the order
/// and the phone put down is not somebody serving — it is a till that has
/// quietly stopped listening, which is how her phone sat on 1216 while the
/// barista's was on 1217.
void main() {
  final DateTime ten = DateTime(2026, 11, 22, 10);

  test('an empty till is a good moment', () {
    expect(
      waitForTheTill(serving: false, putOffSince: null, now: ten),
      isFalse,
    );
  });

  test('an order on the screen is not', () {
    expect(waitForTheTill(serving: true, putOffSince: null, now: ten), isTrue);
  });

  test('and it keeps waiting while she is still ringing it up', () {
    expect(
      waitForTheTill(
        serving: true,
        putOffSince: ten,
        now: ten.add(const Duration(seconds: 40)),
      ),
      isTrue,
    );
  });

  test('but a forgotten order does not hold the tills apart all day', () {
    expect(
      waitForTheTill(
        serving: true,
        putOffSince: ten,
        now: ten.add(const Duration(minutes: 2)),
      ),
      isFalse,
      reason: 'after two minutes it goes anyway',
    );
    expect(
      waitForTheTill(
        serving: true,
        putOffSince: ten,
        now: ten.add(const Duration(hours: 3)),
      ),
      isFalse,
    );
  });

  test('once she finishes, nothing is waiting for anything', () {
    expect(
      waitForTheTill(
        serving: false,
        putOffSince: ten,
        now: ten.add(const Duration(seconds: 25)),
      ),
      isFalse,
    );
  });
}
