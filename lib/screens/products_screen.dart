import 'dart:async';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../services/product_export.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

String _cleanImportHeader(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

String _stringFromImportCell(Object? value) => value == null
    ? ''
    : value.toString().trim();

double _doubleFromImportCell(Object? value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  final text = value.toString().trim();
  if (text.isEmpty) return 0;
  final cleaned = text.replaceAll(',', '').replaceAll('Rs', '').replaceAll('PKR', '').trim();
  return parseAmount(cleaned) ?? 0;
}

String _productNameFromImportValues(Map<String, dynamic> values) {
  final rawParts = [
    values['name'],
    values['product_name'],
    values['item_name'],
    values['description'],
    values['product_description'],
    values['item_description'],
    values['variant_name'],
    values['variant'],
  ].map((value) => _stringFromImportCell(value)).where((part) => part.isNotEmpty).toList();

  if (rawParts.isEmpty) return '';

  final parts = <String>[];
  final seen = <String>{};
  for (final part in rawParts) {
    final normalized = part.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) continue;
    final key = normalized.toLowerCase();
    if (seen.add(key)) {
      parts.add(normalized);
    }
  }

  return parts.join(' ');
}

String? _importHeaderToField(String header) {
  final h = _cleanImportHeader(header);
  const map = {
    'name': 'name',
    'product name': 'product_name',
    'product title': 'product_name',
    'item title': 'item_name',
    'title': 'name',
    'product': 'product_name',
    'item': 'item_name',
    'description': 'description',
    'product description': 'product_description',
    'item description': 'item_description',
    'variant name': 'variant_name',
    'variant': 'variant_name',
    'barcode': 'barcode',
    'ean': 'barcode',
    'ean code': 'barcode',
    'item code': 'barcode',
    'product code': 'barcode',
    'sku': 'sku',
    'code': 'sku',
    'cost': 'cost_price',
    'cost price': 'cost_price',
    'cost price price': 'cost_price',
    'actual cost': 'cost_price',
    'buying price': 'cost_price',
    'unit cost': 'cost_price',
    'price': 'sale_price',
    'sale price': 'sale_price',
    'selling price': 'sale_price',
    'retail price': 'sale_price',
    'unit price': 'sale_price',
    'mrp': 'sale_price',
    'opening stock': 'opening_stock',
    'opening qty': 'opening_stock',
    'opening quantity': 'opening_stock',
    'qty': 'opening_stock',
    'quantity': 'opening_stock',
    'stock': 'opening_stock',
    'unit': 'unit',
    'unit of measure': 'unit',
    'uom': 'unit',
    'measure': 'unit',
    'measurement': 'unit',
    'size': 'unit',
    'weight': 'unit',
    'pack': 'unit',
    'pack size': 'unit',
    'packaging': 'unit',
    'package': 'unit',
    'package size': 'unit',
    'packet': 'unit',
    'packet size': 'unit',
    'category': 'category_name',
    'category name': 'category_name',
    'item name': 'item_name',
    'item type': 'unit',
    'item type name': 'unit',
    'subcategory': 'subcategory_name',
    'sub_category': 'subcategory_name',
    'brand': 'brand',
    'reorder level': 'reorder_level',
    'reorder': 'reorder_level',
    'supplier': 'supplier_name',
    'supplier name': 'supplier_name',
  };
  return map[h];
}

String _detectImportDelimiter(String text) {
  if (text.isEmpty) return ',';
  const candidates = ['\t', ';', '|', ','];
  final sample = text
      .split(RegExp(r'\r?\n'))
      .where((line) => line.trim().isNotEmpty)
      .take(5)
      .toList();

  if (sample.isEmpty) return ',';

  var bestDelimiter = ',';
  var bestScore = 0;
  for (final delimiter in candidates) {
    var score = 0;
    for (final line in sample) {
      score += line.split(delimiter).length - 1;
    }
    if (score > bestScore) {
      bestScore = score;
      bestDelimiter = delimiter;
    }
  }

  return bestDelimiter;
}

List<Map<String, dynamic>> parseProductImportRowsFromText(String text) {
  final rows = <List<String>>[];
  final current = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  final delimiter = _detectImportDelimiter(text);

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '"') {
      if (inQuotes && i + 1 < text.length && text[i + 1] == '"') {
        field.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (ch == delimiter && !inQuotes) {
      current.add(field.toString().trim());
      field.clear();
      continue;
    }
    if ((ch == '\n' || ch == '\r') && !inQuotes) {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
        i++;
      }
      current.add(field.toString().trim());
      field.clear();
      if (current.any((e) => e.isNotEmpty)) {
        rows.add(current.toList());
      }
      current.clear();
      continue;
    }
    field.write(ch);
  }

  if (field.isNotEmpty || current.isNotEmpty) {
    current.add(field.toString().trim());
    if (current.any((e) => e.isNotEmpty)) {
      rows.add(current.toList());
    }
  }

  if (rows.isEmpty) return const [];

  final headers = rows.first.map((h) => _cleanImportHeader(h)).toList();
  final result = <Map<String, dynamic>>[];

  for (var i = 1; i < rows.length; i++) {
    final row = rows[i];
    if (row.every((cell) => cell.trim().isEmpty)) continue;

    final values = <String, dynamic>{};
    for (var j = 0; j < headers.length; j++) {
      final header = headers[j];
      if (header.isEmpty) continue;
      final target = _importHeaderToField(header);
      if (target == null) continue;
      final raw = j < row.length ? row[j] : '';
      values[target] = raw;
    }

    final name = _productNameFromImportValues(values);
    if (name.isEmpty) continue;

    final sale = _doubleFromImportCell(values['sale_price']);
    final cost = _doubleFromImportCell(values['cost_price']);
    final opening = _doubleFromImportCell(values['opening_stock']);

    final item = <String, dynamic>{
      'name': name,
      'barcode': _stringFromImportCell(values['barcode']),
      'cost_price': cost,
      'sale_price': sale,
      'opening_stock': opening,
    };

    final categoryName = _stringFromImportCell(values['category_name']);
    if (categoryName.isNotEmpty) {
      item['category_name'] = categoryName;
    }

    final itemName = _stringFromImportCell(values['item_name']);
  
    final subcategoryName = _stringFromImportCell(values['subcategory_name']);
    if (subcategoryName.isNotEmpty) {
      item['subcategory_name'] = subcategoryName;
    } else if (itemName.isNotEmpty) {
      item['subcategory_name'] = itemName;
    }

    final sku = _stringFromImportCell(values['sku']);
    if (sku.isNotEmpty) {
      item['sku'] = sku;
    }
    final unit = _stringFromImportCell(values['unit']);
    if (unit.isNotEmpty) {
      item['unit'] = unit;
    }
    if (_stringFromImportCell(values['brand']).isNotEmpty) {
      item['brand'] = _stringFromImportCell(values['brand']);
    }
    if (_stringFromImportCell(values['category_name']).isNotEmpty) {
      item['category_name'] = _stringFromImportCell(values['category_name']);
    }
    if (_stringFromImportCell(values['subcategory_name']).isNotEmpty) {
      item['subcategory_name'] = _stringFromImportCell(values['subcategory_name']);
    }
    if (_stringFromImportCell(values['supplier_name']).isNotEmpty) {
      item['supplier_name'] = _stringFromImportCell(values['supplier_name']);
    }

    result.add(item);
  }

  return result;
}

