import '../../../core/money/money.dart';
import '../../../domain/entities/menu.dart';

/// The menu exactly as the owner supplied it in the setup worksheet.
///
/// **Every price here is provisional.** Her sheet says, against each drink:
/// *"prices and cost are not decided yet, I've put tentative price, make it
/// customizable."* They are seeded so the POS has something real to work with
/// on day one, the app flags them as unconfirmed, and every one of them is
/// editable in Menu → Drinks without a code change.
///
/// Nothing in this file was invented. Anything she left blank is left blank
/// here too, and listed in `unpricedOptions` so the app can show what still
/// needs a number.
abstract final class MenuSeed {
  static const String classics = 'Classics';
  static const String specialty = 'Specialty Coffee';

  static const List<SeedSize> sizes = <SeedSize>[
    SeedSize(code: 'small', name: 'Small', volumeOz: 12),
    SeedSize(code: 'grande', name: 'Grande', volumeOz: 16),
  ];

  /// Q1 of the worksheet was answered **B — two sizes on everything**.
  /// The default size is the one printed on her menu card.
  static const List<SeedProduct> products = <SeedProduct>[
    SeedProduct(
      category: classics,
      name: 'Black',
      description: 'Phin-brewed coffee served black. Bold, smooth and clean.',
      smallPrice: 12900,
      grandePrice: 13900,
      defaultSizeCode: 'grande',
      showsMilk: false,
    ),
    SeedProduct(
      category: classics,
      name: 'Spanish Latte',
      description:
          'Bold phin coffee with creamy milk and a touch of sweetness.',
      smallPrice: 12900,
      grandePrice: 13900,
      defaultSizeCode: 'grande',
    ),
    SeedProduct(
      category: classics,
      name: 'Caramel Macchiato with Cold Foam',
      description:
          'Smooth milk, vanilla and caramel with our signature cold foam.',
      smallPrice: 12900,
      grandePrice: 13900,
      defaultSizeCode: 'grande',
    ),
    SeedProduct(
      category: classics,
      name: 'Matcha Latte',
      description:
          'Vibrant matcha with creamy milk. Smooth, earthy and lightly sweet.',
      smallPrice: 12900,
      grandePrice: 13900,
      defaultSizeCode: 'grande',
    ),
    SeedProduct(
      category: specialty,
      name: 'Vietnamese Coffee',
      description:
          'Traditional phin coffee with sweetened condensed milk. '
          'Strong, bold and comforting.',
      smallPrice: 12900,
      grandePrice: 13900,
      // The card prints this one at 12 oz, unlike every other drink.
      defaultSizeCode: 'small',
      showsMilk: false,
    ),
    SeedProduct(
      category: specialty,
      name: 'Vietnamese Sea Salt Cream',
      description:
          'Strong phin coffee with smooth sea salt cream. '
          'Rich, creamy and perfectly balanced.',
      smallPrice: 13900,
      grandePrice: 15900,
      defaultSizeCode: 'grande',
    ),
    SeedProduct(
      category: specialty,
      name: 'Vietnamese Egg Coffee',
      description:
          'Classic Hanoi-style egg coffee. '
          'Creamy, velvety and deliciously indulgent.',
      smallPrice: 13900,
      grandePrice: 15900,
      defaultSizeCode: 'grande',
    ),
  ];

