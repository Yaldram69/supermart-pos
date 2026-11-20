import 'package:flutter_test/flutter_test.dart';
import 'package:supermart_pos/state/offline_overlay.dart';

void main() {
  final base = <Map<String, dynamic>>[
    {'product_id': 'p1', 'name': 'Milk', 'sale_price': 180, 'stock_qty': 10, 'is_active': true, 'is_deleted': false},
    {'product_id': 'p2', 'name': 'Bread', 'sale_price': 80, 'stock_qty': 5, 'is_active': true, 'is_deleted': false},
  ];

  group('products', () {
    test('a product created offline appears with its temporary id and opening stock', () {
      final rows = overlayProducts(base, ops: [
        {
          'op': 'save_product',
          'p': {'name': 'Eggs', 'sale_price': 40, 'opening_stock': 12},
          'temp_id': 'local-1',
        },
      ], ids: {});
      final eggs = rows.firstWhere((r) => r['product_id'] == 'local-1');
      expect(eggs['name'], 'Eggs');
      expect(eggs['sale_price'], 40);
      expect(eggs['stock_qty'], 12);
      expect(rows.length, 3);
    });

    test('an edit changes only the fields it sends and leaves the base rows untouched', () {
      final rows = overlayProducts(base, ops: [
        {
          'op': 'save_product',
          'p': {'id': 'p1', 'name': 'Milk 1L', 'sale_price': 190},
        },
      ], ids: {});
      final milk = rows.firstWhere((r) => r['product_id'] == 'p1');
      expect(milk['name'], 'Milk 1L');
      expect(milk['sale_price'], 190);
      expect(milk['stock_qty'], 10);
      expect(base.first['name'], 'Milk');
    });

    test('an offline edit of a product that was created offline uses the server id once known', () {
      final rows = overlayProducts(base, ops: [
        {
          'op': 'save_product',
          'p': {'id': 'local-1', 'name': 'Eggs tray'},
        },
      ], ids: {'local-1': 'srv-9'});
      expect(rows.where((r) => r['product_id'] == 'srv-9').length, 1);
      expect(rows.where((r) => r['product_id'] == 'local-1'), isEmpty);
    });

    test('a removal and a stock count are applied', () {
      final rows = overlayProducts(base, ops: [
        {'op': 'delete_product', 'p': {'id': 'p2'}},
        {'op': 'adjust_stock', 'p': {'id': 'p1', 'new_qty': 7, 'reason': 'count'}},
      ], ids: {});
      expect(rows.map((r) => r['product_id']), ['p1']);
      expect(rows.first['stock_qty'], 7);
    });

    test('a refused change is not shown', () {
      final rows = overlayProducts(base, ops: [
        {'op': 'delete_product', 'p': {'id': 'p2'}, 'refused': true},
      ], ids: {});
      expect(rows.length, 2);
    });
  });

  group('stock of sales waiting to send', () {
    test('the quantities of queued sales are taken off the shelves', () {
      final rows = subtractQueuedSales(base, sales: [
        {
          'items': [
            {'product_id': 'p1', 'qty': 3},
            {'product_id': 'p1', 'qty': 2},
          ],
        },
      ], ids: {});
      expect(rows.firstWhere((r) => r['product_id'] == 'p1')['stock_qty'], 5);
      expect(rows.firstWhere((r) => r['product_id'] == 'p2')['stock_qty'], 5);
      expect(base.first['stock_qty'], 10);
    });
  });

  group('customers', () {
    final customers = <Map<String, dynamic>>[
      {'id': 'c1', 'name': 'Ali', 'phone': '0300', 'balance': 500},
    ];

    test('a new customer is added with a temporary id; an edit keeps the balance', () {
      final rows = overlayCustomers(customers, ops: [
        {'op': 'save_customer', 'p': {'name': 'Sana'}, 'temp_id': 'local-7'},
        {'op': 'save_customer', 'p': {'id': 'c1', 'phone': '0311'}},
      ], ids: {});
      expect(rows.length, 2);
      final ali = rows.firstWhere((r) => r['id'] == 'c1');
      expect(ali['phone'], '0311');
      expect(ali['balance'], 500);
      expect(rows.firstWhere((r) => r['id'] == 'local-7')['name'], 'Sana');
    });
  });

  group('sale references', () {
    test('a local id with no server id is reported; a known one is replaced', () {
      expect(unresolvedLocalIds(['local-1', 'srv-2', null], {}), ['local-1']);
      expect(unresolvedLocalIds(['local-1'], {'local-1': 'srv-1'}), isEmpty);
    });

    test('remapSale swaps local customer and product ids for the server ids', () {
      final sale = {
        'customer_id': 'local-c',
        'items': [
          {'product_id': 'local-p', 'qty': 1},
          {'name': 'Misc item', 'qty': 2},
        ],
      };
      final out = remapSale(sale, {'local-c': 'srv-c', 'local-p': 'srv-p'});
      expect(out['customer_id'], 'srv-c');
      expect((out['items'] as List)[0]['product_id'], 'srv-p');
      expect((out['items'] as List)[1].containsKey('product_id'), isFalse);
      expect(sale['customer_id'], 'local-c');
    });
  });
}
