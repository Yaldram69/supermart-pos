import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../widgets/receipt.dart';

pw.Widget _pwKv(String k, String v, {bool bold = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text(k, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : null)),
        pw.Text(v, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : null)),
      ]),
    );

/// Customer accounts: who owes what (udhaar), and taking payments against it.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String _query = '';
  bool _onlyDebtors = true;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final list = state.customers.where((c) {
      if (_onlyDebtors && c.balance <= 0) return false;
      final q = _query.toLowerCase();
      return q.isEmpty || c.name.toLowerCase().contains(q) || c.phone.contains(q);
    }).toList();

    final owed = state.customers.fold<double>(0, (a, c) => a + (c.balance > 0 ? c.balance : 0));

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(children: [
          SectionCard(child: Column(children: [
            Row(children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search customer by name or phone',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                selected: _onlyDebtors,
                label: const Text('Only customers who owe money'),
                onSelected: (v) => setState(() => _onlyDebtors = v),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => _edit(state, null),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('New customer'),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              StatusPill(text: '${list.length} shown', color: AppColors.info),
              const SizedBox(width: 8),
              StatusPill(text: 'Total udhaar ${money(owed)}', color: owed > 0 ? AppColors.warn : AppColors.good),
              const Spacer(),
              IconButton(
                  onPressed: _loading
                      ? null
                      : () async {
                          setState(() => _loading = true);
                          await state.refreshReference();
                          setState(() => _loading = false);
                        },
                  icon: const Icon(Icons.refresh)),
            ]),
          ])),
          const SizedBox(height: 12),
          list.isEmpty
              ? const EmptyState(
                  icon: Icons.people_outline,
                  title: 'Nobody to show',
                  message: 'Attach a customer at the till to start a khata (credit) account.')
              : SectionCard(
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    child: DataTable(
                      showCheckboxColumn: false,
                      columns: const [
                        DataColumn(label: Text('Customer')),
                        DataColumn(label: Text('Phone')),
                        DataColumn(label: Text('Owes us'), numeric: true),
                        DataColumn(label: Text('Credit limit'), numeric: true),
                        DataColumn(label: Text('')),
                      ],
                      rows: [
                        for (final c in list)
                          DataRow(
                            onSelectChanged: (_) => _ledger(state, c),
                            cells: [
                              DataCell(Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                              DataCell(Text(c.phone.isEmpty ? '—' : c.phone)),
                              DataCell(Text(num2(c.balance),
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: c.balance > 0 ? AppColors.warn : AppColors.good))),
                              DataCell(Text(c.creditLimit > 0 ? num2(c.creditLimit) : '—')),
                              DataCell(Row(children: [
                                TextButton(
                                  onPressed: () => _collect(state, c),
                                  child: const Text('Take payment'),
                                ),
                                IconButton(
                                  tooltip: 'Print membership card',
                                  icon: const Icon(Icons.badge_outlined, size: 18),
                                  onPressed: () => _memberCard(state, c),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  onPressed: () => _edit(state, c),
                                ),
                              ])),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
        ]),
      ),
    );
  }

  Future<void> _collect(AppState state, Customer c) async {
    final amount = TextEditingController(text: c.balance > 0 ? num2(c.balance) : '');
    String method = 'cash';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setLocal) => AlertDialog(
          title: Text('Payment from ${c.name}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(c.balance > 0 ? 'Currently owes ${money(c.balance)}' : 'Nothing outstanding'),
            const SizedBox(height: 12),
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount received (Rs)'),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final m in const ['cash', 'card', 'jazzcash', 'easypaisa', 'bank_transfer'])
                ChoiceChip(
                  selected: method == m,
                  label: Text(m.replaceAll('_', ' ')),
                  onSelected: (_) => setLocal(() => method = m),
                ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                try {
                  final res = await state.api
                      .collectCustomerPayment(c.id, parseAmount(amount.text) ?? 0, method);
                  if (d.mounted) Navigator.pop(d, true);
                  if (mounted) {
                    showMessage(context,
                        'Payment saved — ${c.name} now owes ${money(toD(res['balance']))}');
                  }
                } catch (e) {
                  if (d.mounted) showError(d, e);
                }
              },
              child: const Text('Save payment'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await state.refreshReference();
  }

  Future<void> _edit(AppState state, Customer? existing) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final phone = TextEditingController(text: existing?.phone ?? '');
    final limit = TextEditingController(text: existing == null ? '0' : num2(existing.creditLimit));
    final address = TextEditingController(text: existing?.raw['address']?.toString() ?? '');
    final area = TextEditingController(text: existing?.area ?? '');
    final cnic = TextEditingController(text: existing?.cnic ?? '');
    final card = TextEditingController(text: existing?.cardNo ?? '');
    final email = TextEditingController(text: existing?.raw['email']?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(existing == null ? 'New customer' : 'Edit ${existing.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name *')),
          const SizedBox(height: 12),
          TextField(
              controller: phone,
              decoration: const InputDecoration(labelText: 'Phone (used to find them at the till)')),
          const SizedBox(height: 12),
          TextField(
              controller: address, decoration: const InputDecoration(labelText: 'Address')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: area,
                decoration: const InputDecoration(
                  labelText: 'Area / mohalla', helperText: 'Handy when collecting udhaar'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: cnic,
                decoration: const InputDecoration(labelText: 'CNIC', hintText: '42101-1234567-1'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: card,
                decoration: const InputDecoration(
                  labelText: 'Membership card number',
                  helperText: 'Scan a card or leave blank to auto-number it',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: email,
                decoration: const InputDecoration(labelText: 'Email (optional)'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: limit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Credit (udhaar) limit',
              helperText: 'The till refuses credit sales beyond this',
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              try {
                await state.persistCustomer({
                  if (existing != null) 'id': existing.id,
                  'name': name.text.trim(),
                  'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
                  'address': address.text.trim().isEmpty ? null : address.text.trim(),
                  'credit_limit': parseAmount(limit.text) ?? 0,
                  'area': area.text.trim().isEmpty ? null : area.text.trim(),
                  'cnic': cnic.text.trim().isEmpty ? null : cnic.text.trim(),
                  'card_no': card.text.trim().isEmpty ? null : card.text.trim(),
                  'email': email.text.trim().isEmpty ? null : email.text.trim(),
                });
                if (d.mounted) Navigator.pop(d, true);
              } catch (e) {
                if (d.mounted) showError(d, e);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) await state.refreshReference();
  }

  Future<void> _memberCard(AppState state, Customer c) async {
    // a membership card carries its own number; the phone number is not a card
    final cardNo = c.cardNo;
    if (cardNo.isEmpty) {
      showMessage(context, 'This customer has no membership card number yet', error: true);
      return;
    }
    try {
      await ReceiptPrinter.printMembershipCard(
        storeName: state.store?.name ?? 'Store',
        customerName: c.name,
        cardNo: cardNo,
        phone: c.phone,
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _ledger(AppState state, Customer customer) async {
    try {
      final sales = await state.loadSales(customerId: customer.id);
      final mine = sales.map(SaleRow.new).toList();
      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: Text('${customer.name} — ledger'),
          content: SizedBox(
            width: 760,
            height: 520,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              KeyValue(k: 'Owes', v: money(customer.balance), bold: true, color: AppColors.warn),
              Row(children: [
                Expanded(child: KeyValue(k: 'Credit limit', v: customer.creditLimit > 0 ? money(customer.creditLimit) : '—')),
              ]),
              const Divider(height: 12),
              const Text('Invoices', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Expanded(
                child: mine.isEmpty
                    ? const EmptyState(icon: Icons.receipt_long, title: 'No invoices for this customer')
                    : ListView.separated(
                        itemCount: mine.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final row = mine[i];
                          return ListTile(
                            dense: true,
                            title: Text(row.invoiceNo),
                            subtitle: Text(row.createdAt == null ? '' : dateTimeFmt.format(row.createdAt!)),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(num2(row.total)),
                              const SizedBox(width: 8),
                              StatusPill(text: row.payment, color: row.payment == 'credit' ? AppColors.warn : AppColors.good),
                            ]),
                            onTap: () async {
                              try {
                                final full = await state.saleDetail(row.id);
                                final sale = SaleResult(full);
                                final lines = ((full['lines'] as List?) ?? const []).map((e) => SaleLine(e as Map<String, dynamic>)).toList();
                                if (!ctx.mounted) return;

                                await showDialog(
                                  context: ctx,
                                  builder: (invoiceCtx) => AlertDialog(
                                    title: Text('Invoice ${sale.invoiceNo}'),
                                    content: SizedBox(
                                      width: 720,
                                      child: SingleChildScrollView(
                                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                          KeyValue(k: 'Date', v: sale.createdAt == null ? '' : dateTimeFmt.format(sale.createdAt!)),
                                          KeyValue(k: 'Cashier', v: sale.cashier),
                                          KeyValue(k: 'Payment', v: sale.payment),
                                          const Divider(),
                                          SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            child: DataTable(
                                              showCheckboxColumn: false,
                                              columns: const [
                                                DataColumn(label: Text('Item')),
                                                DataColumn(label: Text('Qty'), numeric: true),
                                                DataColumn(label: Text('Rate'), numeric: true),
                                                DataColumn(label: Text('Total'), numeric: true),
                                              ],
                                              rows: [
                                                for (final l in lines)
                                                  DataRow(cells: [
                                                    DataCell(Text(l.name)),
                                                    DataCell(Text(qtyStr(l.qty))),
                                                    DataCell(Text(num2(l.unitPrice))),
                                                    DataCell(Text(num2(l.lineTotal))),
                                                  ])
                                              ],
                                            ),
                                          ),
                                          const Divider(),
                                          KeyValue(k: 'Subtotal', v: num2(sale.subtotal)),
                                          if (sale.discount > 0) KeyValue(k: 'Discount', v: num2(sale.discount)),
                                          KeyValue(k: 'Total', v: money(sale.total), bold: true),
                                        ]),
                                      ),
                                    ),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(invoiceCtx), child: const Text('Close')),
                                      OutlinedButton.icon(
                                        onPressed: () async {
                                          try {
                                            await ReceiptPrinter.showPrintPreview(
                                              invoiceCtx,
                                              sale: sale,
                                              store: state.store,
                                              reprint: true,
                                              onPrint: () async {
                                                await ReceiptPrinter.printSale(invoiceCtx, result: sale.raw, store: state.store, reprint: true);
                                              },
                                            );
                                          } catch (e) {
                                            if (invoiceCtx.mounted) showError(invoiceCtx, e);
                                          }
                                        },
                                        icon: const Icon(Icons.print_outlined),
                                        label: const Text('Preview / duplicate'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () async {
                                          try {
                                            await ReceiptPrinter.printA4Invoice(sale: sale, store: state.store!);
                                          } catch (e) {
                                            if (invoiceCtx.mounted) showError(invoiceCtx, e);
                                          }
                                        },
                                        icon: const Icon(Icons.picture_as_pdf_outlined),
                                        label: const Text('A4 invoice'),
                                      ),
                                    ],
                                  ),
                                );
                              } catch (e) {
                                if (mounted) showError(context, e);
                              }
                            },
                          );
                        },
                      ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Close')),
            FilledButton.icon(
              onPressed: mine.isEmpty
                  ? null
                  : () async {
                      try {
                        Navigator.pop(dialogCtx);
                        final st = state.store;
                        if (st == null) return;

                        // Fetch all sale details first so we can create a flowing document
                        final fullSales = await Future.wait(mine.map((r) => state.saleDetail(r.id)));

                        final doc = pw.Document();
                        doc.addPage(pw.MultiPage(
                          pageFormat: PdfPageFormat.a4,
                          margin: const pw.EdgeInsets.all(20),
                          build: (ctx) {
                            final List<pw.Widget> items = [];
                            for (final full in fullSales) {
                              final sale = SaleResult(full);
                              final lines = ((full['lines'] as List?) ?? []).cast<Map<String, dynamic>>();

                              items.add(pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                                pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                                  pw.Text(st.name, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                                  if (st.address.isNotEmpty) pw.Text(st.address, style: const pw.TextStyle(fontSize: 9)),
                                ]),
                                pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
                                  pw.Text('INVOICE', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                                  pw.Text('No: ${sale.invoiceNo}', style: const pw.TextStyle(fontSize: 10)),
                                  pw.Text('Date: ${dateTimeFmt.format(sale.createdAt ?? DateTime.now())}', style: const pw.TextStyle(fontSize: 9)),
                                ]),
                              ]));

                              items.add(pw.SizedBox(height: 8));

                              // compact table for the sale lines
                              items.add(pw.TableHelper.fromTextArray(
                                headers: const ['#', 'Item', 'Qty', 'Rate', 'Amount'],
                                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
                                cellStyle: const pw.TextStyle(fontSize: 9),
                                headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
                                cellAlignments: {
                                  0: pw.Alignment.centerLeft,
                                  1: pw.Alignment.centerLeft,
                                  2: pw.Alignment.centerRight,
                                  3: pw.Alignment.centerRight,
                                  4: pw.Alignment.centerRight,
                                },
                                data: [
                                  for (var i = 0; i < lines.length; i++)
                                    [
                                      '${i + 1}',
                                      '${lines[i]['name_snapshot'] ?? lines[i]['name'] ?? ''}',
                                      '${lines[i]['qty'] ?? ''} ${lines[i]['unit'] ?? ''}',
                                      toD(lines[i]['unit_price']).toStringAsFixed(2),
                                      toD(lines[i]['line_total']).toStringAsFixed(2),
                                    ]
                                ],
                              ));

                              items.add(pw.SizedBox(height: 8));

                              // totals aligned to right
                              items.add(pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
                                pw.Container(
                                  width: 240,
                                  child: pw.Column(children: [
                                    _pwKv('Subtotal', '${st.currencySymbol} ${sale.subtotal.toStringAsFixed(2)}'),
                                    if (sale.discount > 0) _pwKv('Discount', '- ${st.currencySymbol} ${sale.discount.toStringAsFixed(2)}'),
                                    _pwKv('Total', '${st.currencySymbol} ${sale.total.toStringAsFixed(2)}', bold: true),
                                  ]),
                                ),
                              ]));

                              items.add(pw.SizedBox(height: 12));
                              items.add(pw.Divider());
                              items.add(pw.SizedBox(height: 8));
                            }
                            return items;
                          },
                        ));

                        await Printing.layoutPdf(name: 'sales-${customer.name}.pdf', format: PdfPageFormat.a4, onLayout: (f) => doc.save());
                      } catch (e) {
                        if (mounted) showError(context, e);
                      }
                    },
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Print all sales (A4)'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}
