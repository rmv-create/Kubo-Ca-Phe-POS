import 'dart:io';

import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;

import '../../core/money/money.dart';
import '../../domain/entities/customer.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/purchasing.dart';
import '../../domain/entities/reporting.dart';
import '../../domain/repositories/customer_repository.dart';
import '../../domain/repositories/inventory_repository.dart';
import '../../domain/repositories/purchasing_repository.dart';
import '../../domain/services/reporting_service.dart';

/// Turns what SQLite already knows into spreadsheets she can open.
///
/// Excel is an export, never the database. Every sheet is a formatted report
/// with headers, real dates and peso amounts — not a dump of table rows.
class ExcelExportService {
  const ExcelExportService({
    required this.directory,
    required ReportingService reporting,
    required InventoryRepository inventory,
    required PurchasingRepository purchasing,
    required CustomerRepository customers,
  }) : _reporting = reporting,
       _inventory = inventory,
       _purchasing = purchasing,
       _customers = customers;

  final Directory directory;
  final ReportingService _reporting;
  final InventoryRepository _inventory;
  final PurchasingRepository _purchasing;
  final CustomerRepository _customers;

  /// Everything, as one workbook per report.
  /// Everything, in one workbook.
  ///
  /// One file rather than eight: a browser can only hand over one file at a
  /// time without asking eight times, and a person opening this in Google
  /// Sheets would rather tab between sheets than between downloads.
  ///
  /// Returns the bytes, not a file. Where those bytes end up — a folder on
  /// a phone, the share sheet in a browser — is the caller's business, and
  /// in a browser there is no folder at all.
  Future<ExcelBook> everything({String? businessDate, String? month}) async {
    final String day = businessDate ?? _reporting.today;
    final String period = month ?? _reporting.thisMonth;

    final Excel book = Excel.createExcel();
    await _fillDailySales(book, day);
    await _fillMonthlySales(book, period);
    await _fillProductProfitability(book, month: period);
    await _fillInventory(book);
    await _fillWaste(book);
    await _fillCustomers(book);
    await _fillPurchases(book);
    await _fillSuppliers(book);

    final List<int>? bytes = book.encode();
    if (bytes == null) {
      throw StateError('The spreadsheet could not be written.');
    }
    return ExcelBook(name: 'Kubo $period.xlsx', bytes: bytes);
  }

  /// The same workbook, written into a folder. Phones only.
  Future<File> exportAll({String? businessDate, String? month}) async {
    final ExcelBook made = await everything(
      businessDate: businessDate,
      month: month,
    );
    await directory.create(recursive: true);
    final File file = File(p.join(directory.path, made.name));
    await file.writeAsBytes(made.bytes, flush: true);
    return file;
  }


  // ── one sheet at a time, each in its own workbook ──
  //
  // Kept because each is separately useful and separately tested: a test
  // that opens one workbook and reads one sheet is worth more than one
  // that opens a workbook of eight.

  Future<File> exportDailySales(String businessDate) async {
    final Excel book = Excel.createExcel();
    await _fillDailySales(book, businessDate);
    return _save(book, 'Daily Sales $businessDate');
  }

  Future<File> exportMonthlySales(String month) async {
    final Excel book = Excel.createExcel();
    await _fillMonthlySales(book, month);
    return _save(book, 'Monthly Sales $month');
  }

  Future<File> exportProductProfitability({required String month}) async {
    final Excel book = Excel.createExcel();
    await _fillProductProfitability(book, month: month);
    return _save(book, 'Product Profitability $month');
  }

  Future<File> exportInventory() async {
    final Excel book = Excel.createExcel();
    await _fillInventory(book);
    return _save(book, 'Inventory ${_reporting.today}');
  }

  Future<File> exportWaste() async {
    final Excel book = Excel.createExcel();
    await _fillWaste(book);
    return _save(book, 'Waste ${_reporting.today}');
  }

  Future<File> exportCustomers() async {
    final Excel book = Excel.createExcel();
    await _fillCustomers(book);
    return _save(book, 'Customers ${_reporting.today}');
  }

