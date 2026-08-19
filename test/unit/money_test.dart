import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';

void main() {
  group('Money construction', () {
    test('builds from pesos and centavos', () {
      expect(Money.of(180).centavos, 18000);
      expect(Money.of(180, 50).centavos, 18050);
      expect(Money.of(1250, 50).centavos, 125050);
      expect(Money.of(0, 5).centavos, 5);
    });

    test('carries the sign into negative amounts', () {
      expect(Money.of(-25).centavos, -2500);
      expect(Money.of(0, -5).centavos, -5);
    });

    test('parses the ways an amount might be typed', () {
      expect(Money.tryParse('180'), Money.of(180));
      expect(Money.tryParse('180.5'), Money.of(180, 50));
      expect(Money.tryParse('180.05'), Money.of(180, 5));
      expect(Money.tryParse('1,250.50'), Money.of(1250, 50));
      expect(Money.tryParse('₱1,250.50'), Money.of(1250, 50));
      expect(Money.tryParse('-25.00'), Money.of(-25));
    });

    test('rejects input that is not an amount', () {
      expect(Money.tryParse(''), isNull);
      expect(Money.tryParse('abc'), isNull);
      expect(Money.tryParse('180.505'), isNull);
      expect(Money.tryParse('1.2.3'), isNull);
    });
  });

  group('Money arithmetic', () {
    test('adds and subtracts exactly', () {
      expect(Money.of(180) + Money.of(70, 50), Money.of(250, 50));
      expect(Money.of(250, 50) - Money.of(70, 50), Money.of(180));
    });

    test('multiplies by a whole count', () {
      expect(Money.of(185) * 3, Money.of(555));
    });

    test('does not drift the way floating point would', () {
      // 0.1 + 0.2 != 0.3 in binary floating point. In centavos it is exact,
      // and it stays exact after ten thousand additions.
      Money total = Money.zero;
      for (int i = 0; i < 10000; i++) {
        total = total + Money.of(0, 10);
      }
      expect(total, Money.of(1000));
      expect(total.centavos, 100000);
    });

    test('sums a list without leaving integers', () {
      final List<Money> line = <Money>[
        Money.of(185),
        Money.of(165),
        Money.of(20, 50),
      ];
      expect(line.sum(), Money.of(370, 50));
    });

    test('compares amounts', () {
      expect(Money.of(180) > Money.of(170), isTrue);
      expect(Money.of(180) <= Money.of(180), isTrue);
      expect(Money.of(-10).isNegative, isTrue);
      expect(Money.zero.isZero, isTrue);
    });
  });

  group('Money formatting', () {
    test('always shows the peso sign and two decimals', () {
      expect(Money.of(180).format(), '₱180.00');
      expect(Money.of(250).format(), '₱250.00');
      expect(Money.of(1250, 50).format(), '₱1,250.50');
      expect(Money.zero.format(), '₱0.00');
      expect(Money.of(0, 5).format(), '₱0.05');
    });

    test('puts the minus sign before the symbol', () {
      expect(Money.of(-25).format(), '-₱25.00');
    });

    test('never shows a foreign currency symbol', () {
      final String formatted = Money.of(1250, 50).format();
      expect(formatted.contains(r'$'), isFalse);
      expect(formatted.contains('€'), isFalse);
      expect(formatted.contains('USD'), isFalse);
      expect(formatted.startsWith('₱'), isTrue);
    });

    test('exports a plain decimal for spreadsheets', () {
      expect(Money.of(1250, 50).toPlainString(), '1250.50');
      expect(Money.of(0, 5).toPlainString(), '0.05');
      expect(Money.of(-25).toPlainString(), '-25.00');
    });
  });
}