Future<List<Map<String, dynamic>>> parseProductImportRowsFromFilePath(String path) async {
  final file = File(path);
  final lower = path.toLowerCase();
  if (lower.endsWith('.xlsx') || lower.endsWith('.xls')) {
    try {
      final bytes = await file.readAsBytes();
      final excel = Excel.decodeBytes(bytes);
      final rows = <Map<String, dynamic>>[];
      for (final table in excel.tables.values) {
        if (table.rows.isEmpty) continue;
        final matrix = table.rows.map((r) => r.map((cell) => cell?.value ?? '').toList()).toList();
        rows.addAll(parseProductImportRowsFromMatrix(matrix));
      }
      return rows;
    } on Exception catch (e) {
      final msg = e.toString();
      if (msg.contains('numFmtId') || msg.contains('custom numFmt')) {
        throw Exception(
          'This Excel file uses unsupported custom number formatting. Save the sheet as a simple CSV or a normal .xlsx file and import again.',
        );
      }
      rethrow;
    }
  }
  return parseProductImportRowsFromText(await file.readAsString());
}

List<Map<String, dynamic>> parseProductImportRowsFromMatrix(List<List<dynamic>> matrix) {
  if (matrix.isEmpty) return const [];
  final headers = matrix.first.map((h) => _cleanImportHeader(h.toString())).toList();
  final result = <Map<String, dynamic>>[];

  for (var i = 1; i < matrix.length; i++) {
    final row = matrix[i];
    if (row.every((cell) => cell.toString().trim().isEmpty)) continue;
    final values = <String, dynamic>{};
    for (var j = 0; j < headers.length; j++) {
      final header = headers[j];
      if (header.isEmpty) continue;
      final target = _importHeaderToField(header);
      if (target == null) continue;
      final raw = j < row.length ? row[j] : '';
      values[target] = raw;
    }

    final name = _productNameFromImportValues(values);
    if (name.isEmpty) continue;

    final item = <String, dynamic>{
      'name': name,
      'barcode': _stringFromImportCell(values['barcode']),
      'cost_price': _doubleFromImportCell(values['cost_price']),
      'sale_price': _doubleFromImportCell(values['sale_price']),
      'opening_stock': _doubleFromImportCell(values['opening_stock']),
    };

    final categoryName = _stringFromImportCell(values['category_name']);
    if (categoryName.isNotEmpty) {
      item['category_name'] = categoryName;
    }
    final itemName = _stringFromImportCell(values['item_name']);
    final subcategoryName = _stringFromImportCell(values['subcategory_name']);
    if (subcategoryName.isNotEmpty) {
      item['subcategory_name'] = subcategoryName;
    } else if (itemName.isNotEmpty) {
      item['subcategory_name'] = itemName;
    }

    final sku = _stringFromImportCell(values['sku']);
    if (sku.isNotEmpty) {
      item['sku'] = sku;
    }
    final unit = _stringFromImportCell(values['unit']);
    if (unit.isNotEmpty) {
      item['unit'] = unit;
    }
    if (_stringFromImportCell(values['brand']).isNotEmpty) {
      item['brand'] = _stringFromImportCell(values['brand']);
    }
    if (_stringFromImportCell(values['category_name']).isNotEmpty) {
      item['category_name'] = _stringFromImportCell(values['category_name']);
    }
    if (_stringFromImportCell(values['subcategory_name']).isNotEmpty) {
      item['subcategory_name'] = _stringFromImportCell(values['subcategory_name']);
    }
    if (_stringFromImportCell(values['supplier_name']).isNotEmpty) {
      item['supplier_name'] = _stringFromImportCell(values['supplier_name']);
    }

    result.add(item);
  }

  return result;
}