  Future<File> exportPurchases() async {
    final Excel book = Excel.createExcel();
    await _fillPurchases(book);
    return _save(book, 'Purchases ${_reporting.today}');
  }

  Future<File> exportSuppliers() async {
    final Excel book = Excel.createExcel();
    await _fillSuppliers(book);
    return _save(book, 'Suppliers ${_reporting.today}');
  }

  Future<void> _fillDailySales(Excel book, String businessDate) async {
    final SalesSummary summary = await _reporting.forDay(businessDate);
    final List<ProductPerformance> products = await _reporting
        .productPerformance(businessDate: businessDate);

    final Sheet sheet = _sheet(book, 'Daily Sales');
    _title(sheet, 'DAILY SALES', businessDate);
    _summaryBlock(sheet, summary, startRow: 3);

    int row = 14;
    _header(sheet, row++, <String>[
      'Drink',
      'Size',
      'Sold',
      'Revenue',
      'Cost',
      'Gross profit',
      'Margin',
    ]);
    for (final ProductPerformance p in products) {
      _row(sheet, row++, <CellValue?>[
        TextCellValue(p.productName),
        TextCellValue(p.sizeName),
        IntCellValue(p.unitsSold),
        _money(p.revenue),
        p.isCosted ? _money(p.cogs) : TextCellValue('not costed'),
        p.isCosted ? _money(p.grossProfit) : TextCellValue('—'),
        TextCellValue(p.marginLabel),
      ]);
    }
    _totalsRow(sheet, row, products);

  }

