import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Everything with an expiry date: what has already gone off, what is about to,
/// what it is worth, and how to write it off or return it to the supplier.
/// Batches arrive automatically when a delivery is booked in with an expiry
/// date (Stock & Purchases → Book in a delivery).
class ExpiryScreen extends StatefulWidget {
  const ExpiryScreen({super.key});

  @override
  State<ExpiryScreen> createState() => _ExpiryScreenState();
}

class _ExpiryScreenState extends State<ExpiryScreen> {
  List<BatchRow> _rows = [];
  int _days = 30;
  String _filter = 'risk'; // risk | expired | expiring | all
  double _atRisk = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final state = context.read<AppState>();
      final res = _filter == 'all'
          ? await state.api.listBatches()
          : await state.api.expiringStock(days: _days);
      if (!mounted) return;
      setState(() {
        _rows = ((res['rows'] as List?) ?? const [])
            .map((e) => BatchRow((e as Map).cast<String, dynamic>()))
            .toList();
        _atRisk = toD(res['at_risk_value']);
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<BatchRow> get _visible => switch (_filter) {
        'expired' => _rows.where((r) => r.isExpired).toList(),
        'expiring' => _rows.where((r) => r.isExpiring).toList(),
        'all' => _rows,
        _ => _rows.where((r) => r.isExpired || r.isExpiring).toList(),
      };

  Future<void> _writeOff(BatchRow b) async {
    final state = context.read<AppState>();
    final qty = TextEditingController(text: num2(b.qtyRemaining));
    String reason = b.isExpired ? 'expired' : 'damaged';
    final note = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: const Text('Write off stock'),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Write off ${b.productName}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                KeyValue(k: 'Batch', v: b.batchNo.isEmpty ? '—' : b.batchNo),
                KeyValue(k: 'Expires', v: b.expiryDate == null ? '—' : dateFmt.format(b.expiryDate!)),
                KeyValue(k: 'In this batch', v: '${num2(b.qtyRemaining)} ${b.unit}'),
                KeyValue(k: 'Value', v: money(b.value, symbol: state.store?.currencySymbol ?? 'Rs')),
                const SizedBox(height: 12),
                TextField(
                  controller: qty,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  decoration: InputDecoration(labelText: 'Quantity to write off (${b.unit})'),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in const [
                      ('expired', 'Expired'), ('damaged', 'Damaged'), ('theft', 'Theft / lost'),
                      ('sample', 'Used as sample'), ('other', 'Other'),
                    ])
                      ChoiceChip(
                        label: Text(r.$2),
                        selected: reason == r.$1,
                        onSelected: (_) => setLocal(() => reason = r.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Note (optional)'),
                ),
                const SizedBox(height: 12),
                Text(
                  'The stock goes out of the books straight away and the reason is recorded against your name in the Activity log.',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Write off'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;

    try {
      final res = await state.api.writeOffStock({
        'batch_id': b.id,
        'product_id': b.productId,
        'qty': parseAmount(qty.text) ?? 0,
        'reason': reason,
        'note': note.text.trim(),
      });
      if (!mounted) return;
      showMessage(context,
          '${res['product']}: ${num2(toD(res['qty']))} written off — '
          '${money(toD(res['value_lost']), symbol: state.store?.currencySymbol ?? 'Rs')} lost');
      await state.refreshCatalogue(silent: true);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sym = state.store?.currencySymbol ?? 'Rs';
    final rows = _visible;
    final expired = _rows.where((r) => r.isExpired).toList();
    final expiring = _rows.where((r) => r.isExpiring).toList();
    final expiredValue = expired.fold<double>(0, (a, r) => a + r.value);
    final alertDays = state.store?.expiryAlertDays ?? 30;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    Text('Expiry & batches', style: Theme.of(context).textTheme.headlineSmall),
                    StatusPill(text: 'alerts at $alertDays days', color: AppColors.info, icon: Icons.schedule),
                  ],
                ),
              ),
              if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 260,
                child: StatCard(
                  label: 'Already expired',
                  value: '${expired.length}',
                  sub: '${money(expiredValue, symbol: sym)} to throw away',
                  icon: Icons.dangerous_outlined,
                  color: expired.isEmpty ? AppColors.good : AppColors.danger,
                ),
              ),
              SizedBox(
                width: 260,
                child: StatCard(
                  label: 'Expiring soon',
                  value: '${expiring.length}',
                  sub: 'within $alertDays days',
                  icon: Icons.hourglass_bottom,
                  color: expiring.isEmpty ? AppColors.good : AppColors.warn,
                ),
              ),
              SizedBox(
                width: 260,
                child: StatCard(
                  label: 'Money at risk',
                  value: money(_atRisk, symbol: sym),
                  sub: 'expired + expiring stock',
                  icon: Icons.account_balance_wallet_outlined,
                  color: _atRisk > 0 ? AppColors.warn : AppColors.good,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Batches',
            actions: [
              Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'risk', label: Text('Needs action')),
                      ButtonSegment(value: 'expired', label: Text('Expired')),
                      ButtonSegment(value: 'expiring', label: Text('Expiring')),
                      ButtonSegment(value: 'all', label: Text('All batches')),
                    ],
                    selected: {_filter},
                    onSelectionChanged: (v) {
                      setState(() => _filter = v.first);
                      _load();
                    },
                  ),
                  DropdownButton<int>(
                    value: _days,
                    items: const [
                      DropdownMenuItem(value: 7, child: Text('7 days')),
                      DropdownMenuItem(value: 15, child: Text('15 days')),
                      DropdownMenuItem(value: 30, child: Text('30 days')),
                      DropdownMenuItem(value: 60, child: Text('60 days')),
                      DropdownMenuItem(value: 90, child: Text('90 days')),
                    ],
                    onChanged: (v) {
                      setState(() => _days = v ?? 30);
                      if (_filter != 'all') _load();
                    },
                  ),
                ],
              ),
            ],
            child: rows.isEmpty
                ? EmptyState(
                    icon: Icons.verified_outlined,
                    title: _filter == 'all' ? 'No batches recorded yet' : 'Nothing is going out of date',
                    message: _filter == 'all'
                        ? 'Batches appear here when you book in a delivery with a batch number or an expiry date.'
                        : 'No stock expires within $_days days. That is exactly what you want.',
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final b = rows[i];
                      final days = b.daysLeft;
                      final color = b.isExpired
                          ? AppColors.danger
                          : b.isExpiring
                              ? AppColors.warn
                              : AppColors.good;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: color.withValues(alpha: 0.15),
                          child: Icon(
                            b.isExpired ? Icons.dangerous_outlined : Icons.inventory_2_outlined,
                            color: color,
                            size: 20,
                          ),
                        ),
                        title: Text(b.productName),
                        subtitle: Text(
                          '${b.batchNo.isEmpty ? 'no batch no.' : 'batch ${b.batchNo}'}'
                          '${b.supplierName.isEmpty ? '' : '  •  ${b.supplierName}'}'
                          '${b.poNo.isEmpty ? '' : '  •  ${b.poNo}'}\n'
                          '${b.expiryDate == null ? 'no expiry date' : 'expires ${dateFmt.format(b.expiryDate!)}'
                              '${days == null ? '' : days < 0 ? '  (${-days} days ago)' : '  (in $days days)'}'}'
                          '  •  ${num2(b.qtyRemaining)} ${b.unit} left of ${num2(b.qtyReceived)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        isThreeLine: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: Text(
                                money(b.value, symbol: sym),
                                style: TextStyle(fontWeight: FontWeight.bold, color: color),
                              ),
                            ),
                            if (state.isManager)
                              ConstrainedBox(
                                constraints: const BoxConstraints(minWidth: 112),
                                child: OutlinedButton.icon(
                                  onPressed: () => _writeOff(b),
                                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                                  label: const Text('Write off'),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
