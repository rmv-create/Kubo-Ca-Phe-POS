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
}
