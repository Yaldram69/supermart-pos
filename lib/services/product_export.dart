import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../models.dart';

/// The columns of the product list export, in order.
///
/// CATEGORY     the main category (General Items, Milk, Biscuits...)
/// ITEM_TYPE    the unit it is sold by (pcs, ltr, kg...)
/// ITEM_NAME    the subcategory (Bisconni, Innovative...)
/// VARIANT_NAME the rest of the product name after the subcategory (Candi, Zeera Plus...)
/// PRICE        the sale price
/// COST_PRICE   what the shop paid
/// STOCK        quantity on hand
/// BARCODE, SKU the codes
const productExportColumns = <String>[
  'CATEGORY',
  'ITEM_TYPE',
  'ITEM_NAME',
  'VARIANT_NAME',
  'PRICE',
  'COST_PRICE',
  'STOCK',
  'BARCODE',
  'SKU',
];

/// The main category and the subcategory a product sits in. A product's category_id
/// points at its subcategory, whose parent_id points at the main category. A product
/// filed directly under a main category has no subcategory, so its ITEM_NAME is blank.
({String main, String sub}) productCategoryLevels(AdminProduct p, Map<String, Map<String, dynamic>> byId) {
  String idOf(Object? value) => (value ?? '').toString().trim();
  String nameOf(Map<String, dynamic> row) => idOf(row['name']);

  final row = byId[idOf(p.raw['category_id'])];
  if (row == null) return (main: p.categoryName, sub: '');
  if (row['parent_id'] == null || idOf(row['parent_id']).isEmpty) {
    return (main: nameOf(row), sub: '');
  }
  final parent = byId[idOf(row['parent_id'])];
  return (main: parent == null ? '' : nameOf(parent), sub: nameOf(row));
}

/// One row per product, in the order the products were created (oldest first),
/// the way the shop entered them.
List<List<Object>> productExportRows(
  Iterable<AdminProduct> products, {
  List<Map<String, dynamic>> categories = const [],
  List<Map<String, dynamic>> subcategories = const [],
}) {
  final byId = <String, Map<String, dynamic>>{
    for (final row in [...categories, ...subcategories]) (row['id'] ?? '').toString().trim(): row,
  };

  // Products are written in the order they were created, oldest first, the way
  // the shop entered them. Ties keep their original order.
  final indexed = [for (var i = 0; i < products.length; i++) MapEntry(i, products.elementAt(i))];
  indexed.sort((a, b) {
    final byCreated = (a.value.raw['created_at'] ?? '').toString().compareTo((b.value.raw['created_at'] ?? '').toString());
    if (byCreated != 0) return byCreated;
    return a.key.compareTo(b.key);
  });
  final sorted = [for (final e in indexed) e.value];

  final rows = <List<Object>>[];
  for (final p in sorted) {
    final levels = productCategoryLevels(p, byId);
    rows.add(<Object>[
      levels.main,
      p.unit,
      levels.sub,
      productVariantName(p, levels.sub),
      p.salePrice,
      p.costPrice,
      p.stockQty,
      p.barcode,
      p.sku,
    ]);
  }
  return rows;
}

/// One CSV cell in the shop's layout: plain text unless it needs quoting
/// (a comma, a quote, a line break, or a leading = + - @ that a spreadsheet
/// would read as a formula). Whole numbers print without decimals (380, not
/// 380.0). A blank value is an empty cell.
String productCsvField(Object? value) {
  if (value == null) return '';
  if (value is num) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }
  final text = value.toString();
  if (text.isEmpty) return '';
  final needsFormulaGuard = '=+-@'.contains(text[0]);
  final safe = needsFormulaGuard ? "'$text" : text;
  final needsQuotes = safe.contains(RegExp(r'[,"\r\n]'));
  return needsQuotes ? '"${safe.replaceAll('"', '""')}"' : safe;
}

/// CSV text, opened by Excel, Sheets or any editor. Starts with a byte-order
/// mark so Excel reads Urdu and other non-Latin text correctly.
Uint8List productExportCsv(List<List<Object>> rows) {
  final buffer = StringBuffer()
    ..write('﻿')
    ..write(productExportColumns.join(','))
    ..write('\r\n');
  for (final row in rows) {
    buffer
      ..write(row.map(productCsvField).join(','))
      ..write('\r\n');
  }
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

/// A real Excel workbook (.xlsx) with one sheet: a plain column-name row, then one
/// row per product. Numbers are stored as numbers, and columns are sized to their contents.
Uint8List productExportExcel(List<List<Object>> rows) {
  final excel = Excel.createExcel();
  final sheetName = 'Products';
  excel.rename(excel.getDefaultSheet()!, sheetName);
  final sheet = excel[sheetName];

  for (var c = 0; c < productExportColumns.length; c++) {
    final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0));
    cell.value = TextCellValue(productExportColumns[c]);
  }

  for (final row in rows) {
    sheet.appendRow([
      for (final value in row)
        switch (value) {
          final num n when n == n.roundToDouble() => IntCellValue(n.toInt()),
          final num n => DoubleCellValue(n.toDouble()),
          _ when value.toString().isEmpty => null,
          _ => TextCellValue(value.toString()),
        },
    ]);
  }

  // wide enough for the longest value in each column, within reason
  for (var c = 0; c < productExportColumns.length; c++) {
    var width = productExportColumns[c].length;
    for (final row in rows) {
      final text = row[c] is num ? '${row[c]}' : row[c].toString();
      if (text.length > width) width = text.length;
    }
    sheet.setColumnWidth(c, (width.clamp(8, 40) + 2).toDouble());
  }

  final bytes = excel.encode();
  return Uint8List.fromList(bytes ?? const <int>[]);
}

/// The product detail alone (Honey Almond, Aloe Vara...). Shop names often
/// begin with the subcategory (ITEM_NAME), so when the name starts with it that
/// prefix is removed: "4ME Moisturizing Cream Aloe Vara" with subcategory
/// "4ME Moisturizing Cream" becomes "Aloe Vara". A name that does not start
/// with the subcategory is used as it is.
String productVariantName(AdminProduct p, String itemName) {
  // Compare word by word, ignoring extra spaces, non-breaking spaces and case,
  // so "4ME  Moisturizing Cream Aloe Vara" still matches the brand.
  List<String> words(String text) => text
      .split(RegExp(r'[\s ​]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  final nameWords = words(p.name);
  final brandWords = words(itemName).map((w) => w.toLowerCase()).toList();
  if (brandWords.isEmpty || nameWords.length <= brandWords.length) return p.name.trim();
  for (var i = 0; i < brandWords.length; i++) {
    if (nameWords[i].toLowerCase() != brandWords[i]) return p.name.trim();
  }
  var rest = nameWords.sublist(brandWords.length).join(' ');
  rest = rest.replaceFirst(RegExp(r'^[\-–:,/|]+\s*'), '').trim();
  return rest.isEmpty ? p.name.trim() : rest;
}
