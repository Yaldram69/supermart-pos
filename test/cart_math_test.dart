// These tests pin down the till's arithmetic so it always agrees with what the
// server will charge. If you ever change pricing rules in the SQL, run:
//     flutter test
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:supermart_pos/core/app_config.dart';
import 'package:supermart_pos/core/format.dart';
import 'package:supermart_pos/models.dart';
import 'package:supermart_pos/screens/invoices_screen.dart';
import 'package:supermart_pos/screens/pos_screen.dart';
import 'package:supermart_pos/screens/products_screen.dart';
import 'package:supermart_pos/services/api.dart';
import 'package:supermart_pos/state/app_state.dart';

class _SignedInTestApi extends Api {
  _SignedInTestApi() : super(SupabaseClient('https://example.supabase.co', 'test-key'));

  @override
  bool get isSignedIn => true;

  @override
  void requireSignIn() {}

  @override
  Future<List<Map<String, dynamic>>> adminProducts({
    int offset = 0,
    int limit = 0,
    String? search,
    String? category,
    String? filter,
  }) async {
    return [
      {
        'id': 'p1',
        'cost_price': 80.0,
        'sale_price': 100.0,
        'stock_qty': 12,
        'is_active': true,
        'is_deleted': false,
      },
    ];
  }
}

class _NoRemoteSearchApi extends Api {
  _NoRemoteSearchApi() : super(SupabaseClient('https://example.supabase.co', 'test-key'));

  @override
  Future<List<Map<String, dynamic>>> adminProducts({
    int offset = 0,
    int limit = 0,
    String? search,
    String? category,
    String? filter,
  }) async {
    throw StateError('remote search should not run while catalogue is already loaded');
  }
}

class _RemoteFallbackSearchApi extends Api {
  _RemoteFallbackSearchApi() : super(SupabaseClient('https://example.supabase.co', 'test-key'));

  @override
  Future<List<Map<String, dynamic>>> adminProducts({
    int offset = 0,
    int limit = 0,
    String? search,
    String? category,
    String? filter,
  }) async {
    if (search == null || search.trim().isEmpty) {
      return [];
    }
    return [
      {
        'id': 'p2',
        'name': 'Bread',
        'barcode': '2002',
        'unit': 'pcs',
        'sale_price': 80,
        'cost_price': 55,
        'stock_qty': 18,
        'reorder_level': 2,
        'is_active': true,
        'is_deleted': false,
      },
    ];
  }
}

AppState makeState({double tax = 0, bool inclusive = false}) {
  final api = Api(SupabaseClient('https://example.supabase.co', 'test-key'));
  final state = AppState(api);
  state.store = StoreSettings({
    'name': 'Supermart',
    'currency_symbol': 'Rs',
    'tax_percent': tax,
    'tax_inclusive': inclusive,
    'allow_negative_stock': false,
  });
  return state;
}

PosProduct product(
  String id,
  double price, {
  double? tax,
  double stock = 100,
}) => PosProduct({
  'id': id,
  'name': 'Item $id',
  'barcode': '000$id',
  'unit': 'pcs',
  'sale_price': price,
  'tax_percent': tax,
  'stock_qty': stock,
  'reorder_level': 5,
  'is_active': true,
});

