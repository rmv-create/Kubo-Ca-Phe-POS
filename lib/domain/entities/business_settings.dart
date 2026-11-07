import 'package:meta/meta.dart';

/// How ingredient cost is resolved when an order is costed.
enum CostingMethod {
  /// Use the most recent cost effective on or before the order.
  latestCost('latest_cost', 'Latest cost'),

  /// Use the weighted average of costs recorded to date.
  weightedAverage('weighted_average', 'Weighted average');

  const CostingMethod(this.code, this.label);

  final String code;
  final String label;

  static CostingMethod fromCode(String code) => CostingMethod.values.firstWhere(
    (CostingMethod m) => m.code == code,
    orElse: () => CostingMethod.latestCost,
  );
}

/// Everything the owner can configure about how the business runs.
///
/// Currency is fixed to Philippine Peso in V1 and is present here only so that
/// the rest of the app reads it from one place rather than hard-coding `₱`
/// across dozens of widgets.
@immutable
class BusinessSettings {
  const BusinessSettings({
    required this.businessName,
    required this.currencyCode,
    required this.currencySymbol,
    required this.businessDayCutoffHour,
    required this.costingMethod,
    required this.orderNumberPrefix,
    required this.backupRetentionCount,
    required this.autoBackupDaily,
    required this.discountsEnabled,
    required this.lowStockAlertsEnabled,
    required this.orderNumberResetDaily,
    required this.showCustomerName,
    required this.pricesProvisional,
    required this.vatRegistered,
    required this.vatRateBp,
    required this.statutoryDiscountRateBp,
    required this.deliveryFeeEnabled,
    required this.receiptThankYou,
    required this.receiptAddress,
    required this.receiptFacebook,
    required this.receiptInstagram,
    required this.receiptQrData,
    required this.receiptPhone,
  });

  /// Values used before the owner has configured anything. The business name
  /// is deliberately the app name, not an invented trading name.
  static const BusinessSettings defaults = BusinessSettings(
    businessName: 'Kubo Cà Phê',
    currencyCode: 'PHP',
    currencySymbol: '₱',
    businessDayCutoffHour: 4,
    costingMethod: CostingMethod.latestCost,
    orderNumberPrefix: '',
    backupRetentionCount: 14,
    autoBackupDaily: true,
    // V1 ships with discounts switched off; the POS shows no discount control.
    discountsEnabled: false,
    lowStockAlertsEnabled: true,
    // The owner numbers orders K-0001 onwards, continuously.
    orderNumberResetDaily: false,
    showCustomerName: true,
    pricesProvisional: false,
    // Off until the owner says otherwise. A shop below the ₱3M threshold is
    // not VAT-registered, and claiming VAT it never charged would misstate
    // both the receipt and every Senior Citizen discount computed from it.
    vatRegistered: false,
    vatRateBp: 1200,
    // Twenty per cent, set by RA 9994 and RA 10754. Configurable because a
    // statute can change; it is not a promotion the owner should tune.
    statutoryDiscountRateBp: 2000,
    // She delivers, so the fee is offered from the start rather than hidden
    // behind a switch she would have to go looking for.
    deliveryFeeEnabled: true,
    // Hers, smiley and all. The receipt font has no ☺, so the face is drawn
    // on the page instead of typeset — see ReceiptDocument.
    receiptThankYou: 'THANK YOU! ☺',
    // All four off the receipt she marked up herself.
    receiptAddress: 'Sandatahan St. San Isidro Mariveles, Bataan',
    receiptFacebook: 'Kubo Ca Phe',
    receiptInstagram: '@kubocaphe',
    receiptPhone: '+63 947 186 6367',
    // The link behind the QR she already uses on her menu card. The code is
    // drawn from this text at print time, so changing the link changes the
    // code and there is no image to re-upload.
    receiptQrData: 'https://www.facebook.com/profile.php?id=61595992611233',
  );

  final String businessName;
  final String currencyCode;
  final String currencySymbol;

  /// Local hour at which a new trading day begins (a 00:30 sale belongs to the
  /// previous day).
  final int businessDayCutoffHour;

  final CostingMethod costingMethod;
  final String orderNumberPrefix;
  final int backupRetentionCount;
  final bool autoBackupDaily;
  final bool discountsEnabled;
  final bool lowStockAlertsEnabled;

  /// Whether order numbers start again at 1 each trading day.
  final bool orderNumberResetDaily;

  /// Whether the customer's name is shown on the order screen.
  final bool showCustomerName;

  /// Set while the seeded menu still carries the owner's tentative prices.
  /// The app says so on screen rather than presenting guesses as final.
  final bool pricesProvisional;

  /// Whether the shop is registered for VAT.
  ///
  /// This changes real money. Menu prices are entered VAT-inclusive either
  /// way, but for a VAT-registered seller a Senior Citizen or PWD sale is
  /// *exempt* from VAT, so the twelve per cent comes out before the twenty per
  /// cent discount is applied. For a non-registered seller there is no VAT in
  /// the price to remove, and the discount is simply twenty per cent of what
  /// is on the menu.
  final bool vatRegistered;

  /// VAT rate in basis points — 1200 is 12%.
  final int vatRateBp;

  /// The statutory Senior Citizen / PWD discount, in basis points.
  final int statutoryDiscountRateBp;

  /// Whether the POS offers a delivery fee line on the order.
  final bool deliveryFeeEnabled;

