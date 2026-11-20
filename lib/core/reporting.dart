import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/format.dart';
import '../models.dart';

DateTimeRange previousPeriodRange(DateTimeRange currentRange) {
  final duration = currentRange.end.difference(currentRange.start);
  final previousEnd = currentRange.start.subtract(const Duration(days: 1));
  final previousStart = previousEnd.subtract(duration);
  return DateTimeRange(start: previousStart, end: previousEnd);
}

String periodDeltaText(num current, num previous) {
  if (current == previous) return 'flat';
  if (previous == 0) return current > 0 ? 'new' : 'flat';

  final delta = ((current - previous) / previous) * 100;
  final sign = delta >= 0 ? '+' : '-';
  final amount = delta.abs().toStringAsFixed(1);
  return '$sign$amount%';
}

class TrendPoint {
  const TrendPoint({required this.label, required this.value});

  final String label;
  final double value;
}

class CategoryMarginInsight {
  const CategoryMarginInsight({
    required this.category,
    required this.revenue,
    required this.estimatedMargin,
    required this.marginPercent,
  });

  final String category;
  final double revenue;
  final double estimatedMargin;
  final double marginPercent;
}

class ProductPerformanceInsight {
  const ProductPerformanceInsight({
    required this.productName,
    required this.sales,
    required this.profit,
    required this.quantity,
    required this.marginPercent,
  });

  final String productName;
  final double sales;
  final double profit;
  final double quantity;
  final double marginPercent;
}

class ForecastRiskRow {
  const ForecastRiskRow({
    required this.productName,
    required this.stockQty,
    required this.reorderLevel,
    required this.daysLeft,
    required this.dailyVelocity,
  });

  final String productName;
  final double stockQty;
  final double reorderLevel;
  final double daysLeft;
  final double dailyVelocity;
}

class InventoryHealthRow {
  const InventoryHealthRow({
    required this.name,
    required this.stockQty,
    required this.reorderLevel,
    required this.coverageRatio,
    required this.suggestedOrderQty,
  });

  final String name;
  final double stockQty;
  final double reorderLevel;
  final double coverageRatio;
  final double suggestedOrderQty;
}

class InventoryHealthSummary {
  const InventoryHealthSummary({
    required this.totalSkus,
    required this.lowStockCount,
    required this.outOfStockCount,
    required this.reorderValue,
    required this.riskRows,
  });

  final int totalSkus;
  final int lowStockCount;
  final int outOfStockCount;
  final double reorderValue;
  final List<InventoryHealthRow> riskRows;
}

class OperationalDashboardSummary {
  const OperationalDashboardSummary({
    required this.onlineDeviceCount,
    required this.totalDeviceCount,
    required this.openShiftCount,
    required this.pendingOffline,
    required this.lowStockCount,
    required this.expectedCash,
    required this.countedCash,
    required this.variance,
    required this.status,
    required this.healthScore,
    required this.reasons,
  });

  final int onlineDeviceCount;
  final int totalDeviceCount;
  final int openShiftCount;
  final int pendingOffline;
  final int lowStockCount;
  final double expectedCash;
  /// Null until a drawer count exists (see [buildOperationalDashboardSummary]).
  final double? countedCash;
  final double variance;
  final String status;
  final int healthScore;
  final List<String> reasons;
}

class InventoryReorderSuggestion {
  const InventoryReorderSuggestion({
    required this.productName,
    required this.supplierName,
    required this.stockQty,
    required this.reorderLevel,
    required this.avgDailySales,
    required this.leadTimeDays,
    required this.recommendedOrderQty,
    required this.coverageDays,
    required this.urgency,
  });

  final String productName;
  final String supplierName;
  final double stockQty;
  final double reorderLevel;
  final double avgDailySales;
  final int leadTimeDays;
  final double recommendedOrderQty;
  final double coverageDays;
  final String urgency;
}

class InventoryAgingBand {
  const InventoryAgingBand({
    required this.label,
    required this.count,
    required this.value,
  });

  final String label;
  final int count;
  final double value;
}

class StockActionItem {
  const StockActionItem({
    required this.productName,
    required this.action,
    required this.reason,
    required this.severity,
    required this.stockQty,
    required this.reorderLevel,
    required this.daysSinceSale,
    required this.expiryDays,
    required this.supplierName,
  });

  final String productName;
  final String action;
  final String reason;
  final String severity;
  final double stockQty;
  final double reorderLevel;
  final int daysSinceSale;
  final int expiryDays;
  final String supplierName;
}

class SupplierPriceComparison {
  const SupplierPriceComparison({
    required this.supplierName,
    required this.avgCost,
    required this.productCount,
  });

  final String supplierName;
  final double avgCost;
  final int productCount;
}