void main() {
  group('barcode scanning', () {
    test('normalizes scanner input before lookup', () {
      expect(AppState.normalizeBarcodeInput('  00012345\r '), '00012345');
      expect(AppState.normalizeBarcodeInput(' 12345\n'), '12345');
      expect(AppState.normalizeBarcodeInput('AB-1234'), 'AB1234');
    });

    test('findByBarcode resolves the common leading-zero and suffix cases', () {
      final state = makeState();
      state.catalogue = [
        PosProduct({
          'id': 'p1',
          'name': 'Milk',
          'barcode': '00012345',
          'unit': 'pcs',
          'sale_price': 120,
          'cost_price': 80,
          'stock_qty': 10,
          'reorder_level': 2,
          'is_active': true,
        }),
      ];

      expect(state.findByBarcode('12345')?.id, 'p1');
      expect(state.findByBarcode('00012345')?.id, 'p1');
    });

    test('normalizes barcode text case-insensitively before matching', () {
      final state = makeState();
      state.catalogue = [
        PosProduct({
          'id': 'p1',
          'name': 'Milk',
          'barcode': 'AbC-000123',
          'unit': 'pcs',
          'sale_price': 120,
          'cost_price': 80,
          'stock_qty': 10,
          'reorder_level': 2,
          'is_active': true,
        }),
      ];

      expect(AppState.normalizeBarcodeInput('ab-c000123'), 'ABC000123');
      expect(state.findByBarcode('abc000123')?.id, 'p1');
      expect(state.findByBarcode('000123')?.id, 'p1');
    });

    test('findByBarcode falls back to the cached product catalogue when stock rows are stale', () {
      final state = makeState();
      state.catalogue = [];
      state.productCatalogue = [
        PosProduct({
          'id': 'p-scan',
          'name': 'Rice',
          'barcode': '00098765',
          'unit': 'kg',
          'sale_price': 90,
          'cost_price': 60,
          'stock_qty': 25,
          'reorder_level': 5,
          'is_active': true,
        }),
      ];

      expect(state.findByBarcode('98765')?.id, 'p-scan');
      expect(state.findByBarcode('00098765')?.id, 'p-scan');
    });
  });

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      'device_name': 'Counter-1',
      'terminal_no': 1,
    });
    await AppConfig.load();
  });

  group('product search filters', () {
    test(
      'prioritizes prefix and word matches over arbitrary letter sequences',
      () {
        final products = [
          PosProduct({
            'id': 'p1',
            'name': 'Milk Powder',
            'barcode': '1001',
            'unit': 'pcs',
            'sale_price': 150,
            'cost_price': 100,
            'stock_qty': 12,
            'reorder_level': 2,
            'is_active': true,
          }),
          PosProduct({
            'id': 'p2',
            'name': 'Olpers Full Cream',
            'barcode': '1002',
            'unit': 'pcs',
            'sale_price': 160,
            'cost_price': 110,
            'stock_qty': 10,
            'reorder_level': 2,
            'is_active': true,
          }),
          PosProduct({
            'id': 'p3',
            'name': 'Olive Oil',
            'barcode': '1003',
            'unit': 'pcs',
            'sale_price': 220,
            'cost_price': 150,
            'stock_qty': 8,
            'reorder_level': 2,
            'is_active': true,
          }),
          PosProduct({
            'id': 'p4',
            'name': 'Trolley Wheels',
            'barcode': '1004',
            'unit': 'pcs',
            'sale_price': 350,
            'cost_price': 260,
            'stock_qty': 5,
            'reorder_level': 1,
            'is_active': true,
          }),
        ];

        final filtered = AppState.filterPosProducts(products, query: 'ol');

        expect(filtered.map((p) => p.name), ['Olive Oil', 'Olpers Full Cream']);
        expect(filtered.map((p) => p.name), isNot(contains('Trolley Wheels')));
      },
    );

    test('quantity-break pricing is applied to the cart payload and tooltip', () {
      final product = PosProduct({
        'id': 'p-tier',
        'name': 'Carton of Eggs',
        'barcode': '3001',
        'unit': 'pcs',
        'sale_price': 120,
        'cost_price': 80,
        'stock_qty': 30,
        'reorder_level': 5,
        'is_active': true,
        'price_tiers': [
          {'min_qty': 6, 'price': 110.0},
          {'min_qty': 12, 'price': 95.0},
        ],
      });

      final line = CartLine(product: product, qty: 12);

      expect(line.effectiveUnitPrice, 95.0);
      expect(line.toPayload()['unit_price'], 95.0);
      expect(productPriceTooltipMessage(product, 'Rs'), contains('12+'));
    });

    test(
      'includes all genuine substring matches while still ranking strong prefix hits first',
      () {
        final products = [
          PosProduct({
            'id': 'p1',
            'name': 'Alpha Olper',
            'barcode': '1101',
            'unit': 'pcs',
            'sale_price': 90,
            'cost_price': 70,
            'stock_qty': 4,
            'reorder_level': 1,
            'is_active': true,
          }),
          PosProduct({
            'id': 'p2',
            'name': 'Olpers Creamer',
            'barcode': '1102',
            'unit': 'pcs',
            'sale_price': 120,
            'cost_price': 90,
            'stock_qty': 5,
            'reorder_level': 1,
            'is_active': true,
          }),
          PosProduct({
            'id': 'p3',
            'name': 'Fresh Milk',
            'barcode': '1103',
            'unit': 'pcs',
            'sale_price': 110,
            'cost_price': 80,
            'stock_qty': 6,
            'reorder_level': 1,
            'is_active': true,
          }),
        ];

        final filtered = AppState.filterPosProducts(products, query: 'olper');

        expect(filtered.map((p) => p.name), ['Olpers Creamer', 'Alpha Olper']);
        expect(filtered.length, 2);
      },
    );

    test('uses the loaded catalogue for quick searches without hitting the server', () async {
      final state = AppState(_NoRemoteSearchApi());
      state.catalogue = [
        PosProduct({
          'id': 'p1',
          'name': 'Milk',
          'barcode': '1001',
          'unit': 'pcs',
          'sale_price': 100,
          'stock_qty': 12,
          'reorder_level': 2,
          'is_active': true,
        }),
      ];

      final results = await state.searchFull('milk', limit: 10);
      expect(results.map((p) => p.name), ['Milk']);
    });

    test('falls back to admin search when the cached catalogue is missing the item', () async {
      final state = AppState(_RemoteFallbackSearchApi());
      state.catalogue = [
        PosProduct({
          'id': 'p1',
          'name': 'Milk',
          'barcode': '1001',
          'unit': 'pcs',
          'sale_price': 100,
          'stock_qty': 12,
          'reorder_level': 2,
          'is_active': true,
        }),
      ];

      final results = await state.searchFull('bread', limit: 10);
      expect(results.map((p) => p.name), ['Bread']);
    });

    test('uses the cached product catalogue for fast local searches', () async {
      final state = AppState(_NoRemoteSearchApi());
      state.productCatalogue = [
        PosProduct({
          'id': 'p1',
          'name': 'Milk',
          'barcode': '1001',
          'unit': 'pcs',
          'sale_price': 100,
          'stock_qty': 12,
          'reorder_level': 2,
          'is_active': true,
        }),
      ];

      final results = state.searchProductCache('milk', limit: 10);
      expect(results.map((p) => p.name), ['Milk']);
    });

    test('re-hydrates missing cost prices even after a recent refresh', () async {
      final state = AppState(_SignedInTestApi());
      state.catalogue = [
        PosProduct({
          'id': 'p1',
          'name': 'Milk',
          'barcode': '1001',
          'unit': 'pcs',
          'sale_price': 100,
          'stock_qty': 12,
          'reorder_level': 2,
          'is_active': true,
        }),
      ];

      await state.hydrateActualCostsFromProducts(force: true);
      expect(state.catalogue.single.costPrice, 80.0);

      state.catalogue.first.raw['cost_price'] = 0;
      await state.hydrateActualCostsFromProducts();

      expect(state.catalogue.single.costPrice, 80.0);
    });
  });

  group('product category filters', () {
    test(
      'selecting a parent category includes items assigned to its subcategories',
      () {
        final fruitCategoryId = 'cat-fruit';
        final redApplesSubcategoryId = 'sub-red-apples';
        final products = [
          AdminProduct({
            'id': 'p1',
            'name': 'Red apples',
            'category_id': redApplesSubcategoryId,
            'category_name': 'Red apples',
            'stock_qty': 10,
            'reorder_level': 3,
            'cost_price': 40,
            'sale_price': 70,
            'stock_value': 400,
            'margin_percent': 42.8,
            'is_low_stock': false,
            'is_active': true,
          }),
          AdminProduct({
            'id': 'p2',
            'name': 'Banana',
            'category_id': fruitCategoryId,
            'category_name': 'Fruit',
            'stock_qty': 5,
            'reorder_level': 2,
            'cost_price': 20,
            'sale_price': 40,
            'stock_value': 100,
            'margin_percent': 50,
            'is_low_stock': false,
            'is_active': true,
          }),
          AdminProduct({
            'id': 'p3',
            'name': 'Milk',
            'category_id': 'cat-dairy',
            'category_name': 'Dairy',
            'stock_qty': 8,
            'reorder_level': 2,
            'cost_price': 60,
            'sale_price': 110,
            'stock_value': 480,
            'margin_percent': 45.5,
            'is_low_stock': false,
            'is_active': true,
          }),
        ];

        final filtered = AppState.filterAdminProducts(
          products,
          category: 'Fruit',
          categories: [
            {'id': fruitCategoryId, 'name': 'Fruit'},
          ],
          subcategories: [
            {
              'id': redApplesSubcategoryId,
              'parent_id': fruitCategoryId,
              'name': 'Red apples',
            },
          ],
        );

        expect(filtered.map((p) => p.id), containsAll(['p1', 'p2']));
        expect(filtered.map((p) => p.id), isNot(contains('p3')));
      },
    );
  });

  group('replacement adjustment math', () {
    test(
      'shows the net cash movement when a returned line is swapped for a new product',
      () {
        final returnedLine = SaleLine({
          'id': 'line-a',
          'name_snapshot': 'Milk 1L',
          'qty': 2,
          'refunded_qty': 0,
          'unit_price': 60,
          'line_discount': 0,
          'line_total': 120,
        });

        final replacement = PosProduct({
          'id': 'p-juice',
          'name': 'Orange Juice',
          'barcode': '1009',
          'unit': 'pcs',
          'sale_price': 90,
          'stock_qty': 15,
          'reorder_level': 3,
          'is_active': true,
        });

        final delta = InvoicesScreen.calculateReplacementDelta(
          returnedLine: returnedLine,
          returnedQty: 1,
          replacementProduct: replacement,
          replacementQty: 1,
        );

        expect(delta, 30);
      },
    );
  });

  group('miscellaneous cart lines', () {
    test(
      'a custom item can be added with a typed name, price and quantity',
      () {
        final s = makeState();
        final misc = PosProduct({
          'id': '',
          'name': 'Toffee',
          'barcode': '',
          'unit': 'pcs',
          'sale_price': 15,
          'cost_price': 0,
          'stock_qty': 0,
          'is_active': true,
          'is_misc_item': true,
        });

        final line = s.addToCart(misc, qty: 3)!;

        expect(s.cart.length, 1);
        expect(line.product.name, 'Toffee');
        expect(line.qty, 3);
        expect(line.gross, 45);
        expect(line.toPayload()['name'], 'Toffee');
        expect(line.toPayload()['unit'], 'pcs');
        expect(line.toPayload()['unit_price'], 15);
      },
    );

    test('custom item payload keeps the entered name in the sale line', () {
      final s = makeState();
      final misc = PosProduct({
        'id': '',
        'name': 'Bubbles',
        'barcode': '',
        'unit': 'pcs',
        'sale_price': 20,
        'cost_price': 0,
        'stock_qty': 0,
        'is_active': true,
        'is_misc_item': true,
      });

      final payload = s.addToCart(misc, qty: 2)!.toPayload();

      expect(payload['name_snapshot'], 'Bubbles');
      expect(payload['name'], 'Bubbles');
      expect(payload['qty'], 2);
      expect(payload['unit_price'], 20);
      expect(payload['line_discount'], isNull);
    });

    test('custom items do not count toward cart profit', () {
      final s = makeState();
      final regular = product('p1', 120);
      regular.raw['cost_price'] = 80;
      final misc = PosProduct({
        'id': '',
        'name': 'Toffee',
        'barcode': '',
        'unit': 'pcs',
        'sale_price': 20,
        'cost_price': 0,
        'stock_qty': 0,
        'is_active': true,
        'is_misc_item': true,
      });

      s.addToCart(regular, qty: 2);
      s.addToCart(misc, qty: 3);

      expect(s.subtotal, 300);
      expect(s.cartProfit, 80);
    });
  });

  group('cart arithmetic (must match create_sale in the database)', () {
    test('simple cart with no tax', () {
      final s = makeState();
      s.addToCart(product('a', 50), qty: 3);
      s.addToCart(product('b', 148), qty: 2);

      expect(s.subtotal, 446);
      expect(s.taxTotal, 0);
      expect(s.total, 446);
      expect(s.totalDiscount, 0);
    });

    test('scanning the same item twice stacks the quantity', () {
      final s = makeState();
      s.addToCart(product('a', 50));
      s.addToCart(product('a', 50));
      expect(s.cart.length, 1);
      expect(s.cart.first.qty, 2);
      expect(s.subtotal, 100);
    });

    test('tax added on top when the shelf price is tax exclusive', () {
      final s = makeState(tax: 5);
      s.addToCart(product('a', 100), qty: 2);
      expect(s.subtotal, 200);
      expect(s.taxTotal, 10);
      expect(s.total, 210);
    });

    test('per-product tax beats the store default', () {
      final s = makeState(tax: 5);
      s.addToCart(product('a', 100, tax: 0));
      expect(s.taxTotal, 0);
      expect(s.total, 100);
    });

    test('tax inclusive leaves the total alone', () {
      final s = makeState(tax: 17, inclusive: true);
      s.addToCart(product('a', 117));
      expect(s.subtotal, 117);
      expect(s.total, 117);
      expect(s.taxTotal, closeTo(17, 0.01));
    });

    test('percent discount off the whole bill', () {
      final s = makeState();
      s.addToCart(product('a', 100), qty: 10);
      s.setInvoiceDiscount('percent', 5);
      expect(s.total, 950);
      expect(s.totalDiscount, 50);
      expect(s.effectiveDiscountPercent, 5);
    });

    test('rupee discount cannot exceed the bill', () {
      final s = makeState();
      s.addToCart(product('a', 100));
      s.setInvoiceDiscount('amount', 500);
      expect(s.total, 0);
    });

    test('code discount uses the amount the server calculated', () {
      final s = makeState();
      s.addToCart(product('a', 148), qty: 10); // 1480
      s.setInvoiceDiscount(
        'code',
        10,
        code: 'EID10',
        label: 'EID10',
        amount: 148,
      );
      expect(s.total, 1332);
    });

    test(
      'line discount reduces the bill and counts towards the discount %',
      () {
        final s = makeState();
        final line = s.addToCart(product('a', 100), qty: 2)!;
        s.setLineDiscount(line, 20);
        expect(s.subtotal, 180);
        expect(s.lineDiscountTotal, 20);
        expect(s.effectiveDiscountPercent, closeTo(10, 0.01));
      },
    );

    test('quantity zero removes the line', () {
      final s = makeState();
      final line = s.addToCart(product('a', 100))!;
      s.setQty(line, 0);
      expect(s.cart, isEmpty);
      expect(s.total, 0);
    });

    test(
      'quantity tiers reduce the cart line and total when the threshold is met',
      () {
        final p = PosProduct({
          'id': 'tier-1',
          'name': 'Rice 10kg',
          'barcode': 'rice-10',
          'unit': 'bag',
          'sale_price': 150,
          'stock_qty': 30,
          'is_active': true,
          'price_tiers': [
            {'min_qty': 12, 'price': 130},
            {'min_qty': 20, 'price': 120},
          ],
        });

        final s = makeState();
        s.addToCart(p, qty: 20);

        expect(s.cart.first.effectiveUnitPrice, 120);
        expect(s.cart.first.gross, 2400);
        expect(s.subtotal, 2400);
        expect(s.total, 2400);
      },
    );

    test(
      'bulk buyer wholesale pricing is applied when the quantity threshold is reached',
      () {
        final p = PosProduct({
          'id': 'wholesale-1',
          'name': 'Bulk rice',
          'barcode': 'bulk-rice',
          'unit': 'bag',
          'sale_price': 170,
          'wholesale_price': 140,
          'wholesale_min_qty': 12,
          'stock_qty': 30,
          'is_active': true,
        });

        final s = makeState();
        s.addToCart(p, qty: 12);

        expect(s.cart.first.effectiveUnitPrice, 140);
        expect(s.cart.first.gross, 1680);
        expect(s.subtotal, 1680);
        expect(s.total, 1680);
      },
    );

    test('comma-formatted numeric inputs are accepted', () {
      expect(toD('7,000'), 7000);
      expect(toD('1,250.50'), 1250.5);
      expect(toD('25'), 25);
    });

    test('weighed goods convert between grams and rupees', () {
      final p = PosProduct({
        'id': 'flour',
        'name': 'Flour',
        'barcode': 'flour-1',
        'unit': 'kg',
        'sale_price': 100,
        'stock_qty': 20,
        'is_active': true,
        'is_weighed': true,
      });

      expect(p.priceForGrams(500), 50);
      expect(p.gramsForPrice(50), 500);
      expect(p.weightKgForPrice(50), closeTo(0.5, 0.0001));
    });

    test('clearing the cart resets discounts and customer', () {
      final s = makeState();
      s.addToCart(product('a', 100));
      s.setInvoiceDiscount('percent', 10);
      s.setCustomer(Customer({'id': 'c1', 'name': 'Ahmed'}));
      s.clearCart();
      expect(s.cart, isEmpty);
      expect(s.total, 0);
      expect(s.cartCustomer, isNull);
      expect(s.invDiscountType, 'none');
    });
  });

  group('cart price hover tooltip', () {
    test('cashier role can view cart price and profit hover details', () {
      final s = makeState();
      s.identity = Identity({'role': 'cashier', 'full_name': 'Cashier One'});

      expect(canViewCartPriceInsights(s), isTrue);
    });

    test('shows the actual cost price and shelf price in the tooltip', () {
      final p = PosProduct({
        'id': 'a',
        'name': 'Apple Kala Kulu',
        'unit': 'kg',
        'sale_price': 160,
        'cost_price': 130,
        'stock_qty': 37.423,
      });

      final line = CartLine(product: p, unitPrice: 160);
      final msg = priceTooltipMessage(line, 'Rs');

      expect(msg, contains('Actual cost price'));
      expect(msg, contains('Rs 130'));
      expect(msg, contains('Shelf price'));
      expect(msg, contains('Rs 160'));
    });

    test('subtotal hover shows the cart profit from cost vs selling price', () {
      final s = makeState();
      s.addToCart(
        PosProduct({
          'id': 'a',
          'name': 'A',
          'unit': 'pcs',
          'sale_price': 160,
          'cost_price': 140,
          'stock_qty': 10,
          'is_active': true,
        }),
        qty: 2,
      );
      s.addToCart(
        PosProduct({
          'id': 'b',
          'name': 'B',
          'unit': 'pcs',
          'sale_price': 200,
          'cost_price': 150,
          'stock_qty': 10,
          'is_active': true,
        }),
        qty: 6,
      );

      expect(s.cartProfit, 340);
      expect(s.subtotal, 160 * 2 + 200 * 6);
    });

    test(
      'fills missing cart product cost price from the admin product row',
      () {
        final s = makeState();
        final p = PosProduct({
          'id': 'prod-1',
          'name': 'Apple',
          'unit': 'kg',
          'sale_price': 160,
          'stock_qty': 10,
          'is_active': true,
        });
        s.catalogue = [p];
        s.byId['prod-1'] = p;

        s.applyCostPriceOverride(p, {'id': 'prod-1', 'cost_price': 130});
        final line = s.addToCart(p)!;

        expect(p.costPrice, 130);
        expect(line.product.costPrice, 130);
        expect(priceTooltipMessage(line, 'Rs'), contains('Rs 130'));
      },
    );
  });

  group('spreadsheet import parser', () {
    test('accepts common Excel headers and numeric values', () {
      final rows = parseProductImportRowsFromText(
        'Name, Barcode, Cost Price, Sale Price, Opening Stock\n'
        'Milk 1L, 9001, 120, 180, 12\n'
        'Rice 5kg, 9002, 330, 420, 18\n',
      );

      expect(rows, [
        {
          'name': 'Milk 1L',
          'barcode': '9001',
          'cost_price': 120.0,
          'sale_price': 180.0,
          'opening_stock': 12.0,
        },
        {
          'name': 'Rice 5kg',
          'barcode': '9002',
          'cost_price': 330.0,
          'sale_price': 420.0,
          'opening_stock': 18.0,
        },
      ]);
    });

    test('handles common supplier headers like description and pack size', () {
      final rows = parseProductImportRowsFromText(
        'Description, Barcode, Unit, Cost Price, Sale Price, Opening Stock\n'
        'Tomato Ketchup, 9003, 1 Bottle, 180, 240, 14\n'
        'Plain Flour, 9004, 5kg, 120, 160, 20\n',
      );

      expect(rows, [
        {
          'name': 'Tomato Ketchup',
          'barcode': '9003',
          'unit': '1 Bottle',
          'cost_price': 180.0,
          'sale_price': 240.0,
          'opening_stock': 14.0,
        },
        {
          'name': 'Plain Flour',
          'barcode': '9004',
          'unit': '5kg',
          'cost_price': 120.0,
          'sale_price': 160.0,
          'opening_stock': 20.0,
        },
      ]);
    });

    test('combines item name and variant name into one product name', () {
      final rows = parseProductImportRowsFromText(
        'CATEGORY,ITEM_TYPE,ITEM_NAME,VARIANT_NAME,PRICE,COST_PRICE,STOCK,BARCODE,SKU\n'
        'Bisket,Unit,Bisconni,Cocomo®10 24p,240,216.66,0,8859178707011,\n',
      );

      expect(rows.single['name'], 'Bisconni Cocomo®10 24p');
      expect(rows.single['unit'], 'Unit');
      expect(rows.single['category_name'], 'Bisket');
      expect(rows.single['barcode'], '8859178707011');
      expect(rows.single['cost_price'], 216.66);
      expect(rows.single['sale_price'], 240.0);
    });

    test(
      'uses item name as the subcategory when Excel provides category + item name',
      () {
        final rows = parseProductImportRowsFromText(
          'CATEGORY,ITEM_TYPE,ITEM_NAME,VARIANT_NAME,PRICE,COST_PRICE,STOCK,BARCODE,SKU\n'
          'Snacks,Unit,Noodles,Hot & Spicy,180,140,10,1234567890123,\n',
        );

        expect(rows.single['category_name'], 'Snacks');
        expect(rows.single['subcategory_name'], 'Noodles');
        expect(rows.single['name'], 'Noodles Hot & Spicy');
      },
    );

    test('accepts tab-delimited Excel rows and preserves category mapping', () {
      final rows = parseProductImportRowsFromText(
        'CATEGORY\tITEM_TYPE\tITEM_NAME\tVARIANT_NAME\tPRICE\tCOST_PRICE\tSTOCK\tBARCODE\tSKU\n'
        'Bisket\tUnit\tBisconni\tCocomo®10 24p\t240\t216.66\t0\t8859178707011\t\n',
      );

      expect(rows, isNotEmpty);
      expect(rows.single['category_name'], 'Bisket');
      expect(rows.single['name'], 'Bisconni Cocomo®10 24p');
      expect(rows.single['unit'], 'Unit');
      expect(rows.single['barcode'], '8859178707011');
      expect(rows.single['cost_price'], 216.66);
      expect(rows.single['sale_price'], 240.0);
    });

    test(
      'keeps category and supplier names available for real database persistence',
      () {
        final row = Api.prepareBulkImportRowForPersistence({
          'name': 'Milk 1L',
          'category_name': 'Dairy & Eggs',
          'supplier_name': 'Al-Karam Traders',
        });

        expect(row['category_name'], 'Dairy & Eggs');
        expect(row['supplier_name'], 'Al-Karam Traders');
        expect(row['category_name'] != '', isTrue);
        expect(row['supplier_name'] != '', isTrue);
      },
    );

    test('seed scripts do not create dummy category names', () async {
      final root = Directory.current.path;
      final seedSql = await File('$root/supabase/05_seed.sql').readAsString();
      final setupSql = await File(
        '$root/supabase/SUPERMART_SETUP.sql',
      ).readAsString();

      expect(seedSql.contains("('Grocery',1)"), isFalse);
      expect(setupSql.contains("('Grocery',1)"), isFalse);
    });
  });

  group('cart validation blocks broken product rows', () {
    test('blank product ids are rejected before checkout', () {
      final s = makeState();
      final broken = PosProduct({
        'id': '   ',
        'name': 'Broken item',
        'barcode': '999',
        'sale_price': 50,
        'stock_qty': 10,
      });

      expect(() => s.addToCart(broken), throwsA(isA<AppError>()));
      expect(s.cart, isEmpty);
    });

    test('raw stock rows with product_id still give a usable product id', () {
      final s = makeState();
      final p = PosProduct({
        'product_id': '6c8f3c6d-c7c9-4d90-bcf4-5d7a8c2d88ec',
        'name': 'Milk 1L',
        'barcode': '9001',
        'sale_price': 120,
        'stock_qty': 8,
      });

      expect(p.id, '6c8f3c6d-c7c9-4d90-bcf4-5d7a8c2d88ec');
      expect(() => s.addToCart(p), returnsNormally);
      expect(s.cart.single.product.id, p.id);
    });
  });

  group('barcode lookup tolerates real-world scanners', () {
    test('exact barcode', () {
      final s = makeState();
      final p = product('a', 50);
      s.catalogue = [p];
      s.byBarcode['8964000300015'] = p;
      expect(s.findByBarcode('8964000300015')?.id, 'a');
    });

    test('leading zeros from an older scanner are ignored', () {
      final s = makeState();
      final p = PosProduct({
        'id': 'a',
        'name': 'Lays',
        'barcode': '8964000300015',
        'sale_price': 50,
        'stock_qty': 10,
      });
      s.catalogue = [p];
      s.byBarcode['8964000300015'] = p;
      expect(s.findByBarcode('08964000300015')?.id, 'a');
    });

    test('unknown barcode returns null so the till can complain', () {
      final s = makeState();
      expect(s.findByBarcode('123'), isNull);
      expect(s.findByBarcode('   '), isNull);
    });

    test('search finds products by name and category', () {
      final s = makeState();
      s.catalogue = [
        PosProduct({
          'id': 'a',
          'name': 'Lays Masala 40g',
          'sale_price': 50,
          'category_name': 'Snacks',
        }),
        PosProduct({
          'id': 'b',
          'name': 'Sugar 1kg',
          'sale_price': 148,
          'category_name': 'Grocery',
        }),
      ];
      expect(s.search('lays').single.id, 'a');
      expect(s.search('grocery').single.id, 'b');
      expect(s.search('').length, 2);
    });
  });

  group('server errors are turned into words a cashier understands', () {
    test('stock refusal keeps the server wording', () {
      final e = AppError.parse(
        'INSUFFICIENT_STOCK|Lays Masala 40g — only 0 pkt in stock',
      );
      expect(e.code, 'INSUFFICIENT_STOCK');
      expect(e.message, contains('Lays Masala'));
      expect(e.isOffline, isFalse);
    });

    test('discount limit refusal', () {
      final e = AppError.parse(
        'DISCOUNT_LIMIT|That is a 20% discount but your limit is 5%.',
      );
      expect(e.code, 'DISCOUNT_LIMIT');
    });

    test('a dropped connection is recognised as offline', () {
      final e = AppError.parse(
        'SocketException: Failed host lookup: example.supabase.co',
      );
      expect(e.code, 'OFFLINE');
      expect(e.isOffline, isTrue);
    });

    test('wrong password reads properly', () {
      final e = AppError.parse('AuthException: Invalid login credentials');
      expect(e.message, 'Wrong email or password.');
    });
  });

  group('money formatting', () {
    test('rupees are grouped like a Pakistani shop expects', () {
      expect(money(1234567.5), 'Rs 1,234,567.5');
      expect(num2(446), '446');
      expect(num2(446.5), '446.5');
      expect(qtyStr(2.5), '2.5');
    });
  });
}
