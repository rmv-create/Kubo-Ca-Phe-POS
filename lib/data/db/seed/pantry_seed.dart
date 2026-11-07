import 'package:meta/meta.dart';

import '../../../core/quantity/measurement_unit.dart';

/// Her pantry and her recipes, exactly as she wrote them in the worksheet.
///
/// Nothing here is estimated. Every quantity, price and stock level is off
/// sheets 4 and 5 of the spreadsheet she filled in; where a figure was
/// missing it is missing here too, rather than guessed, and the app reports
/// the drink as "not fully costed" instead of claiming a profit it cannot
/// stand behind.
abstract final class PantrySeed {
  /// Everything she buys, off sheet 4 of her worksheet.
  static const List<PantryItem> ingredients = <PantryItem>[
    PantryItem(
      name: 'Straw',
      category: 'Packaging',
      unit: BaseUnit.piece,
      buyBy: 'pack',
      perPurchase: 100,
      pricePerPurchase: 4800,
      reorderAt: 50,
      panicAt: 30,
      onHand: 200,
    ),
    PantryItem(
      name: 'Paper Cover',
      category: 'Packaging',
      unit: BaseUnit.piece,
      buyBy: 'pack',
      perPurchase: 100,
      pricePerPurchase: 5800,
      reorderAt: 50,
      panicAt: 30,
      onHand: 200,
    ),
    PantryItem(
      name: 'Large cup 16oz',
      category: 'Packaging',
      unit: BaseUnit.piece,
      buyBy: 'pack',
      perPurchase: 50,
      pricePerPurchase: 22900,
      reorderAt: 50,
      panicAt: 30,
      onHand: 200,
    ),
    PantryItem(
      name: 'Small cup 12oz',
      category: 'Packaging',
      unit: BaseUnit.piece,
      buyBy: 'pack',
      perPurchase: 50,
      pricePerPurchase: 21500,
      reorderAt: 30,
      panicAt: 15,
      onHand: 100,
    ),
    PantryItem(
      name: 'Cold Foam Cup',
      category: 'Packaging',
      unit: BaseUnit.piece,
      buyBy: 'pack',
      perPurchase: 50,
      pricePerPurchase: 8500,
      reorderAt: 20,
      panicAt: 15,
      onHand: 50,
    ),
    PantryItem(
      name: 'Double Plastic',
      category: 'Packaging',
      unit: BaseUnit.piece,
      buyBy: 'pack',
      perPurchase: 100,
      pricePerPurchase: 8800,
      reorderAt: 25,
      panicAt: 15,
      onHand: 100,
    ),
    PantryItem(
      name: 'Single Plastic',
      category: 'Packaging',
      unit: BaseUnit.piece,
      buyBy: 'pack',
      perPurchase: 100,
      pricePerPurchase: 5600,
      reorderAt: 30,
      panicAt: 15,
      onHand: 100,
    ),
    PantryItem(
      name: 'Sang Tao 1',
      category: 'Coffee',
      unit: BaseUnit.gram,
      buyBy: 'piece',
      perPurchase: 340,
      pricePerPurchase: 31700,
      reorderAt: 1700,
      panicAt: 1020,
      onHand: 3060,
    ),
    PantryItem(
      name: 'Alaska Fresh Milk',
      category: 'Milk',
      unit: BaseUnit.gram,
      buyBy: 'carton',
      perPurchase: 1000,
      pricePerPurchase: 9500,
      reorderAt: 4000,
      panicAt: 2000,
      onHand: 4000,
    ),
    PantryItem(
      name: 'Alaska Evaporada',
      category: 'Milk',
      unit: BaseUnit.gram,
      buyBy: 'piece',
      perPurchase: 360,
      pricePerPurchase: 3500,
      reorderAt: 1440,
      panicAt: 720,
      onHand: 720,
    ),
    PantryItem(
      name: 'Oatside',
      category: 'Milk',
      unit: BaseUnit.gram,
      buyBy: 'carton',
      perPurchase: 1000,
      pricePerPurchase: 16000,
      reorderAt: 6000,
      panicAt: 4000,
      onHand: 9000,
    ),
    PantryItem(
      name: 'Vinamilk Condensed',
      category: 'Sweetener',
      unit: BaseUnit.gram,
      buyBy: 'carton',
      perPurchase: 1284,
      pricePerPurchase: 33000,
      reorderAt: 2568,
      panicAt: 1284,
      onHand: 3852,
    ),
    PantryItem(
      name: 'Caramel Syrup',
      category: 'Syrup',
      unit: BaseUnit.gram,
      buyBy: 'piece',
      perPurchase: 1000,
      pricePerPurchase: 79000,
      reorderAt: 300,
      panicAt: 200,
      onHand: 1000,
    ),
    PantryItem(
      name: 'Caramel Sauce',
      category: 'Sauce',
      unit: BaseUnit.gram,
      buyBy: 'piece',
      perPurchase: 500,
      pricePerPurchase: 72100,
      reorderAt: 250,
      panicAt: 125,
      onHand: 500,
    ),
    PantryItem(
      name: 'Matcha',
      category: 'Powder',
      unit: BaseUnit.gram,
      buyBy: 'piece',
      perPurchase: 50,
      pricePerPurchase: 46600,
      reorderAt: 150,
      panicAt: 100,
      onHand: 350,
    ),
    PantryItem(
      name: 'Nestle All Purpose Cream',
      category: 'Dairy',
      unit: BaseUnit.gram,
      buyBy: 'piece',
      perPurchase: 250,
      pricePerPurchase: 7000,
      reorderAt: 750,
      panicAt: 500,
      onHand: 2250,
    ),
    PantryItem(
      name: 'Water',
      category: 'Other food',
      unit: BaseUnit.gram,
      buyBy: 'pack',
      perPurchase: 15000,
      pricePerPurchase: 5000,
      tracked: false,
    ),
    PantryItem(
      name: 'Electricity & Gas',
      category: 'Other food',
      unit: BaseUnit.piece,
      buyBy: 'pack',
      perPurchase: 1,
      pricePerPurchase: 1000,
      tracked: false,
    ),
    PantryItem(
      name: 'Ice',
      category: 'Other food',
      unit: BaseUnit.gram,
      buyBy: 'piece',
      perPurchase: 100,
      pricePerPurchase: 500,
      tracked: false,
    ),
    PantryItem(
      name: 'Sea Salt',
      category: 'Powder',
      unit: BaseUnit.gram,
      buyBy: 'piece',
      perPurchase: 1000,
      pricePerPurchase: 17500,
      tracked: false,
    ),
    PantryItem(
      name: 'Cinnamon',
      category: 'Powder',
      unit: BaseUnit.gram,
      buyBy: 'piece',
      perPurchase: 50,
      pricePerPurchase: 7500,
      tracked: false,
    ),
    PantryItem(
      name: 'Egg',
      unit: BaseUnit.piece,
      buyBy: 'tray',
      perPurchase: 1,
      pricePerPurchase: 900,
      tracked: false,
    ),
  ];