class InventoryIntelligenceSummary {
  const InventoryIntelligenceSummary({
    required this.reorderSuggestions,
    required this.agingBands,
    required this.deadStock,
    required this.supplierComparison,
  });

  final List<InventoryReorderSuggestion> reorderSuggestions;
  final List<InventoryAgingBand> agingBands;
  final List<Map<String, dynamic>> deadStock;
  final List<SupplierPriceComparison> supplierComparison;
}

double _inventoryDouble(Map<String, dynamic> row, List<String> keys, {double fallback = 0}) {
  for (final key in keys) {
    final value = row[key];
    if (value != null) return toD(value);
  }
  return fallback;
}

int _inventoryInt(Map<String, dynamic> row, List<String> keys, {int fallback = 0}) {
  for (final key in keys) {
    final value = row[key];
    if (value != null) return toD(value).toInt();
  }
  return fallback;
}

InventoryIntelligenceSummary buildInventoryIntelligenceSummary(List<Map<String, dynamic>> rows) {
  final suggestions = <InventoryReorderSuggestion>[];
  final deadStock = <Map<String, dynamic>>[];
  final agingCounts = <String, int>{
    '0-30 days': 0,
    '31-60 days': 0,
    '61-90 days': 0,
    '90+ days': 0,
  };
  final agingValue = <String, double>{
    '0-30 days': 0,
    '31-60 days': 0,
    '61-90 days': 0,
    '90+ days': 0,
  };
  final supplierTotals = <String, List<double>>{};

  for (final row in rows) {
    final name = (row['name'] ?? row['product_name'] ?? 'Unknown product').toString();
    final stock = _inventoryDouble(row, const ['stock_qty', 'qty_on_hand', 'available_qty']);
    final reorder = _inventoryDouble(row, const ['reorder_level', 'restock_level', 'minimum_stock']);
    final avgDailySales = _inventoryDouble(row, const ['avg_daily_sales', 'avg_sold_per_day', 'sales_velocity'], fallback: reorder > 0 ? reorder / 7 : 0);
    final leadTimeDays = _inventoryInt(row, const ['lead_time_days', 'lead_time', 'days_to_arrival', 'delivery_days'], fallback: 7);
    final cost = _inventoryDouble(row, const ['cost_price', 'purchase_cost', 'avg_cost']);
    final supplier = (row['supplier_name'] ?? row['supplier'] ?? 'General supplier').toString();
    final daysSinceSale = _inventoryInt(row, const ['days_since_sale', 'days_idle', 'days_since_last_sale'], fallback: 0);

    if (supplier.isNotEmpty) {
      supplierTotals.putIfAbsent(supplier, () => []).add(cost);
    }

    final coverageDays = avgDailySales > 0 ? stock / avgDailySales : 0.0;
    final leadTimeDemand = avgDailySales * leadTimeDays;
    final reorderThreshold = reorder + leadTimeDemand;
    final recommendedQty = (leadTimeDemand + (reorder - stock).clamp(0.0, double.infinity)).clamp(0.0, double.infinity).toDouble();

    if (stock <= 0 || stock <= reorder || stock <= reorderThreshold) {
      suggestions.add(InventoryReorderSuggestion(
        productName: name,
        supplierName: supplier,
        stockQty: stock,
        reorderLevel: reorder,
        avgDailySales: avgDailySales,
        leadTimeDays: leadTimeDays,
        recommendedOrderQty: recommendedQty > 0 ? recommendedQty : (reorder - stock).clamp(0.0, double.infinity).toDouble(),
        coverageDays: coverageDays.toDouble(),
        urgency: stock <= 0 ? 'Critical' : stock <= reorder ? 'High' : 'Medium',
      ));
    }

    final segment = daysSinceSale <= 30
        ? '0-30 days'
        : daysSinceSale <= 60
            ? '31-60 days'
            : daysSinceSale <= 90
                ? '61-90 days'
                : '90+ days';
    agingCounts[segment] = (agingCounts[segment] ?? 0) + 1;
    agingValue[segment] = (agingValue[segment] ?? 0) + stock * cost;

    if (daysSinceSale >= 90 || (stock > 0 && avgDailySales <= 0.1 && daysSinceSale >= 60)) {
      deadStock.add({
        'name': name,
        'stock_qty': stock,
        'days_since_sale': daysSinceSale,
        'supplier': supplier,
        'value': stock * cost,
      });
    }
  }

  final agingBands = agingCounts.entries
      .map((entry) => InventoryAgingBand(
            label: entry.key,
            count: entry.value,
            value: agingValue[entry.key] ?? 0,
          ))
      .toList();

  final supplierComparison = supplierTotals.entries
      .map((entry) => SupplierPriceComparison(
            supplierName: entry.key,
            avgCost: entry.value.fold<double>(0, (sum, value) => sum + value) / entry.value.length,
            productCount: entry.value.length,
          ))
      .toList()
    ..sort((a, b) => a.avgCost.compareTo(b.avgCost));

  suggestions.sort((a, b) { 
    final urgencyOrder = {'Critical': 0, 'High': 1, 'Medium': 2};
    final byUrgency = urgencyOrder[a.urgency]!.compareTo(urgencyOrder[b.urgency]!);
    if (byUrgency != 0) return byUrgency;
    return b.recommendedOrderQty.compareTo(a.recommendedOrderQty);
  });

  return InventoryIntelligenceSummary(
    reorderSuggestions: suggestions.take(8).toList(),
    agingBands: agingBands,
    deadStock: deadStock,
    supplierComparison: supplierComparison,
  );
}

