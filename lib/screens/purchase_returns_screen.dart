import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Sending goods back to the supplier: damaged cartons, short-expiry stock the
/// supplier agreed to take back, or a wrong item delivered. The stock leaves
/// the shop and the money comes off what you owe that supplier.
class PurchaseReturnsScreen extends StatefulWidget {
  const PurchaseReturnsScreen({super.key});

  @override
  State<PurchaseReturnsScreen> createState() => _PurchaseReturnsScreenState();
}

class _PurchaseReturnsScreenState extends State<PurchaseReturnsScreen> {
  List<PurchaseReturnRow> _rows = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final raw = await context.read<AppState>().api.purchaseReturns();
      if (mounted) setState(() => _rows = raw.map(PurchaseReturnRow.new).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newReturn() async {
    final state = context.read<AppState>();
    List<Map<String, dynamic>> suppliers;
    try {
      suppliers = await state.api.suppliers();
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    if (suppliers.isEmpty) {
      showMessage(context, 'Add a supplier first (Suppliers screen)', error: true);
      return;
    }

    String? supplierId = suppliers.first['id'] as String;
    final lines = <_ReturnLine>[];
    final note = TextEditingController();
    final reason = TextEditingController(text: 'Damaged / expired');
    String settled = 'payable';

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) {
          final total = lines.fold<double>(0, (a, l) => a + l.qty * l.cost);
          return AlertDialog(
            title: const Text('Return goods to a supplier'),
            content: SizedBox(
              width: 720,
              height: 520,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      initialValue: supplierId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Supplier *'),
                      items: [
                        for (final s in suppliers)
                          DropdownMenuItem(value: s['id'] as String, child: Text(s['name'] as String)),
                      ],
                      onChanged: (v) => setLocal(() => supplierId = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      initialValue: settled,
                      decoration: const InputDecoration(labelText: 'Money comes back as'),
                      items: const [
                        DropdownMenuItem(value: 'payable', child: Text('Reduce what we owe')),
                        DropdownMenuItem(value: 'cash', child: Text('Supplier pays cash/cheque')),
                        DropdownMenuItem(value: 'replacement', child: Text('Replacement goods')),
                      ],
                      onChanged: (v) => setLocal(() => settled = v ?? 'payable'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final picked = await _pickProduct(state);
                      if (picked != null) {
                        setLocal(() => lines.add(picked));
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add product'),
                  ),
                  const SizedBox(width: 12),
                  Text('${lines.length} line(s)  •  ${money(total)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
                const Divider(),
                Expanded(
                  child: lines.isEmpty
                      ? const EmptyState(
                          icon: Icons.keyboard_return,
                          title: 'Add what is going back',
                          message: 'Pick the products, set the quantity and the cost you paid. '
                              'Stock and what you owe the supplier both change when you confirm.')
                      : ListView.builder(
                          itemCount: lines.length,
                          itemBuilder: (c, i) {
                            final l = lines[i];
                            // keyed by the line itself, so removing a row does not leave
                            // another row's typed figures in these fields
                            return Padding(
                              key: ObjectKey(l),
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(children: [
                                Expanded(flex: 4, child: Text(l.name, overflow: TextOverflow.ellipsis)),
                                SizedBox(
                                  width: 90,
                                  child: TextFormField(
                                    key: ValueKey('qty-${identityHashCode(l)}'),
                                    initialValue: num2(l.qty),
                                    decoration: const InputDecoration(labelText: 'Qty'),
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    onChanged: (v) => setLocal(() => l.qty = parseAmount(v) ?? 0),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 100,
                                  child: TextFormField(
                                    key: ValueKey('cost-${identityHashCode(l)}'),
                                    initialValue: num2(l.cost),
                                    decoration: const InputDecoration(labelText: 'Cost'),
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    onChanged: (v) => setLocal(() => l.cost = parseAmount(v) ?? 0),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => setLocal(() => lines.removeAt(i)),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                              ]),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: reason,
                  decoration: const InputDecoration(labelText: 'Why is it going back?'),
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
                child: const Text('Confirm return'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;

    try {
      final res = await state.api.createPurchaseReturn({
        'supplier_id': supplierId,
        'reason': reason.text.trim(),
        'note': note.text.trim(),
        'settled_by': settled,
        'items': [
          for (final l in lines)
            {'product_id': l.productId, 'qty': l.qty, 'unit_cost': l.cost,
             'reason': l.reason.isEmpty ? reason.text.trim() : l.reason,
             if (l.batchId != null) 'batch_id': l.batchId,
             if (l.expiry != null) 'expiry_date': l.expiry},
        ],
      });
      await state.refreshCatalogue(silent: true);
      await _load();
      if (!mounted) return;
      showMessage(context,
          'Return ${res['return_no']} saved — ${money(toD(res['total']))} off ${res['supplier_name']}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<_ReturnLine?> _pickProduct(AppState state) async {
    final search = TextEditingController();
    List<BatchRow> batches = [];
    try {
      final res = await state.api.listBatches();
      batches = ((res['rows'] as List?) ?? const [])
          .map((e) => BatchRow((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      batches = [];
    }
    if (!mounted) return null;

    return showDialog<_ReturnLine>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) {
          final q = search.text.toLowerCase();
          final products = state.catalogue
              .where((p) => q.isEmpty || p.name.toLowerCase().contains(q) || p.barcode.contains(q))
              .take(60)
              .toList();
          // One row per batch, so the cashier picks the batch the goods came from.
          // Stock only comes off a batch when it is named.
          final choices = <(PosProduct, BatchRow?)>[];
          for (final p in products) {
            final mine = batches.where((b) => b.productId == p.id).toList();
            if (mine.isEmpty) {
              choices.add((p, null));
            } else {
              choices.addAll([for (final b in mine) (p, b)]);
            }
          }
          return AlertDialog(
            title: const Text('Which product is going back?'),
            content: SizedBox(
              width: 560,
              height: 460,
              child: Column(children: [
                TextField(
                  controller: search,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Search name or barcode',
                      prefixIcon: Icon(Icons.search)),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: choices.length,
                    itemBuilder: (c, i) {
                      final (p, b) = choices[i];
                      return ListTile(
                        dense: true,
                        title: Text(p.name),
                        subtitle: Text(
                          b == null
                              ? 'in stock ${num2(p.stockQty)} ${p.unit}  •  cost ${money(p.costPrice)}'
                              : 'batch ${b.batchNo.isEmpty ? '-' : b.batchNo}  •  '
                                  '${num2(b.qtyRemaining)} left'
                                  '${b.expiryDate == null ? '' : '  •  expires ${dateFmt.format(b.expiryDate!)}'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onTap: () {
                          Navigator.pop(
                            c,
                            _ReturnLine(
                              productId: p.id,
                              name: p.name,
                              qty: 1,
                              cost: (b != null && b.unitCost > 0) ? b.unitCost : p.costPrice,
                              // empty = use the reason in the header box
                              reason: '',
                              batchId: b?.id,
                              expiry: b?.expiryDate == null ? null : dateFmt.format(b!.expiryDate!),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sym = state.store?.currencySymbol ?? 'Rs';
    final total = _rows.fold<double>(0, (a, r) => a + r.total);
    final payable = _rows.where((r) => r.settledBy == 'payable').fold<double>(0, (a, r) => a + r.total);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Returns to supplier', style: Theme.of(context).textTheme.headlineSmall),
          const Spacer(),
          if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => _newReturn(),
            icon: const Icon(Icons.keyboard_return),
            label: const Text('New return'),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          StatCard(label: 'Returned (all time)', value: money(total, symbol: sym),
              sub: '${_rows.length} note(s)', icon: Icons.keyboard_return),
          const SizedBox(width: 12),
          StatCard(label: 'Taken off payables', value: money(payable, symbol: sym),
              icon: Icons.trending_down, color: AppColors.good),
        ]),
        const SizedBox(height: 16),
        Expanded(
          child: SectionCard(
            title: 'Return notes',
            child: _rows.isEmpty
                ? const EmptyState(
                    icon: Icons.keyboard_return,
                    title: 'Nothing returned yet',
                    message: 'When a carton arrives damaged, or short-dated stock goes back to the '
                        'supplier, record it here so the stock and the payable stay honest.',
                  )
                : ListView.separated(
                    itemCount: _rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final r = _rows[i];
                      return ExpansionTile(
                        leading: Icon(Icons.keyboard_return, color: AppColors.info),
                        title: Text('${r.returnNo}  •  ${r.supplierName}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          '${r.itemCount} item(s)  •  ${money(r.total, symbol: sym)}  •  '
                          '${r.settledBy == 'payable' ? 'taken off what we owe' : r.settledBy}'
                          '${r.reason.isEmpty ? '' : '  •  ${r.reason}'}'
                          '${r.createdAt == null ? '' : '  •  ${dateFmt.format(r.createdAt!)}'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        children: [
                          for (final it in r.items)
                            ListTile(
                              dense: true,
                              title: Text('${it['name']}  ×  ${num2(it['qty'])}'),
                              subtitle: it['expiry_date'] == null
                                  ? null
                                  : Text('batch expiry ${it['expiry_date']}',
                                      style: const TextStyle(fontSize: 11)),
                              trailing: Text(money(toD(it['line_total']), symbol: sym)),
                            ),
                          if (r.note.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text('Note: ${r.note}',
                                  style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}

class _ReturnLine {
  _ReturnLine({
    required this.productId,
    required this.name,
    required this.qty,
    required this.cost,
    required this.reason,
    this.batchId,
    this.expiry,
  });
  final String productId;
  final String name;
  double qty;
  double cost;
  String reason;
  final String? batchId;
  final String? expiry;
}
