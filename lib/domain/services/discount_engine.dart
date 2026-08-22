import 'package:meta/meta.dart';

import '../../core/money/money.dart';
import '../entities/business_settings.dart';

/// The kinds of discount the POS can apply to a whole order.
enum DiscountKind {
  /// Republic Act 9994. Twenty per cent, and VAT-exempt.
  senior('senior', 'Senior Citizen'),

  /// Republic Act 10754. The same twenty per cent, and the same VAT exemption.
  pwd('pwd', 'PWD'),

  /// Anything the owner decides herself. Not statutory, not VAT-exempt.
  other('other', 'Other discount');

  const DiscountKind(this.code, this.label);

  final String code;
  final String label;

  /// Whether the law, rather than the owner, sets the rate — and whether the
  /// sale is exempt from VAT.
  bool get isStatutory => this != DiscountKind.other;

  static DiscountKind fromCode(String code) => DiscountKind.values.firstWhere(
    (DiscountKind k) => k.code == code,
    orElse: () => DiscountKind.other,
  );
}

/// A discount as it applies to one order, with every figure it produced.
///
/// Everything here is derived, never typed in: the owner picks *Senior
/// Citizen*, and the arithmetic below is what she is shown, what is stored,
/// and what is printed. A discount she could edit by hand would not be a
/// statutory discount.
@immutable
class DiscountBreakdown {
  const DiscountBreakdown({
    required this.kind,
    required this.grossSales,
    required this.vatRemoved,
    required this.discountableBase,
    required this.discountAmount,
    required this.vatOnBalance,
    required this.amountDue,
    required this.rateBp,
  });

  /// No discount: everything passes through untouched.
  factory DiscountBreakdown.none(Money grossSales) => DiscountBreakdown(
    kind: null,
    grossSales: grossSales,
    vatRemoved: Money.zero,
    discountableBase: grossSales,
    discountAmount: Money.zero,
    vatOnBalance: Money.zero,
    amountDue: grossSales,
    rateBp: 0,
  );

  /// Null when nothing was applied.
  final DiscountKind? kind;

  /// The menu total, VAT-inclusive, before anything is taken off.
  final Money grossSales;

  /// The VAT stripped out because the sale is exempt. Zero unless the shop is
  /// VAT-registered *and* the discount is statutory.
  final Money vatRemoved;

  /// What the percentage is actually applied to.
  final Money discountableBase;

  /// The discount itself.
  final Money discountAmount;

  /// VAT still owed on the balance. Zero for an exempt sale; for an ordinary
  /// discount the VAT was never removed, so it is not re-added either.
  final Money vatOnBalance;

  /// What the customer pays for the drinks, before any delivery fee.
  final Money amountDue;

  final int rateBp;

  bool get isEmpty => kind == null || discountAmount.isZero;

  /// Everything the customer saved: the discount, plus the VAT they were
  /// exempted from. This is the number a Senior Citizen recognises.
  Money get totalSaving => grossSales - amountDue;
}

/// Works out Senior Citizen, PWD and ordinary discounts.
///
/// The Philippine rules for a VAT-registered seller are specific, and the
/// order of operations changes the answer. On a ₱139 VAT-inclusive drink:
///
/// * **VAT-registered.** The sale is VAT-exempt, so the 12% comes out first:
///   139 ÷ 1.12 = ₱124.11 net. Twenty per cent of that is ₱24.82. The customer
///   pays ₱99.29 and has saved ₱39.71, not ₱27.80.
/// * **Not VAT-registered.** There is no VAT in the price to remove. Twenty
///   per cent of ₱139 is ₱27.80 and the customer pays ₱111.20.
///
/// Which of those is correct is a fact about the shop, not a preference, so it
/// comes from [BusinessSettings.vatRegistered] and is recorded on every order.
class DiscountEngine {
  const DiscountEngine(this.settings);

  final BusinessSettings settings;

  /// Applies [kind] to [grossSales], a VAT-inclusive menu total.
  ///
  /// A statutory discount sets its own rate. For [DiscountKind.other] the
  /// caller supplies [rateBpOverride]; without one there is no rate to apply
  /// and nothing is taken off.
  ///
  /// The discount covers the whole order. Where only part of a group is a
  /// cardholder, the law apportions the discount to that person's own
  /// consumption — at this counter the honest way to do that is to ring their
  /// drink as its own order, and the POS says so where the discount is chosen.
  DiscountBreakdown apply({
    required DiscountKind? kind,
    required Money grossSales,
    int? rateBpOverride,
  }) {
    if (kind == null || grossSales.isZero) {
      return DiscountBreakdown.none(grossSales);
    }

    final int vatRateBp = settings.effectiveVatRateBp;
    final bool exempt = kind.isStatutory && vatRateBp > 0;

    // Strip the VAT out of the inclusive price: net = gross × 10000 ÷ (10000 + rate).
    final Money net = exempt
        ? Money(_divideRound(grossSales.centavos * 10000, 10000 + vatRateBp))
        : grossSales;
    final Money vatRemoved = grossSales - net;

    final int rateBp = kind.isStatutory
        ? settings.statutoryDiscountRateBp
        : (rateBpOverride ?? 0);
    if (rateBp <= 0) return DiscountBreakdown.none(grossSales);
    final Money discount = Money(_divideRound(net.centavos * rateBp, 10000));

    return DiscountBreakdown(
      kind: kind,
      grossSales: grossSales,
      vatRemoved: vatRemoved,
      discountableBase: net,
      discountAmount: discount,
      // An exempt sale owes no VAT at all — not on the discount, and not on
      // the balance. This is what "VAT-exempt" means, and it is why the
      // customer saves more than the twenty per cent on the tag.
      vatOnBalance: Money.zero,
      amountDue: net - discount,
      rateBp: rateBp,
    );
  }
}

/// Integer division rounded half away from zero.
///
/// The same rule the costing engine uses. Truncation would quietly favour the
/// shop on every single discounted sale, which over a year is a real amount of
/// somebody else's money.
int _divideRound(int numerator, int denominator) {
  final int magnitude = numerator.abs();
  final int rounded = (magnitude + denominator ~/ 2) ~/ denominator;
  return numerator.isNegative ? -rounded : rounded;
}
