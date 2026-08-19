import 'package:meta/meta.dart';

/// Indirection over "now" so that every timestamp the app writes can be
/// controlled in tests. Nothing outside this file may call `DateTime.now()`.
abstract class Clock {
  const Clock();

  DateTime now();

  /// UTC ISO-8601 string, the only timestamp format written to SQLite.
  String nowIso() => now().toUtc().toIso8601String();
}

class SystemClock extends Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// A clock the tests drive by hand.
class FixedClock extends Clock {
  FixedClock(this._now);

  DateTime _now;

  void set(DateTime value) => _now = value;
  void advance(Duration by) => _now = _now.add(by);

  @override
  DateTime now() => _now;
}

/// Resolves which *business* day a moment belongs to.
///
/// A drink sold at 00:30 belongs to the previous trading day, not to a new one.
/// [cutoffHour] is the local hour at which a new business day starts; it is a
/// setting because only the owner knows her hours.
@immutable
class BusinessDay {
  const BusinessDay({this.cutoffHour = 4});

  final int cutoffHour;

  /// `YYYY-MM-DD` for the trading day containing [moment] (local time).
  String dateOf(DateTime moment) {
    final DateTime local = moment.isUtc ? moment.toLocal() : moment;
    final DateTime day = local.hour < cutoffHour
        ? local.subtract(const Duration(days: 1))
        : local;
    return formatDate(day);
  }

  static String formatDate(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static DateTime parseDate(String yyyyMmDd) {
    final List<String> parts = yyyyMmDd.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }
}