List<StockActionItem> buildStockActionPlan(
  List<Map<String, dynamic>> rows, {
  int expiryAlertDays = 10,
}) {
  final actionPlan = <StockActionItem>[];

  for (final row in rows) {
    final name = (row['name'] ?? row['product_name'] ?? 'Unknown product').toString();
    final stock = _inventoryDouble(row, const ['stock_qty', 'qty_on_hand', 'available_qty']);
    final reorder = _inventoryDouble(row, const ['reorder_level', 'restock_level', 'minimum_stock']);
    final avgDailySales = _inventoryDouble(
      row,
      const ['avg_daily_sales', 'avg_sold_per_day', 'sales_velocity'],
      fallback: reorder > 0 ? reorder / 7 : 0,
    );
    final supplier = (row['supplier_name'] ?? row['supplier'] ?? 'General supplier').toString();
    final daysSinceSale = _inventoryInt(row, const ['days_since_sale', 'days_idle', 'days_since_last_sale'], fallback: 0);
    final expiryDays = _inventoryInt(row, const ['expiry_days', 'days_to_expiry', 'days_until_expiry', 'expires_in'], fallback: 9999);

    if (stock <= 0 || stock <= reorder) {
      // Any item at or under its reorder point is high priority (the shop's rule,
      // covered by the reporting tests), whether it is out of stock or just low.
      const severity = 'high';
      final action = stock <= 0
          ? 'reorder immediately: $name is out of stock'
          : 'reorder soon: $name is below its reorder point';
      final reason = stock <= 0
          ? 'stock is $stock and the reorder level is $reorder.'
          : 'stock is $stock against a reorder level of $reorder and a lead time of ${_inventoryInt(row, const ['lead_time_days', 'lead_time', 'days_to_arrival', 'delivery_days'], fallback: 7)} days.';
      actionPlan.add(StockActionItem(
        productName: name,
        action: action,
        reason: reason,
        severity: severity,
        stockQty: stock,
        reorderLevel: reorder,
        daysSinceSale: daysSinceSale,
        expiryDays: expiryDays,
        supplierName: supplier,
      ));
    }

    if (daysSinceSale >= 90 || (stock > 0 && avgDailySales <= 0.1 && daysSinceSale >= 60)) {
      actionPlan.add(StockActionItem(
        productName: name,
        action: 'markdown / slow mover action for $name',
        reason: 'it has been idle for $daysSinceSale days with only ${avgDailySales.toStringAsFixed(1)} units/day selling.',
        severity: daysSinceSale >= 120 ? 'high' : 'medium',
        stockQty: stock,
        reorderLevel: reorder,
        daysSinceSale: daysSinceSale,
        expiryDays: expiryDays,
        supplierName: supplier,
      ));
    }

    if (expiryDays <= expiryAlertDays && expiryDays >= 0 && stock > 0) {
      actionPlan.add(StockActionItem(
        productName: name,
        action: 'expiry alert: $name is close to expiry',
        reason: 'only $expiryDays days remain before expiry; review markdown, first-in-first-out, and promotion actions.',
        severity: expiryDays <= expiryAlertDays ~/ 2 ? 'high' : 'medium',
        stockQty: stock,
        reorderLevel: reorder,
        daysSinceSale: daysSinceSale,
        expiryDays: expiryDays,
        supplierName: supplier,
      ));
    }
  }

  actionPlan.sort((a, b) {
    const priority = {'high': 0, 'medium': 1, 'low': 2};
    final bySeverity = priority[a.severity]!.compareTo(priority[b.severity]!);
    if (bySeverity != 0) return bySeverity;
    if (a.expiryDays != b.expiryDays) return a.expiryDays.compareTo(b.expiryDays);
    return a.daysSinceSale.compareTo(b.daysSinceSale);
  });

  return actionPlan;
}

class SupplierPurchaseSpend {
  const SupplierPurchaseSpend({
    required this.supplierName,
    required this.total,
  });

  final String supplierName;
  final double total;
}

