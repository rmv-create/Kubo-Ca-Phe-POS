import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/data/export/excel_export_service.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late Directory outDir;
  late ExcelExportService export;

  setUp(() async {
    shop = await PosFixture.open();
    outDir = await Directory.systemTemp.createTemp('kubo_export_test');
    export = ExcelExportService(
      directory: outDir,
      reporting: shop.reports,
      inventory: shop.stock,
      purchasing: shop.purchasing,
      customers: shop.customers,
    );

    // SAMPLE data, enough to make every report non-empty.
    final Ingredient beans = await shop.addIngredient(
      'Coffee beans',
      price: Money.of(1200),
      openingStock: 5000,
    );
    await shop.setRecipe('Black', 'Grande', <Ingredient, double>{beans: 20});

    final int mariaId = await shop.customers.create(
      name: 'Maria Santos',
      mobile: '0917 555 4521',
    );
    await shop.sell(
      OrderDraft(
        customer: (await shop.customers.byId(mariaId))!,
        items: <DraftItem>[await shop.item('Black', 'Grande', quantity: 2)],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await shop.stock.recordWaste(
      ingredientId: beans.id,
      quantity: Quantity.fromBase(50, BaseUnit.gram),
      reason: WasteReason.spill,
    );
  });

  tearDown(() async {
    await shop.close();
    if (outDir.existsSync()) await outDir.delete(recursive: true);
  });

  test('writes every report as a real .xlsx file', () async {
    final List<File> files = await export.exportAll();

    expect(files.length, 8);
    for (final File file in files) {
      expect(file.existsSync(), isTrue, reason: file.path);
      expect(file.path, endsWith('.xlsx'));
      expect(
        await file.length(),
        greaterThan(1000),
        reason: '${file.path} looks empty',
      );
      // It has to actually open as a workbook, not merely exist.
      final Excel reopened = Excel.decodeBytes(await file.readAsBytes());
      expect(reopened.sheets, isNotEmpty);
    }
  });

  test('the daily sales sheet carries the real figures', () async {
    final File file = await export.exportDailySales(shop.reports.today);
    final Excel book = Excel.decodeBytes(await file.readAsBytes());
    final Sheet sheet = book['Daily Sales'];

    final List<String> text = <String>[
      for (final List<Data?> row in sheet.rows)
        for (final Data? cell in row)
          if (cell?.value != null) cell!.value.toString(),
    ];

    expect(text, contains('DAILY SALES'));
    expect(text, contains('Revenue'));
    expect(text, contains('Gross profit'));
    expect(text, contains('Black'));
    // 2 x ₱139.00 revenue, 2 x ₱24.00 cost. Excel normalises a whole-peso
    // amount back to an integer on decode, so both forms are accepted.
    expect(text.any((String v) => v == '278' || v == '278.0'), isTrue);
    expect(text.any((String v) => v == '48' || v == '48.0'), isTrue);
  });

  test('money is a number in pesos, not text', () async {
    final File file = await export.exportDailySales(shop.reports.today);
    final Excel book = Excel.decodeBytes(await file.readAsBytes());
    final Sheet sheet = book['Daily Sales'];

    bool numericMoney = false;
    bool pesoFormatted = false;
    for (final List<Data?> row in sheet.rows) {
      for (final Data? cell in row) {
        final CellValue? value = cell?.value;
        if (value is DoubleCellValue || value is IntCellValue) {
          numericMoney = true;
          if (cell!.cellStyle?.numberFormat.toString().contains('₱') ?? false) {
            pesoFormatted = true;
          }
        }
      }
    }
    expect(
      numericMoney,
      isTrue,
      reason: 'amounts written as text cannot be summed in a spreadsheet',
    );
    expect(
      pesoFormatted,
      isTrue,
      reason: 'and they have to read as pesos, not bare numbers',
    );
  });

  test('the inventory export has both stock and its movements', () async {
    final File file = await export.exportInventory();
    final Excel book = Excel.decodeBytes(await file.readAsBytes());
    expect(book.sheets.keys, containsAll(<String>['Inventory', 'Movements']));

    final List<String> movementText = <String>[
      for (final List<Data?> row in book['Movements'].rows)
        for (final Data? cell in row)
          if (cell?.value != null) cell!.value.toString(),
    ];
    expect(movementText, contains('Coffee beans'));
    expect(movementText, contains('Sold'));
    expect(movementText, contains('Wasted'));
  });

  test('best sellers and most profitable are separate sheets', () async {
    final File file = await export.exportProductProfitability(
      month: shop.reports.thisMonth,
    );
    final Excel book = Excel.decodeBytes(await file.readAsBytes());
    expect(
      book.sheets.keys,
      containsAll(<String>['Best Sellers', 'Most Profitable']),
    );
  });

  test('the customer export lists real history', () async {
    final File file = await export.exportCustomers();
    final Excel book = Excel.decodeBytes(await file.readAsBytes());
    final List<String> text = <String>[
      for (final List<Data?> row in book['Customers'].rows)
        for (final Data? cell in row)
          if (cell?.value != null) cell!.value.toString(),
    ];
    expect(text, contains('Maria Santos'));
    expect(text, contains('0917 555 4521'));
    expect(text, contains('Total spend'));
  });

  test('an empty period still produces a readable sheet', () async {
    final File file = await export.exportDailySales('2020-01-01');
    expect(file.existsSync(), isTrue);
    final Excel book = Excel.decodeBytes(await file.readAsBytes());
    final List<String> text = <String>[
      for (final List<Data?> row in book['Daily Sales'].rows)
        for (final Data? cell in row)
          if (cell?.value != null) cell!.value.toString(),
    ];
    expect(text, contains('DAILY SALES'));
    expect(text, contains('2020-01-01'));
  });
}
