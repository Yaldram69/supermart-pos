import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/reporting.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Owner's dashboard: what sold, what it earned, what is running out, and
/// which of the 4 tills is doing what.
// Date text for report rows. A malformed value from the server shows as blank
// instead of throwing, which used to take the whole reports screen down.
String _dayText(Object? v) {
  final d = DateTime.tryParse(v?.toString() ?? '');
  return d == null ? '' : dateFmt.format(d);
}

String _dayMonth(Object? v) {
  final d = DateTime.tryParse(v?.toString() ?? '');
  return d == null ? '' : '${d.day}/${d.month}';
}

String _timeText(Object? v) {
  final d = DateTime.tryParse(v?.toString() ?? '');
  return d == null ? '' : timeFmt.format(d.toLocal());
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  Dashboard? _dash;
  SalesReport? _report;
  SalesReport? _previousReport;
  bool _loading = true;
  final int _days = 7;
  DateTime _from = DateTime.now().subtract(const Duration(days: 6));
  DateTime _to = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final state = context.read<AppState>();
    try {
      // The requests are independent, so they run together, not one after another.
      final previousRange = previousPeriodRange(DateTimeRange(start: _from, end: _to));
      final dashFuture = state.api.dashboard(days: _days);
      final reportFutures = state.isManager
          ? Future.wait([
              state.api.salesReport(_from, _to),
              state.api.salesReport(previousRange.start, previousRange.end),
            ])
          : Future.value(<SalesReport>[]);
      final results = await Future.wait<Object>([dashFuture, reportFutures]);
      final dash = results[0] as Dashboard;
      final reports = results[1] as List<SalesReport>;
      final SalesReport? report = reports.isNotEmpty ? reports[0] : null;
      final SalesReport? previousReport = reports.length > 1 ? reports[1] : null;
      if (mounted) {
        setState(() {
          _dash = dash;
          _report = report;
          _previousReport = previousReport;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (_loading) return const Center(child: CircularProgressIndicator());
    final dash = _dash;
    if (dash == null) return const EmptyState(icon: Icons.insights, title: 'No data yet');

    final cashSummary = buildCashControlSummary(
      openingFloat: state.hasOpenShift ? state.shift!.openingFloat : 0.0,
      cashSales: dash.todayCash,
      refunds: toD(dash.today['refunds']),
      expenses: dash.expensesToday,
    );

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              child: Wrap(spacing: 10, runSpacing: 10, children: [
                _stat('Today\'s takings', money(dash.todaySales), Icons.payments_outlined, AppColors.good,
                    '${dash.todayInvoices} invoices'),
                _stat('Today\'s profit', money(dash.todayProfit), Icons.trending_up,
                    AppColors.info, 'before expenses'),
                if (state.isManager)
                  _stat('This month', money(dash.monthSales), Icons.calendar_month, AppColors.cash,
                      'profit ${money(dash.monthProfit)}'),
                _stat('Cash in tills today', money(dash.todayCash), Icons.account_balance_wallet,
                    AppColors.cash, 'other payments excluded'),
                _stat('Stock value', money(dash.stockValue), Icons.inventory_2_outlined,
                    AppColors.info, 'retail ${money(dash.stockRetail)}'),
                _stat('Needs reordering', '${dash.lowStockCount}', Icons.warning_amber_outlined,
                    dash.lowStockCount > 0 ? AppColors.warn : AppColors.good,
                    '${dash.outOfStockCount} out of stock'),
                if (state.isManager)
                  _stat('Customer udhaar', money(dash.customerDebt), Icons.people_outline,
                      AppColors.warn, 'total owed to you'),
                _stat('My sales today', money(dash.mySalesToday), Icons.badge_outlined,
                    AppColors.cash, '${dash.myInvoicesToday} of my invoices'),
              ]),
            ),
          ]),
          const SizedBox(height: 16),

          // ---- sales trend ----
          SectionCard(
            title: 'Sales — last $_days days',
            child: SizedBox(
              height: 190,
              child: _bars(dash.series),
            ),
          ),
          const SizedBox(height: 16),

          if (state.isManager && _report != null) ...[
            () {
              final paymentMix = buildPaymentMixSummary(_report!.byPayment);
              final automationSummary = buildAutomationSummary(
                lowStockRows: dash.lowStock,
                cashierRows: _report!.byCashier,
                todaySales: dash.todaySales,
                previousSales: _previousReport?.sales ?? dash.todaySales,
                todayProfit: dash.todayProfit,
                previousProfit: _previousReport?.profit ?? dash.todayProfit,
                pendingOffline: state.pendingOffline,
                lowStockCount: dash.lowStockCount,
                backupDue: false,
              );
              return Column(children: [
                SectionCard(
                  title: 'Payment mix',
                  child: Column(children: [
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      for (final method in paymentMix.methods)
                        _stat(
                          method.label,
                          money(method.amount),
                          method.method == 'cash'
                              ? Icons.payments_outlined
                              : method.method == 'card'
                                  ? Icons.credit_card
                                  : method.method == 'jazzcash'
                                      ? Icons.phone_android
                                      : method.method == 'easypaisa'
                                          ? Icons.phone_iphone
                                          : method.method == 'bank_transfer'
                                              ? Icons.account_balance
                                              : Icons.receipt_long,
                          method.method == 'cash' ? AppColors.cash : AppColors.info,
                          '${method.invoices} invoices · ${method.share.toStringAsFixed(1)}%',
                        ),
                    ]),
                    const SizedBox(height: 12),
                    _miniTable(
                      const ['Method', 'Share', 'Amount'],
                      paymentMix.methods
                          .map((entry) => [entry.label, '${entry.share.toStringAsFixed(1)}%', money(entry.amount)])
                          .toList(),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'Automation & alert centre',
                  child: Column(children: [
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      _stat('Active alerts', automationSummary.totalAlerts.toString(), Icons.notifications_active_outlined,
                          automationSummary.highPriorityCount > 0 ? AppColors.warn : AppColors.good,
                          automationSummary.highPriorityCount > 0 ? '${automationSummary.highPriorityCount} urgent' : 'all clear'),
                      _stat('Low stock', dash.lowStockCount.toString(), Icons.warning_amber_outlined,
                          dash.lowStockCount > 0 ? AppColors.warn : AppColors.good,
                          'needs attention'),
                      _stat('Offline queue', state.pendingOffline.toString(), Icons.cloud_off_outlined,
                          state.pendingOffline > 0 ? AppColors.warn : AppColors.good,
                          'pending sync'),
                    ]),
                    const SizedBox(height: 12),
                    for (final alert in automationSummary.alerts)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: alert.severity == 'high'
                              ? AppColors.warn.withValues(alpha: 0.12)
                              : AppColors.info.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Icon(
                            alert.severity == 'high' ? Icons.priority_high : Icons.info_outline,
                            size: 16,
                            color: alert.severity == 'high' ? AppColors.warn : AppColors.info,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(alert.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Text(alert.message, style: const TextStyle(fontSize: 12)),
                              ],
                            ),
                          ),
                        ]),
                      ),
                  ]),
                ),
                const SizedBox(height: 16),
                _businessIntelligenceSection(_report!, state),
                const SizedBox(height: 16),
              ]);
            }(),
          ],

          SectionCard(
            title: 'Cash management & accounting controls',
            child: Column(children: [
              Wrap(spacing: 10, runSpacing: 10, children: [
                _stat('Opening float', money(cashSummary.openingFloat), Icons.payments_outlined,
                    AppColors.cash, 'cash available to start'),
                _stat('Cash sales', money(cashSummary.cashSales), Icons.account_balance_wallet,
                    AppColors.good, 'cash-only takings today'),
                _stat('Expected drawer', money(cashSummary.expectedInDrawer), Icons.calculate_outlined,
                    AppColors.info, 'float + cash sales - refunds - expenses'),
                _stat('Variance', money(cashSummary.variance),
                    cashSummary.variance >= 0 ? Icons.trending_up : Icons.trending_down,
                    cashSummary.variance >= 0 ? AppColors.good : AppColors.danger,
                    'drawer difference from expectation'),
              ]),
              const SizedBox(height: 12),
              _miniTable(
                const ['Control', 'Value'],
                [
                  ['Opening float', money(cashSummary.openingFloat)],
                  ['Cash sales', money(cashSummary.cashSales)],
                  ['Refunds', money(cashSummary.refunds)],
                  ['Expenses', money(cashSummary.expenses)],
                  ['Expected in drawer', money(cashSummary.expectedInDrawer)],
                ],
              ),
            ]),
          ),
          const SizedBox(height: 16),

          () {
            final operationalSummary = buildOperationalDashboardSummary(
              openingFloat: state.hasOpenShift ? state.shift!.openingFloat : 0.0,
              cashSales: dash.todayCash,
              refunds: toD(dash.today['refunds']),
              expenses: dash.expensesToday,
              // No drawer count is entered on this screen; the real variance is
              // recorded when a shift is closed with its counted cash.
              countedCash: null,
              pendingOffline: state.pendingOffline,
              lowStockCount: dash.lowStockCount,
              openShiftCount: dash.openShifts.length,
              onlineDeviceCount: dash.devices.where((device) => toD(device['minutes_ago']) < 3).length,
              totalDeviceCount: dash.devices.length,
            );

            return SectionCard(
              title: 'Operational dashboard',
              child: Column(children: [
                Wrap(spacing: 10, runSpacing: 10, children: [
                  _stat('Store health', '${operationalSummary.healthScore}/100', Icons.health_and_safety_outlined,
                      operationalSummary.healthScore >= 70 ? AppColors.good : AppColors.warn,
                      '${operationalSummary.onlineDeviceCount}/${operationalSummary.totalDeviceCount} tills online'),
                  _stat('Open shifts', operationalSummary.openShiftCount.toString(), Icons.lock_open_outlined,
                      operationalSummary.openShiftCount > 0 ? AppColors.warn : AppColors.good,
                      'currently active'),
                  _stat('Pending sync', operationalSummary.pendingOffline.toString(), Icons.sync_outlined,
                      operationalSummary.pendingOffline > 0 ? AppColors.warn : AppColors.good,
                      'queued sales'),
                  _stat('Low stock', operationalSummary.lowStockCount.toString(), Icons.inventory_2_outlined,
                      operationalSummary.lowStockCount > 0 ? AppColors.warn : AppColors.good,
                      'items need review'),
                ]),
                const SizedBox(height: 12),
                _miniTable(
                  const ['Check', 'Value'],
                  [
                    ['Expected cash', money(operationalSummary.expectedCash)],
                    ['Counted cash', operationalSummary.countedCash == null ? 'Not counted' : money(operationalSummary.countedCash!)],
                    ['Variance', money(operationalSummary.variance)],
                    ['Status', operationalSummary.status],
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.info.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Operational notes', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      for (final reason in operationalSummary.reasons)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.fiber_manual_record, size: 8),
                              const SizedBox(width: 8),
                              Expanded(child: Text(reason, style: const TextStyle(fontSize: 12))),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ]),
            );
          }(),
          const SizedBox(height: 16),

          if (state.isManager && _report != null) ...[
            Wrap(spacing: 10, runSpacing: 10, children: [
              _deltaStat(
                'Sales vs prior period',
                _report!.sales,
                _previousReport?.sales ?? 0,
                Icons.trending_up,
                AppColors.good,
              ),
              _deltaStat(
                'Profit vs prior period',
                _report!.profit,
                _previousReport?.profit ?? 0,
                Icons.account_balance_wallet,
                AppColors.info,
              ),
              _deltaStat(
                'Average basket',
                _report!.avgBasket,
                _previousReport?.avgBasket ?? 0,
                Icons.shopping_basket_outlined,
                AppColors.cash,
              ),
            ]),
            const SizedBox(height: 16),
          ],

          // ---- tills and shifts ----
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: SectionCard(
                title: 'The 4 counters',
                child: Column(children: [
                  for (final d in dash.devices)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        (toD(d['minutes_ago']) < 3) ? Icons.circle : Icons.circle_outlined,
                        size: 12,
                        color: (toD(d['minutes_ago']) < 3) ? AppColors.good : AppColors.warn,
                      ),
                      title: Text('${d['name']}  (terminal ${d['terminal_no'] ?? '—'})'),
                      trailing: Text('seen ${agoLabel(DateTime.now().subtract(Duration(minutes: toD(d['minutes_ago']).toInt())))}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  if (dash.devices.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(8), child: Text('No tills have checked in yet.')),
                ]),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SectionCard(
                title: 'Open shifts',
                child: Column(children: [
                  for (final s in dash.openShifts)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.lock_open_outlined, size: 18),
                      title: Text('${s['cashier']} on ${s['device']}'),
                      subtitle: Text('since ${_timeText(s['opened_at'])}'),
                    ),
                  if (dash.openShifts.isEmpty)
                    const Padding(padding: EdgeInsets.all(8), child: Text('No shift is open right now.')),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // ---- what is selling ----
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: SectionCard(
                title: 'Best sellers today',
                child: _miniTable(
                  const ['Product', 'Qty', 'Value'],
                  dash.topProducts
                      .map((p) => [
                            p['name']?.toString() ?? '',
                            qtyStr(p['qty']),
                            num2(p['amount']),
                          ])
                      .toList(),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SectionCard(
                title: 'Running out',
                child: _miniTable(
                  const ['Product', 'Left', 'Reorder at'],
                  dash.lowStock
                      .map((p) => [
                            p['name']?.toString() ?? '',
                            qtyStr(p['stock_qty']),
                            qtyStr(p['reorder_level']),
                          ])
                      .toList(),
                ),
              ),
            ),
          ]),

          // ---- the manager report ----
          if (state.isManager && _report != null) ...[
            const SizedBox(height: 20),
            SectionCard(
              title: 'Full report',
              actions: [
                OutlinedButton.icon(
                  onPressed: _pickRange,
                  icon: const Icon(Icons.date_range, size: 18),
                  label: Text('${dateFmt.format(_from)} → ${dateFmt.format(_to)}'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _exportCsv,
                  icon: const Icon(Icons.table_view_outlined, size: 18),
                  label: const Text('Export CSV'),
                ),
                const SizedBox(width: 8),
                IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
              ],
              child: Column(children: [
                Wrap(spacing: 10, runSpacing: 10, children: [
                  _stat('Sales', money(_report!.sales), Icons.payments_outlined, AppColors.good,
                      '${_report!.invoiceCount} invoices'),
                  _stat('Gross profit', money(_report!.profit), Icons.trending_up, AppColors.info,
                      'before expenses'),
                  _stat('Discounts given', money(_report!.discounts), Icons.percent, AppColors.warn,
                      'all tills'),
                  _stat('Tax collected', money(_report!.tax), Icons.receipt, AppColors.cash, ''),
                  _stat('Refunds', money(_report!.refunds), Icons.assignment_return_outlined,
                      AppColors.danger, ''),
                  _stat('Average bill', money(_report!.avgBasket), Icons.shopping_basket_outlined,
                      AppColors.cash, ''),
                ]),
                const SizedBox(height: 16),
                _section('Day by day'),
                _miniTable(
                  const ['Day', 'Invoices', 'Sales', 'Profit'],
                  _report!.daily
                      .map((r) => [
                            _dayText(r['day']),
                            r['invoices'].toString(),
                            num2(r['sales']),
                            num2(r['profit']),
                          ])
                      .toList(),
                ),
                const SizedBox(height: 16),
                if (_report!.byCategory.isNotEmpty) ...[
                  _section('Category sales'),
                  _miniTable(
                    const ['Category', 'Qty', 'Value'],
                    _report!.byCategory
                        .map((r) => [
                              r['category']?.toString() ?? '',
                              qtyStr(r['qty']),
                              num2(r['amount']),
                            ])
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(children: [
                      _section('How customers paid'),
                      _miniTable(
                        const ['Method', 'Invoices', 'Amount'],
                        _report!.byPayment
                            .map((r) => [
                                  r['method'].toString(),
                                  r['invoices'].toString(),
                                  num2(r['amount']),
                                ])
                            .toList(),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(children: [
                      _section('Cashier performance'),
                      _miniTable(
                        const ['Cashier', 'Invoices', 'Sales'],
                        _report!.byCashier
                            .map((r) => [
                                  r['cashier']?.toString() ?? '',
                                  r['invoices'].toString(),
                                  num2(r['sales']),
                                ])
                            .toList(),
                      ),
                    ]),
                  ),
                ]),
                const SizedBox(height: 16),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(children: [
                      _section('Sales per till'),
                      _miniTable(
                        const ['Till', 'Invoices', 'Sales'],
                        _report!.byDevice
                            .map((r) => [
                                  r['device']?.toString() ?? '',
                                  r['invoices'].toString(),
                                  num2(r['sales']),
                                ])
                            .toList(),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(children: [
                      _section('Sales by category'),
                      _miniTable(
                        const ['Category', 'Qty', 'Value'],
                        _report!.byCategory
                            .map((r) => [
                                  r['category']?.toString() ?? '',
                                  qtyStr(r['qty']),
                                  num2(r['amount']),
                                ])
                            .toList(),
                      ),
                    ]),
                  ),
                ]),
                const SizedBox(height: 16),
                _section('Top 25 products in this period'),
                _miniTable(
                  const ['Product', 'Qty', 'Value', 'Profit'],
                  _report!.topProducts
                      .map((r) => [
                            r['name'].toString(),
                            qtyStr(r['qty']),
                            num2(r['amount']),
                            num2(r['profit']),
                          ])
                      .toList(),
                ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, String value, IconData icon, Color color, String sub) => SizedBox(
        width: 235,
        child: StatCard(label: label, value: value, icon: icon, color: color, sub: sub),
      );

  Widget _deltaStat(String label, double current, double previous, IconData icon, Color color) {
    final delta = periodDeltaText(current, previous);
    final positive = delta.startsWith('+') || delta == 'new';
    return SizedBox(
      width: 230,
      child: StatCard(
        label: label,
        value: money(current),
        icon: icon,
        color: color,
        sub: '${positive ? 'Up' : delta == 'flat' ? 'Flat' : 'Down'} $delta vs prior period',
      ),
    );
  }

  Widget _businessIntelligenceSection(SalesReport report, AppState state) {
    final totalSales = report.sales;
    final profitability = totalSales > 0 ? report.profit / totalSales : 0.0;
    final categoryMargins = buildCategoryMargins(report.byCategory, totalSales, report.profit);
    final productPerformance = buildProductPerformanceSummary(report.topProducts);
    final topRevenue = report.topProducts
        .map((row) => {
              'name': row['name']?.toString() ?? 'Unknown',
              'amount': toD(row['amount']),
            })
        .toList();
    final totalRevenue = topRevenue.fold<double>(0, (sum, item) => sum + toD(item['amount']));
    final shiftBlocks = [
      {'label': 'AM', 'value': _sumHourly(report.hourly, 6, 11)},
      {'label': 'PM', 'value': _sumHourly(report.hourly, 12, 17)},
      {'label': 'Evening', 'value': _sumHourly(report.hourly, 18, 23)},
    ];
    final forecast = buildLowStockForecast(state.catalogue, report.topProducts, days: 7);
    final weekly = aggregateTrendByPeriod(report.daily, 'week');
    final monthly = aggregateTrendByPeriod(report.daily, 'month');
    final hourly = buildHourlyHeatMap(report.hourly);

    return SectionCard(
      title: 'Business intelligence',
      child: Column(children: [
        Wrap(spacing: 10, runSpacing: 10, children: [
          _stat('Weekly trend', money(weekly.isEmpty ? 0 : weekly.last.value), Icons.trending_up, AppColors.good,
              'last bucket ${weekly.isNotEmpty ? weekly.last.label : '—'}'),
          _stat('Monthly run-rate', money(monthly.isEmpty ? 0 : monthly.last.value), Icons.bar_chart, AppColors.info,
              '${monthly.length} months covered'),
          _stat('Est. margin', '${(profitability * 100).toStringAsFixed(1)}%', Icons.percent, AppColors.cash,
              'profit on sales'),
          _stat('Low-stock alerts', '${forecast.length}', Icons.warning_amber_rounded,
              forecast.isEmpty ? AppColors.good : AppColors.warn, 'forecast risk'),
        ]),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(children: [
              _section('Gross margin by category'),
              _miniTable(
                const ['Category', 'Revenue', 'Margin'],
                categoryMargins.isEmpty
                    ? const []
                    : categoryMargins
                        .take(5)
                        .map((row) => [
                              row.category,
                              num2(row.revenue),
                              '${row.marginPercent.toStringAsFixed(1)}% (${num2(row.estimatedMargin)})',
                            ])
                        .toList(),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(children: [
              _section('Revenue contribution'),
              _miniTable(
                const ['Product', 'Revenue', 'Share'],
                topRevenue.isEmpty
                    ? const []
                    : topRevenue
                        .take(5)
                        .map((row) {
                          final amount = toD(row['amount']);
                          final share = totalRevenue > 0 ? (amount / totalRevenue) * 100 : 0.0;
                          return [row['name'].toString(), num2(amount), '${share.toStringAsFixed(1)}%'];
                        })
                        .toList(),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(children: [
              _section('Best and weakest sellers'),
              _miniTable(
                const ['Product', 'Sales', 'Profit', 'Margin'],
                productPerformance.isEmpty
                    ? const []
                    : productPerformance
                        .take(5)
                        .map((row) => [
                              row.productName,
                              num2(row.sales),
                              num2(row.profit),
                              '${row.marginPercent.toStringAsFixed(1)}%',
                            ])
                        .toList(),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(children: [
              _section('Decision signal'),
              _miniTable(
                const ['Signal', 'Detail'],
                [
                  [
                    'Top seller',
                    productPerformance.isEmpty
                        ? 'No sales yet'
                        : '${productPerformance.first.productName} • ${money(productPerformance.first.sales)}',
                  ],
                  [
                    'Needs attention',
                    productPerformance.isEmpty
                        ? 'No weak products'
                        : '${productPerformance.last.productName} • ${productPerformance.last.marginPercent.toStringAsFixed(1)}% margin',
                  ],
                ],
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(children: [
              _section('Cashier productivity'),
              _miniTable(
                const ['Cashier', 'Sales', 'Profit', 'Invoices'],
                report.byCashier.isEmpty
                    ? const []
                    : report.byCashier
                        .take(5)
                        .map((row) => [
                              row['cashier']?.toString() ?? '',
                              num2(row['sales']),
                              num2(row['profit']),
                              row['invoices'].toString(),
                            ])
                        .toList(),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(children: [
              _section('Time-of-day sales'),
              _hourlyHeatMap(hourly),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(children: [
              _section('Shift split'),
              _miniTable(
                const ['Shift', 'Sales'],
                shiftBlocks
                    .map((row) => [row['label'].toString(), num2(row['value'])])
                    .toList(),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(children: [
              _section('Low-stock forecast'),
              _miniTable(
                const ['Product', 'Stock', 'Velocity', 'Days left'],
                forecast.isEmpty
                    ? const []
                    : forecast
                        .take(5)
                        .map((row) => [
                              row.productName,
                              row.stockQty.toStringAsFixed(0),
                              '${row.dailyVelocity.toStringAsFixed(1)}/day',
                              row.daysLeft.isFinite ? row.daysLeft.toStringAsFixed(1) : '—',
                            ])
                        .toList(),
              ),
            ]),
          ),
        ]),
      ]),
    );
  }

  double _sumHourly(List<Map<String, dynamic>> hourly, int startHour, int endHour) {
    double total = 0;
    for (final row in hourly) {
      final hour = toD(row['hour']);
      if (hour >= startHour && hour <= endHour) total += toD(row['sales']);
    }
    return total;
  }

  Widget _hourlyHeatMap(List<double> hourly) {
    final labels = ['6', '7', '8', '9', '10', '11', '12', '13', '14', '15', '16', '17', '18', '19', '20', '21', '22', '23'];
    final maxValue = hourly.isEmpty ? 0.0 : hourly.reduce((a, b) => a > b ? a : b);
    return SizedBox(
      height: 160,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 6,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 1.0,
        ),
        itemCount: labels.length,
        itemBuilder: (context, index) {
          final value = index < hourly.length ? hourly[index] : 0.0;
          final intensity = maxValue > 0 ? (value / maxValue).clamp(0.0, 1.0) : 0.0;
          final color = Color.lerp(Theme.of(context).colorScheme.surfaceContainerHighest, AppColors.cash, intensity) ?? AppColors.cash;
          return Tooltip(
            message: '${labels[index]}:00 → ${money(value)}',
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                labels[index],
                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(t, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        ),
      );

  Widget _miniTable(List<String> headers, List<List<String>> rows) {
    if (rows.isEmpty) {
      return const Padding(padding: EdgeInsets.all(8), child: Text('Nothing to show for this period.'));
    }
    return SizedBox(
      width: double.infinity,
      child: DataTable(
        columnSpacing: 18,
        headingRowHeight: 36,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 38,
        columns: [for (final h in headers) DataColumn(label: Text(h))],
        rows: [
          for (final r in rows)
            DataRow(cells: [for (final cell in r) DataCell(Text(cell))]),
        ],
      ),
    );
  }

  /// A simple bar chart: no chart library needed, and it prints cleanly.
  Widget _bars(List<Map<String, dynamic>> series) {
    if (series.isEmpty) return const Center(child: Text('No sales recorded yet.'));
    final values = series.map((e) => toD(e['sales'])).toList();
    final maxV = values.fold<double>(0, (a, b) => a > b ? a : b);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < series.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(values[i] > 0 ? num2(values[i]) : '',
                      style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Tooltip(
                    message:
                        '${series[i]['d']}\n${money(values[i])}',
                    child: Container(
                      height: maxV <= 0 ? 4 : (values[i] / maxV * 120).clamp(4, 120),
                      decoration: BoxDecoration(
                        color: AppColors.cash.withValues(alpha: 0.85),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _dayMonth(series[i]['d']),
                    style: const TextStyle(fontSize: 9.5),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (picked != null) {
      setState(() {
        _from = picked.start;
        _to = picked.end;
      });
      await _load();
    }
  }

  Future<void> _exportCsv() async {
    final r = _report;
    if (r == null) return;
    final buffer = StringBuffer();
    buffer.writeln('Supermart sales report,${dateFmt.format(_from)} to ${dateFmt.format(_to)}');
    buffer.writeln();
    buffer.writeln('Summary');
    buffer.writeln('Invoices,${r.invoiceCount}');
    buffer.writeln('Sales,${r.sales}');
    buffer.writeln('Discounts,${r.discounts}');
    buffer.writeln('Tax,${r.tax}');
    buffer.writeln('Refunds,${r.refunds}');
    buffer.writeln('Profit,${r.profit}');
    buffer.writeln();
    buffer.writeln('Day,Invoices,Sales,Profit');
    for (final d in r.daily) {
      buffer.writeln([d['day'], d['invoices'], d['sales'], d['profit']].map(csvCell).join(','));
    }
    buffer.writeln();
    buffer.writeln('Method,Invoices,Amount');
    for (final p in r.byPayment) {
      buffer.writeln([p['method'], p['invoices'], p['amount']].map(csvCell).join(','));
    }
    buffer.writeln();
    buffer.writeln('Category,Qty,Value');
    for (final p in r.byCategory) {
      buffer.writeln([p['category'], p['qty'], p['amount']].map(csvCell).join(','));
    }
    buffer.writeln();
    buffer.writeln('Product,Qty,Value,Profit');
    for (final p in r.topProducts) {
      buffer.writeln([p['name'], p['qty'], p['amount'], p['profit']].map(csvCell).join(','));
    }
    buffer.writeln();
    buffer.writeln('Cashier,Invoices,Sales');
    for (final c in r.byCashier) {
      buffer.writeln([c['cashier'], c['invoices'], c['sales']].map(csvCell).join(','));
    }
    buffer.writeln();
    buffer.writeln('Till,Invoices,Sales');
    for (final c in r.byDevice) {
      buffer.writeln([c['device'], c['invoices'], c['sales']].map(csvCell).join(','));
    }

    try {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/supermart_report_${fileStamp.format(DateTime.now())}.csv');
      await file.writeAsString(buffer.toString());
      if (mounted) showMessage(context, 'Saved to ${file.path}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}