  /// One short line of thanks at the foot of the receipt. Empty prints
  /// nothing rather than an empty gap.
  final String receiptThankYou;

  /// Where the shop is, as it should read on a receipt. Free text, because a
  /// Philippine address is not a form.
  final String receiptAddress;

  /// Facebook page and Instagram handle, printed as typed.
  final String receiptFacebook;
  final String receiptInstagram;

  /// The shop's own number, for a customer who needs to reach her about an
  /// order. Not the customer's — the receipt never carries that.
  final String receiptPhone;

  /// What the QR code on the receipt points at — her page, or a review link.
  /// Empty prints no code.
  final String receiptQrData;

  /// The VAT rate to actually apply. Zero unless the shop is registered.
  int get effectiveVatRateBp => vatRegistered ? vatRateBp : 0;

  BusinessSettings copyWith({
    String? businessName,
    int? businessDayCutoffHour,
    CostingMethod? costingMethod,
    String? orderNumberPrefix,
    int? backupRetentionCount,
    bool? autoBackupDaily,
    bool? discountsEnabled,
    bool? lowStockAlertsEnabled,
    bool? orderNumberResetDaily,
    bool? showCustomerName,
    bool? pricesProvisional,
    bool? vatRegistered,
    int? vatRateBp,
    int? statutoryDiscountRateBp,
    bool? deliveryFeeEnabled,
    String? receiptThankYou,
    String? receiptAddress,
    String? receiptFacebook,
    String? receiptInstagram,
    String? receiptQrData,
    String? receiptPhone,
  }) => BusinessSettings(
    businessName: businessName ?? this.businessName,
    currencyCode: currencyCode,
    currencySymbol: currencySymbol,
    businessDayCutoffHour: businessDayCutoffHour ?? this.businessDayCutoffHour,
    costingMethod: costingMethod ?? this.costingMethod,
    orderNumberPrefix: orderNumberPrefix ?? this.orderNumberPrefix,
    backupRetentionCount: backupRetentionCount ?? this.backupRetentionCount,
    autoBackupDaily: autoBackupDaily ?? this.autoBackupDaily,
    discountsEnabled: discountsEnabled ?? this.discountsEnabled,
    lowStockAlertsEnabled: lowStockAlertsEnabled ?? this.lowStockAlertsEnabled,
    orderNumberResetDaily: orderNumberResetDaily ?? this.orderNumberResetDaily,
    showCustomerName: showCustomerName ?? this.showCustomerName,
    pricesProvisional: pricesProvisional ?? this.pricesProvisional,
    vatRegistered: vatRegistered ?? this.vatRegistered,
    vatRateBp: vatRateBp ?? this.vatRateBp,
    statutoryDiscountRateBp:
        statutoryDiscountRateBp ?? this.statutoryDiscountRateBp,
    deliveryFeeEnabled: deliveryFeeEnabled ?? this.deliveryFeeEnabled,
    receiptThankYou: receiptThankYou ?? this.receiptThankYou,
    receiptAddress: receiptAddress ?? this.receiptAddress,
    receiptFacebook: receiptFacebook ?? this.receiptFacebook,
    receiptInstagram: receiptInstagram ?? this.receiptInstagram,
    receiptQrData: receiptQrData ?? this.receiptQrData,
    receiptPhone: receiptPhone ?? this.receiptPhone,
  );
}

/// Keys used in the `app_settings` table.
abstract final class SettingKeys {
  static const String businessName = 'business.name';
  static const String businessDayCutoffHour = 'business.day_cutoff_hour';
  static const String costingMethod = 'costing.method';
  static const String orderNumberPrefix = 'orders.number_prefix';
  static const String backupRetentionCount = 'backup.retention_count';
  static const String autoBackupDaily = 'backup.auto_daily';
  static const String lastAutoBackupDate = 'backup.last_auto_date';
  static const String discountsEnabled = 'features.discounts_enabled';
  static const String lowStockAlertsEnabled = 'features.low_stock_alerts';
  static const String orderNumberResetDaily = 'orders.number_reset_daily';
  static const String showCustomerName = 'pos.show_customer_name';
  static const String pricesProvisional = 'menu.prices_provisional';
  static const String menuSeeded = 'data.menu_seeded';

  /// Which edition of her setup worksheet the pantry was written from, so a
  /// corrected sheet can replace the recipes she has not edited herself.
  static const String pantrySeedVersion = 'data.pantry_seed_version';
  static const String vatRegistered = 'tax.vat_registered';
  static const String vatRateBp = 'tax.vat_rate_bp';
  static const String statutoryDiscountRateBp =
      'tax.statutory_discount_rate_bp';
  static const String deliveryFeeEnabled = 'pos.delivery_fee_enabled';

  /// A small image the owner uploads — a QR to her socials or a review link —
  /// printed at the foot of every receipt. Held as base64 PNG in the settings
  /// table rather than as a file, so it travels inside her backups.
  static const String receiptFooterImage = 'receipt.footer_image_png';

  static const String receiptThankYou = 'receipt.thank_you';
  static const String receiptAddress = 'receipt.address';
  static const String receiptFacebook = 'receipt.facebook';
  static const String receiptInstagram = 'receipt.instagram';
  static const String receiptQrData = 'receipt.qr_data';
  static const String receiptPhone = 'receipt.phone';
}