class PurchaseOrderSummary {
  const PurchaseOrderSummary({
    required this.receivedCount,
    required this.openDraftCount,
    required this.totalOpenValue,
    required this.supplierSpend,
  });

  final int receivedCount;
  final int openDraftCount;
  final double totalOpenValue;
  final List<SupplierPurchaseSpend> supplierSpend;
}

class CashControlSummary {
  const CashControlSummary({
    required this.openingFloat,
    required this.cashSales,
    required this.refunds,
    required this.expenses,
    required this.expectedInDrawer,
    required this.countedCash,
    required this.variance,
    required this.controlStatus,
  });

  final double openingFloat;
  final double cashSales;
  final double refunds;
  final double expenses;
  final double expectedInDrawer;
  final double countedCash;
  final double variance;
  final String controlStatus;
}

class AuditSummary {
  const AuditSummary({
    required this.totalEntries,
    required this.pinApprovals,
    required this.stockAdjustments,
    required this.cancellations,
    required this.refunds,
    required this.complianceAlerts,
  });

  final int totalEntries;
  final int pinApprovals;
  final int stockAdjustments;
  final int cancellations;
  final int refunds;
  final List<String> complianceAlerts;
}

class PaymentMixEntry {
  const PaymentMixEntry({
    required this.method,
    required this.label,
    required this.amount,
    required this.invoices,
    required this.share,
  });

  final String method;
  final String label;
  final double amount;
  final int invoices;
  final double share;
}

class PaymentMixSummary {
  const PaymentMixSummary({
    required this.totalSales,
    required this.methods,
    required this.leadingMethod,
    required this.leadingShare,
  });

  final double totalSales;
  final List<PaymentMixEntry> methods;
  final String leadingMethod;
  final double leadingShare;
}

String _paymentMethodLabel(String method) {
  switch (method.toLowerCase()) {
    case 'cash':
      return 'Cash';
    case 'card':
      return 'Card';
    case 'jazzcash':
      return 'JazzCash';
    case 'easypaisa':
      return 'Easypaisa';
    case 'bank_transfer':
      return 'Bank transfer';
    case 'credit':
      return 'Udhaar';
    default:
      return method.isEmpty ? 'Unknown' : method[0].toUpperCase() + method.substring(1);
  }
}

PaymentMixSummary buildPaymentMixSummary(List<Map<String, dynamic>> rows) {
  final byMethod = <String, Map<String, dynamic>>{};
  for (final row in rows) {
    final rawMethod = (row['method'] ?? row['payment_method'] ?? '').toString();
    final key = rawMethod.trim();
    if (key.isEmpty) continue;
    final current = byMethod.putIfAbsent(key, () => {'method': key, 'amount': 0.0, 'invoices': 0});
    current['amount'] = toD(current['amount']) + toD(row['amount']);
    current['invoices'] = toD(current['invoices']) + toD(row['invoices']);
  }

  final methods = byMethod.values
      .map((row) {
        final amount = toD(row['amount']);
        return PaymentMixEntry(
          method: (row['method'] ?? '').toString(),
          label: _paymentMethodLabel((row['method'] ?? '').toString()),
          amount: amount,
          invoices: toD(row['invoices']).toInt(),
          share: 0,
        );
      })
      .toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));

  final totalSales = methods.fold<double>(0, (sum, item) => sum + item.amount);
  final normalized = methods
      .map((entry) => PaymentMixEntry(
            method: entry.method,
            label: entry.label,
            amount: entry.amount,
            invoices: entry.invoices,
            share: totalSales > 0 ? (entry.amount / totalSales) * 100 : 0,
          ))
      .toList();

  final leadingMethod = normalized.isEmpty ? 'Cash' : normalized.first.label;
  final leadingShare = normalized.isEmpty ? 0.0 : normalized.first.share;

  return PaymentMixSummary(
    totalSales: totalSales,
    methods: normalized,
    leadingMethod: leadingMethod,
    leadingShare: leadingShare,
  );
}

class AutomationAlert {
  const AutomationAlert({
    required this.title,
    required this.message,
    required this.severity,
  });

  final String title;
  final String message;
  final String severity;
}

class AutomationSummary {
  const AutomationSummary({
    required this.totalAlerts,
    required this.alerts,
    required this.highPriorityCount,
  });

  final int totalAlerts;
  final List<AutomationAlert> alerts;
  final int highPriorityCount;
}

