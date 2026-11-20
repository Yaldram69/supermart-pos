// Offline changes laid over the shop data this till holds, so the till shows what
// it has been told even while the server cannot be reached. Every function here
// returns new lists and never changes the rows it is given.

/// Prefix of an id the till gives a customer or product made with no internet.
/// The server gives the real id when the change is sent.
const offlineIdPrefix = 'local-';

bool isLocalId(Object? id) => id is String && id.startsWith(offlineIdPrefix);

/// Local ids that have no server id yet.
List<String> unresolvedLocalIds(Iterable<Object?> ids, Map<String, String> known) => [
      for (final id in ids)
        if (isLocalId(id) && !known.containsKey(id)) id as String,
    ];

/// The payload with its local ids swapped for the server ids, where known.
Map<String, dynamic> remapSale(Map<String, dynamic> sale, Map<String, String> known) {
  String? real(Object? v) => v == null ? null : (known[v.toString()] ?? v.toString());
  final out = Map<String, dynamic>.from(sale);
  if (out['customer_id'] != null) out['customer_id'] = real(out['customer_id']);
  if (out['items'] is List) {
    out['items'] = [
      for (final item in out['items'] as List)
        {
          ...Map<String, dynamic>.from(item as Map),
          if (item['product_id'] != null) 'product_id': real(item['product_id']),
        },
    ];
  }
  return out;
}

/// Every local id a sale refers to (its customer and its products).
List<Object?> saleReferences(Map<String, dynamic> sale) => [
      sale['customer_id'],
      if (sale['items'] is List) for (final item in sale['items'] as List) (item as Map)['product_id'],
    ];

const _productFields = [
  'name', 'barcode', 'sku', 'unit', 'cost_price', 'sale_price', 'reorder_level', 'brand',
  'pack_size', 'shelf_location', 'plu_code', 'is_weighed', 'is_expiry_tracked',
  'country_of_origin', 'wholesale_price', 'wholesale_min_qty', 'tax_percent', 'expiry_date',
];

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;

String _productIdOf(Map<String, dynamic> row) => (row['product_id'] ?? row['id'] ?? '').toString();

/// Product rows (the till catalogue or the admin list) with the offline product
/// changes applied: new products, edits, removals and stock counts.
List<Map<String, dynamic>> overlayProducts(
  List<Map<String, dynamic>> rows, {
  required List<Map<String, dynamic>> ops,
  required Map<String, String> ids,
}) {
  final out = [for (final r in rows) Map<String, dynamic>.from(r)];
  for (final op in ops) {
    if (op['refused'] == true) continue;
    final p = (op['p'] as Map).cast<String, dynamic>();
    switch (op['op']) {
      case 'save_product':
        final key = (p['id'] ?? op['temp_id'])?.toString() ?? '';
        final id = ids[key] ?? key;
        final i = out.indexWhere((r) => _productIdOf(r) == id);
        final row = i >= 0
            ? out[i]
            : <String, dynamic>{'id': id, 'product_id': id, 'stock_qty': 0, 'is_active': true, 'is_deleted': false};
        for (final k in _productFields) {
          if (p.containsKey(k)) row[k] = p[k];
        }
        if (i < 0) row['stock_qty'] = _num(p['opening_stock']);
        if (i >= 0) {
          out[i] = row;
        } else {
          out.add(row);
        }
      case 'delete_product':
        final id = ids[(p['id'] ?? '').toString()] ?? (p['id'] ?? '').toString();
        out.removeWhere((r) => _productIdOf(r) == id);
      case 'adjust_stock':
        final id = ids[(p['id'] ?? '').toString()] ?? (p['id'] ?? '').toString();
        for (final r in out) {
          if (_productIdOf(r) == id) r['stock_qty'] = _num(p['new_qty']);
        }
    }
  }
  return out;
}

/// Product rows with the stock of every sale still waiting to send taken off, so
/// the shelves show what has already left.
List<Map<String, dynamic>> subtractQueuedSales(
  List<Map<String, dynamic>> rows, {
  required List<Map<String, dynamic>> sales,
  required Map<String, String> ids,
}) {
  final taken = <String, double>{};
  for (final sale in sales) {
    final items = sale['items'];
    if (items is! List) continue;
    for (final item in items) {
      final raw = (item as Map)['product_id']?.toString() ?? '';
      if (raw.isEmpty) continue;
      final id = ids[raw] ?? raw;
      taken[id] = (taken[id] ?? 0) + _num(item['qty']);
    }
  }
  if (taken.isEmpty) return rows;
  return [
    for (final r in rows)
      if (taken[_productIdOf(r)] == null)
        r
      else
        {...r, 'stock_qty': _num(r['stock_qty']) - taken[_productIdOf(r)]!},
  ];
}

/// Customer rows with the offline customer changes applied (edits and new customers).
List<Map<String, dynamic>> overlayCustomers(
  List<Map<String, dynamic>> rows, {
  required List<Map<String, dynamic>> ops,
  required Map<String, String> ids,
}) {
  final out = [for (final r in rows) Map<String, dynamic>.from(r)];
  for (final op in ops) {
    if (op['op'] != 'save_customer' || op['refused'] == true) continue;
    final p = (op['p'] as Map).cast<String, dynamic>();
    final key = (p['id'] ?? op['temp_id'])?.toString() ?? '';
    final id = ids[key] ?? key;
    final i = out.indexWhere((r) => r['id']?.toString() == id);
    final row = i >= 0
        ? out[i]
        : <String, dynamic>{'id': id, 'balance': 0, 'is_active': true};
    row.addAll(p);
    row['id'] = id;
    if (i >= 0) {
      out[i] = row;
    } else {
      out.add(row);
    }
  }
  return out;
}
