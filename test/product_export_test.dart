import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermart_pos/models.dart';
import 'package:supermart_pos/services/product_export.dart';

// Main categories (parent_id null) and subcategories (parent_id set), as the
// Settings screen stores them. A product's category_id points at its subcategory.
final _categories = <Map<String, dynamic>>[
  {'id': 'c-gen', 'name': 'General Items', 'parent_id': null},
  {'id': 'c-bis', 'name': 'Biscuits', 'parent_id': null},
  {'id': 'c-milk', 'name': 'Milk', 'parent_id': null},
  {'id': 'c-cos', 'name': 'Cosmetics', 'parent_id': null},
  {'id': 'c-misc', 'name': 'Misc', 'parent_id': null},
];
final _subcategories = <Map<String, dynamic>>[
  {'id': 's-cra', 'name': 'Cracker', 'parent_id': 'c-gen'},
  {'id': 's-inn', 'name': 'Innovative', 'parent_id': 'c-bis'},
  {'id': 's-bis', 'name': 'Bisconni', 'parent_id': 'c-bis'},
  {'id': 's-nes', 'name': 'Nestle', 'parent_id': 'c-milk'},
  {'id': 's-4me', 'name': '4ME Moisturizing Cream', 'parent_id': 'c-cos'},
  {'id': 's-tea', 'name': 'Tea, Milk', 'parent_id': 'c-misc'},
];

AdminProduct _p({
  required String name,
  String? categoryId,
  String unit = 'pcs',
  double sale = 100,
  double cost = 80,
  double stock = 10,
  String barcode = '',
  String sku = '',
  String created = '2026-01-01T09:00:00',
}) =>
    AdminProduct({
      'id': name,
      'name': name,
      'category_id': categoryId,
      'unit': unit,
      'sale_price': sale,
      'cost_price': cost,
      'stock_qty': stock,
      'barcode': barcode,
      'sku': sku,
      'is_active': true,
      'created_at': created,
    });

List<List<Object>> _rows(Iterable<AdminProduct> products) =>
    productExportRows(products, categories: _categories, subcategories: _subcategories);

void main() {
  _sampleFromTheShop();
  _variantOnly();
  _spacingVariants();
  final products = [
    _p(name: 'Innovative Zeera Plus', categoryId: 's-inn', unit: 'pcs', sale: 120, cost: 95, stock: 40, barcode: '8964001', sku: 'INN-ZP', created: '2026-01-02T09:00:00'),
    _p(name: 'Bisconni Candi', categoryId: 's-bis', unit: 'pcs', sale: 60, cost: 45.5, stock: 12, barcode: '8964002', sku: 'BIS-CA', created: '2026-01-01T09:00:00'),
    _p(name: 'Loose Sugar', categoryId: 'c-gen', unit: 'kg', sale: 180, cost: 150, stock: 25.5, created: '2026-01-03T09:00:00'),
    _p(name: 'Nestle Full Cream', categoryId: 's-nes', unit: 'ltr', sale: 230, cost: 205, stock: 8, created: '2026-01-04T09:00:00'),
  ];

  test('the columns are exactly the shop\'s list, in order', () {
    expect(productExportColumns, [
      'CATEGORY', 'ITEM_TYPE', 'ITEM_NAME', 'VARIANT_NAME', 'PRICE', 'COST_PRICE', 'STOCK', 'BARCODE', 'SKU',
    ]);
  });

  test('rows are written in the order the products were created', () {
    final rows = _rows(products);
    expect([for (final r in rows) r[3]], ['Candi', 'Zeera Plus', 'Loose Sugar', 'Full Cream']);
    // the last row carries each value in its column
    expect(rows[3], ['Milk', 'ltr', 'Nestle', 'Full Cream', 230.0, 205.0, 8.0, '', '']);
  });

  test('CATEGORY is the main category, ITEM_NAME the subcategory, and a product filed directly under a main category has a blank ITEM_NAME', () {
    final rows = _rows(products);
    expect(rows[0], ['Biscuits', 'pcs', 'Bisconni', 'Candi', 60.0, 45.5, 12.0, '8964002', 'BIS-CA']);
    final general = rows.firstWhere((r) => r[0] == 'General Items');
    expect(general[2], '');
    expect(general[1], 'kg');
    expect(general[3], 'Loose Sugar');
    expect(general[6], 25.5);
  });

  test('the CSV has a byte-order mark, the header, and one line per product', () {
    final bytes = productExportCsv(_rows(products));
    expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF], reason: 'Excel needs the mark to read Urdu and other scripts');
    final text = utf8.decode(bytes);
    final lines = text.split('\r\n')..removeWhere((l) => l.isEmpty);
    expect(lines.first, 'CATEGORY,ITEM_TYPE,ITEM_NAME,VARIANT_NAME,PRICE,COST_PRICE,STOCK,BARCODE,SKU');
    expect(lines.length, 1 + products.length);
    expect(lines[1], 'Biscuits,pcs,Bisconni,Candi,60,45.5,12,8964002,BIS-CA');
  });

  test('a row comes out exactly like the shop\'s layout: 380 not 380.0, blanks left empty', () {
    final shop = [
      _p(name: '4ME Moisturizing Cream Goat Milk 200 Ml', categoryId: 's-4me', unit: 'Unit', sale: 380, cost: 280, stock: 0),
    ];
    final lines = utf8.decode(productExportCsv(_rows(shop))).split('\r\n');
    expect(lines[0], 'CATEGORY,ITEM_TYPE,ITEM_NAME,VARIANT_NAME,PRICE,COST_PRICE,STOCK,BARCODE,SKU');
    expect(lines[1], 'Cosmetics,Unit,4ME Moisturizing Cream,Goat Milk 200 Ml,380,280,0,,');
  });

  test('CSV cells cannot run as spreadsheet formulas or break the row', () {
    final tricky = [
      _p(name: '=HYPERLINK("http://x")', categoryId: 's-tea'),
    ];
    final text = utf8.decode(productExportCsv(_rows(tricky)));
    expect(text, contains('"\'=HYPERLINK(""http://x"")"'));
    expect(text, contains('"Tea, Milk"'));
  });

  test('the Excel file opens with the Products sheet, a header and numbers stored as numbers', () {
    final bytes = productExportExcel(_rows(products));
    final book = Excel.decodeBytes(bytes);
    expect(book.tables.keys, contains('Products'));
    final sheet = book.tables['Products']!;

    String text(int r, int c) => (sheet.rows[r][c]!.value as TextCellValue).value.toString();

    expect([for (var c = 0; c < productExportColumns.length; c++) text(0, c)], productExportColumns);
    // data row 1 is Candi
    expect(text(1, 3), 'Candi');
    expect(text(1, 2), 'Bisconni');
    expect(text(1, 0), 'Biscuits');
    // whole amounts come back as integer cells, fractions as decimal cells; both are numbers
    double number(int r, int c) {
      final v = sheet.rows[r][c]!.value;
      return switch (v) {
        IntCellValue() => v.value.toDouble(),
        DoubleCellValue() => v.value,
        _ => throw StateError('cell $r,$c is not a number: $v'),
      };
    }

    expect(number(1, 4), 60.0); // PRICE
    expect(number(1, 5), 45.5); // COST_PRICE
    expect(number(1, 6), 12.0); // STOCK
  });
}

