import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/time/clock.dart';

void main() {
  group('BusinessDay', () {
    const BusinessDay day = BusinessDay(cutoffHour: 4);

    test('an ordinary daytime sale belongs to that date', () {
      expect(day.dateOf(DateTime(2026, 3, 15, 10, 30)), '2026-03-15');
      expect(day.dateOf(DateTime(2026, 3, 15, 23, 59)), '2026-03-15');
    });

    test('a sale after midnight still belongs to the previous trading day', () {
      expect(day.dateOf(DateTime(2026, 3, 16, 0, 30)), '2026-03-15');
      expect(day.dateOf(DateTime(2026, 3, 16, 3, 59)), '2026-03-15');
    });

    test('the new trading day starts at the cutoff', () {
      expect(day.dateOf(DateTime(2026, 3, 16, 4)), '2026-03-16');
    });

    test('rolls back across a month boundary', () {
      expect(day.dateOf(DateTime(2026, 4, 1, 1)), '2026-03-31');
      expect(day.dateOf(DateTime(2026, 1, 1, 2)), '2025-12-31');
    });

    test('a midnight cutoff makes the trading day the calendar day', () {
      const BusinessDay midnight = BusinessDay(cutoffHour: 0);
      expect(midnight.dateOf(DateTime(2026, 3, 16, 0, 30)), '2026-03-16');
    });
  });

  group('Clock', () {
    test('a fixed clock can be driven by the tests', () {
      final FixedClock clock = FixedClock(DateTime(2026, 3, 15, 10));
      expect(clock.now(), DateTime(2026, 3, 15, 10));
      clock.advance(const Duration(hours: 2));
      expect(clock.now(), DateTime(2026, 3, 15, 12));
    });

    test('timestamps are written as UTC ISO-8601', () {
      final FixedClock clock = FixedClock(DateTime.utc(2026, 3, 15, 10, 30));
      expect(clock.nowIso(), '2026-03-15T10:30:00.000Z');
    });
  });
}