  /// What goes into each drink, from the corrected recipe sheet she
  /// sent on 7 November. Sizes are her own: Small and Large.
  ///
  /// Where she lists an ingredient twice in one drink — the milk in a
  /// cold foam, say — the two lines are added together, because a
  /// recipe holds one figure per ingredient.
  static const List<PantryRecipe> recipes = <PantryRecipe>[
    PantryRecipe(
      drink: 'Iced Black',
      size: 'Large',
      lines: <String, double>{
        'Sang Tao 1': 33,
        'Water': 235,
        'Ice': 180,
        'Electricity & Gas': 1,
        'Large cup 16oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Iced Black',
      size: 'Small',
      lines: <String, double>{
        'Sang Tao 1': 24.75,
        'Water': 176.25,
        'Ice': 135,
        'Electricity & Gas': 1,
        'Small cup 12oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Spanish Latte',
      size: 'Large',
      lines: <String, double>{
        'Sang Tao 1': 22,
        'Water': 130,
        'Vinamilk Condensed': 32,
        'Ice': 180,
        'Alaska Fresh Milk': 85,
        'Alaska Evaporada': 20,
        'Electricity & Gas': 1,
        'Large cup 16oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Spanish Latte',
      size: 'Small',
      lines: <String, double>{
        'Sang Tao 1': 16.5,
        'Water': 97.5,
        'Vinamilk Condensed': 24,
        'Ice': 135,
        'Alaska Fresh Milk': 63.75,
        'Alaska Evaporada': 15,
        'Electricity & Gas': 1,
        'Small cup 12oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Cinnamon Oat Latte',
      size: 'Large',
      lines: <String, double>{
        'Sang Tao 1': 20,
        'Water': 115,
        'Vinamilk Condensed': 28,
        'Ice': 180,
        'Oatside': 140,
        'Cinnamon': 0.2,
        'Electricity & Gas': 1,
        'Large cup 16oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Cinnamon Oat Latte',
      size: 'Small',
      lines: <String, double>{
        'Sang Tao 1': 15,
        'Water': 86.25,
        'Vinamilk Condensed': 21,
        'Ice': 135,
        'Oatside': 105,
        'Cinnamon': 0.15,
        'Electricity & Gas': 1,
        'Small cup 12oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Caramel Macchiato',
      size: 'Large',
      lines: <String, double>{
        'Sang Tao 1': 22,
        'Water': 130,
        'Vinamilk Condensed': 17,
        'Ice': 180,
        'Alaska Fresh Milk': 100,
        'Alaska Evaporada': 20,
        'Caramel Syrup': 16,
        'Caramel Sauce': 12,
        'Nestle All Purpose Cream': 10,
        'Sea Salt': 0.3,
        'Electricity & Gas': 1,
        'Large cup 16oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Caramel Macchiato',
      size: 'Small',
      lines: <String, double>{
        'Sang Tao 1': 16.5,
        'Water': 97.5,
        'Vinamilk Condensed': 12.75,
        'Ice': 135,
        'Alaska Fresh Milk': 75,
        'Alaska Evaporada': 15,
        'Caramel Syrup': 12,
        'Caramel Sauce': 9,
        'Nestle All Purpose Cream': 7.5,
        'Sea Salt': 0.225,
        'Electricity & Gas': 1,
        'Small cup 12oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Matcha Oat Latte',
      size: 'Large',
      lines: <String, double>{
        'Matcha': 4.4,
        'Water': 60,
        'Ice': 140,
        'Oatside': 176,
        'Vinamilk Condensed': 12,
        'Electricity & Gas': 1,
        'Large cup 16oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Matcha Oat Latte',
      size: 'Small',
      lines: <String, double>{
        'Matcha': 3.3,
        'Water': 45,
        'Ice': 105,
        'Oatside': 132,
        'Vinamilk Condensed': 9,
        'Electricity & Gas': 1,
        'Small cup 12oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Sea Salt Matcha Oat Latte',
      size: 'Large',
      lines: <String, double>{
        'Matcha': 4.4,
        'Water': 60,
        'Ice': 140,
        'Oatside': 176,
        'Vinamilk Condensed': 22,
        'Nestle All Purpose Cream': 20,
        'Alaska Fresh Milk': 30,
        'Sea Salt': 0.6,
        'Electricity & Gas': 1,
        'Large cup 16oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Sea Salt Matcha Oat Latte',
      size: 'Small',
      lines: <String, double>{
        'Matcha': 3.3,
        'Water': 45,
        'Ice': 105,
        'Oatside': 132,
        'Vinamilk Condensed': 16.5,
        'Nestle All Purpose Cream': 15,
        'Alaska Fresh Milk': 22.5,
        'Sea Salt': 0.45,
        'Electricity & Gas': 1,
        'Small cup 12oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Ca Phe Sua Da',
      size: 'Large',
      lines: <String, double>{
        'Sang Tao 1': 33,
        'Water': 235,
        'Vinamilk Condensed': 48,
        'Ice': 180,
        'Electricity & Gas': 1,
        'Large cup 16oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Ca Phe Sua Da',
      size: 'Small',
      lines: <String, double>{
        'Sang Tao 1': 24.75,
        'Water': 176.25,
        'Vinamilk Condensed': 36,
        'Ice': 135,
        'Electricity & Gas': 1,
        'Small cup 12oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Ca Phe Muoi',
      size: 'Large',
      lines: <String, double>{
        'Sang Tao 1': 22,
        'Water': 170,
        'Vinamilk Condensed': 44.5,
        'Ice': 180,
        'Nestle All Purpose Cream': 25,
        'Alaska Fresh Milk': 37.5,
        'Sea Salt': 0.75,
        'Electricity & Gas': 1,
        'Large cup 16oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Ca Phe Muoi',
      size: 'Small',
      lines: <String, double>{
        'Sang Tao 1': 16.5,
        'Water': 127.5,
        'Vinamilk Condensed': 33.375,
        'Ice': 135,
        'Nestle All Purpose Cream': 18.75,
        'Alaska Fresh Milk': 28.125,
        'Sea Salt': 0.5625,
        'Electricity & Gas': 1,
        'Small cup 12oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Ca Phe Trung',
      size: 'Large',
      lines: <String, double>{
        'Sang Tao 1': 22,
        'Water': 170,
        'Vinamilk Condensed': 56,
        'Ice': 180,
        'Egg': 2,
        'Electricity & Gas': 1,
        'Large cup 16oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
    PantryRecipe(
      drink: 'Ca Phe Trung',
      size: 'Small',
      lines: <String, double>{
        'Sang Tao 1': 16.5,
        'Water': 127.5,
        'Vinamilk Condensed': 42,
        'Ice': 135,
        'Egg': 1.5,
        'Electricity & Gas': 1,
        'Small cup 12oz': 1,
        'Paper Cover': 1,
        'Straw': 1,
      },
    ),
  ];
}

/// One thing she buys.
@immutable
class PantryItem {
  const PantryItem({
    required this.name,
    required this.unit,
    required this.buyBy,
    required this.perPurchase,
    required this.pricePerPurchase,
    this.category,
    this.tracked = true,
    this.reorderAt = 0,
    this.panicAt = 0,
    this.onHand = 0,
  });

  final String name;

  /// Her own heading — Packaging, Coffee, Milk, Syrup. Null where she left it
  /// blank or typed something that is not one.
  final String? category;

  /// Grams, millilitres or pieces: how the recipes measure it.
  final BaseUnit unit;

  /// What she buys it by: a pack, a carton, a piece.
  final String buyBy;

  /// How many [unit] are in one [buyBy] — a 1 kg bag of beans is 1000.
  final double perPurchase;

  /// Centavos for one [buyBy].
  final int pricePerPurchase;

  /// False for the things she does not count down — ice, water, the gas.
  final bool tracked;

  /// Her reorder and panic levels, in [unit].
  final double reorderAt;
  final double panicAt;

  /// What she had on the day she wrote the sheet.
  final double onHand;
}

/// One drink at one size, and what goes into it.
@immutable
class PantryRecipe {
  const PantryRecipe({
    required this.drink,
    required this.size,
    required this.lines,
  });

  final String drink;
  final String size;

  /// Ingredient name → how much of it, in that ingredient's own unit.
  final Map<String, double> lines;
}