AutomationSummary buildAutomationSummary({
  required List<Map<String, dynamic>> lowStockRows,
  required List<Map<String, dynamic>> cashierRows,
  required double todaySales,
  required double previousSales,
  required double todayProfit,
  required double previousProfit,
  required int pendingOffline,
  required int lowStockCount,
  bool backupDue = false,
}) {
  final alerts = <AutomationAlert>[];

  if (lowStockCount > 0 || lowStockRows.isNotEmpty) {
    alerts.add(AutomationAlert(
      title: 'low-stock alert',
      message: lowStockCount > 0
          ? '$lowStockCount products are below reorder points or out of stock.'
          : '${lowStockRows.length} products need attention before the next delivery.',
      severity: 'high',
    ));
  }

  final salesDelta = previousSales > 0 ? ((todaySales - previousSales) / previousSales) * 100 : 0;
  final profitDelta = previousProfit > 0 ? ((todayProfit - previousProfit) / previousProfit) * 100 : 0;
  if (previousSales > 0 && salesDelta < -15) {
    alerts.add(AutomationAlert(
      title: 'Sales dip alert',
      message: 'Sales are down ${salesDelta.abs().toStringAsFixed(1)}% versus the prior period.',
      severity: 'medium',
    ));
  }
  if (previousProfit > 0 && profitDelta < -15) {
    alerts.add(AutomationAlert(
      title: 'Profit drop alert',
      message: 'Profit is down ${profitDelta.abs().toStringAsFixed(1)}% versus the prior period.',
      severity: 'high',
    ));
  }

  final varianceRows = cashierRows.where((row) {
    final sales = toD(row['sales']);
    final expected = toD(row['expected']);
    return expected > 0 && sales < expected * 0.85;
  }).toList();
  if (varianceRows.isNotEmpty) {
    alerts.add(AutomationAlert(
      title: 'Cashier variance alert',
      message: '${varianceRows.length} cashier(s) are materially below their expected performance.',
      severity: 'medium',
    ));
  }

  if (pendingOffline > 0) {
    alerts.add(AutomationAlert(
      title: 'offline queue alert',
      message: '$pendingOffline sale(s) are queued and need to sync before the next cycle.',
      severity: 'high',
    ));
  }

  if (backupDue) {
    alerts.add(AutomationAlert(
      title: 'Backup reminder',
      message: 'A database backup is due and should be created before the next trading day.',
      severity: 'medium',
    ));
  }

  if (alerts.isEmpty) {
    alerts.add(AutomationAlert(
      title: 'No action needed',
      message: 'The store is running normally and no alerts are active right now.',
      severity: 'low',
    ));
  }

  final highPriorityCount = alerts.where((alert) => alert.severity == 'high').length;

  return AutomationSummary(
    totalAlerts: alerts.length,
    alerts: alerts,
    highPriorityCount: highPriorityCount,
  );
}

class QuickActionItem {
  const QuickActionItem({
    required this.label,
    required this.icon,
    required this.target,
    required this.priority,
    this.visible = true,
  });

  final String label;
  final IconData icon;
  final String target;
  final int priority;
  final bool visible;
}

class KeyboardShortcutGuideItem {
  const KeyboardShortcutGuideItem({
    required this.key,
    required this.action,
    required this.description,
  });

  final String key;
  final String action;
  final String description;
}

List<KeyboardShortcutGuideItem> buildKeyboardShortcutGuide() {
  return const [
    KeyboardShortcutGuideItem(key: 'F2', action: 'barcode', description: 'focus the barcode scanner field'),
    KeyboardShortcutGuideItem(key: 'F4', action: 'customer', description: 'pick a customer for the current bill'),
    KeyboardShortcutGuideItem(key: 'F6', action: 'discount', description: 'apply an invoice discount'),
    KeyboardShortcutGuideItem(key: 'F8', action: 'hold', description: 'save the current bill for later'),
    KeyboardShortcutGuideItem(key: 'F9', action: 'resume', description: 'open a previously held bill'),
    KeyboardShortcutGuideItem(key: 'F12', action: 'charge', description: 'complete the sale and take payment'),
    KeyboardShortcutGuideItem(key: 'Esc', action: 'clear search', description: 'reset the product search box'),
  ];
}

List<QuickActionItem> buildQuickActions({
  required bool hasOpenShift,
  required bool isManager,
  required bool isAdmin,
  required bool isSuperAdmin,
}) {
  final actions = <QuickActionItem>[
    const QuickActionItem(
      label: 'Billing',
      icon: Icons.point_of_sale,
      target: 'billing',
      priority: 0,
    ),
    QuickActionItem(
      label: hasOpenShift ? 'Close shift' : 'Open shift',
      icon: hasOpenShift ? Icons.lock_outline : Icons.lock_open_outlined,
      target: 'shift',
      priority: 1,
    ),
    const QuickActionItem(
      label: 'Products',
      icon: Icons.inventory_2_outlined,
      target: 'products',
      priority: 2,
      visible: true,
    ),
    const QuickActionItem(
      label: 'Stock',
      icon: Icons.warehouse_outlined,
      target: 'stock',
      priority: 3,
      visible: true,
    ),
    const QuickActionItem(
      label: 'Reports',
      icon: Icons.insights,
      target: 'reports',
      priority: 4,
      visible: true,
    ),
  ];

  if (!(isManager || isAdmin || isSuperAdmin)) {
    return actions.where((a) => a.label != 'Products' && a.label != 'Stock' && a.label != 'Reports').toList();
  }

  return actions..sort((a, b) => a.priority.compareTo(b.priority));
}

