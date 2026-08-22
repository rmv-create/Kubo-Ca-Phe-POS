import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/services/discount_engine.dart';

void main() {
  const BusinessSettings notRegistered = BusinessSettings.defaults;
  final BusinessSettings vatRegistered = BusinessSettings.defaults.copyWith(
    vatRegistered: true,
  );

  group('not VAT-registered', () {
    const DiscountEngine engine = DiscountEngine(notRegistered);

    test('a Senior Citizen pays twenty per cent less than the menu', () {
      final DiscountBreakdown d = engine.apply(
        kind: DiscountKind.senior,
        grossSales: Money.of(139),
      );

      expect(d.vatRemoved, Money.zero);
      expect(d.discountableBase, Money.of(139));
      expect(d.discountAmount, Money.of(27, 80));
      expect(d.amountDue, Money.of(111, 20));
      expect(d.totalSaving, Money.of(27, 80));
    });

    test('PWD is treated exactly the same as Senior Citizen', () {
      final Money senior = engine
          .apply(kind: DiscountKind.senior, grossSales: Money.of(278))
          .amountDue;
      final Money pwd = engine
          .apply(kind: DiscountKind.pwd, grossSales: Money.of(278))
          .amountDue;

      expect(pwd, senior);
    });
  });

  group('VAT-registered', () {
    late DiscountEngine engine;
    setUp(() => engine = DiscountEngine(vatRegistered));

    test(
      'the sale is VAT-exempt, so the VAT comes off before the discount',
      () {
        final DiscountBreakdown d = engine.apply(
          kind: DiscountKind.senior,
          grossSales: Money.of(139),
        );

        // 139 ÷ 1.12 = 124.107…, which rounds to ₱124.11.
        expect(d.discountableBase, Money.of(124, 11));
        expect(d.vatRemoved, Money.of(14, 89));
        // 20% of 124.11 = 24.822, which rounds to ₱24.82.
        expect(d.discountAmount, Money.of(24, 82));
        expect(d.amountDue, Money.of(99, 29));
        expect(d.vatOnBalance, Money.zero);
      },
    );

    test('the customer saves more than the twenty per cent on the tag', () {
      final DiscountBreakdown d = engine.apply(
        kind: DiscountKind.senior,
        grossSales: Money.of(139),
      );

      expect(d.totalSaving, Money.of(39, 71));
      expect(d.totalSaving > d.discountAmount, isTrue);
    });

    test('an ordinary discount is not VAT-exempt', () {
      final DiscountBreakdown d = engine.apply(
        kind: DiscountKind.other,
        grossSales: Money.of(139),
        rateBpOverride: 1000,
      );

      expect(d.vatRemoved, Money.zero);
      expect(d.discountableBase, Money.of(139));
      expect(d.discountAmount, Money.of(13, 90));
      expect(d.amountDue, Money.of(125, 10));
    });

    test('an ordinary discount with no rate takes nothing off', () {
      final DiscountBreakdown d = engine.apply(
        kind: DiscountKind.other,
        grossSales: Money.of(139),
      );

      expect(d.discountAmount, Money.zero);
      expect(d.amountDue, Money.of(139));
    });
  });

  group('arithmetic', () {
    test('rounding is half away from zero, never truncation', () {
      // ₱0.05 at 20% is exactly 1 centavo; ₱0.075 would be 1.5 and must round
      // up to 2. Truncating would shave a centavo off the customer every time.
      const DiscountEngine engine = DiscountEngine(notRegistered);

      expect(
        engine
            .apply(kind: DiscountKind.senior, grossSales: const Money(5))
            .discountAmount,
        const Money(1),
      );
      expect(
        engine
            .apply(kind: DiscountKind.senior, grossSales: const Money(15))
            .discountAmount,
        const Money(3),
      );
      expect(
        engine
            .apply(kind: DiscountKind.senior, grossSales: const Money(35))
            .discountAmount,
        const Money(7),
      );
    });

    test('nothing is taken off an empty order', () {
      const DiscountEngine engine = DiscountEngine(notRegistered);
      final DiscountBreakdown d = engine.apply(
        kind: DiscountKind.senior,
        grossSales: Money.zero,
      );

      expect(d.isEmpty, isTrue);
      expect(d.amountDue, Money.zero);
    });

    test('no discount chosen leaves the total exactly as it was', () {
      const DiscountEngine engine = DiscountEngine(notRegistered);
      final DiscountBreakdown d = engine.apply(
        kind: null,
        grossSales: Money.of(1250, 50),
      );

      expect(d.isEmpty, isTrue);
      expect(d.amountDue, Money.of(1250, 50));
      expect(d.totalSaving, Money.zero);
    });

    test('the parts always add back up to the menu total', () {
      // Whatever the path, gross = VAT removed + discount + what is paid.
      for (final BusinessSettings settings in <BusinessSettings>[
        notRegistered,
        vatRegistered,
      ]) {
        final DiscountEngine engine = DiscountEngine(settings);
        for (int centavos = 1; centavos <= 5000; centavos += 7) {
          final Money gross = Money(centavos);
          final DiscountBreakdown d = engine.apply(
            kind: DiscountKind.pwd,
            grossSales: gross,
          );
          expect(
            d.vatRemoved + d.discountAmount + d.amountDue,
            gross,
            reason:
                'broke at ${gross.format()} '
                'with vatRegistered=${settings.vatRegistered}',
          );
        }
      }
    });
  });
}