  Future<void> _fillMonthlySales(Excel book, String month) async {
    final SalesSummary summary = await _reporting.forMonth(month);
    final List<ProductPerformance> products = await _reporting
        .productPerformance(month: month);

    final Sheet sheet = _sheet(book, 'Monthly Sales');
    _title(sheet, 'MONTHLY SALES', month);
    _summaryBlock(sheet, summary, startRow: 3);

    _label(sheet, 12, 0, 'Average order value');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 12)).value =
        _money(summary.averageOrderValue);

    int row = 15;
    _header(sheet, row++, <String>[
      'Drink',
      'Size',
      'Sold',
      'Revenue',
      'Cost',
      'Gross profit',
      'Margin',
    ]);
    for (final ProductPerformance p in products) {
      _row(sheet, row++, <CellValue?>[
        TextCellValue(p.productName),
        TextCellValue(p.sizeName),
        IntCellValue(p.unitsSold),
        _money(p.revenue),
        p.isCosted ? _money(p.cogs) : TextCellValue('not costed'),
        p.isCosted ? _money(p.grossProfit) : TextCellValue('—'),
        TextCellValue(p.marginLabel),
      ]);
    }
    _totalsRow(sheet, row, products);

  }

  Future<void> _fillProductProfitability(Excel book, {required String month}) async {
    final List<ProductPerformance> bestSellers = await _reporting
        .productPerformance(month: month);
    final List<ProductPerformance> mostProfitable = await _reporting
        .mostProfitable(month: month);


    // Two sheets, because the drink that sells most and the drink that earns
    // most are usually not the same one.
    final Sheet sellers = _sheet(book, 'Best Sellers');
    _title(sellers, 'BEST SELLERS', month);
    _performanceTable(sellers, bestSellers, startRow: 3);

    final Sheet profit = book['Most Profitable'];
    _title(profit, 'MOST PROFITABLE', month);
    _performanceTable(profit, mostProfitable, startRow: 3);

  }

  Future<void> _fillInventory(Excel book) async {
    final List<Ingredient> ingredients = await _inventory.ingredients();
    final Sheet sheet = _sheet(book, 'Inventory');
    _title(sheet, 'INVENTORY', _reporting.today);

    int row = 3;
    _header(sheet, row++, <String>[
      'Ingredient',
      'Category',
      'On hand',
      'In purchase units',
      'Reorder at',
      'Critical at',
      'Status',
      'Cost per unit bought',
      'Tracked',
    ]);
    for (final Ingredient i in ingredients) {
      _row(sheet, row++, <CellValue?>[
        TextCellValue(i.name),
        TextCellValue(i.category ?? ''),
        TextCellValue(i.onHand?.format() ?? '—'),
        TextCellValue(i.onHandInPurchaseUnits ?? '—'),
        TextCellValue(i.reorderThreshold.format()),
        TextCellValue(i.criticalThreshold.format()),
        TextCellValue(i.status.label),
        i.purchasePrice == null
            ? TextCellValue('no price yet')
            : _money(i.purchasePrice!),
        TextCellValue(i.isInventoryTracked ? 'Yes' : 'No'),
      ]);
    }

    final Sheet movements = book['Movements'];
    _title(movements, 'STOCK MOVEMENTS', 'Most recent first');
    int m = 3;
    _header(movements, m++, <String>[
      'When',
      'Ingredient',
      'What happened',
      'Change',
      'Before',
      'After',
      'Value',
      'Reason',
    ]);
    for (final InventoryMovement mv in await _inventory.movements(limit: 500)) {
      _row(movements, m++, <CellValue?>[
        TextCellValue(_dateTime(mv.at)),
        TextCellValue(mv.ingredientName),
        TextCellValue(mv.type.label),
        TextCellValue(mv.delta.format()),
        TextCellValue(mv.before.format()),
        TextCellValue(mv.after.format()),
        _money(mv.value),
        TextCellValue(mv.reason ?? ''),
      ]);
    }

  }

  Future<void> _fillWaste(Excel book) async {
    final List<WasteEntry> entries = await _inventory.waste(limit: 500);
    final Sheet sheet = _sheet(book, 'Waste');
    _title(sheet, 'WASTE', 'Most recent first');

    int row = 3;
    _header(sheet, row++, <String>[
      'When',
      'Day',
      'Ingredient',
      'Amount',
      'Why',
      'Cost',
      'Notes',
    ]);
    int total = 0;
    for (final WasteEntry w in entries) {
      total += w.value.centavos;
      _row(sheet, row++, <CellValue?>[
        TextCellValue(_dateTime(w.at)),
        TextCellValue(w.businessDate),
        TextCellValue(w.ingredientName),
        TextCellValue(w.quantity.format()),
        TextCellValue(w.reason.label),
        _money(w.value),
        TextCellValue(w.notes ?? ''),
      ]);
    }
    _label(sheet, row + 1, 4, 'Total');
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row + 1))
        .value = _money(
      Money(total),
    );

  }

  Future<void> _fillCustomers(Excel book) async {
    final List<Customer> customers = await _customers.recent(limit: 1000);
    final Sheet sheet = _sheet(book, 'Customers');
    _title(sheet, 'CUSTOMERS', _reporting.today);

    int row = 3;
    _header(sheet, row++, <String>[
      'Name',
      'Mobile',
      'Visits',
      'Orders',
      'Drinks',
      'Total spend',
      'Average order',
      'Last visit',
      'Segment',
    ]);
    for (final Customer c in customers) {
      _row(sheet, row++, <CellValue?>[
        TextCellValue(c.name),
        TextCellValue(c.mobile ?? ''),
        IntCellValue(c.visitCount),
        IntCellValue(c.orderCount),
        IntCellValue(c.itemCount),
        _money(c.totalSpend),
        _money(c.averageOrderValue),
        TextCellValue(c.lastVisitAt == null ? '—' : _date(c.lastVisitAt!)),
        TextCellValue(c.storedSegment.label),
      ]);
    }

  }

  Future<void> _fillPurchases(Excel book) async {
    final List<Purchase> purchases = await _purchasing.purchases(limit: 500);
    final Sheet sheet = _sheet(book, 'Purchases');
    _title(sheet, 'PURCHASES', 'Most recent first');

    int row = 3;
    _header(sheet, row++, <String>[
      'When',
      'Supplier',
      'Ingredient',
      'Amount bought',
      'In base units',
      'Cost',
    ]);
    for (final Purchase purchase in purchases) {
      for (final PurchaseLine line in purchase.lines) {
        _row(sheet, row++, <CellValue?>[
          TextCellValue(_dateTime(purchase.purchasedAt)),
          TextCellValue(purchase.supplierName ?? '—'),
          TextCellValue(line.ingredientName),
          TextCellValue('${line.quantityInPurchaseUnits}'),
          TextCellValue(line.quantity.format()),
          _money(line.totalCost),
        ]);
      }
    }

  }

  Future<void> _fillSuppliers(Excel book) async {
    final List<Supplier> suppliers = await _purchasing.suppliers();
    final Sheet sheet = _sheet(book, 'Suppliers');
    _title(sheet, 'SUPPLIERS', _reporting.today);

    int row = 3;
    _header(sheet, row++, <String>[
      'Supplier',
      'Contact',
      'Phone / page',
      'Ingredients supplied',
      'Notes',
    ]);
    for (final Supplier s in suppliers) {
      _row(sheet, row++, <CellValue?>[
        TextCellValue(s.name),
        TextCellValue(s.contactPerson ?? ''),
        TextCellValue(s.contactDetails ?? ''),
        IntCellValue(s.ingredientCount),
        TextCellValue(s.notes ?? ''),
      ]);
    }

  }

  Future<File> exportDailyClosing(DailyClosing closing) async {
    final Excel book = Excel.createExcel();
    final Sheet sheet = _sheet(book, 'Daily Closing');
    _title(sheet, 'DAILY CLOSING', closing.businessDate);
    _label(sheet, 2, 0, 'Closed at');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 2)).value =
        TextCellValue(_dateTime(closing.closedAt));
    _summaryBlock(sheet, closing.summary, startRow: 4);
    return _save(book, 'Daily Closing ${closing.businessDate}');
  }

  // ─────────────────────────────── helpers ───────────────────────────────

  Sheet _sheet(Excel book, String name) {
    if (book.sheets.containsKey(name)) return book[name];

    // A new workbook comes with one empty default sheet. The first report
    // takes it over, so no empty "Sheet1" is left beside the real ones.
    // Every report after that gets a sheet of its own — renaming the first
    // sheet each time, which is what this used to do, quietly renamed the
    // report written just before it and lost all but the last three.
    final String first = book.sheets.keys.first;
    if (book.sheets.length == 1 && book.sheets[first]!.rows.isEmpty) {
      book.rename(first, name);
    }
    return book[name];
  }

  void _title(Sheet sheet, String title, String subtitle) {
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
      ..value = TextCellValue(title)
      ..cellStyle = CellStyle(bold: true, fontSize: 14);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 1)).value =
        TextCellValue(subtitle);
  }

  void _header(Sheet sheet, int row, List<String> labels) {
    for (int i = 0; i < labels.length; i++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: row))
        ..value = TextCellValue(labels[i])
        ..cellStyle = CellStyle(bold: true);
    }
  }

  void _row(Sheet sheet, int row, List<CellValue?> values) {
    for (int i = 0; i < values.length; i++) {
      final Data cell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: i, rowIndex: row),
      );
      cell.value = values[i];
      if (values[i] is DoubleCellValue) cell.cellStyle = _moneyStyle;
    }
  }

  void _label(Sheet sheet, int row, int column, String text) {
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: column, rowIndex: row))
      ..value = TextCellValue(text)
      ..cellStyle = CellStyle(bold: true);
  }

  void _summaryBlock(Sheet sheet, SalesSummary s, {required int startRow}) {
    final List<(String, CellValue)> rows = <(String, CellValue)>[
      ('Orders', IntCellValue(s.orderCount)),
      ('Drinks', IntCellValue(s.drinkCount)),
      ('Revenue', _money(s.revenue)),
      for (final MapEntry<String, Money> m in s.byMethod.entries)
        (_methodName(m.key), _money(m.value)),
      ('Cost of goods sold', _money(s.cogs)),
      ('Gross profit', _money(s.grossProfit)),
      ('Gross margin', TextCellValue(s.marginLabel)),
      ('Waste', _money(s.waste)),
      ('Refunds', _money(s.refunds)),
      ('Voids', _money(s.voids)),
    ];
    for (int i = 0; i < rows.length; i++) {
      _label(sheet, startRow + i, 0, rows[i].$1);
      final Data cell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: startRow + i),
      );
      cell.value = rows[i].$2;
      if (rows[i].$2 is DoubleCellValue) cell.cellStyle = _moneyStyle;
    }
    if (s.uncostedOrders > 0) {
      sheet
          .cell(
            CellIndex.indexByColumnRow(
              columnIndex: 0,
              rowIndex: startRow + rows.length,
            ),
          )
          .value = TextCellValue(
        '${s.uncostedOrders} order${s.uncostedOrders == 1 ? '' : 's'} '
        'could not be costed, so gross profit is understated. '
        'Add the missing recipes and ingredient prices.',
      );
    }
  }

  void _performanceTable(
    Sheet sheet,
    List<ProductPerformance> products, {
    required int startRow,
  }) {
    int row = startRow;
    _header(sheet, row++, <String>[
      'Drink',
      'Size',
      'Sold',
      'Revenue',
      'Cost',
      'Gross profit',
      'Margin',
    ]);
    for (final ProductPerformance p in products) {
      _row(sheet, row++, <CellValue?>[
        TextCellValue(p.productName),
        TextCellValue(p.sizeName),
        IntCellValue(p.unitsSold),
        _money(p.revenue),
        p.isCosted ? _money(p.cogs) : TextCellValue('not costed'),
        p.isCosted ? _money(p.grossProfit) : TextCellValue('—'),
        TextCellValue(p.marginLabel),
      ]);
    }
    _totalsRow(sheet, row, products);
  }

  void _totalsRow(Sheet sheet, int row, List<ProductPerformance> products) {
    if (products.isEmpty) return;
    int units = 0;
    int revenue = 0;
    int cogs = 0;
    bool allCosted = true;
    for (final ProductPerformance p in products) {
      units += p.unitsSold;
      revenue += p.revenue.centavos;
      if (p.isCosted) {
        cogs += p.cogs.centavos;
      } else {
        allCosted = false;
      }
    }
    _label(sheet, row + 1, 0, 'Total');
    _row(sheet, row + 1, <CellValue?>[
      TextCellValue('Total'),
      null,
      IntCellValue(units),
      _money(Money(revenue)),
      allCosted ? _money(Money(cogs)) : TextCellValue('partial'),
      allCosted ? _money(Money(revenue - cogs)) : TextCellValue('—'),
      null,
    ]);
  }

  /// A peso amount as a real number, so the column adds up rather than being
  /// text. The ₱ and the two decimals come from the cell's number format.
  CellValue _money(Money amount) => DoubleCellValue(amount.toDoubleForExport());

  /// The Philippine Peso format applied to every money cell.
  static final CellStyle _moneyStyle = CellStyle(
    numberFormat: const CustomNumericNumFormat(formatCode: r'"₱"#,##0.00'),
  );

  static String _date(DateTime moment) {
    final DateTime local = moment.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)}';
  }

  static String _dateTime(DateTime moment) {
    final DateTime local = moment.toLocal();
    return '${_date(moment)} ${_two(local.hour)}:${_two(local.minute)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  Future<File> _save(Excel book, String name) async {
    await directory.create(recursive: true);
    final String safe = name.replaceAll(RegExp(r'[^A-Za-z0-9 _.-]'), '');
    final File file = File(p.join(directory.path, '$safe.xlsx'));
    final List<int>? bytes = book.encode();
    if (bytes == null) {
      throw StateError('The spreadsheet could not be written.');
    }
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}


/// The codes payments carry, in the words on the buttons.
String _methodName(String code) => switch (code) {
  'cash' => 'Cash',
  'gcash' => 'GCash',
  'maya' => 'Maya',
  'maribank' => 'MariBank',
  'bpi' => 'BPI',
  _ => code,
};


/// A workbook, as bytes, with the name it should be saved under.
class ExcelBook {
  const ExcelBook({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;
}
