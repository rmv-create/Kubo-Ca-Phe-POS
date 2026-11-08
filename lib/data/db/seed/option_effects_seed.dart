import 'package:meta/meta.dart';

/// What each customisation does to the drink it is put on.
///
/// A customisation is not only a price. Sea salt cold foam is cream, milk,
/// condensed milk and salt that come out of her stock and cost her money; a
/// gram of matcha is a gram of matcha. Until these are written down, a
/// customised drink is sold at the right price and costed as though it were
/// plain — which overstates the profit on exactly the drinks she sells most.
///
/// Quantities are hers, off the recipe sheet. Two shapes:
///
/// * an **addition** — the same wherever it is poured, so no drink is named;
/// * a **swap** — takes out what that drink holds and puts the same weight of
///   something else in, which has to be written per drink and per size,
///   because a Spanish Latte and a Caramel Macchiato do not hold the same
///   milk.
abstract final class OptionEffectsSeed {
  /// Her sea salt cold foam, from the "Sea Salt Cold Foam" recipe on the
  /// sheet. Poured on top, so it adds to whatever is underneath.
  static final List<OptionEffect> effects = <OptionEffect>[
    const OptionEffect(
      option: 'Sea Salt Cold Foam',
      ingredient: 'Nestle All Purpose Cream',
      amount: 20,
    ),
    const OptionEffect(
      option: 'Sea Salt Cold Foam',
      ingredient: 'Alaska Fresh Milk',
      amount: 30,
    ),
    const OptionEffect(
      option: 'Sea Salt Cold Foam',
      ingredient: 'Vinamilk Condensed',
      amount: 10,
    ),
    const OptionEffect(
      option: 'Sea Salt Cold Foam',
      ingredient: 'Sea Salt',
      amount: 0.6,
    ),

    // The name is the recipe.
    const OptionEffect(option: '1g Matcha', ingredient: 'Matcha', amount: 1),

    // Sub Oat: out comes the dairy, in goes the same weight of oat. The
    // amounts are each drink's own, so the cost moves by what the swap
    // actually costs rather than by a flat guess.
    ..._subOat('Spanish Latte', 'Large', fresh: 85, evaporada: 20),
    ..._subOat('Spanish Latte', 'Small', fresh: 63.75, evaporada: 15),
    ..._subOat('Caramel Macchiato', 'Large', fresh: 100, evaporada: 20),
    ..._subOat('Caramel Macchiato', 'Small', fresh: 75, evaporada: 15),
    ..._subOat('Ca Phe Muoi', 'Large', fresh: 37.5),
    ..._subOat('Ca Phe Muoi', 'Small', fresh: 28.125),
    // Already an oat latte, but its cold foam is made with dairy.
    ..._subOat('Sea Salt Matcha Oat Latte', 'Large', fresh: 30),
    ..._subOat('Sea Salt Matcha Oat Latte', 'Small', fresh: 22.5),
  ];

  /// One drink's milk, swapped for the same weight of oat.
  static List<OptionEffect> _subOat(
    String drink,
    String size, {
    double fresh = 0,
    double evaporada = 0,
  }) => <OptionEffect>[
    if (fresh > 0)
      OptionEffect(
        option: 'Oat',
        ingredient: 'Alaska Fresh Milk',
        amount: -fresh,
        drink: drink,
        size: size,
      ),
    if (evaporada > 0)
      OptionEffect(
        option: 'Oat',
        ingredient: 'Alaska Evaporada',
        amount: -evaporada,
        drink: drink,
        size: size,
      ),
    OptionEffect(
      option: 'Oat',
      ingredient: 'Oatside',
      amount: fresh + evaporada,
      drink: drink,
      size: size,
    ),
  ];
}

/// One customisation's effect on one ingredient.
@immutable
class OptionEffect {
  const OptionEffect({
    required this.option,
    required this.ingredient,
    required this.amount,
    this.drink,
    this.size,
  });

  /// The choice, by the name it has on the POS.
  final String option;

  final String ingredient;

  /// In that ingredient's own unit. Negative takes it out of the recipe.
  final double amount;

  /// Null means every drink. Both set means this drink at this size only.
  final String? drink;
  final String? size;
}
