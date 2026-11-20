import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Who you owe money to, and how much. Pay a supplier here: the money is
/// recorded and applied to their oldest unpaid deliveries first.
class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key});

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  List<SupplierPayable> _rows = [];
  double _outstanding = 0;
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
      final res = await state.api.supplierPayables();
      if (!mounted) return;
      setState(() {
        _rows = (res['rows'] as List)
            .map((e) => SupplierPayable((e as Map).cast<String, dynamic>()))
            .toList();
        _outstanding = toD(res['total_outstanding']);
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pay(SupplierPayable s) async {
    final state = context.read<AppState>();
    // the exact balance, not a rounded one: rounding 12.50 to 13 would overpay
    final amount = TextEditingController(
        text: s.outstanding > 0 ? s.outstanding.toStringAsFixed(2) : '');
    final ref = TextEditingController();
    final note = TextEditingController();
    String method = 'cash';

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text('Pay ${s.name}'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              KeyValue(k: 'You owe', v: money(s.outstanding, symbol: state.store?.currencySymbol ?? 'Rs'), bold: true),
              const SizedBox(height: 12),
              TextField(
                controller: amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount paid (Rs)'),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                for (final m in const [('cash', 'Cash'), ('bank_transfer', 'Bank'),
                                       ('jazzcash', 'JazzCash'), ('easypaisa', 'Easypaisa')])
                  ChoiceChip(
                    label: Text(m.$2),
                    selected: method == m.$1,
                    onSelected: (_) => setLocal(() => method = m.$1),
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: ref,
                decoration: const InputDecoration(labelText: 'Cheque / slip number (optional)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Record payment')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;

    try {
      final res = await state.api.paySupplier({
        'supplier_id': s.id,
        'amount': parseAmount(amount.text) ?? 0,
        'payment_method': method,
        'reference_no': ref.text.trim(),
        'note': note.text.trim(),
      });
      if (!mounted) return;
      showMessage(context,
          'Paid ${money(toD(res['amount']), symbol: state.store?.currencySymbol ?? 'Rs')} — '
          '${s.name} now owes ${money(toD(res['outstanding']), symbol: state.store?.currencySymbol ?? 'Rs')}');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _ledger(SupplierPayable s) async {
    final state = context.read<AppState>();
    Map<String, dynamic> data;
    try {
      data = await state.api.supplierLedger(s.id);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final rows = (data['rows'] as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    final sym = state.store?.currencySymbol ?? 'Rs';
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${s.name} — ledger'),
        content: SizedBox(
          width: 560,
          height: 420,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            KeyValue(k: 'Total purchased', v: money(toD(data['purchased']), symbol: sym)),
            KeyValue(k: 'Total paid', v: money(toD(data['paid']), symbol: sym)),
            KeyValue(k: 'Outstanding', v: money(toD(data['purchased']) - toD(data['paid']), symbol: sym), bold: true),
            const Divider(),
            Expanded(
              child: rows.isEmpty
                  ? const EmptyState(icon: Icons.receipt_long, title: 'No history yet')
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final r = rows[i];
                        final isPayment = r['kind'] == 'payment';
                        return ListTile(
                          dense: true,
                          leading: Icon(isPayment ? Icons.south_east : Icons.north_east,
                              color: isPayment ? AppColors.good : AppColors.warn, size: 18),
                          title: Text('${r['ref'] ?? ''}  ${isPayment ? 'payment' : 'delivery'}'),
                          subtitle: Text(dateFmt.format(dt(r, 'at') ?? DateTime.now())),
                          trailing: Text(
                            isPayment
                                ? '- ${money(toD(r['debit']), symbol: sym)}'
                                : '+ ${money(toD(r['credit']), symbol: sym)}',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isPayment ? AppColors.good : AppColors.warn),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
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
            Text('Supplier payments', style: Theme.of(context).textTheme.headlineSmall),
            const Spacer(),
            FilledButton.icon(
              onPressed: () async {
                await showDialog(context: context, builder: (_) => const _NewSupplierDialog());
                if (mounted) _load();
              },
              icon: const Icon(Icons.add_business_outlined),
              label: const Text('New supplier'),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            StatCard(label: 'Total owed', value: money(_outstanding, symbol: sym),
                icon: Icons.account_balance_wallet_outlined,
                color: _outstanding > 0 ? AppColors.warn : AppColors.good),
            const SizedBox(width: 12),
            StatCard(label: 'Suppliers with a balance',
                value: '${_rows.where((r) => r.outstanding > 0).length}',
                icon: Icons.storefront_outlined),
          ]),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Who you owe',
            actions: [
              if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            ],
            child: _rows.isEmpty
                ? const EmptyState(
                    icon: Icons.local_shipping_outlined,
                    title: 'Nothing owed',
                    message: 'When you receive a delivery without paying in full, the balance shows here.',
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final r = _rows[i];
                      final owes = r.outstanding > 0.009;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: (owes ? AppColors.warn : AppColors.good).withValues(alpha: 0.15),
                          child: Icon(owes ? Icons.arrow_upward : Icons.check,
                              size: 18, color: owes ? AppColors.warn : AppColors.good),
                        ),
                        title: Text(r.name),
                        subtitle: Text(
                          '${r.city.isEmpty ? '' : '${r.city}  •  '}'
                          'purchases ${money(r.purchases, symbol: sym)}  •  paid ${money(r.paid, symbol: sym)}'
                          '${r.unpaidOrders > 0 ? '  •  ${r.unpaidOrders} order(s) unpaid' : ''}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(money(r.outstanding, symbol: sym),
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15,
                                  color: owes ? AppColors.warn : AppColors.good)),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () => _ledger(r),
                            child: const Text('Ledger'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonal(
                            onPressed: () => _pay(r),
                            child: const Text('Pay'),
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

/// Add a supplier without leaving the till (products and purchases both use them).
class _NewSupplierDialog extends StatefulWidget {
  const _NewSupplierDialog();

  @override
  State<_NewSupplierDialog> createState() => _NewSupplierDialogState();
}

class _NewSupplierDialogState extends State<_NewSupplierDialog> {
  final _name = TextEditingController();
  final _person = TextEditingController();
  final _phone = TextEditingController();
  final _city = TextEditingController();
  final _code = TextEditingController();
  final _ntn = TextEditingController();
  final _days = TextEditingController(text: '0');
  final _bank = TextEditingController();
  final _account = TextEditingController();
  final _address = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New supplier'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _name, autofocus: true,
              decoration: const InputDecoration(labelText: 'Supplier / company name')),
          const SizedBox(height: 12),
          TextField(controller: _person, decoration: const InputDecoration(labelText: 'Contact person')),
          const SizedBox(height: 12),
          TextField(controller: _phone, decoration: const InputDecoration(labelText: 'Phone')),
          const SizedBox(height: 12),
          TextField(controller: _city, decoration: const InputDecoration(labelText: 'City')),
          const SizedBox(height: 12),
          TextField(controller: _address,
              decoration: const InputDecoration(labelText: 'Address')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _code,
                decoration: const InputDecoration(
                    labelText: 'Supplier code', hintText: 'your own short code'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _ntn,
                decoration: const InputDecoration(labelText: 'NTN / STRN'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _bank,
                decoration: const InputDecoration(labelText: 'Bank name'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _account,
                decoration: const InputDecoration(labelText: 'Account / IBAN'),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 130,
              child: TextField(
                controller: _days,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Credit days',
                  helperText: 'e.g. 30',
                ),
              ),
            ),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  if (_name.text.trim().isEmpty) {
                    showMessage(context, 'Enter the supplier name', error: true);
                    return;
                  }
                  setState(() => _busy = true);
                  try {
                    await context.read<AppState>().api.saveSupplier({
                      'name': _name.text.trim(),
                      'contact_person': _person.text.trim(),
                      'phone': _phone.text.trim(),
                      'city': _city.text.trim(),
                      'address': _address.text.trim(),
                      'supplier_code': _code.text.trim(),
                      'ntn': _ntn.text.trim(),
                      'bank_name': _bank.text.trim(),
                      'bank_account': _account.text.trim(),
                      'credit_days': int.tryParse(_days.text) ?? 0,
                    });
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          child: Text(_busy ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