/// Inventory master file: everything a manager needs to add goods, fix stock
/// and keep prices honest. Cashiers never see this screen.
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  // Keep the full catalogue in memory so the page never drops products behind a
  // hidden limit while filtering or sorting. We intentionally avoid truncating
  // this list and only apply filtering on top.
  List<AdminProduct> _allProducts = [];
  List<AdminProduct> _products = [];
  bool _loading = true;
  String _error = '';
  String _query = '';
  String _filter = 'all';
  String? _category;
  String? _subcategory;
  int _pageSize = 80;
  int _currentPage = 0;
  int _catalogueTotalCount = 0;
  /// How many products match the current search and filters (across all pages).
  int _filteredCount = 0;
  Timer? _queryDebounce;
  final ScrollController _tableVerticalScroll = ScrollController();
  final ScrollController _tableHorizontalScroll = ScrollController();
  final TextEditingController _barcodeController = TextEditingController();
  final FocusNode _barcodeFocus = FocusNode();
  final FocusNode _globalBarcodeFocus = FocusNode();
  final StringBuffer _barcodeScannerBuffer = StringBuffer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<AppState>().refreshReference();
      if (mounted) {
        _globalBarcodeFocus.requestFocus();
        _load();
      }
    });
  }

  @override
  void dispose() {
    _queryDebounce?.cancel();
    _tableVerticalScroll.dispose();
    _tableHorizontalScroll.dispose();
    _barcodeController.dispose();
    _barcodeFocus.dispose();
    _globalBarcodeFocus.dispose();
    super.dispose();
  }

  Future<void> _scanBarcode(String rawCode) async {
    final code = AppState.normalizeBarcodeInput(rawCode);
    if (code.isEmpty) return;

    _barcodeController.clear();
    _globalBarcodeFocus.requestFocus();

    final state = context.read<AppState>();
    AdminProduct? match;
    final candidates = List<AdminProduct>.from(_allProducts);
    if (candidates.isNotEmpty) {
      for (final item in candidates) {
        if (AppState.matchesBarcode(code, item.barcode)) {
          match = item;
          break;
        }
      }
    }
    if (match == null && state.catalogue.isNotEmpty) {
      for (final item in state.catalogue) {
        if (AppState.matchesBarcode(code, item.barcode)) {
          match = AdminProduct(item.raw);
          break;
        }
      }
    }
    if (match == null) {
      final shouldAdd = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('No product found'),
          content: Text('Barcode "$code" was not found. Do you want to add a new product for it?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add item')),
          ],
        ),
      );
      if (shouldAdd == true && mounted) {
        await _editProduct(state, null, initialBarcode: code);
      }
      return;
    }

    if (mounted) {
      await _editProduct(state, match);
    }
  }

  /// The list the screen is showing. It is rebuilt only when the shared product
  /// list changes (after a save, stock change, delete, or the periodic refresh), so
  /// a search keystroke does not re-wrap thousands of products.
  List<AdminProduct> _productsFrom(List<PosProduct> source) {
    if (!identical(source, _sourceList)) {
      _sourceList = source;
      _allProducts = source.map((p) => AdminProduct(p.raw)).toList();
    }
    return _allProducts;
  }

  List<PosProduct>? _sourceList;

  /// Asks for the file type, then saves every product (not just the page on
  /// screen) with the columns the shop uses.
  Future<void> _chooseExport(AppState state) async {
    final format = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Export all products'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'xlsx'),
            child: const ListTile(
              leading: Icon(Icons.table_chart_outlined),
              title: Text('Excel workbook (.xlsx)'),
              subtitle: Text('Opens straight in Excel, column names in the first row'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'csv'),
            child: const ListTile(
              leading: Icon(Icons.description_outlined),
              title: Text('CSV file (.csv)'),
              subtitle: Text('Plain text; opens in Excel, Sheets or Notepad'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
    if (format == null || !mounted) return;
    await _exportProducts(state, format);
  }

  Future<void> _exportProducts(AppState state, String format) async {
    final products = _productsFrom(state.productCatalogue);
    if (products.isEmpty) {
      showMessage(context, 'There are no products to export yet');
      return;
    }
    final rows = productExportRows(
      products,
      categories: state.categories,
      subcategories: state.subcategories,
    );
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)}';

    final picked = await FilePicker.platform.saveFile(
      dialogTitle: 'Save the product list',
      fileName: 'supermart_products_$stamp.$format',
      type: FileType.custom,
      allowedExtensions: [format],
    );
    if (picked == null || !mounted) return;

    final path = picked.toLowerCase().endsWith('.$format') ? picked : '$picked.$format';
    try {
      final bytes = format == 'xlsx' ? productExportExcel(rows) : productExportCsv(rows);
      await File(path).writeAsBytes(bytes, flush: true);
      if (mounted) {
        showMessage(context, 'Saved ${products.length} products to $path');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _load({bool fromServer = false}) async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final appState = context.read<AppState>();
      if (fromServer || appState.productCatalogue.isEmpty) {
        await appState.refreshProductCatalogue(silent: true, force: true);
      }
      final allCatalogueProducts = _productsFrom(appState.productCatalogue);

      final filteredProducts = AppState.filterAdminProducts(
        allCatalogueProducts,
        query: _query,
        filter: _filter,
        category: _category,
        subcategory: _subcategory,
        categories: appState.categories,
        subcategories: appState.subcategories,
      );

      if (!mounted) return;
      final totalPages = filteredProducts.isEmpty ? 1 : (filteredProducts.length / _pageSize).ceil();
      final safePage = _currentPage.clamp(0, totalPages - 1);
      final start = safePage * _pageSize;
      final end = (start + _pageSize).clamp(0, filteredProducts.length);

      setState(() {
        _catalogueTotalCount = allCatalogueProducts.length;
        _filteredCount = filteredProducts.length;
        _products = filteredProducts.sublist(start, end);
        _error = '';
        _currentPage = safePage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // The shared product list was replaced elsewhere (another save, a refresh, an
    // import from Settings): show it. Checked by identity, so this costs nothing.
    if (!identical(state.productCatalogue, _sourceList) && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final visibleProducts = _products;
    final totalProducts = _allProducts;
    final totalProductCount = _catalogueTotalCount;
    final stockValue = totalProducts.fold<double>(0, (a, p) => a + p.stockValue);
    final lowCount = totalProducts.where((p) => p.isLow).length;

    return KeyboardListener(
      focusNode: _globalBarcodeFocus,
      onKeyEvent: (event) {
        // Only when no text field has focus. Otherwise the keys belong to that
        // field (the barcode box handles its own Enter via onSubmitted).
        if (event is! KeyDownEvent || !_globalBarcodeFocus.hasPrimaryFocus) return;

        // Enter is checked first: on Windows it arrives as '\r', a non-empty
        // character, which used to be swallowed and never flushed the scan.
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
          final value = _barcodeScannerBuffer.toString().trim();
          _barcodeScannerBuffer.clear();
          if (value.isNotEmpty) {
            unawaited(_scanBarcode(value));
          }
          return;
        }

        final character = event.character;
        if (character != null && character.isNotEmpty && !character.startsWith('\u0000')) {
          _barcodeScannerBuffer.write(character.replaceAll(RegExp(r'\s+'), ''));
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _barcodeController,
              focusNode: _barcodeFocus,
              decoration: const InputDecoration(
                labelText: 'Scan barcode',
                prefixIcon: Icon(Icons.qr_code_scanner),
                helperText: 'Scan a barcode to open the product details',
              ),
              onSubmitted: (value) => _scanBarcode(value),
            ),
            const SizedBox(height: AppSpacing.md),
            SectionCard(
              headerContent: Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Wrap(
                      spacing: AppSpacing.md,
                      runSpacing: AppSpacing.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 200,
                          child: StatCard(
                            label: 'Visible items',
                            value: _filteredCount.toString(),
                            sub: 'matching filters',
                            icon: Icons.inventory_2_outlined,
                            color: AppColors.info,
                          ),
                        ),
                        SizedBox(
                          width: 200,
                          child: StatCard(
                            label: 'Total products',
                            value: totalProductCount.toString(),
                            sub: 'all products in stock list',
                            icon: Icons.grid_view_rounded,
                            color: AppColors.cash,
                          ),
                        ),
                        SizedBox(
                          width: 220,
                          child: StatCard(
                            label: 'Need reordering',
                            value: lowCount.toString(),
                            sub: lowCount > 0 ? 'check stock levels' : 'all stocked well',
                            icon: Icons.warning_amber_rounded,
                            color: lowCount > 0 ? AppColors.warn : AppColors.good,
                          ),
                        ),
                        SizedBox(
                          width: 220,
                          child: StatCard(
                            label: 'Stock value',
                            value: money(stockValue),
                            sub: 'current visible total',
                            icon: Icons.account_balance_wallet_outlined,
                            color: AppColors.good,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                OutlinedButton.icon(
                  onPressed: () => _chooseExport(state),
                  icon: const Icon(Icons.file_download_outlined),
                  label: const Text('Export'),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: () => _editProduct(state, null),
                  icon: const Icon(Icons.add),
                  label: const Text('New product'),
                ),
              ],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            hintText: 'Search by name, barcode or SKU',
                            prefixIcon: Icon(Icons.search),
                            filled: true,
                          ),
                          onChanged: (v) {
                            _queryDebounce?.cancel();
                            setState(() {
                              _query = v;
                              _currentPage = 0;
                            });
                            _queryDebounce = Timer(const Duration(milliseconds: 220), _load);
                          },
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'all', label: Text('All')),
                          ButtonSegment(value: 'low', label: Text('Low')),
                          ButtonSegment(value: 'out', label: Text('Out')),
                        ],
                        selected: {_filter},
                        onSelectionChanged: (s) {
                          setState(() {
                            _filter = s.first;
                            _currentPage = 0;
                          });
                          _load();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButtonFormField<String?>(
                        initialValue: _category,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                          constraints: BoxConstraints(maxWidth: 220),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('All categories')),
                          for (final c in state.categories)
                            DropdownMenuItem<String?>(
                              value: c['name'] as String,
                              child: Text(c['name'] as String),
                            ),
                        ],
                        onChanged: (v) {
                          setState(() {
                            _category = v;
                            final parentId = v == null
                                ? null
                                : state.categories
                                    .firstWhere(
                                      (c) => c['name'] == v,
                                      orElse: () => <String, dynamic>{'id': null},
                                    )['id'];
                            if (parentId == null ||
                                !state.subcategories.any((s) => s['parent_id'] == parentId && s['name'] == _subcategory)) {
                              _subcategory = null;
                            }
                            _currentPage = 0;
                          });
                          _load();
                        },
                      ),
                      if (_category != null &&
                          state.subcategories.any((s) =>
                              s['parent_id'] ==
                              state.categories.firstWhere(
                                    (c) => c['name'] == _category,
                                    orElse: () => <String, dynamic>{'id': null},
                                  )['id']))
                        DropdownButtonFormField<String?>(
                          initialValue: _subcategory,
                          decoration: const InputDecoration(
                            labelText: 'Subcategory',
                            constraints: BoxConstraints(maxWidth: 220),
                          ),
                          items: [
                            const DropdownMenuItem<String?>(value: null, child: Text('All subcategories')),
                            for (final s in state.subcategories.where((sub) =>
                                _category != null &&
                                sub['parent_id'] ==
                                    state.categories.firstWhere(
                                          (c) => c['name'] == _category,
                                          orElse: () => <String, dynamic>{'id': null},
                                        )['id']))
                              DropdownMenuItem<String?>(
                                value: s['name'] as String,
                                child: Text(s['name'] as String),
                              ),
                          ],
                          onChanged: (v) {
                            setState(() {
                              _subcategory = v;
                              _currentPage = 0;
                            });
                            _load();
                          },
                        ),
                      DropdownButtonFormField<int>(
                        initialValue: _pageSize,
                        decoration: const InputDecoration(
                          labelText: 'Rows per page',
                          constraints: BoxConstraints(maxWidth: 170),
                        ),
                        items: const [
                          DropdownMenuItem(value: 40, child: Text('40')),
                          DropdownMenuItem(value: 80, child: Text('80')),
                          DropdownMenuItem(value: 120, child: Text('120')),
                          DropdownMenuItem(value: 200, child: Text('200')),
                          DropdownMenuItem(value: 500, child: Text('500')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _pageSize = v;
                            _currentPage = 0;
                          });
                          _load();
                        },
                      ),
                      IconButton(
                        tooltip: 'Refresh products',
                        onPressed: () => _load(fromServer: true),
                        icon: const Icon(Icons.refresh),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Previous page',
                            onPressed: _currentPage > 0
                                ? () {
                                    setState(() => _currentPage--);
                                    _load();
                                  }
                                : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Text(
                            _filteredCount == 0
                                ? 'Page 1 of 1'
                                : 'Page ${_currentPage + 1} of ${(_filteredCount / _pageSize).ceil()}',
                          ),
                          IconButton(
                            tooltip: 'Next page',
                            onPressed: _currentPage + 1 < (_filteredCount / _pageSize).ceil()
                                ? () {
                                    setState(() => _currentPage++);
                                    _load();
                                  }
                                : null,
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error.isNotEmpty
                          ? EmptyState(
                              icon: Icons.error_outline,
                              title: 'Could not load products',
                              message: _error,
                            )
                          : SectionCard(
                              title: 'Product catalogue',
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              actions: [
                                StatusPill(
                                  text: '${visibleProducts.length} shown',
                                  color: AppColors.info,
                                ),
                              ],
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final tableWidth = constraints.maxWidth < 1100 ? 1100.0 : constraints.maxWidth;
                                  final headerLabels = const [
                                    'Product',
                                    'Barcode',
                                    'Category',
                                    'Cost',
                                    'Sale',
                                    'Margin',
                                    'In stock',
                                    'Value',
                                    'Actions',
                                  ];
                                  final columnFlex = const [4, 2, 2, 1, 1, 1, 1, 1, 1];

                                  return SizedBox(
                                    height: 520,
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: SizedBox(
                                        width: tableWidth,
                                        child: Column(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: AppSpacing.md,
                                                vertical: AppSpacing.sm,
                                              ),
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHighest
                                                  .withValues(alpha: 0.35),
                                              child: Row(
                                                children: [
                                                  for (var i = 0; i < headerLabels.length; i++)
                                                    Expanded(
                                                      flex: columnFlex[i],
                                                      child: Text(
                                                        headerLabels[i],
                                                        style: const TextStyle(
                                                          fontWeight: FontWeight.w700,
                                                          fontSize: 12.5,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                            const Divider(height: 1),
                                            Expanded(
                                              child: ListView.separated(
                                                itemCount: visibleProducts.length,
                                                itemBuilder: (context, index) {
                                                  final p = visibleProducts[index];
                                                  return InkWell(
                                                    onTap: () => _editProduct(state, p),
                                                    child: Padding(
                                                      padding: const EdgeInsets.symmetric(
                                                        horizontal: AppSpacing.md,
                                                        vertical: AppSpacing.sm,
                                                      ),
                                                      child: Row(
                                                        crossAxisAlignment: CrossAxisAlignment.center,
                                                        children: [
                                                          Expanded(
                                                            flex: columnFlex[0],
                                                            child: Text(
                                                              p.name,
                                                              style: const TextStyle(fontWeight: FontWeight.w600),
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                          ),
                                                          Expanded(
                                                            flex: columnFlex[1],
                                                            child: Text(
                                                              p.barcode.isEmpty ? '—' : p.barcode,
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                          ),
                                                          Expanded(
                                                            flex: columnFlex[2],
                                                            child: Text(
                                                              p.categoryName.isEmpty ? 'Unassigned' : p.categoryName,
                                                              overflow: TextOverflow.ellipsis,
                                                            ),
                                                          ),
                                                          Expanded(
                                                            flex: columnFlex[3],
                                                            child: Text(num2(p.costPrice), textAlign: TextAlign.right),
                                                          ),
                                                          Expanded(
                                                            flex: columnFlex[4],
                                                            child: Text(num2(p.salePrice), textAlign: TextAlign.right),
                                                          ),
                                                          Expanded(
                                                            flex: columnFlex[5],
                                                            child: Text(
                                                              '${num2(p.marginPercent)}%',
                                                              textAlign: TextAlign.right,
                                                              style: TextStyle(
                                                                color: p.marginPercent < 5 ? AppColors.warn : AppColors.good,
                                                                fontWeight: FontWeight.w600,
                                                              ),
                                                            ),
                                                          ),
                                                          Expanded(
                                                            flex: columnFlex[6],
                                                            child: Text(
                                                              '${qtyStr(p.stockQty)} ${p.unit}',
                                                              textAlign: TextAlign.right,
                                                              style: TextStyle(
                                                                color: p.stockQty <= 0
                                                                    ? AppColors.danger
                                                                    : (p.isLow ? AppColors.warn : null),
                                                                fontWeight: p.isLow ? FontWeight.bold : null,
                                                              ),
                                                            ),
                                                          ),
                                                          Expanded(
                                                            flex: columnFlex[7],
                                                            child: Text(num2(p.stockValue), textAlign: TextAlign.right),
                                                          ),
                                                          SizedBox(
                                                            width: 140,
                                                            child: Row(
                                                              mainAxisAlignment: MainAxisAlignment.end,
                                                              children: [
                                                                IconButton(
                                                                  tooltip: 'Bulk / quantity prices',
                                                                  icon: Icon(
                                                                    Icons.stacked_line_chart,
                                                                    size: 18,
                                                                    color: p.wholesalePrice > 0 ? AppColors.info : null,
                                                                  ),
                                                                  onPressed: () => _bulkPrices(state, p),
                                                                ),
                                                                IconButton(
                                                                  tooltip: 'Adjust stock',
                                                                  icon: const Icon(Icons.tune, size: 18),
                                                                  onPressed: () => _adjustStock(state, p),
                                                                ),
                                                                if (state.isAdmin)
                                                                  IconButton(
                                                                    tooltip: 'Remove from catalogue',
                                                                    icon: const Icon(Icons.delete_outline, size: 18),
                                                                    onPressed: () => _delete(state, p),
                                                                  ),
                                                              ],
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  );
                                                },
                                                separatorBuilder: (context, index) => const Divider(height: 1),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------- bulk pricing
  /// Quantity price breaks for one product: "1–11 at 150, 12+ at 138".
  /// The till reads these by itself — the cashier does nothing.
  Future<void> _bulkPrices(AppState state, AdminProduct p) async {
    final sym = state.store?.currencySymbol ?? 'Rs';
    List<Map<String, dynamic>> tiers;
    try {
      tiers = await state.api.priceTiers(p.id);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;

    final tiersState = ValueNotifier<List<Map<String, dynamic>>>(tiers);

    await showDialog<void>(
      context: context,
      builder: (c) {
        Future<void> refreshTiers() async {
          tiersState.value = await state.api.priceTiers(p.id);
        }

        Future<void> saveTierEditor({
          required String? id,
          required TextEditingController qty,
          required TextEditingController price,
          required TextEditingController label,
        }) async {
          final payload = <String, dynamic>{
            'product_id': p.id,
            'min_qty': parseAmount(qty.text) ?? 0,
            'price': parseAmount(price.text) ?? 0,
            'label': label.text.trim(),
            'is_active': true,
          };
          if (id != null && id.isNotEmpty) payload['id'] = id;
          await state.api.savePriceTier(payload);
          await refreshTiers();
        }

        Future<void> addTier() async {
          final qty = TextEditingController();
          final price = TextEditingController(text: num2(p.salePrice));
          final label = TextEditingController();
          final ok = await showDialog<bool>(
            context: c,
            builder: (cc) => AlertDialog(
              title: Text('Add a price break for ${p.name}'),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: qty,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'From how many? (quantity)',
                        helperText: 'e.g. 12 → 12 and above get the new price',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: price,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: 'Price per unit ($sym)'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: label,
                      decoration: const InputDecoration(
                          labelText: 'Label (optional)', hintText: 'e.g. carton rate'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(cc, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(cc, true), child: const Text('Add')),
              ],
            ),
          );
          if (ok != true) return;
          try {
            await saveTierEditor(id: null, qty: qty, price: price, label: label);
          } catch (e) {
            if (mounted) showError(context, e);
          }
        }

        Future<void> editTier(Map<String, dynamic> tier) async {
          final qty = TextEditingController(text: num2(toD(tier['min_qty'])));
          final price = TextEditingController(text: num2(toD(tier['price'])));
          final label = TextEditingController(text: (tier['label'] ?? '').toString());
          final ok = await showDialog<bool>(
            context: c,
            builder: (cc) => AlertDialog(
              title: Text('Edit price break for ${p.name}'),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: qty,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'From how many? (quantity)',
                        helperText: 'e.g. 12 → 12 and above get the new price',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: price,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: 'Price per unit ($sym)'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      controller: label,
                      decoration: const InputDecoration(
                          labelText: 'Label (optional)', hintText: 'e.g. carton rate'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(cc, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(cc, true), child: const Text('Save')),
              ],
            ),
          );
          if (ok != true) return;
          try {
            await saveTierEditor(
              id: (tier['id'] ?? '').toString(),
              qty: qty,
              price: price,
              label: label,
            );
          } catch (e) {
            if (mounted) showError(context, e);
          }
        }

        return AlertDialog(
          title: Text('Bulk prices — ${p.name}'),
          content: SizedBox(
            width: 520,
            height: 400,
            child: ValueListenableBuilder<List<Map<String, dynamic>>>(
              valueListenable: tiersState,
              builder: (context, currentTiers, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    KeyValue(
                      k: 'Normal price',
                      v: '${money(p.salePrice, symbol: sym)} per ${p.unit}',
                      bold: true,
                    ),
                    const Divider(height: AppSpacing.lg),
                    if (currentTiers.isNotEmpty)
                      ...currentTiers.map((t) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.stacked_line_chart, size: 20),
                            title: Text('${num2(toD(t['min_qty']))}+  →  ${money(toD(t['price']), symbol: sym)} each'),
                            subtitle: (t['label'] ?? '').toString().isEmpty
                                ? null
                                : Text((t['label']).toString()),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  tooltip: 'Edit price break',
                                  onPressed: () async {
                                    try {
                                      await editTier(t);
                                    } catch (e) {
                                      if (context.mounted) showError(context, e);
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                  tooltip: 'Delete price break',
                                  onPressed: () async {
                                    final sure = await confirm(context,
                                        title: 'Delete this price break?',
                                        message: 'Customers buying this quantity will pay the normal price.',
                                        okLabel: 'Delete');
                                    if (!sure || !context.mounted) return;
                                    try {
                                      await state.api.deletePriceTier(t['id'] as String);
                                      await refreshTiers();
                                    } catch (e) {
                                      if (context.mounted) showError(context, e);
                                    }
                                  },
                                ),
                              ],
                            ),
                          )),
                    if (currentTiers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                        child: Text('No price breaks yet. Add one for customers who buy in bulk - '
                            'shopkeepers, restaurants, caterers.'),
                      ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
            FilledButton.icon(
              onPressed: addTier,
              icon: const Icon(Icons.add),
              label: const Text('Add price break'),
            ),
          ],
        );
      },
    );
  }

  // ------------------------------------------------------------- editing
  Future<void> _editProduct(AppState state, AdminProduct? existing, {String initialBarcode = ''}) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final barcode = TextEditingController(text: existing?.barcode ?? initialBarcode);
    final sku = TextEditingController(text: existing?.sku ?? '');
    final cost = TextEditingController(text: existing == null ? '' : num2(existing.costPrice));
    final sale = TextEditingController(text: existing == null ? '' : num2(existing.salePrice));
    final reorder = TextEditingController(text: existing == null ? '5' : num2(existing.reorderLevel));
    final opening = TextEditingController(text: '0');
    final shelf = TextEditingController();
    final wholesale = TextEditingController(
        text: existing == null ? '' : num2(existing.wholesalePrice));
    final wholesaleQty = TextEditingController(
        text: existing == null || existing.wholesaleMinQty <= 0 ? '' : num2(existing.wholesaleMinQty));
    final plu = TextEditingController(text: existing?.pluCode ?? '');
    final brand = TextEditingController(text: existing?.brand ?? '');
    final packSize = TextEditingController(text: existing?.packSize ?? '');
    final origin = TextEditingController(text: existing?.countryOfOrigin ?? '');
    final expiry = TextEditingController(text: existing?.expiryDate ?? '');
    final batchNo = TextEditingController();
    final mfgDate = TextEditingController();
    var expiryTracked = existing?.isExpiryTracked ?? false;
    String? categoryId;
    String? subcategoryId;
    String? supplierId;
    final existingRaw = existing?.raw ?? const {};
    if (existingRaw['category_id'] != null) {
      final selectedId = existingRaw['category_id'].toString();
      subcategoryId = selectedId;
      for (final sub in state.subcategories) {
        if (sub['id']?.toString() == selectedId) {
          categoryId = (sub['parent_id'] ?? '').toString();
          if (categoryId.isEmpty) categoryId = null;
          break;
        }
      }
      if (categoryId == null) {
        categoryId = selectedId;
        subcategoryId = null;
      }
    }
    if (existingRaw['supplier_id'] != null) supplierId = existingRaw['supplier_id'].toString();
    final unitController = TextEditingController(text: existing?.unit ?? 'pcs');
    String unit = existing?.unit ?? 'pcs';
    var isWeighed = existing?.raw['is_weighed'] == true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: Text(existing == null ? 'New product' : 'Edit ${existing.name}'),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 5, bottom: 5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                      controller: name,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Product name *'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: unitController,
                      onChanged: (v) => unit = v,
                      decoration: const InputDecoration(
                        labelText: 'Unit (pcs / kg / ltr)',
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: barcode,
                      decoration: const InputDecoration(
                        labelText: 'Barcode',
                        helperText: 'Scan into this box, or type it',
                        suffixIcon: Icon(Icons.qr_code_scanner),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: sku,
                      decoration: const InputDecoration(labelText: 'SKU / item code'),
                    ),
                  ),
                ]),
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      // ignore: deprecated_member_use
                      value: categoryId,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('—')),
                        for (final cat in state.categories)
                          DropdownMenuItem(
                              value: cat['id'] as String, child: Text(cat['name'] as String)),
                      ],
                      onChanged: (v) => setLocal(() {
                        categoryId = v;
                        if (v == null || !state.subcategories.any((sub) => sub['parent_id'] == v)) {
                          subcategoryId = null;
                        } else if (subcategoryId != null && !state.subcategories.any((sub) => sub['id'] == subcategoryId && sub['parent_id'] == v)) {
                          subcategoryId = null;
                        }
                      }),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      // ignore: deprecated_member_use
                      value: subcategoryId,
                      decoration: const InputDecoration(labelText: 'Subcategory'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('—')),
                        for (final sub in state.subcategories.where((item) => categoryId != null && item['parent_id'] == categoryId))
                          DropdownMenuItem(
                              value: sub['id'] as String, child: Text(sub['name'] as String)),
                      ],
                      onChanged: (v) => setLocal(() => subcategoryId = v),
                    ),
                  ),
                ]),
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  Expanded(
                    child: FutureBuilder<List<Map<String, dynamic>>>(
                      future: state.loadSuppliers(),
                      builder: (c, snap) => DropdownButtonFormField<String?>(
                        initialValue: supplierId,
                        decoration: const InputDecoration(labelText: 'Supplier'),
                        items: [
                          const DropdownMenuItem(value: null, child: Text('—')),
                          for (final sup in snap.data ?? [])
                            DropdownMenuItem(
                                value: sup['id'] as String,
                                child: Text(sup['name'] as String)),
                        ],
                        onChanged: (v) => setLocal(() => supplierId = v),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: cost,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Cost price (Rs)'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: sale,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Sale price (Rs) *'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: reorder,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Reorder level',
                        helperText: 'Warn me at or below this',
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: shelf,
                      decoration: const InputDecoration(labelText: 'Shelf / aisle (optional)'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  if (existing == null)
                    Expanded(
                      child: TextField(
                        controller: opening,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Opening stock now'),
                      ),
                    ),
                ]),
                const SizedBox(height: AppSpacing.xs),
                SwitchListTile(
                  value: isWeighed,
                  onChanged: (v) => setLocal(() => isWeighed = v),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sold by weight (loose item)'),
                  subtitle: const Text(
                      'For atta, sugar, fruit: the till asks for the weight instead of '
                      'counting pieces, and reads scale barcode labels.'),
                ),
                const Divider(height: AppSpacing.xl),
                const SectionLabel('Expiry & batch'),
                Row(children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: expiry,
                      decoration: const InputDecoration(
                        labelText: 'Expiry / best-before date',
                        hintText: 'yyyy-mm-dd',
                        prefixIcon: Icon(Icons.event, size: 18),
                      ),
                      onChanged: (_) => setLocal(() {}),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: batchNo,
                      decoration: InputDecoration(
                        labelText: existing == null ? 'Batch no. (optional)' : 'Batch no. (opening stock)',
                        hintText: 'e.g. L-2291',
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: mfgDate,
                      decoration: const InputDecoration(
                        labelText: 'Made on (optional)', hintText: 'yyyy-mm-dd'),
                    ),
                  ),
                ]),
                SwitchListTile(
                  value: expiryTracked,
                  onChanged: (v) => setLocal(() => expiryTracked = v),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Watch the expiry date of this item'),
                  subtitle: const Text('Sends it to Expiry & batches so expired stock is caught '
                      'before it is sold, and starts a write-off record when it goes off.'),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Fill the expiry date quickly',
                  onSelected: (v) {
                    final days = switch (v) {
                      'm6' => 182,
                      'y1' => 365,
                      'y2' => 730,
                      _ => int.parse(v),
                    };
                    expiry.text = DateTime.now()
                        .add(Duration(days: days))
                        .toIso8601String()
                        .substring(0, 10);
                    setLocal(() => expiryTracked = true);
                  },
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Text('Shelf life shortcuts: 1 · 2 · 3 months · 6 months · 1 year  ▾',
                        style: TextStyle(fontSize: 12.5, color: AppColors.info)),
                  ),
                  itemBuilder: (c) => const [
                    PopupMenuItem(value: '30', child: Text('1 month from today')),
                    PopupMenuItem(value: '60', child: Text('2 months from today')),
                    PopupMenuItem(value: '90', child: Text('3 months from today')),
                    PopupMenuItem(value: 'm6', child: Text('6 months from today')),
                    PopupMenuItem(value: 'y1', child: Text('1 year from today')),
                    PopupMenuItem(value: 'y2', child: Text('2 years from today')),
                  ],
                ),
                const Divider(height: AppSpacing.xl),
                const SectionLabel('Wholesale / bulk buyers'),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: wholesale,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Wholesale price (Rs)',
                        helperText: 'Leave blank if not sold in bulk',
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: wholesaleQty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Wholesale from quantity',
                        helperText: 'e.g. 12 → 12 or more gets this price',
                      ),
                    ),
                  ),
                ]),
                const Divider(height: AppSpacing.xl),
                const SectionLabel('Where it sits in the shop'),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: brand,
                      decoration: const InputDecoration(labelText: 'Brand (optional)'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: packSize,
                      decoration: const InputDecoration(
                          labelText: 'Pack size (optional)', hintText: 'e.g. 1 kg, 500 ml'),
                    ),
                  ),
                ]),
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: plu,
                      decoration: const InputDecoration(
                        labelText: 'PLU / item number (scale items)',
                        helperText: 'The number the weighing scale prints',
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: origin,
                      decoration: const InputDecoration(
                          labelText: 'Country of origin (optional)', hintText: 'e.g. Pakistan'),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty || sale.text.trim().isEmpty) return;
                // a typo must not save as 0: every number box has to read as a number
                final numbers = [cost.text, sale.text, reorder.text, opening.text];
                final bad = numbers.any((t) => t.trim().isNotEmpty && parseAmount(t) == null);
                if (bad || parseAmount(sale.text) == null || parseAmount(sale.text)! < 0) {
                  showMessage(context, 'Check the prices and quantities: enter plain numbers, e.g. 1250 or 1,250.', error: true);
                  return;
                }
                try {
                  await state.persistProduct({
                    if (existing != null) 'id': existing.id,
                    'name': name.text.trim(),
                    'barcode': barcode.text.trim().isEmpty ? null : barcode.text.trim(),
                    'sku': sku.text.trim().isEmpty ? null : sku.text.trim(),
                    'category_id': subcategoryId ?? categoryId,
                    'supplier_id': supplierId,
                    'unit': unit.trim().isEmpty ? 'pcs' : unit.trim(),
                    'cost_price': parseAmount(cost.text) ?? 0,
                    'sale_price': parseAmount(sale.text) ?? 0,
                    'reorder_level': parseAmount(reorder.text) ?? 5,
                    'shelf_location': shelf.text.trim().isEmpty ? null : shelf.text.trim(),
                    'opening_stock': existing == null ? (parseAmount(opening.text) ?? 0) : 0,
                    'is_weighed': isWeighed,
                    'brand': brand.text.trim().isEmpty ? null : brand.text.trim(),
                    'pack_size': packSize.text.trim().isEmpty ? null : packSize.text.trim(),
                    'plu_code': plu.text.trim().isEmpty ? null : plu.text.trim(),
                    'country_of_origin': origin.text.trim().isEmpty ? null : origin.text.trim(),
                    'expiry_date': expiry.text.trim().isEmpty ? null : expiry.text.trim(),
                    'mfg_date': mfgDate.text.trim().isEmpty ? null : mfgDate.text.trim(),
                    'batch_no': batchNo.text.trim().isEmpty ? null : batchNo.text.trim(),
                    'is_expiry_tracked': expiryTracked || expiry.text.trim().isNotEmpty,
                    'wholesale_price': wholesale.text.trim().isEmpty ? null : wholesale.text.trim(),
                    'wholesale_min_qty': wholesaleQty.text.trim().isEmpty ? 0 : parseAmount(wholesaleQty.text.trim()) ?? 0,
                  });
                  if (c.mounted) Navigator.pop(c, true);
                } catch (e) {
                  if (c.mounted) showError(c, e);
                }
              },
              child: const Text('Save product'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      await state.reloadProducts();
      await _load(fromServer: true);
      await state.refreshReference();
      if (mounted) showMessage(context, 'Product saved');
    }
  }

  Future<void> _adjustStock(AppState state, AdminProduct p) async {
    final qty = TextEditingController(text: num2(p.stockQty));
    final reason = TextEditingController(text: 'Stock count');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Adjust stock — ${p.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('The system currently shows ${qtyStr(p.stockQty)} ${p.unit}. '
              'Type what you actually counted; the difference is logged against your name.'),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: qty,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Counted quantity'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: reason,
            decoration: const InputDecoration(labelText: 'Reason (damage, theft, count…)'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final counted = parseAmount(qty.text);
              if (counted == null || counted < 0) {
                showMessage(context, 'Enter the counted quantity as a plain number, e.g. 1500 or 2.5.', error: true);
                return;
              }
              try {
                await state.persistStockCount(p.id, counted, reason.text);
                if (c.mounted) Navigator.pop(c, true);
              } catch (e) {
                if (c.mounted) showError(c, e);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.reloadProducts();
      await _load(fromServer: true);
    }
  }

  Future<void> _delete(AppState state, AdminProduct p) async {
    if (!await confirm(context,
        title: 'Remove ${p.name}?',
        message: 'It stays in old invoices but disappears from the till. You can add it back later.',
        okLabel: 'Remove')) {
      return;
    }
    try {
      await state.persistProductRemoval(p.id);
      await state.reloadProducts();
      await _load(fromServer: true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

/// Paste-friendly bulk import: one product per line, comma separated.
class BulkImportDialog extends StatefulWidget {
  const BulkImportDialog({super.key});
  @override
  State<BulkImportDialog> createState() => _BulkImportDialogState();
}

class _BulkImportDialogState extends State<BulkImportDialog> {
  final _text = TextEditingController();
  String? _result;
  /// One line per row the server refused, so the cause is visible.
  List<String> _errorLines = [];

  /// Shows the counts plus why each failed row was refused.
  void _showImportResult(Map<String, dynamic> res) {
    final errors = (res['errors'] as List? ?? const []).cast<Map>();
    setState(() {
      _result = 'Imported ${res['imported']}, failed ${res['failed']}.';
      _errorLines = [
        for (final e in errors.take(50))
          '${_rowLabel(e['row'])} - ${e['error']}',
      ];
    });
  }

  String _rowLabel(Object? row) {
    final r = row is Map ? row : const {};
    final name = (r['name'] ?? '').toString().trim();
    final barcode = (r['barcode'] ?? '').toString().trim();
    final sku = (r['sku'] ?? '').toString().trim();
    return [
      name.isEmpty ? '(no name)' : name,
      if (barcode.isNotEmpty) 'barcode $barcode',
      if (sku.isNotEmpty) 'sku $sku',
    ].join(', ');
  }

  Future<void> _pickAndImportFile() async {
    final state = context.read<AppState>();
    _errorLines = [];
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'xlsx', 'xls'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final path = file.path;
    if (path == null || path.isEmpty) {
      setState(() => _result = 'Unable to read the selected file.');
      return;
    }

    try {
      final rows = await parseProductImportRowsFromFilePath(path);
      if (rows.isEmpty) {
        setState(() => _result = 'No valid rows found in the file.');
        return;
      }
      final res = await state.api.bulkImport(rows);
      _showImportResult(res);
      await state.reloadProducts();
      await state.refreshReference();
    } catch (e) {
      setState(() => _result = e.toString().contains('unsupported custom number formatting')
          ? 'Import failed: save this Excel as a simple CSV or a normal .xlsx without custom number formats.'
          : 'Import failed: $e');
    }
  }

  Future<void> _importFromText() async {
    final state = context.read<AppState>();
    _errorLines = [];
    final rows = parseProductImportRowsFromText(_text.text);
    if (rows.isEmpty) {
      setState(() => _result = 'Nothing to import — check the format above.');
      return;
    }
    try {
      final res = await state.api.bulkImport(rows);
      _showImportResult(res);
      await state.reloadProducts();
      await state.refreshReference();
    } catch (e) {
      setState(() => _result = 'Import failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Bulk import products'),
      content: SizedBox(
        width: 620,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Import an Excel or CSV file or paste lines below.\n'
              'Accepted columns include: name, barcode, sku, cost price, sale price, unit, opening stock.\n\n'
              'Example row: Milk 1L, 9001, 120, 180, 12',
              style: TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _pickAndImportFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('Choose Excel / CSV file'),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _text,
            maxLines: 10,
            minLines: 6,
            decoration: const InputDecoration(
              hintText: 'Paste your CSV-style lines here…',
              border: OutlineInputBorder(),
            ),
          ),
          if (_result != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_result!, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
          if (_errorLines.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Rows not imported${_errorLines.length == 50 ? ' (first 50 shown)' : ''}:',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_errorLines.join('\n'), style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(
          onPressed: _importFromText,
          child: const Text('Import pasted rows'),
        ),
      ],
    );
  }
}

/// Small helper used by screens that need to copy CSV text to the clipboard.
Future<void> copyCsv(BuildContext context, String csv, String what) async {
  await Clipboard.setData(ClipboardData(text: csv));
  if (context.mounted) showMessage(context, '$what copied — paste into Excel');
}