String _trendLabel(DateTime date, String period) {
  switch (period) {
    case 'week':
      return DateFormat('MMM d').format(date);
    case 'month':
      return DateFormat('MMM').format(date);
    case 'day':
    default:
      return DateFormat('d').format(date);
  }
}

double _numericValueFromRow(Map<String, dynamic> row, List<String> candidates) {
  for (final key in candidates) {
    final value = row[key];
    if (value != null) return toD(value);
  }
  return 0;
}

List<TrendPoint> aggregateTrendByPeriod(List<Map<String, dynamic>> source, String period) {
  final buckets = <DateTime, double>{};

  for (final row in source) {
    final rawDate = row['day'] ?? row['d'] ?? row['date'] ?? row['label'];
    final parsed = DateTime.tryParse(rawDate?.toString() ?? '');
    if (parsed == null) continue;

    final key = switch (period) {
      'week' => parsed.subtract(Duration(days: parsed.weekday - 1)),
      'month' => DateTime(parsed.year, parsed.month, 1),
      _ => DateTime(parsed.year, parsed.month, parsed.day),
    };

    final value = _numericValueFromRow(row, const ['sales', 'amount', 'profit']);
    buckets[key] = (buckets[key] ?? 0) + value;
  }

  // Sort by the real date, not the printed label: "Dec" sorts before "Jan"
  // alphabetically and "Jan 2027" would sort before "Dec 2026".
  final ordered = buckets.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return [
    for (final entry in ordered)
      TrendPoint(label: _trendLabel(entry.key, period), value: entry.value),
  ];
}

List<CategoryMarginInsight> buildCategoryMargins(
  List<Map<String, dynamic>> byCategory,
  double totalSales,
  double totalProfit,
) {
  if (byCategory.isEmpty) return const [];
  final grossMarginRate = totalSales > 0 ? totalProfit / totalSales : 0.0;

  final rows = byCategory
      .map((row) {
        final revenue = _numericValueFromRow(row, const ['amount', 'sales']);
        final margin = revenue * grossMarginRate;
        return CategoryMarginInsight(
          category: (row['category'] ?? row['name'] ?? 'Uncategorised').toString(),
          revenue: revenue,
          estimatedMargin: margin,
          marginPercent: totalSales > 0 && revenue > 0 ? (margin / revenue) * 100 : 0,
        );
      })
      .toList()
    ..sort((a, b) => b.revenue.compareTo(a.revenue));

  return rows;
}

List<ProductPerformanceInsight> buildProductPerformanceSummary(List<Map<String, dynamic>> rows) {
  final byProduct = <String, Map<String, dynamic>>{};

  for (final row in rows) {
    final name = (row['name'] ?? row['product_name'] ?? row['item'] ?? 'Unknown').toString();
    if (name.trim().isEmpty) continue;
    final current = byProduct.putIfAbsent(name, () => {'name': name, 'sales': 0.0, 'profit': 0.0, 'quantity': 0.0});
    current['sales'] = toD(current['sales']) + _numericValueFromRow(row, const ['sales', 'amount', 'revenue', 'gross']);
    current['profit'] = toD(current['profit']) + _numericValueFromRow(row, const ['profit', 'gross_profit', 'margin']);
    current['quantity'] = toD(current['quantity']) + _numericValueFromRow(row, const ['quantity', 'qty', 'units', 'items']);
  }

  final items = byProduct.values
      .map((row) {
        final sales = toD(row['sales']);
        final profit = toD(row['profit']);
        return ProductPerformanceInsight(
          productName: row['name'].toString(),
          sales: sales,
          profit: profit,
          quantity: toD(row['quantity']),
          marginPercent: sales > 0 ? (profit / sales) * 100 : 0,
        );
      })
      .toList()
    ..sort((a, b) {
      final byProfit = b.profit.compareTo(a.profit);
      if (byProfit != 0) return byProfit;
      return b.sales.compareTo(a.sales);
    });

  return items;
}