void _sampleFromTheShop() {
  test('the two Cracker rows come out exactly as the shop wrote them, in entry order', () {
    final shop = [
      _p(name: 'Cracker Krela Papir', categoryId: 's-cra', unit: 'Unit', sale: 300, cost: 200, stock: 0, created: '2026-02-01T10:00:00'),
      _p(name: 'Cracker Gandiri Papir', categoryId: 's-cra', unit: 'Unit', sale: 300, cost: 200, stock: 0, created: '2026-02-01T10:05:00'),
    ];
    final lines = utf8.decode(productExportCsv(_rows(shop))).split('\r\n');
    expect(lines[1], 'General Items,Unit,Cracker,Krela Papir,300,200,0,,');
    expect(lines[2], 'General Items,Unit,Cracker,Gandiri Papir,300,200,0,,');
  });
}

void _variantOnly() {
  test('the variant is the detail alone, without the subcategory and main category in front', () {
    final aloe = _p(name: '4ME Moisturizing Cream Aloe Vara', categoryId: 's-4me', unit: 'Unit', sale: 380, cost: 280, stock: 59);
    final honey = _p(name: '4ME Moisturizing Cream - Honey Almond', categoryId: 's-4me', unit: 'Unit', sale: 380, cost: 280, stock: 0);
    final plain = _p(name: 'Goat Milk 200 Ml', categoryId: 's-nes', unit: 'ltr', sale: 1, cost: 1);
    expect(productVariantName(aloe, '4ME Moisturizing Cream'), 'Aloe Vara');
    expect(productVariantName(honey, '4ME Moisturizing Cream'), 'Honey Almond');
    expect(productVariantName(plain, 'Nestle'), 'Goat Milk 200 Ml');
    final lines = utf8.decode(productExportCsv(_rows([aloe]))).split('\r\n');
    expect(lines[1], 'Cosmetics,Unit,4ME Moisturizing Cream,Aloe Vara,380,280,59,,');
  });
}

void _spacingVariants() {
  test('a double space or a non-breaking space in the name still removes the subcategory', () {
    final dbl = _p(name: '4ME  Moisturizing Cream Aloe Vara', categoryId: 's-4me', sale: 380, cost: 280, stock: 59);
    final nbsp = _p(name: '4ME Moisturizing Cream Honey Almond', categoryId: 's-4me', sale: 380, cost: 280, stock: 0);
    final lower = _p(name: '4me moisturizing cream Aloe Vara', categoryId: 's-4me', sale: 380, cost: 280, stock: 1);
    expect(productVariantName(dbl, '4ME Moisturizing Cream'), 'Aloe Vara');
    expect(productVariantName(nbsp, '4ME Moisturizing Cream'), 'Honey Almond');
    expect(productVariantName(lower, '4ME Moisturizing Cream'), 'Aloe Vara');
  });
}
