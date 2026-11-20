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

/// The reports an owner actually uses to make decisions:
/// what makes money, who is selling it, and what is sitting on the shelf.
/// Text cells go through [csvCell] (quoting and formula-injection safe).
String _csvText(String value) => csvCell(value);


class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  DateTime _from = DateTime.now().subtract(const Duration(days: 30));
  DateTime _to = DateTime.now();

  List<ProfitRow> _profit = [];
  List<ProfitRow> _previousProfit = [];
  List<CashierPerfRow> _cashiers = [];
  List<DeadStockRow> _dead = [];
  int _deadDays = 60;
  String _profitOrder = 'profit';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() => _busy = true);
    try {
      final api = context.read<AppState>().api;
      final previousRange = previousPeriodRange(DateTimeRange(start: _from, end: _to));
      final profit = await api.profitByProduct(from: _from, to: _to, order: _profitOrder);
      final previousProfit = await api.profitByProduct(
        from: previousRange.start,
        to: previousRange.end,
        order: _profitOrder,
      );
      final cash = await api.cashierPerformance(from: _from, to: _to);
      final dead = await api.deadStock(days: _deadDays);
      if (!mounted) return;
      setState(() {
        _profit = ((profit['rows'] as List?) ?? const [])
            .map((e) => ProfitRow((e as Map).cast<String, dynamic>()))
            .toList();
        _previousProfit = ((previousProfit['rows'] as List?) ?? const [])
            .map((e) => ProfitRow((e as Map).cast<String, dynamic>()))
            .toList();
        _cashiers = ((cash['rows'] as List?) ?? const [])
            .map((e) => CashierPerfRow((e as Map).cast<String, dynamic>()))
            .toList();
        _dead = ((dead['rows'] as List?) ?? const [])
            .map((e) => DeadStockRow((e as Map).cast<String, dynamic>()))
            .toList();
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (picked == null) return;
    setState(() {
      _from = picked.start;
      _to = picked.end;
    });
    await _loadAll();
  }

  void _quickRange(int days) {
    setState(() {
      _to = DateTime.now();
      _from = DateTime.now().subtract(Duration(days: days));
    });
    _loadAll();
  }

  Future<void> _exportCsv() async {
    final buffer = StringBuffer();

    buffer.writeln('Owner report,${dateFmt.format(_from)} to ${dateFmt.format(_to)}');
    buffer.writeln();
    buffer.writeln('Metric,Current,Previous');
    final revenue = _profit.fold<double>(0, (a, r) => a + r.gross);
    final profit = _profit.fold<double>(0, (a, r) => a + r.profit);
    final prevRevenue = _previousProfit.fold<double>(0, (a, r) => a + r.gross);
    final prevProfit = _previousProfit.fold<double>(0, (a, r) => a + r.profit);
    buffer.writeln('Revenue,$revenue,$prevRevenue');
    buffer.writeln('Profit,$profit,$prevProfit');
    buffer.writeln();
    buffer.writeln('Product,Qty Sold,Gross,Profit,Margin');
    for (final row in _profit) {
      buffer.writeln([
        _csvText(row.name),
        row.qtySold,
        row.gross,
        row.profit,
        row.margin,
      ].join(','));
    }
    buffer.writeln();
    buffer.writeln('Cashier,Invoices,Items,Sales,Profit,Discounts');
    for (final row in _cashiers) {
      buffer.writeln([
        _csvText(row.cashier),
        row.invoices,
        row.items,
        row.sales,
        row.profit,
        row.discountsGiven,
      ].join(','));
    }
    buffer.writeln();
    buffer.writeln('Dead stock product,Stock qty,Cost price,Value,Days idle');
    for (final row in _dead) {
      buffer.writeln([
        _csvText(row.name),
        row.stockQty,
        row.costPrice,
        row.value,
        row.daysIdle,
      ].join(','));
    }

    try {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/owner_report_${fileStamp.format(DateTime.now())}.csv');
      await file.writeAsString(buffer.toString());
      if (mounted) showMessage(context, 'Saved to ${file.path}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sym = state.store?.currencySymbol ?? 'Rs';
    final previousRange = previousPeriodRange(DateTimeRange(start: _from, end: _to));
    final revenue = _profit.fold<double>(0, (a, r) => a + r.gross);
    final profit = _profit.fold<double>(0, (a, r) => a + r.profit);
    final realPreviousRevenue = _previousProfit.fold<double>(0, (a, r) => a + r.gross);
    final realPreviousProfit = _previousProfit.fold<double>(0, (a, r) => a + r.profit);
    final tied = _dead.fold<double>(0, (a, r) => a + r.value);
    final margin = revenue > 0 ? profit / revenue * 100 : 0.0;
    final hasAnyData = _profit.isNotEmpty || _cashiers.isNotEmpty || _dead.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Owner reports', style: Theme.of(context).textTheme.headlineSmall),
          const Spacer(),
          if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _pickRange,
            icon: const Icon(Icons.date_range, size: 18),
            label: Text('${dateFmt.format(_from)} → ${dateFmt.format(_to)}'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _exportCsv,
            icon: const Icon(Icons.download_outlined),
            label: const Text('Export CSV'),
          ),
          const SizedBox(width: 8),
          IconButton(onPressed: _loadAll, icon: const Icon(Icons.refresh)),
        ]),
        const SizedBox(height: 8),
        Text(
          'vs ${dateFmt.format(previousRange.start)} → ${dateFmt.format(previousRange.end)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Row(children: [
          for (final d in const [(7, '7 days'), (30, '30 days'), (90, '90 days'), (365, '1 year')]) ...[
            TextButton(onPressed: () => _quickRange(d.$1), child: Text(d.$2)),
            const SizedBox(width: 4),
          ],
          const Spacer(),
          StatCard(
            label: 'Sold',
            value: money(revenue, symbol: sym),
            sub: !hasAnyData ? 'No sales in this period' : '${periodDeltaText(revenue, realPreviousRevenue)} vs prior span',
            icon: Icons.sell_outlined,
          ),
          const SizedBox(width: 12),
          StatCard(
            label: 'Profit',
            value: money(profit, symbol: sym),
            sub: !hasAnyData
                ? 'No completed sales yet'
                : '${periodDeltaText(profit, realPreviousProfit)} vs prior span • ${margin.toStringAsFixed(1)}% margin',
            icon: Icons.trending_up,
            color: profit >= 0 ? AppColors.good : AppColors.danger,
          ),
          const SizedBox(width: 12),
          StatCard(
            label: 'Dead stock value',
            value: money(tied, symbol: sym),
            sub: !hasAnyData ? 'No stock flagged as slow' : 'no sale in $_deadDays days',
            icon: Icons.inventory_2_outlined,
            color: tied > 0 ? AppColors.warn : AppColors.good,
          ),
        ]),
        if (!hasAnyData) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.info.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.info.withValues(alpha: 0.15)),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, color: AppColors.info),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'No completed sales or dead-stock records were found in ${dateFmt.format(_from)} to ${dateFmt.format(_to)}. Try a wider date range or make a few sales to populate this report.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        TabBar(
          controller: _tabs,
          labelColor: AppColors.info,
          tabs: const [
            Tab(text: 'Profit per product'),
            Tab(text: 'Cashier scoreboard'),
            Tab(text: 'Dead stock / slow movers'),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TabBarView(controller: _tabs, children: [
            SectionCard(
              title: 'Best and worst sellers',
              actions: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'profit', label: Text('By profit')),
                    ButtonSegment(value: 'qty', label: Text('By quantity')),
                  ],
                  selected: {_profitOrder},
                  onSelectionChanged: (v) {
                    setState(() => _profitOrder = v.first);
                    _loadAll();
                  },
                ),
              ],
              child: _profit.isEmpty
                  ? const EmptyState(
                      icon: Icons.insights,
                      title: 'No sales in this period',
                      message: 'Complete a few sales or widen the date range to populate the profit table.',
                    )
                  : ListView.separated(
                      itemCount: _profit.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final r = _profit[i];
                        return ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            backgroundColor: (r.profit >= 0 ? AppColors.good : AppColors.danger).withValues(alpha: 0.15),
                            child: Text('${i + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          title: Text(r.name),
                          subtitle: Text(
                            'sold ${num2(r.qtySold)} ${r.unit}  •  ${r.invoices} bill(s)  •  '
                            'cost ${money(r.cost, symbol: sym)}'
                            '${r.discount > 0 ? '  •  discounts ${money(r.discount, symbol: sym)}' : ''}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(money(r.profit, symbol: sym),
                                style: TextStyle(fontWeight: FontWeight.bold,
                                    color: r.profit >= 0 ? AppColors.good : AppColors.danger)),
                            Text('${r.margin.toStringAsFixed(1)}% of ${money(r.gross, symbol: sym)}',
                                style: const TextStyle(fontSize: 11)),
                          ]),
                        );
                      },
                    ),
            ),
            SectionCard(
              title: 'Who is selling what',
              child: _cashiers.isEmpty
                  ? const EmptyState(
                      icon: Icons.badge_outlined,
                      title: 'No cashier activity',
                      message: 'No completed sales were recorded in the selected range yet.',
                    )
                  : ListView.separated(
                      itemCount: _cashiers.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final r = _cashiers[i];
                        return ListTile(
                          leading: const Icon(Icons.person_outline),
                          title: Text(r.cashier),
                          subtitle: Text(
                            '${r.invoices} bill(s)  •  ${num2(r.items)} items  •  '
                            'average ${money(r.averageBill, symbol: sym)}\n'
                            'discounts given ${money(r.discountsGiven, symbol: sym)}'
                            '${r.voids > 0 ? '  •  ${r.voids} cancelled' : ''}'
                            '${r.refunds > 0 ? '  •  refunds ${money(r.refunds, symbol: sym)}' : ''}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          isThreeLine: true,
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(money(r.sales, symbol: sym),
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('profit ${money(r.profit, symbol: sym)}',
                                style: const TextStyle(fontSize: 11)),
                          ]),
                        );
                      },
                    ),
            ),
            SectionCard(
              title: 'Sitting on the shelf',
              actions: [
                DropdownButton<int>(
                  value: _deadDays,
                  items: const [
                    DropdownMenuItem(value: 30, child: Text('30 days')),
                    DropdownMenuItem(value: 60, child: Text('60 days')),
                    DropdownMenuItem(value: 90, child: Text('90 days')),
                    DropdownMenuItem(value: 180, child: Text('180 days')),
                  ],
                  onChanged: (v) {
                    setState(() => _deadDays = v ?? 60);
                    _loadAll();
                  },
                ),
              ],
              child: _dead.isEmpty
                  ? EmptyState(
                      icon: Icons.thumb_up_outlined,
                      title: 'Nothing is stuck',
                      message: 'Every product with stock has sold in the last $_deadDays days, or there are no stock rows yet.',)
                  : ListView.separated(
                      itemCount: _dead.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final r = _dead[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            r.daysIdle > 9000 ? Icons.fiber_new : Icons.hourglass_empty,
                            color: r.value > 20000 ? AppColors.danger : AppColors.warn),
                          title: Text(r.name),
                          subtitle: Text(
                            '${num2(r.stockQty)} ${r.unit} in stock  •  '
                            '${r.daysIdle > 9000 ? 'never sold' : 'last sold ${r.daysIdle} days ago'}'
                            '${r.categoryName.isEmpty ? '' : '  •  ${r.categoryName}'}'
                            '${r.expiryDate.isEmpty ? '' : '  •  expires ${r.expiryDate}'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Text(money(r.value, symbol: sym),
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ]),
    );
  }
}