List<ForecastRiskRow> buildLowStockForecast(
  List<PosProduct> products,
  List<Map<String, dynamic>> topProducts, {
  int days = 7,
}) {
  final salesByName = <String, double>{};
  for (final row in topProducts) {
    final name = (row['name'] ?? '').toString().trim();
    if (name.isEmpty) continue;
    salesByName[name.toLowerCase()] = _numericValueFromRow(row, const ['qty', 'quantity']);
  }

  final risks = products
      .where((product) => product.stockQty <= product.reorderLevel || product.stockQty <= 0)
      .map((product) {
        final velocity = salesByName[product.name.toLowerCase()] ?? 0.0;
        final dailyVelocity = days > 0 ? velocity / days : 0.0;
        final daysLeft = dailyVelocity > 0 ? product.stockQty / dailyVelocity : double.infinity;
        return ForecastRiskRow(
          productName: product.name,
          stockQty: product.stockQty,
          reorderLevel: product.reorderLevel,
          daysLeft: daysLeft,
          dailyVelocity: dailyVelocity,
        );
      })
      .toList()
    ..sort((a, b) {
      if (a.daysLeft.isInfinite && b.daysLeft.isInfinite) return a.productName.compareTo(b.productName);
      if (a.daysLeft.isInfinite) return 1;
      if (b.daysLeft.isInfinite) return -1;
      return a.daysLeft.compareTo(b.daysLeft);
    });

  return risks;
}

List<double> buildHourlyHeatMap(List<Map<String, dynamic>> hourly) {
  final values = List<double>.filled(24, 0.0);
  for (final entry in hourly) {
    final hour = toD(entry['hour']).toInt();
    if (hour >= 0 && hour < 24) {
      values[hour] = toD(entry['sales']);
    }
  }

  final filtered = <double>[];
  for (var hour = 6; hour <= 23; hour++) {
    filtered.add(values[hour]);
  }
  return filtered;
}

InventoryHealthSummary buildInventoryHealthSummary(
  List<Map<String, dynamic>> catalogue,
  List<Map<String, dynamic>> lowStockRows,
) {
  final totalSkus = catalogue.length;
  final lowStockCount = catalogue.where((row) {
    final stock = toD(row['stock_qty']);
    final reorder = toD(row['reorder_level']);
    return stock <= reorder && stock > 0;
  }).length;
  final outOfStockCount = catalogue.where((row) => toD(row['stock_qty']) <= 0).length;
  final reorderValue = lowStockRows.fold<double>(0, (sum, row) {
    final suggested = toD(row['suggested_order_qty']);
    final cost = toD(row['cost_price']);
    return sum + (suggested * cost);
  });

  final riskRows = lowStockRows
      .map((row) {
        final stock = toD(row['stock_qty']);
        final reorder = toD(row['reorder_level']);
        final suggested = toD(row['suggested_order_qty']);
        final ratio = reorder > 0 ? (stock / reorder).clamp(0.0, 1.4) : 0.0;
        return InventoryHealthRow(
          name: (row['name'] ?? 'Unknown').toString(),
          stockQty: stock,
          reorderLevel: reorder,
          coverageRatio: ratio,
          suggestedOrderQty: suggested,
        );
      })
      .toList()
    ..sort((a, b) {
      final byStock = a.stockQty.compareTo(b.stockQty);
      if (byStock != 0) return byStock;
      return a.coverageRatio.compareTo(b.coverageRatio);
    });

  return InventoryHealthSummary(
    totalSkus: totalSkus,
    lowStockCount: lowStockCount,
    outOfStockCount: outOfStockCount,
    reorderValue: reorderValue,
    riskRows: riskRows.take(8).toList(),
  );
}

PurchaseOrderSummary buildPurchaseOrderSummary(
  List<Map<String, dynamic>> orders,
  List<Map<String, dynamic>> drafts,
) {
  final receivedCount = orders.length;
  final openDraftCount = drafts.length;
  final totalOpenValue = orders.fold<double>(0, (sum, order) {
        final total = toD(order['total']);
        final paid = toD(order['paid_amount']);
        return sum + (total - paid);
      }) +
      drafts.fold<double>(0, (sum, draft) => sum + toD(draft['total']));

  final totalsBySupplier = <String, double>{};
  for (final draft in drafts) {
    final supplier = (draft['supplier_name'] ?? 'Unknown supplier').toString();
    totalsBySupplier[supplier] = (totalsBySupplier[supplier] ?? 0) + toD(draft['total']);
  }

  final supplierSpend = totalsBySupplier.entries
      .map((entry) => SupplierPurchaseSpend(supplierName: entry.key, total: entry.value))
      .toList()
    ..sort((a, b) => b.total.compareTo(a.total));

  return PurchaseOrderSummary(
    receivedCount: receivedCount,
    openDraftCount: openDraftCount,
    totalOpenValue: totalOpenValue,
    supplierSpend: supplierSpend,
  );
}

