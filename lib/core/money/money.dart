import 'package:intl/intl.dart';
import 'package:meta/meta.dart';

/// Philippine Peso amount held as an exact integer number of **centavos**.
///
/// Money is never represented as a `double` anywhere in this application:
/// binary floating point cannot represent ₱0.10 exactly, and a POS that
/// accumulates thousands of small amounts per week would drift. Every price,
/// cost, total and report value flows through this type.
@immutable
class Money implements Comparable<Money> {
  const Money(this.centavos);

  /// ₱0.00
  static const Money zero = Money(0);

  /// Builds a [Money] from whole pesos and centavos, e.g. `Money.of(180, 50)`
  /// is ₱180.50. [centavos] must be 0–99; the sign comes from [pesos] unless
  /// [pesos] is zero, in which case pass a negative [centavos].
  factory Money.of(int pesos, [int centavos = 0]) {
    assert(centavos.abs() < 100, 'centavos must be within -99..99');
    final int magnitude = pesos.abs() * 100 + centavos.abs();
    final bool negative = pesos.isNegative || centavos.isNegative;
    return Money(negative ? -magnitude : magnitude);
  }

  /// Parses user input such as `180`, `180.5`, `1,250.50` or `₱1,250.50`.
  /// Returns `null` when the text is not a valid amount.
  static Money? tryParse(String input) {
    final String cleaned = input
        .replaceAll(RegExp(r'[₱\s,]'), '')
        .replaceAll('PHP', '');
    if (cleaned.isEmpty) return null;
    final RegExpMatch? match = RegExp(
      r'^(-?)(\d+)(?:\.(\d{1,2}))?$',
    ).firstMatch(cleaned);
    if (match == null) return null;
    final bool negative = match.group(1) == '-';
    final int pesos = int.parse(match.group(2)!);
    final String fraction = (match.group(3) ?? '').padRight(2, '0');
    final int magnitude = pesos * 100 + int.parse(fraction);
    return Money(negative ? -magnitude : magnitude);
  }

  /// The exact amount in centavos. This is what is persisted to SQLite.
  final int centavos;

  bool get isZero => centavos == 0;
  bool get isNegative => centavos < 0;
  bool get isPositive => centavos > 0;

  Money operator +(Money other) => Money(centavos + other.centavos);
  Money operator -(Money other) => Money(centavos - other.centavos);
  Money operator -() => Money(-centavos);

  /// Exact multiplication by a whole count, e.g. a line of 3 identical drinks.
  Money operator *(int multiplier) => Money(centavos * multiplier);

  Money get abs => Money(centavos.abs());

  bool operator >(Money other) => centavos > other.centavos;
  bool operator >=(Money other) => centavos >= other.centavos;
  bool operator <(Money other) => centavos < other.centavos;
  bool operator <=(Money other) => centavos <= other.centavos;

  /// Formatted for display: `₱1,250.50`, `-₱25.00`.
  String format({bool withSymbol = true}) {
    final NumberFormat formatter = NumberFormat('#,##0.00', 'en_PH');
    final String digits = formatter.format(centavos.abs() / 100);
    final String sign = isNegative ? '-' : '';
    return withSymbol ? '$sign₱$digits' : '$sign$digits';
  }

  /// Plain decimal string for spreadsheet cells: `1250.50`, `-25.00`.
  String toPlainString() {
    final String sign = isNegative ? '-' : '';
    final int magnitude = centavos.abs();
    return '$sign${magnitude ~/ 100}.${(magnitude % 100).toString().padLeft(2, '0')}';
  }

  /// Only for handing a value to a spreadsheet/chart that demands a number.
  /// Never use the result for further arithmetic.
  double toDoubleForExport() => centavos / 100;

  @override
  int compareTo(Money other) => centavos.compareTo(other.centavos);

  @override
  bool operator ==(Object other) =>
      other is Money && other.centavos == centavos;

  @override
  int get hashCode => centavos.hashCode;

  @override
  String toString() => format();
}

/// Sums a list of amounts without ever leaving integer arithmetic.
extension MoneySum on Iterable<Money> {
  Money sum() =>
      Money(fold<int>(0, (int total, Money m) => total + m.centavos));
}
