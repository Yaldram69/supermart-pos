import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/reporting.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/receipt.dart';

/// Stock control: what to reorder, every movement in and out, and booking in
/// deliveries from suppliers.
class StockScreen extends StatefulWidget {
  const StockScreen({super.key});

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: TabBar(
                controller: _tabs,
                isScrollable: false,
                indicatorSize: TabBarIndicatorSize.tab,
                labelPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                tabs: const [
                  Tab(icon: Icon(Icons.insights_outlined), text: 'Intelligence'),
                  Tab(icon: Icon(Icons.warning_amber_outlined), text: 'Reorder list'),
                  Tab(icon: Icon(Icons.local_shipping_outlined), text: 'Purchases'),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: const [_IntelligenceTab(), _ReorderTab(), _PurchasesTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IntelligenceTab extends StatefulWidget {
  const _IntelligenceTab();

  @override
  State<_IntelligenceTab> createState() => _IntelligenceTabState();
}

class _IntelligenceTabState extends State<_IntelligenceTab> {
  /// Set when the stock list could not be loaded; shown in place of the lists.
  String? _loadError;
  bool _loading = true;
  List<Map<String, dynamic>> _catalogue = [];
  List<Map<String, dynamic>> _lowStock = [];
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final state = context.read<AppState>();
      final catalogue = await state.api.catalogue();
      final lowStock = await state.api.lowStock();
      if (mounted) {
        setState(() {
          _catalogue = catalogue;
          _lowStock = lowStock;
          _loadError = null;
        });
      }
    } catch (e) {
      // Keep the failure visible on the screen. An empty list here would otherwise
      // read as "Stock health looks good" when the data simply did not load.
      if (mounted) {
        setState(() => _loadError = e is AppError ? e.message : 'Check the connection and try again.');
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final state = context.read<AppState>();
    final summary = buildInventoryHealthSummary(_catalogue, _lowStock);
    final intelligence = buildInventoryIntelligenceSummary(_catalogue);
    final riskRows = summary.riskRows;
    final actionPlan = buildStockActionPlan(_catalogue, expiryAlertDays: state.store?.expiryAlertDays ?? 10);

    return Column(children: [
      SectionCard(
        child: Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _statTile('Active SKUs', summary.totalSkus.toString(), Icons.inventory_2_outlined, AppColors.info),
            _statTile('Low stock', summary.lowStockCount.toString(), Icons.warning_amber_rounded, AppColors.warn),
            _statTile('Out of stock', summary.outOfStockCount.toString(), Icons.remove_shopping_cart, AppColors.danger),
            _statTile('Reorder spend', money(summary.reorderValue), Icons.attach_money, AppColors.cash),
            _statTile('Reorder alerts', intelligence.reorderSuggestions.length.toString(), Icons.shopping_cart_checkout, AppColors.info),
            _statTile('Dead stock', intelligence.deadStock.length.toString(), Icons.hourglass_bottom, AppColors.warn),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      Expanded(
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.zero,
            children: [
              SectionCard(
                title: 'Critical stock items',
                padding: const EdgeInsets.all(8),
                child: _loadError != null
                    ? EmptyState(
                        icon: Icons.cloud_off_outlined,
                        title: 'Could not load stock',
                        message: _loadError,
                      )
                    : riskRows.isEmpty
                    ? const EmptyState(
                        icon: Icons.check_circle_outline,
                        title: 'Stock health looks good',
                        message: 'No items are currently at risk.',
                      )
                    : LayoutBuilder(
                        builder: (context, tableConstraints) => SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minWidth: tableConstraints.maxWidth),
                            child: DataTable(
                              columnSpacing: 18,
                              horizontalMargin: 12,
                              columns: const [
                                DataColumn(label: Text('Product')),
                                DataColumn(label: Text('In stock'), numeric: true),
                                DataColumn(label: Text('Reorder at'), numeric: true),
                                DataColumn(label: Text('Coverage'), numeric: true),
                                DataColumn(label: Text('Suggested order'), numeric: true),
                              ],
                              rows: [
                                for (final row in riskRows)
                                  DataRow(cells: [
                                    DataCell(Text(row.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                                    DataCell(Text(qtyStr(row.stockQty))),
                                    DataCell(Text(qtyStr(row.reorderLevel))),
                                    DataCell(Text('${(row.coverageRatio * 100).clamp(0.0, 100.0).toStringAsFixed(0)}%')),
                                    DataCell(Text(qtyStr(row.suggestedOrderQty))),
                                  ]),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: AppSpacing.md),
              SectionCard(
                title: 'Reorder suggestions',
                padding: const EdgeInsets.all(8),
                child: intelligence.reorderSuggestions.isEmpty
                    ? const EmptyState(
                        icon: Icons.done_all,
                        title: 'No reorder suggestions',
                        message: 'Everything is comfortably above its reorder point.',
                      )
                    : LayoutBuilder(
                        builder: (context, tableConstraints) => SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minWidth: tableConstraints.maxWidth),
                            child: DataTable(
                              columnSpacing: 18,
                              horizontalMargin: 12,
                              columns: const [
                                DataColumn(label: Text('Product')),
                                DataColumn(label: Text('Supplier')),
                                DataColumn(label: Text('Stock')),
                                DataColumn(label: Text('Avg/day')),
                                DataColumn(label: Text('Lead time')),
                                DataColumn(label: Text('Order qty')),
                              ],
                              rows: [
                                for (final row in intelligence.reorderSuggestions)
                                  DataRow(cells: [
                                    DataCell(Text(row.productName)),
                                    DataCell(Text(row.supplierName)),
                                    DataCell(Text(qtyStr(row.stockQty))),
                                    DataCell(Text(qtyStr(row.avgDailySales))),
                                    DataCell(Text('${row.leadTimeDays} days')),
                                    DataCell(Text(qtyStr(row.recommendedOrderQty))),
                                  ]),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: AppSpacing.md),
              SectionCard(
                title: 'Action plan',
                child: actionPlan.isEmpty
                    ? const EmptyState(
                        icon: Icons.fact_check_outlined,
                        title: 'No action items',
                        message: 'Everything is in healthy range and no stock actions are required right now.',
                      )
                    : Column(
                        children: [
                          for (final item in actionPlan.take(6))
                            Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: item.severity == 'high'
                                    ? AppColors.danger.withValues(alpha: 0.08)
                                    : item.severity == 'medium'
                                        ? AppColors.warn.withValues(alpha: 0.08)
                                        : AppColors.info.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: item.severity == 'high'
                                      ? AppColors.danger.withValues(alpha: 0.2)
                                      : item.severity == 'medium'
                                          ? AppColors.warn.withValues(alpha: 0.2)
                                          : AppColors.info.withValues(alpha: 0.2),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    item.severity == 'high'
                                        ? Icons.priority_high_rounded
                                        : item.severity == 'medium'
                                            ? Icons.warning_amber_rounded
                                            : Icons.info_outline,
                                    color: item.severity == 'high'
                                        ? AppColors.danger
                                        : item.severity == 'medium'
                                            ? AppColors.warn
                                            : AppColors.info,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.action,
                                          style: const TextStyle(fontWeight: FontWeight.w600),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          item.reason,
                                          style: Theme.of(context).textTheme.bodySmall,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${item.supplierName.isNotEmpty ? 'Supplier: ${item.supplierName} • ' : ''}Stock ${qtyStr(item.stockQty)} • Reorder ${qtyStr(item.reorderLevel)}${item.expiryDays <= 365 ? ' • Expires in ${item.expiryDays}d' : ''}',
                                          style: Theme.of(context).textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: AppSpacing.md),
              SectionCard(
                title: 'Stock aging',
                child: Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.md,
                  children: [
                    for (final band in intelligence.agingBands)
                      _statTile(band.label, '${band.count}', Icons.timelapse_rounded, band.label.contains('90+') ? AppColors.warn : AppColors.info),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              SectionCard(
                title: 'Dead stock / slow movers',
                child: intelligence.deadStock.isEmpty
                    ? const EmptyState(
                        icon: Icons.thumb_up_alt_outlined,
                        title: 'No dead stock detected',
                        message: 'Inventory is turning over as expected.',
                      )
                    : LayoutBuilder(
                        builder: (context, tableConstraints) => SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minWidth: tableConstraints.maxWidth),
                            child: DataTable(
                              columnSpacing: 18,
                              horizontalMargin: 12,
                              columns: const [
                                DataColumn(label: Text('Product')),
                                DataColumn(label: Text('Stock')),
                                DataColumn(label: Text('Idle days')),
                                DataColumn(label: Text('Supplier')),
                              ],
                              rows: [
                                for (final row in intelligence.deadStock)
                                  DataRow(cells: [
                                    DataCell(Text(row['name'].toString())),
                                    DataCell(Text(qtyStr(toD(row['stock_qty'])))),
                                    DataCell(Text('${toD(row['days_since_sale']).toInt()} days')),
                                    DataCell(Text(row['supplier'].toString())),
                                  ]),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    ]);
  }

  Widget _statTile(String label, String value, IconData icon, Color color) => SizedBox(
        width: 190,
        child: StatCard(label: label, value: value, icon: icon, color: color, sub: 'inventory health'),
      );
}

class _ReorderTab extends StatefulWidget {
  const _ReorderTab();
  @override
  State<_ReorderTab> createState() => _ReorderTabState();
}

class _ReorderTabState extends State<_ReorderTab> {
  List<LowStockRow> _rows = [];
  bool _loading = true;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final raw = await context.read<AppState>().api.lowStock();
      if (mounted) setState(() => _rows = raw.map(LowStockRow.new).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Build a draft order from everything that is low: pick the supplier, check
  /// the quantities, save. It appears under Purchases until the delivery comes.
  Future<void> _makeOrder() async {
    final state = context.read<AppState>();
    final suppliers = await state.api.suppliers();
    if (!mounted) return;
    if (suppliers.isEmpty) {
      showMessage(context, 'Add a supplier first (Suppliers screen)', error: true);
      return;
    }

    // group the suggestions by the supplier each product is linked to
    final bySupplier = <String, List<ReorderRow>>{};
    for (final r in _rows.map((e) => ReorderRow(e.raw))) {
      final key = r.supplierId.isEmpty ? 'none' : r.supplierId;
      bySupplier.putIfAbsent(key, () => []).add(r);
    }

    String? supplierId = bySupplier.keys.firstWhere(
      (k) => k != 'none', orElse: () => suppliers.first['id'] as String);
    final qtyCtl = <String, TextEditingController>{};
    for (final r in bySupplier[supplierId] ?? const <ReorderRow>[]) {
      qtyCtl[r.id] = TextEditingController(text: r.suggested.toStringAsFixed(0));
    }
    final note = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) {
          final lines = bySupplier[supplierId] ?? const <ReorderRow>[];
          final total = lines.fold<double>(
              0, (a, r) => a + (parseAmount(qtyCtl[r.id]?.text ?? '0') ?? 0) * r.costPrice);
          return AlertDialog(
            title: const Text('Create a purchase order'),
            content: SizedBox(
              width: 640,
              height: 460,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DropdownButtonFormField<String>(
                  initialValue: supplierId,
                  decoration: const InputDecoration(labelText: 'Order from'),
                  items: suppliers
                      .map((s) => DropdownMenuItem(
                          value: s['id'] as String,
                          child: Text((s['name'] ?? '') as String)))
                      .toList(),
                  onChanged: (v) {
                    setLocal(() {
                      supplierId = v;
                      for (final r in bySupplier[supplierId] ?? const <ReorderRow>[]) {
                        qtyCtl.putIfAbsent(r.id, () => TextEditingController(text: r.suggested.toStringAsFixed(0)));
                      }
                    });
                  },
                ),
                const SizedBox(height: 12),
                Text('${lines.length} item(s)  •  order value ${money(total)}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const Divider(),
                Expanded(
                  child: lines.isEmpty
                      ? const EmptyState(
                          icon: Icons.inbox_outlined,
                          title: 'Nothing for this supplier',
                          message: 'Assign a supplier to your low-stock products, or pick another supplier.')
                      : ListView.builder(
                          itemCount: lines.length,
                          itemBuilder: (c, i) {
                            final r = lines[i];
                            return Row(children: [
                              Expanded(child: Text(r.name, overflow: TextOverflow.ellipsis)),
                              SizedBox(
                                width: 90,
                                child: TextField(
                                  controller: qtyCtl[r.id],
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: 'Qty'),
                                  onChanged: (_) => setLocal(() {}),
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 110,
                                child: Text('@ ${money(r.costPrice)}',
                                    style: Theme.of(context).textTheme.bodySmall),
                              ),
                            ]);
                          },
                        ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Note for the supplier (optional)'),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(
                onPressed: lines.isEmpty ? null : () => Navigator.pop(c, true),
                child: const Text('Save as draft order'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;

    final items = (bySupplier[supplierId] ?? const <ReorderRow>[])
        .map((r) => {
              'product_id': r.id,
              'qty': parseAmount(qtyCtl[r.id]?.text ?? '') ?? 0,
              'unit_cost': r.costPrice,
            })
        .where((e) => toD(e['qty']) > 0)
        .toList();
    if (items.isEmpty) {
      showMessage(context, 'Nothing left to order', error: true);
      return;
    }

    try {
      final res = await state.api.createPurchaseOrder({
        'supplier_id': supplierId,
        'items': items,
        'note': note.text.trim(),
      });
      if (!mounted) return;
      showMessage(context,
          'Draft order ${res['po_no']} saved — receive it under Purchases when the goods arrive');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_rows.isEmpty) {
      return const EmptyState(
        icon: Icons.thumb_up_outlined,
        title: 'Nothing needs reordering',
        message: 'Every product is above its reorder level.',
      );
    }
    final orderValue = _rows.fold<double>(0, (a, r) => a + r.suggested * r.costPrice);
    return Column(children: [
      SectionCard(
        child: Row(children: [
          StatusPill(text: '${_rows.length} products to order', color: AppColors.warn),
          const SizedBox(width: AppSpacing.sm),
          StatusPill(text: 'About ${money(orderValue)} to spend', color: AppColors.info),
          const Spacer(),
          FilledButton.icon(
            onPressed: state.isManager ? () => _makeOrder() : null,
            icon: const Icon(Icons.playlist_add_check),
            label: const Text('Create purchase order'),
          ),
          const SizedBox(width: AppSpacing.sm),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ]),
      ),
      const SizedBox(height: AppSpacing.md),
      // The ListView is the scrolling part (same pattern as the Intelligence
      // tab), so it always gets a fixed height from Expanded and scrolls.
      Expanded(
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.zero,
            children: [
              SectionCard(
                padding: const EdgeInsets.all(8),
                child: LayoutBuilder(
                  builder: (context, tableConstraints) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: tableConstraints.maxWidth),
                      child: DataTable(
                        columnSpacing: 18,
                        horizontalMargin: 12,
                        columns: const [
                          DataColumn(label: Text('Product')),
                          DataColumn(label: Text('Supplier')),
                          DataColumn(label: Text('In stock'), numeric: true),
                          DataColumn(label: Text('Reorder at'), numeric: true),
                          DataColumn(label: Text('Suggested order'), numeric: true),
                          DataColumn(label: Text('Cost'), numeric: true),
                        ],
                        rows: [
                          for (final r in _rows)
                            DataRow(cells: [
                              DataCell(Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                              DataCell(Text('${r.supplierName}${r.supplierPhone.isEmpty ? '' : '\n${r.supplierPhone}'}')),
                              DataCell(Text('${qtyStr(r.stockQty)} ${r.unit}',
                                  style: TextStyle(
                                      color: r.stockQty <= 0 ? AppColors.danger : AppColors.warn,
                                      fontWeight: FontWeight.bold))),
                              DataCell(Text(qtyStr(r.reorderLevel))),
                              DataCell(Text('${qtyStr(r.suggested)} ${r.unit}')),
                              DataCell(Text(num2(r.costPrice))),
                            ]),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _PurchasesTab extends StatefulWidget {
  const _PurchasesTab();
  @override
  State<_PurchasesTab> createState() => _PurchasesTabState();
}

class _PurchasesTabState extends State<_PurchasesTab> {
  List<PurchaseRow> _rows = [];
  bool _loading = true;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _drafts = [];

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final state = context.read<AppState>();
      final raw = await state.api.purchases();
      _drafts = await state.api.draftPurchases();
      if (mounted) setState(() => _rows = raw.map(PurchaseRow.new).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final summary = buildPurchaseOrderSummary(
      _rows.map((row) => row.raw).toList(),
      _drafts,
    );

    // The whole tab is one ListView (same pattern as the Intelligence tab), so
    // the info card, summary, draft orders and purchases table all scroll
    // together no matter how many drafts there are.
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: ListView(
        controller: _scroll,
        padding: EdgeInsets.zero,
        children: [
          SectionCard(
            child: Row(children: [
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(
                child: Text('Booking in a delivery adds the quantity to stock on every PC and '
                    'recalculates the average cost price.'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  await showDialog(context: context, builder: (_) => const _ReceivePurchaseDialog());
                  await _load();
                },
                icon: const Icon(Icons.add),
                label: const Text('Book in a delivery'),
              ),
            ]),
          ),
          const SizedBox(height: AppSpacing.md),
          SectionCard(
            child: Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                _summaryTile('Received', summary.receivedCount.toString(), Icons.receipt_long, AppColors.good),
                _summaryTile('Open drafts', summary.openDraftCount.toString(), Icons.assignment_outlined, AppColors.info),
                _summaryTile('Open value', money(summary.totalOpenValue), Icons.account_balance_wallet, AppColors.cash),
                _summaryTile('Top supplier', summary.supplierSpend.isEmpty ? '—' : summary.supplierSpend.first.supplierName, Icons.business, AppColors.warn),
              ],
            ),
          ),
          if (_drafts.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            SectionCard(
              title: 'Draft orders waiting for delivery (${_drafts.length})',
              actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
              child: Column(children: [
                for (final d in _drafts)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.assignment_outlined, color: AppColors.info),
                    title: Text('${d['po_no']}  •  ${d['supplier_name'] ?? 'no supplier'}'),
                    subtitle: Text('${d['item_count']} item(s)  •  about '
                        '${money(toD(d['total']))}  •  ordered ${agoLabel(dt(d, 'created_at'))}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      TextButton.icon(
                        onPressed: () async {
                          final state = context.read<AppState>();
                          final store = state.store;
                          if (store == null) return;
                          // the supplier's phone/address go on the printed order
                          var phone = '', address = '';
                          try {
                            for (final sup in await state.api.suppliers()) {
                              if (sup['id'] == d['supplier_id']) {
                                phone = (sup['phone'] ?? '').toString();
                                address = (sup['address'] ?? '').toString();
                                break;
                              }
                            }
                          } catch (_) {/* printing still works without them */}
                          if (!context.mounted) return;
                          try {
                            await ReceiptPrinter.printPurchaseOrder(
                              order: d,
                              store: store,
                              supplierPhone: phone,
                              supplierAddress: address,
                            );
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                        icon: const Icon(Icons.print_outlined, size: 18),
                        label: const Text('Print order'),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await showDialog(
                              context: context,
                              builder: (_) => _ReceivePurchaseDialog(draft: d));
                          await _load();
                        },
                        icon: const Icon(Icons.inventory_2_outlined, size: 18),
                        label: const Text('Receive'),
                      ),
                      IconButton(
                        tooltip: 'Delete draft',
                        onPressed: () async {
                          final api = context.read<AppState>().api;
                          if (!await confirm(context,
                              title: 'Delete ${d['po_no']}?',
                              message: 'The draft order is removed. Nothing was added to stock.',
                              okLabel: 'Delete')) {
                            return;
                          }
                          if (!context.mounted) return;
                          try {
                            await api.deletePurchase(d['id'] as String);
                            await _load();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                        icon: const Icon(Icons.delete_outline, size: 18),
                      ),
                    ]),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          if (_rows.isEmpty)
            const SectionCard(
              child: EmptyState(
                  icon: Icons.local_shipping_outlined,
                  title: 'No purchases booked in yet',
                  message: 'Use “Book in a delivery” when a supplier drops goods off.'),
            )
          else
            SectionCard(
              title: 'Booked-in purchases',
              padding: const EdgeInsets.all(8),
              child: LayoutBuilder(
                builder: (context, tableConstraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: tableConstraints.maxWidth),
                    child: DataTable(
                      columnSpacing: 18,
                      horizontalMargin: 12,
                      columns: const [
                        DataColumn(label: Text('PO number')),
                        DataColumn(label: Text('Supplier')),
                        DataColumn(label: Text('Date')),
                        DataColumn(label: Text('Items'), numeric: true),
                        DataColumn(label: Text('Total'), numeric: true),
                        DataColumn(label: Text('Paid'), numeric: true),
                        DataColumn(label: Text('Still owed'), numeric: true),
                      ],
                      rows: [
                        for (final p in _rows)
                          DataRow(cells: [
                            DataCell(Text(p.poNo, style: const TextStyle(fontWeight: FontWeight.w600))),
                            DataCell(Text(p.supplierName)),
                            DataCell(Text(p.orderDate == null ? '' : dateFmt.format(p.orderDate!))),
                            DataCell(Text(p.itemCount.toString())),
                            DataCell(Text(num2(p.total))),
                            DataCell(Text(num2(p.paid))),
                            DataCell(Text(num2(p.total - p.paid),
                                style: TextStyle(
                                    color: p.total - p.paid > 0 ? AppColors.warn : AppColors.good))),
                          ]),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }

  Widget _summaryTile(String label, String value, IconData icon, Color color) => SizedBox(
        width: 190,
        child: StatCard(label: label, value: value, icon: icon, color: color, sub: 'purchase workflow'),
      );
}

class _ReceivePurchaseDialog extends StatefulWidget {
  const _ReceivePurchaseDialog({this.draft});
  /// When a draft order is passed in, the dialog opens filled with it, so the
  /// delivery only needs the quantities corrected and a date.
  final Map<String, dynamic>? draft;
  @override
  State<_ReceivePurchaseDialog> createState() => _ReceivePurchaseDialogState();
}

class _ReceivePurchaseDialogState extends State<_ReceivePurchaseDialog> {
  String? _supplierId;
  final List<Map<String, dynamic>> _lines = [];

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    if (d != null) {
      _supplierId = d['supplier_id'] as String?;
      _invoiceRef.text = (d['note'] ?? '') as String;
      for (final raw in (d['items'] as List? ?? const [])) {
        final it = (raw as Map).cast<String, dynamic>();
        _lines.add({
          'product_id': it['product_id'],
          'name': it['name'] ?? '',
          '_qty': TextEditingController(text: toD(it['qty']).toStringAsFixed(0)),
          '_cost': TextEditingController(text: toD(it['unit_cost']).toStringAsFixed(2)),
          '_sale': TextEditingController(text: toD(it['sale_price']).toStringAsFixed(2)),
          '_batch': TextEditingController(text: (it['batch_no'] ?? '').toString()),
          '_mfg': TextEditingController(text: (it['mfg_date'] ?? '').toString()),
          '_expiry': TextEditingController(text: (it['expiry_date'] ?? '').toString()),
        });
      }
    }
  }
  final _discount = TextEditingController(text: '0');
  final _paid = TextEditingController(text: '0');
  final _invoiceRef = TextEditingController();
  bool _busy = false;

  /// Adds a line and gives it its own batch / expiry / manufacturing boxes.
  void _addLine(AdminProduct p, {double? cost, double? sale, double qty = 1}) {
    _lines.add({
      'product_id': p.id,
      'name': p.name,
      '_qty': TextEditingController(text: qty.toStringAsFixed(0)),
      '_cost': TextEditingController(text: (cost ?? 0).toStringAsFixed(2)),
      '_sale': TextEditingController(text: (sale ?? 0).toStringAsFixed(2)),
      '_batch': TextEditingController(),
      '_mfg': TextEditingController(),
      '_expiry': TextEditingController(text: _defaultExpiry(p)),
    });
  }

  /// If the product already has an "expires on" date we start from it, so the
  /// shop does not have to type it again for a straightforward repeat order.
  String _defaultExpiry(AdminProduct p) {
    final d = (p.raw['expiry_date'] ?? '').toString();
    return d.length >= 10 ? d.substring(0, 10) : '';
  }

  bool _needsExpiry() => context.read<AppState>().store?.requireExpiry ?? false;

  @override
  void dispose() {
    for (final l in _lines) {
      for (final key in const ['_qty', '_cost', '_sale', '_batch', '_mfg', '_expiry']) {
        (l[key] as TextEditingController?)?.dispose();
      }
    }
    _discount.dispose();
    _paid.dispose();
    _invoiceRef.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final total = _lines.fold<double>(
        0, (a, l) => a + (parseAmount((l['_qty'] as TextEditingController).text) ?? 0) *
            (parseAmount((l['_cost'] as TextEditingController).text) ?? 0));
    final grand = total - (parseAmount(_discount.text) ?? 0);

    return AlertDialog(
      title: Text(widget.draft == null
          ? 'Book in a delivery'
          : 'Receive ${widget.draft!['po_no']}'),
      content: SizedBox(
        width: 760,
        height: 560,
        child: Column(children: [
          Row(children: [
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: state.api.suppliers(),
                builder: (c, snap) => DropdownButtonFormField<String>(
                  initialValue: _supplierId,
                  decoration: const InputDecoration(labelText: 'Supplier *'),
                  items: [
                    for (final s in snap.data ?? [])
                      DropdownMenuItem(value: s['id'] as String, child: Text(s['name'] as String)),
                  ],
                  onChanged: (v) => setState(() => _supplierId = v),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _invoiceRef,
                decoration: const InputDecoration(labelText: 'Supplier invoice / bill no.'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton.tonalIcon(
              onPressed: () async {
                final product = await _pickProduct(state);
                if (product != null) {
                  setState(() => _addLine(product,
                      // no guessed cost: an unknown cost is typed in, and the save checks it
                      cost: product.costPrice,
                      sale: product.salePrice));
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Add product'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text('${_lines.length} line(s) — total ${money(total)}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 8),
          if (_lines.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Leave batch/expiry blank for goods that do not expire. Anything you fill in '
                'shows up in the Expiry & batches screen, and quick-fill buttons are beside each date.',
                style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _lines.isEmpty
                ? const EmptyState(icon: Icons.inventory, title: 'Add what arrived')
                : ListView.builder(
                    itemCount: _lines.length,
                    itemBuilder: (c, i) {
                      final l = _lines[i];
                      final expiry = (l['_expiry'] as TextEditingController).text.trim();
                      final expired = expiry.isNotEmpty &&
                          (DateTime.tryParse(expiry)?.isBefore(DateTime.now()) ?? false);
                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          border: Border.all(color: Theme.of(context).dividerColor),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(children: [
                          Row(children: [
                            Expanded(
                                flex: 5,
                                child: Text(l['name'] as String,
                                    style: const TextStyle(fontWeight: FontWeight.w600))),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: l['_qty'] as TextEditingController,
                                decoration: const InputDecoration(labelText: 'Qty'),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: l['_cost'] as TextEditingController,
                                decoration: const InputDecoration(labelText: 'Cost'),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: l['_sale'] as TextEditingController,
                                decoration: const InputDecoration(labelText: 'New sale price'),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove line',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => setState(() {
                                for (final key in const ['_qty', '_cost', '_sale', '_batch', '_mfg', '_expiry']) {
                                  (l[key] as TextEditingController?)?.dispose();
                                }
                                _lines.removeAt(i);
                              }),
                            ),
                          ]),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: l['_batch'] as TextEditingController,
                                decoration: const InputDecoration(
                                    labelText: 'Batch no. (optional)', isDense: true),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: l['_expiry'] as TextEditingController,
                                decoration: InputDecoration(
                                  labelText: _needsExpiry() ? 'Expiry date *' : 'Expiry date',
                                  hintText: 'yyyy-mm-dd',
                                  prefixIcon: const Icon(Icons.event, size: 16),
                                  isDense: true,
                                  errorText: expired ? 'already out of date' : null,
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: l['_mfg'] as TextEditingController,
                                decoration: const InputDecoration(
                                    labelText: 'Made on (optional)', hintText: 'yyyy-mm-dd', isDense: true),
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Fill expiry quickly',
                              icon: const Icon(Icons.bolt_outlined, size: 20),
                              onSelected: (v) {
                                final days = switch (v) {
                                  'm6' => 182,
                                  'y1' => 365,
                                  'y2' => 730,
                                  _ => int.parse(v),
                                };
                                final d = DateTime.now().add(Duration(days: days));
                                (l['_expiry'] as TextEditingController).text =
                                    d.pkDay;
                                setState(() {});
                              },
                              itemBuilder: (c) => const [
                                PopupMenuItem(value: '30', child: Text('Shelf life 1 month (+30 days)')),
                                PopupMenuItem(value: '60', child: Text('Shelf life 2 months')),
                                PopupMenuItem(value: '90', child: Text('Shelf life 3 months')),
                                PopupMenuItem(value: 'm6', child: Text('Shelf life 6 months')),
                                PopupMenuItem(value: 'y1', child: Text('Shelf life 1 year')),
                                PopupMenuItem(value: 'y2', child: Text('Shelf life 2 years')),
                              ],
                            ),
                          ]),
                          if (expired)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  'Careful: this delivery is already past its expiry date.',
                                  style: TextStyle(fontSize: 11.5, color: AppColors.danger),
                                ),
                              ),
                            ),
                        ]),
                      );
                    },
                  ),
          ),
          const Divider(height: 20),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _discount,
                decoration: const InputDecoration(labelText: 'Discount on the bill'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _paid,
                decoration: const InputDecoration(labelText: 'Amount paid now'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
            ),
            const SizedBox(width: 12),
            Text('Payable ${money(grand)}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  if (_supplierId == null || _lines.isEmpty) {
                    showMessage(context, 'Pick a supplier and add at least one product.', error: true);
                    return;
                  }
                  // every line must carry a real quantity, a real cost and, where the
                  // product expires, a real expiry date
                  for (final l in _lines) {
                    final name = (l['name'] ?? 'an item').toString();
                    final qty = parseAmount((l['_qty'] as TextEditingController).text) ?? 0;
                    final cost = parseAmount((l['_cost'] as TextEditingController).text) ?? 0;
                    final expiry = (l['_expiry'] as TextEditingController).text.trim();
                    if (qty <= 0) {
                      showMessage(context, 'Type how many $name you received.', error: true);
                      return;
                    }
                    if (cost <= 0) {
                      showMessage(context, 'Type the cost price for $name.', error: true);
                      return;
                    }
                    if (_needsExpiry() && expiry.isEmpty) {
                      showMessage(context, 'Type the expiry date for $name.', error: true);
                      return;
                    }
                    if (expiry.isNotEmpty && DateTime.tryParse(expiry) == null) {
                      showMessage(context, 'The expiry date for $name must look like 2027-03-31.', error: true);
                      return;
                    }
                  }
                  setState(() => _busy = true);
                  try {
                    final res = await state.api.receivePurchase({
                      if (widget.draft != null) 'id': widget.draft!['id'],
                      'supplier_id': _supplierId,
                      'discount': parseAmount(_discount.text) ?? 0,
                      'paid_amount': parseAmount(_paid.text) ?? 0,
                      'payment_method': 'cash',
                      'invoice_ref': _invoiceRef.text,
                      'items': _lines
                          .map((l) => {
                                'product_id': l['product_id'],
                                'qty': parseAmount((l['_qty'] as TextEditingController).text) ?? 0,
                                'unit_cost': parseAmount((l['_cost'] as TextEditingController).text) ?? 0,
                                'sale_price': parseAmount((l['_sale'] as TextEditingController).text) ?? 0,
                                'batch_no': (l['_batch'] as TextEditingController).text.trim().isEmpty
                                    ? null
                                    : (l['_batch'] as TextEditingController).text.trim(),
                                'mfg_date': (l['_mfg'] as TextEditingController).text.trim().isEmpty
                                    ? null
                                    : (l['_mfg'] as TextEditingController).text.trim(),
                                'expiry_date': (l['_expiry'] as TextEditingController).text.trim().isEmpty
                                    ? null
                                    : (l['_expiry'] as TextEditingController).text.trim(),
                              })
                          .toList(),
                    });
                    await state.refreshCatalogue();
                    if (context.mounted) {
                      Navigator.pop(context);
                      showMessage(context,
                          'Delivery ${res['po_no']} booked in — stock updated on all PCs');
                    }
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                    setState(() => _busy = false);
                  }
                },
          icon: const Icon(Icons.save),
          label: Text(_busy ? 'Saving…' : 'Book in and update stock'),
        ),
      ],
    );
  }

  Future<AdminProduct?> _pickProduct(AppState state) async {
    final rows = await state.api.adminProducts();
    if (!mounted) return null;
    final products = rows.map(AdminProduct.new).toList();
    final search = TextEditingController();
    return showDialog<AdminProduct>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) {
          final list = products
              .where((p) =>
                  search.text.isEmpty ||
                  p.name.toLowerCase().contains(search.text.toLowerCase()) ||
                  p.barcode.contains(search.text))
              .take(60)
              .toList();
          return AlertDialog(
            title: const Text('Which product arrived?'),
            content: SizedBox(
              width: 520,
              height: 420,
              child: Column(children: [
                TextField(
                  controller: search,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Search or scan', prefixIcon: Icon(Icons.search)),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (c, i) => ListTile(
                      dense: true,
                      title: Text(list[i].name),
                      subtitle: Text('stock ${qtyStr(list[i].stockQty)} • cost ${num2(list[i].costPrice)}'),
                      onTap: () => Navigator.pop(c, list[i]),
                    ),
                  ),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            ],
          );
        },
      ),
    );
  }
}