OperationalDashboardSummary buildOperationalDashboardSummary({
  required double openingFloat,
  required double cashSales,
  required double refunds,
  required double expenses,
  double? countedCash,
  required int pendingOffline,
  required int lowStockCount,
  required int openShiftCount,
  required int onlineDeviceCount,
  required int totalDeviceCount,
}) {
  final expectedCash = openingFloat + cashSales - refunds - expenses;
  final counted = countedCash;
  // Without a drawer count there is no variance to report. Showing "balanced"
  // here would be a made-up result.
  final variance = counted == null ? 0.0 : counted - expectedCash;
  final status = counted == null
      ? 'not counted'
      : variance.abs() <= 0.01
          ? 'balanced'
          : variance > 0
              ? 'over'
              : 'short';

  final reasons = <String>[];
  if (pendingOffline > 0) {
    reasons.add('$pendingOffline offline sales are still waiting to sync.');
  }
  if (lowStockCount > 0) {
    reasons.add('$lowStockCount items are low stock and need attention.');
  }
  if (openShiftCount > 0) {
    reasons.add('$openShiftCount shift(s) are still open for the day.');
  }
  if (onlineDeviceCount < totalDeviceCount) {
    final idle = totalDeviceCount - onlineDeviceCount;
    if (idle > 0) {
      reasons.add('$idle till(s) are offline or inactive right now.');
    }
  }
  if (counted == null) {
    reasons.add('Drawer not counted yet - close the shift with the counted cash to see the variance.');
  } else if (variance.abs() > 0.01) {
    reasons.add('Cash variance is ${money(variance, symbol: 'Rs')} against the expected drawer total.');
  }
  if (reasons.isEmpty) {
    reasons.add('Store health looks stable and no anomalies were detected.');
  }

  final deviceHealth = totalDeviceCount > 0 ? (onlineDeviceCount / totalDeviceCount * 100).round() : 100;
  final shiftPenalty = openShiftCount > 0 ? 10 : 0;
  final queuePenalty = pendingOffline > 0 ? min(20, pendingOffline * 10) : 0;
  final stockPenalty = lowStockCount > 0 ? min(20, lowStockCount * 5) : 0;
  final variancePenalty = counted != null && variance.abs() > 0.01 ? 20 : 0;
  final score = (deviceHealth - shiftPenalty - queuePenalty - stockPenalty - variancePenalty).clamp(0, 100);

  return OperationalDashboardSummary(
    onlineDeviceCount: onlineDeviceCount,
    totalDeviceCount: totalDeviceCount,
    openShiftCount: openShiftCount,
    pendingOffline: pendingOffline,
    lowStockCount: lowStockCount,
    expectedCash: expectedCash,
    countedCash: countedCash,
    variance: variance,
    status: status,
    healthScore: score,
    reasons: reasons,
  );
}

CashControlSummary buildCashControlSummary({
  required double openingFloat,
  required double cashSales,
  required double refunds,
  required double expenses,
  double? countedCash,
}) {
  final expectedInDrawer = openingFloat + cashSales - refunds - expenses;
  final actualCash = countedCash ?? expectedInDrawer;
  final variance = actualCash - expectedInDrawer;
  final controlStatus = variance.abs() <= 0.01
      ? 'balanced'
      : variance > 0
          ? 'over'
          : 'short';

  return CashControlSummary(
    openingFloat: openingFloat,
    cashSales: cashSales,
    refunds: refunds,
    expenses: expenses,
    expectedInDrawer: expectedInDrawer,
    countedCash: actualCash,
    variance: variance,
    controlStatus: controlStatus,
  );
}

AuditSummary buildAuditSummary(List<Map<String, dynamic>> rows) {
  final alerts = <String>[];
  var pinApprovals = 0;
  var stockAdjustments = 0;
  var cancellations = 0;
  var refunds = 0;

  for (final row in rows) {
    final action = (row['action'] ?? '').toString();
    if (action == 'override.pin') pinApprovals++;
    if (action.startsWith('stock')) stockAdjustments++;
    if (action == 'sale.void') cancellations++;
    if (action.startsWith('return') || action == 'refund.create') refunds++;
  }

  if (pinApprovals > 0) alerts.add('PIN approvals reviewed');
  if (stockAdjustments > 0) alerts.add('Stock adjustments require review');
  if (cancellations > 0) alerts.add('Void sales are logged');
  if (refunds > 0) alerts.add('Refund activity is visible');
  if (cancellations >= 3) {
    alerts.add('Multiple voids detected — review cancellation patterns and cash handoff.');
  }
  if (refunds >= 3) {
    alerts.add('Refund volume is elevated — check return approvals and sale accuracy.');
  }
  if (alerts.isEmpty) alerts.add('No exceptions in this window');

  return AuditSummary(
    totalEntries: rows.length,
    pinApprovals: pinApprovals,
    stockAdjustments: stockAdjustments,
    cancellations: cancellations,
    refunds: refunds,
    complianceAlerts: alerts,
  );
}
