import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermart_pos/core/app_config.dart';
import 'package:supermart_pos/core/reporting.dart';
import 'package:supermart_pos/models.dart';
import 'package:supermart_pos/state/app_state.dart';
import 'package:supermart_pos/widgets/receipt.dart';

void main() {
  test('previous report range keeps the same duration and moves earlier', () {
    final current = DateTimeRange(
      start: DateTime(2026, 9, 1),
      end: DateTime(2026, 9, 10),
    );

    final previous = previousPeriodRange(current);

    expect(previous.start, DateTime(2026, 8, 22));
    expect(previous.end, DateTime(2026, 8, 31));
    expect(previous.duration, current.duration);
  });

  test('delta text highlights positive and negative movement', () {
    expect(periodDeltaText(120, 100), '+20.0%');
    expect(periodDeltaText(80, 100), '-20.0%');
    expect(periodDeltaText(100, 0), 'new');
  });

  test('trend aggregation groups daily sales into weekly and monthly buckets', () {
    final daily = [
      {'day': '2026-09-01', 'sales': 100.0},
      {'day': '2026-09-02', 'sales': 200.0},
      {'day': '2026-09-30', 'sales': 300.0},
      {'day': '2026-10-01', 'sales': 400.0},
    ];

    final weekly = aggregateTrendByPeriod(daily, 'week');
    final monthly = aggregateTrendByPeriod(daily, 'month');

    expect(weekly.length, 2);
    expect(monthly.length, 2);
    expect(weekly.first.value, greaterThanOrEqualTo(0));
    expect(monthly.any((point) => point.label.contains('Sep') && point.value == 600), isTrue);
  });

  test('low-stock forecast estimates the number of days before re-order risk', () {
    final products = [
      PosProduct({'name': 'Rice', 'stock_qty': 15, 'reorder_level': 20, 'sale_price': 100}),
      PosProduct({'name': 'Soap', 'stock_qty': 4, 'reorder_level': 5, 'sale_price': 50}),
    ];
    final topProducts = [
      {'name': 'Rice', 'qty': 30.0, 'amount': 3000.0},
      {'name': 'Soap', 'qty': 10.0, 'amount': 500.0},
    ];

    final forecast = buildLowStockForecast(products, topProducts, days: 7);

    expect(forecast.length, 2);
    expect(forecast.first.productName, 'Soap');
    expect(forecast.first.daysLeft, lessThan(7));
  });

  test('inventory intelligence summarises risky stock clearly', () {
    final catalogue = [
      {'name': 'Rice', 'stock_qty': 15, 'reorder_level': 20},
      {'name': 'Soap', 'stock_qty': 4, 'reorder_level': 5},
      {'name': 'Tea', 'stock_qty': 0, 'reorder_level': 8},
      {'name': 'Salt', 'stock_qty': 25, 'reorder_level': 10},
    ];
    final lowStock = [
      {'name': 'Rice', 'stock_qty': 15, 'reorder_level': 20, 'suggested_order_qty': 10, 'cost_price': 80},
      {'name': 'Soap', 'stock_qty': 4, 'reorder_level': 5, 'suggested_order_qty': 20, 'cost_price': 30},
      {'name': 'Tea', 'stock_qty': 0, 'reorder_level': 8, 'suggested_order_qty': 18, 'cost_price': 40},
    ];

    final summary = buildInventoryHealthSummary(catalogue, lowStock);

    expect(summary.totalSkus, 4);
    expect(summary.lowStockCount, 2);
    expect(summary.outOfStockCount, 1);
    expect(summary.reorderValue, 10 * 80 + 20 * 30 + 18 * 40);
    expect(summary.riskRows.first.name, 'Tea');
  });

  test('purchase-order workflow summarises open spend and draft count', () {
    final orders = [
      {'po_no': 'PO-100', 'total': 1200.0, 'paid_amount': 0.0},
      {'po_no': 'PO-101', 'total': 800.0, 'paid_amount': 800.0},
    ];
    final drafts = [
      {'po_no': 'PO-102', 'total': 900.0, 'supplier_name': 'Mubashir Foods'},
      {'po_no': 'PO-103', 'total': 300.0, 'supplier_name': 'Fresh Grain'},
    ];

    final summary = buildPurchaseOrderSummary(orders, drafts);

    expect(summary.receivedCount, 2);
    expect(summary.openDraftCount, 2);
    expect(summary.totalOpenValue, 1200.0 + 900.0 + 300.0);
    expect(summary.supplierSpend.first.supplierName, 'Mubashir Foods');
  });

  test('cash management and accounting controls reconcile expected drawer cash', () {
    final summary = buildCashControlSummary(
      openingFloat: 500.0,
      cashSales: 1800.0,
      refunds: 100.0,
      expenses: 50.0,
      countedCash: 2200.0,
    );

    expect(summary.expectedInDrawer, 2150.0);
    expect(summary.variance, 50.0);
    expect(summary.controlStatus, 'over');
  });

  test('audit summary flags approval and stock exceptions without hiding normal activity', () {
    final rows = [
      {'action': 'sale.create'},
      {'action': 'override.pin'},
      {'action': 'stock.adjust'},
      {'action': 'stock.adjust'},
      {'action': 'sale.void'},
      {'action': 'return.create'},
      {'action': 'expense.save'},
    ];

    final summary = buildAuditSummary(rows);

    expect(summary.totalEntries, 7);
    expect(summary.pinApprovals, 1);
    expect(summary.stockAdjustments, 2);
    expect(summary.cancellations, 1);
    expect(summary.refunds, 1);
    expect(summary.complianceAlerts, isNotEmpty);
  });

  test('audit summary escalates repeated voids and refunds into control alerts', () {
    final rows = [
      {'action': 'sale.void'},
      {'action': 'sale.void'},
      {'action': 'sale.void'},
      {'action': 'return.create'},
      {'action': 'return.create'},
      {'action': 'return.create'},
    ];

    final summary = buildAuditSummary(rows);

    expect(summary.cancellations, 3);
    expect(summary.refunds, 3);
    expect(summary.complianceAlerts.any((alert) => alert.contains('voids') || alert.contains('refund')), isTrue);
  });

  test('quick actions surface the common work flows and hide admin-only screens for a cashier', () {
    final actions = buildQuickActions(
      hasOpenShift: true,
      isManager: false,
      isAdmin: false,
      isSuperAdmin: false,
    );

    expect(actions.map((item) => item.label).toList(), ['Billing', 'Close shift']);
    expect(actions.any((item) => item.label == 'Activity log'), isFalse);
  });

  test('keyboard shortcut guide names the fast POS flow for cashiers', () {
    final guide = buildKeyboardShortcutGuide();

    expect(guide.any((item) => item.key == 'F2' && item.action.contains('barcode')), isTrue);
    expect(guide.any((item) => item.key == 'F12' && item.action.contains('charge')), isTrue);
    expect(guide.length, greaterThanOrEqualTo(6));
  });

  test('store health dashboard summarises variance, open shifts and anomaly reasons', () {
    final dashboard = buildOperationalDashboardSummary(
      openingFloat: 1000,
      cashSales: 1600,
      refunds: 150,
      expenses: 100,
      countedCash: 2350,
      pendingOffline: 2,
      lowStockCount: 4,
      openShiftCount: 2,
      onlineDeviceCount: 3,
      totalDeviceCount: 4,
    );

    expect(dashboard.expectedCash, 2350);
    expect(dashboard.variance, 0);
    expect(dashboard.healthScore, greaterThan(0));
    expect(dashboard.reasons.any((reason) => reason.contains('offline')), isTrue);
    expect(dashboard.reasons.any((reason) => reason.contains('low stock')), isTrue);
  });

  test('catalogue search supports fuzzy matches and category narrow-downs', () {
    final products = [
      PosProduct({'id': 'p1', 'name': 'Pure Milk 1L', 'barcode': '12345', 'sku': 'MILK-1L', 'category_name': 'Dairy', 'sale_price': 120.0, 'stock_qty': 12, 'reorder_level': 5}),
      PosProduct({'id': 'p2', 'name': 'Rice Basmati 5kg', 'barcode': '67890', 'sku': 'RICE-5', 'category_name': 'Groceries', 'sale_price': 450.0, 'stock_qty': 18, 'reorder_level': 7}),
      PosProduct({'id': 'p3', 'name': 'Fresh Bread', 'barcode': '54321', 'sku': 'BREAD-1', 'category_name': 'Bakery', 'sale_price': 95.0, 'stock_qty': 9, 'reorder_level': 3}),
    ];

    final fuzzy = AppState.filterPosProducts(products, query: 'mlk1');
    final dairy = AppState.filterPosProducts(products, query: 'milk', category: 'Dairy');
    final groceries = AppState.filterPosProducts(products, query: 'rice', category: 'Groceries');

    expect(fuzzy.length, 1);
    expect(fuzzy.first.name, 'Pure Milk 1L');
    expect(dairy.length, 1);
    expect(groceries.length, 1);
  });

  test('offline queue reconciliation removes duplicate and invalid queued sales', () {
    final payloadA = {
      'client_uuid': 'sale-1',
      'payment_method': 'cash',
      'items': [
        {'product_id': 'p1', 'qty': 1, 'unit_price': 100.0},
      ],
    };

    final payloadB = {
      'client_uuid': 'sale-1',
      'payment_method': 'cash',
      'items': [
        {'product_id': 'p1', 'qty': 1, 'unit_price': 100.0},
      ],
    };

    final payloadC = {
      'client_uuid': 'sale-2',
      'payment_method': 'card',
      'items': <Map<String, dynamic>>[],
    };

    final result = AppConfig.reconcileQueue([payloadA, payloadB, payloadC]);

    expect(result.valid.length, 1);
    expect(result.valid.first['client_uuid'], 'sale-1');
    expect(result.duplicatesRemoved, 1);
    expect(result.invalidRemoved, 1);
  });

  test('permission policy locks sensitive cashier actions behind manager approval', () {
    final cashier = Identity({
      'role': 'cashier',
      'is_manager': false,
      'is_admin': false,
      'is_super_admin': false,
    });
    final manager = Identity({
      'role': 'manager',
      'is_manager': true,
      'is_admin': false,
      'is_super_admin': false,
    });
    final admin = Identity({
      'role': 'admin',
      'is_manager': false,
      'is_admin': true,
      'is_super_admin': false,
    });

    expect(cashier.permissions.canPerform('approve_discount'), isFalse);
    expect(cashier.permissions.canPerform('refund_sale'), isFalse);
    expect(cashier.permissions.canPerform('void_sale'), isFalse);
    expect(manager.permissions.canPerform('approve_discount'), isTrue);
    expect(admin.permissions.canPerform('refund_sale'), isTrue);
    expect(admin.permissions.canPerform('manage_staff'), isTrue);
  });

  test('payment mix summary calculates each method share and the leading channel', () {
    final rows = [
      {'method': 'cash', 'amount': 4000.0, 'invoices': 25},
      {'method': 'card', 'amount': 2500.0, 'invoices': 15},
      {'method': 'easypaisa', 'amount': 1500.0, 'invoices': 8},
    ];

    final summary = buildPaymentMixSummary(rows);

    expect(summary.totalSales, 8000.0);
    expect(summary.leadingMethod, 'Cash');
    expect(summary.methods.length, 3);
    expect(summary.methods.first.share, closeTo(50.0, 0.001));
  });

  test('automation summary aggregates low-stock, variance and profit alerts into one action list', () {
    final summary = buildAutomationSummary(
      lowStockRows: [
        {'name': 'Rice', 'stock_qty': 3, 'reorder_level': 20},
      ],
      cashierRows: [
        {'cashier': 'Ali', 'sales': 1200.0, 'expected': 1600.0},
      ],
      todaySales: 3800.0,
      previousSales: 5000.0,
      todayProfit: 950.0,
      previousProfit: 1550.0,
      pendingOffline: 3,
      lowStockCount: 1,
      backupDue: true,
    );

    expect(summary.totalAlerts, greaterThanOrEqualTo(4));
    expect(summary.alerts.any((alert) => alert.title.contains('low-stock')), isTrue);
    expect(summary.alerts.any((alert) => alert.title.contains('Profit')), isTrue);
    expect(summary.alerts.any((alert) => alert.title.contains('offline')), isTrue);
  });

  test('inventory intelligence calculates reorder suggestions, aging bands and dead-stock risk', () {
    final summary = buildInventoryIntelligenceSummary([
      {
        'name': 'Rice',
        'stock_qty': 12.0,
        'reorder_level': 20.0,
        'avg_daily_sales': 3.0,
        'lead_time_days': 5,
        'cost_price': 80.0,
        'supplier_name': 'Alpha Foods',
        'days_since_sale': 30,
      },
      {
        'name': 'Soap',
        'stock_qty': 0.0,
        'reorder_level': 8.0,
        'avg_daily_sales': 0.0,
        'lead_time_days': 7,
        'cost_price': 30.0,
        'supplier_name': 'Alpha Foods',
        'days_since_sale': 95,
      },
      {
        'name': 'Tea',
        'stock_qty': 30.0,
        'reorder_level': 10.0,
        'avg_daily_sales': 2.0,
        'lead_time_days': 4,
        'cost_price': 25.0,
        'supplier_name': 'Green Market',
        'days_since_sale': 15,
      },
    ]);

    expect(summary.reorderSuggestions.length, 2);
    expect(summary.reorderSuggestions.first.recommendedOrderQty, greaterThan(0));
    expect(summary.deadStock.length, 1);
    expect(summary.agingBands.any((band) => band.label.contains('90+') && band.count >= 1), isTrue);
  });

  test('stock action plan recommends reorder, markdown and expiry actions', () {
    final plan = buildStockActionPlan([
      {
        'name': 'Rice',
        'stock_qty': 8.0,
        'reorder_level': 20.0,
        'avg_daily_sales': 2.0,
        'lead_time_days': 5,
        'supplier_name': 'Alpha Foods',
        'days_since_sale': 15,
        'expiry_days': 18,
      },
      {
        'name': 'Soap',
        'stock_qty': 30.0,
        'reorder_level': 10.0,
        'avg_daily_sales': 0.1,
        'lead_time_days': 7,
        'supplier_name': 'Alpha Foods',
        'days_since_sale': 120,
        'expiry_days': 90,
      },
      {
        'name': 'Milk',
        'stock_qty': 12.0,
        'reorder_level': 6.0,
        'avg_daily_sales': 6.0,
        'lead_time_days': 2,
        'supplier_name': 'Blue Dairy',
        'days_since_sale': 5,
        'expiry_days': 5,
      },
    ], expiryAlertDays: 10);

    expect(plan.any((item) => item.action.contains('reorder') && item.severity == 'high'), isTrue);
    expect(plan.any((item) => item.action.contains('markdown') || item.action.contains('slow mover')), isTrue);
    expect(plan.any((item) => item.action.contains('expiry')), isTrue);
    expect(plan.length, greaterThanOrEqualTo(3));
  });

  test('receipt preview includes store branding and duplicate-copy indicator', () {
    final preview = ReceiptPrinter.buildPreviewData(
      sale: SaleResult({
        'invoice_no': 'INV-204',
        'subtotal': 160.0,
        'total': 175.0,
        'paid_amount': 175.0,
        'change_amount': 0.0,
        'payment_method': 'cash',
        'cashier_name': 'Ali',
        'customer_name': 'Walk-in',
        'device_name': 'Till 1',
        'created_at': '2026-10-01T12:30:00',
        'lines': [
          {'name_snapshot': 'Rice', 'qty': 2.0, 'unit_price': 80.0, 'line_total': 160.0, 'unit': 'kg'},
        ],
      }),
      store: StoreSettings({
        'name': 'Fresh Mart',
        'address': 'Main Road',
        'phone': '0300-1234567',
        'receipt_header': 'Thanks for shopping',
        'receipt_footer': 'See you again',
      }),
      reprint: true,
    );

    expect(preview.lines.any((line) => line.contains('Fresh Mart')), isTrue);
    expect(preview.lines.any((line) => line.contains('DUPLICATE COPY')), isTrue);
    expect(preview.lines.any((line) => line.contains('Thanks for shopping')), isTrue);
    expect(preview.lines.any((line) => line.contains('See you again')), isTrue);
  });

  test('product performance summary ranks best and weakest sellers by revenue and margin', () {
    final summary = buildProductPerformanceSummary([
      {'name': 'Rice', 'sales': 4000.0, 'profit': 1200.0, 'quantity': 180},
      {'name': 'Soap', 'sales': 1200.0, 'profit': 350.0, 'quantity': 90},
      {'name': 'Tea', 'sales': 500.0, 'profit': -80.0, 'quantity': 40},
      {'name': 'Milk', 'sales': 2100.0, 'profit': 900.0, 'quantity': 160},
    ]);

    expect(summary.length, 4);
    expect(summary.first.productName, 'Rice');
    expect(summary.last.productName, 'Tea');
    expect(summary.first.profit, greaterThan(summary.last.profit));
    expect(summary.first.marginPercent, greaterThanOrEqualTo(summary.last.marginPercent));
  });
}
