import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Shop running costs: transport, chai, electricity, repairs, wages.
/// They are subtracted from profit in Reports, so recording them keeps the
/// profit figure honest.
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  List<ExpenseRow> _rows = [];
  double _total = 0;
  int _days = 30;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final raw = await state.api.expenses(
          from: DateTime.now().subtract(Duration(days: _days)), to: DateTime.now());
      if (!mounted) return;
      setState(() {
        _rows = (raw['rows'] as List).map((e) => ExpenseRow((e as Map).cast<String, dynamic>())).toList();
        _total = toD(raw['total']);
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final state = context.read<AppState>();
    final amount = TextEditingController();
    final desc = TextEditingController();
    final ref = TextEditingController();
    String category = 'General';
    const categories = ['General', 'Transport', 'Utilities', 'Rent', 'Wages',
                        'Repairs', 'Packing', 'Cleaning', 'Tea & Food', 'Other'];

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: const Text('Record an expense'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'What was it for?'),
                items: categories
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (v) => setLocal(() => category = v ?? 'General'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount (Rs)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: desc,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ref,
                decoration: const InputDecoration(labelText: 'Bill / receipt number (optional)'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Save expense'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;

    // a blank or non-number amount must never be saved as Rs 0
    final value = parseAmount(amount.text);
    if (value == null || value <= 0) {
      showMessage(context, 'Type the amount spent (more than zero)', error: true);
      return;
    }

    try {
      await state.api.saveExpense({
        'category': category,
        'amount': value,
        'description': desc.text.trim(),
        'reference_no': ref.text.trim(),
      });
      if (!mounted) return;
      showMessage(context, 'Expense saved');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(ExpenseRow r) async {
    final state = context.read<AppState>();
    if (!await confirm(context,
        title: 'Delete this expense?',
        message: '${r.category} ${money(r.amount)} — this only removes the record, '
            'it does not touch any sale.',
        okLabel: 'Delete')) {
      return;
    }
    try {
      await state.api.deleteExpense(r.id);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sym = state.store?.currencySymbol ?? 'Rs';
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Expenses', style: Theme.of(context).textTheme.headlineSmall),
            const Spacer(),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Today')),
                ButtonSegment(value: 7, label: Text('7 days')),
                ButtonSegment(value: 30, label: Text('30 days')),
                ButtonSegment(value: 365, label: Text('Year')),
              ],
              selected: {_days},
              onSelectionChanged: (s) {
                setState(() => _days = s.first);
                _load();
              },
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Record expense'),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            StatCard(label: 'Spent', value: money(_total, symbol: sym),
                icon: Icons.payments_outlined, color: AppColors.warn,
                sub: 'last $_days day(s)'),
            const SizedBox(width: 12),
            StatCard(label: 'Entries', value: '${_rows.length}',
                icon: Icons.receipt_outlined),
          ]),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Recorded expenses',
            actions: [
              if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            ],
            child: _rows.isEmpty
                ? const EmptyState(
                    icon: Icons.account_balance_wallet_outlined,
                    title: 'No expenses recorded',
                    message: 'Record transport, bills, wages and repairs here so Reports '
                        'shows your true profit.',
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final r = _rows[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppColors.warn.withValues(alpha: 0.15),
                          child: Icon(Icons.payments_outlined, color: AppColors.warn, size: 18),
                        ),
                        title: Text(r.description.isEmpty ? r.category : r.description),
                        subtitle: Text('${r.category}  •  ${dateTimeFmt.format(r.spentAt ?? DateTime.now())}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(money(r.amount, symbol: sym),
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          IconButton(
                            tooltip: 'Delete',
                            onPressed: state.isAdmin ? () => _delete(r) : null,
                            icon: const Icon(Icons.delete_outline, size: 18),
                          ),
                        ]),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