  /// `proactive: false` means "offered, but do not walk me through it" — her
  /// sheet says *"not proactively asking"* against ice, sweetness, syrup,
  /// sauce and extras. Those groups fold behind one **More options** tap so the
  /// common order stays two taps.
  static const List<SeedGroup> groups = <SeedGroup>[
    SeedGroup(
      code: 'milk',
      name: 'Milk',
      selection: SelectionType.single,
      isRequired: true,
      isProactive: true,
      options: <SeedOption>[
        SeedOption(name: 'Full Cream', price: 0, isDefault: true),
        // "not available yet" — switched off, not deleted.
        SeedOption(name: 'Low Fat', price: 0, isActive: false),
        SeedOption(name: 'Skimmed', price: 0, isActive: false),
        SeedOption(name: 'Oat', price: 2000),
        SeedOption(name: 'Coconut', price: 0, isActive: false),
      ],
    ),
    SeedGroup(
      code: 'ice',
      name: 'Ice',
      selection: SelectionType.single,
      isRequired: false,
      isProactive: false,
      // "Show ice? No" on every drink, with a default of Regular: the group is
      // attached and its default applies, but she is never asked.
      isVisible: false,
      options: <SeedOption>[
        SeedOption(name: 'Regular', price: 0, isDefault: true),
        SeedOption(name: 'Less Ice', price: 0),
        SeedOption(name: 'Extra Ice', price: 0),
        SeedOption(name: 'No Ice', price: 0),
      ],
    ),
    SeedGroup(
      code: 'sweetness',
      name: 'Sweetness',
      selection: SelectionType.single,
      isRequired: false,
      isProactive: false,
      options: <SeedOption>[
        SeedOption(name: 'Regular', price: 0),
        SeedOption(name: 'Less Sweet', price: 0),
        SeedOption(name: 'No Sugar', price: 0),
        SeedOption(name: 'Extra Sweet', price: 0, needsPrice: true),
      ],
    ),
    SeedGroup(
      code: 'syrup',
      name: 'Syrup',
      selection: SelectionType.single,
      isRequired: false,
      isProactive: false,
      options: <SeedOption>[
        SeedOption(name: 'None', price: 0),
        SeedOption(name: 'Vanilla', price: 3000),
        SeedOption(name: 'Caramel', price: 3000),
        SeedOption(name: 'Hazelnut', price: 3000),
      ],
    ),
    SeedGroup(
      code: 'sauce',
      name: 'Sauce',
      selection: SelectionType.single,
      isRequired: false,
      isProactive: false,
      options: <SeedOption>[
        SeedOption(name: 'None', price: 0),
        SeedOption(name: 'Chocolate', price: 0, needsPrice: true),
        SeedOption(name: 'White Mocha', price: 0, needsPrice: true),
        SeedOption(name: 'Caramel', price: 0, needsPrice: true),
      ],
    ),
    SeedGroup(
      code: 'extras',
      name: 'Extras',
      selection: SelectionType.multi,
      isRequired: false,
      isProactive: false,
      options: <SeedOption>[
        // The only add-on price printed on the menu card.
        SeedOption(name: 'Sea Salt Cream', price: 2000),
        SeedOption(name: 'Extra Shot', price: 0, needsPrice: true),
        SeedOption(name: 'Extra Syrup', price: 0, needsPrice: true),
        SeedOption(name: 'Extra Sauce', price: 0, needsPrice: true),
        SeedOption(name: 'Cold Foam', price: 2000),
      ],
    ),
  ];

  /// Choices she left without a number, for the app to surface rather than
  /// quietly charge ₱0 forever.
  static List<String> get unpricedOptions => <String>[
    for (final SeedGroup g in groups)
      for (final SeedOption o in g.options)
        if (o.needsPrice) '${g.name} · ${o.name}',
  ];
}

class SeedSize {
  const SeedSize({
    required this.code,
    required this.name,
    required this.volumeOz,
  });

  final String code;
  final String name;
  final double volumeOz;
}

class SeedProduct {
  const SeedProduct({
    required this.category,
    required this.name,
    required this.description,
    required this.smallPrice,
    required this.grandePrice,
    required this.defaultSizeCode,
    this.showsMilk = true,
  });

  final String category;
  final String name;
  final String description;

  /// Provisional, in centavos.
  final int smallPrice;
  final int grandePrice;

  final String defaultSizeCode;

  /// Black and Vietnamese Coffee are not made with a milk choice, so the group
  /// is simply not attached to them.
  final bool showsMilk;

  Money get small => Money(smallPrice);
  Money get grande => Money(grandePrice);
}

class SeedGroup {
  const SeedGroup({
    required this.code,
    required this.name,
    required this.selection,
    required this.isRequired,
    required this.isProactive,
    required this.options,
    this.isVisible = true,
  });

  final String code;
  final String name;
  final SelectionType selection;
  final bool isRequired;
  final bool isProactive;
  final bool isVisible;
  final List<SeedOption> options;
}

class SeedOption {
  const SeedOption({
    required this.name,
    required this.price,
    this.isDefault = false,
    this.isActive = true,
    this.needsPrice = false,
  });

  final String name;

  /// Centavos. Zero is a real answer — free — and is distinct from
  /// [needsPrice], which means she has not told us yet.
  final int price;

  final bool isDefault;
  final bool isActive;
  final bool needsPrice;
}
