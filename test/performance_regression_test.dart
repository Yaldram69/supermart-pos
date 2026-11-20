import 'package:flutter_test/flutter_test.dart';
import 'package:supermart_pos/core/format.dart';
import 'package:supermart_pos/models.dart';
import 'package:supermart_pos/state/app_state.dart';

void main() {
  group('product filtering keeps the fast path accurate', () {
    final products = <PosProduct>[
      PosProduct({
        'id': 'p1',
        'name': 'Milk 1L',
        'barcode': '9001',
        'sku': 'MILK-1L',
        'category_name': 'Dairy',
        'unit': 'pcs',
        'sale_price': 100,
        'stock_qty': 12,
        'reorder_level': 5,
        'is_active': true,
      }),
      PosProduct({
        'id': 'p2',
        'name': 'Rice 5kg',
        'barcode': '9002',
        'sku': 'RICE-5',
        'category_name': 'Groceries',
        'unit': 'pcs',
        'sale_price': 250,
        'stock_qty': 2,
        'reorder_level': 5,
        'is_active': true,
      }),
    ];

    test('search matches product name, barcode and sku without case issues', () {
      final results = AppState.filterPosProducts(products, query: '9002');
      expect(results, hasLength(1));
      expect(results.first.id, 'p2');

      final byName = AppState.filterPosProducts(products, query: 'milk');
      expect(byName, hasLength(1));
      expect(byName.first.name, 'Milk 1L');
    });

    test('low-stock filter keeps only low inventory products', () {
      final results = AppState.filterPosProducts(products, filter: 'low');
      expect(results, hasLength(1));
      expect(results.single.id, 'p2');
    });

    test('category filter narrows the list while keeping the rest intact', () {
      final results = AppState.filterPosProducts(products, category: 'Dairy');
      expect(results, hasLength(1));
      expect(results.first.categoryName, 'Dairy');
    });

    test('cached catalogue lets startup continue when the connection is offline', () {
      expect(
        AppState.shouldAllowOfflineBoot(
          hasCachedCatalogue: true,
          error: AppError('OFFLINE', 'No connection to the server.'),
        ),
        isTrue,
      );
      expect(
        AppState.shouldAllowOfflineBoot(
          hasCachedCatalogue: false,
          error: AppError('OFFLINE', 'No connection to the server.'),
        ),
        isFalse,
      );
      expect(
        AppState.shouldAllowOfflineBoot(
          hasCachedCatalogue: true,
          error: AppError('BAD_SERVER_URL', 'Bad URL'),
        ),
        isFalse,
      );
    });
  });
}
