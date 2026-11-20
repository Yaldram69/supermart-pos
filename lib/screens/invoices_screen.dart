import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/receipt.dart';
import '../widgets/sync_dialog.dart';

/// Every receipt ever printed, with reprint, cancel (void) and refund.
class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key});

  static double calculateReplacementDelta({
    required SaleLine returnedLine,
    required double returnedQty,
    required PosProduct replacementProduct,
    required double replacementQty,
  }) {
    final returnedValue = returnedLine.unitPrice * returnedQty;
    final replacementValue =
        replacementProduct.priceForQty(replacementQty) * replacementQty;
    return replacementValue - returnedValue;
  }

  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  List<SaleRow> _sales = [];
  bool _loading = true;
  String _range = 'today';
  String _query = '';
  final ScrollController _vScroll = ScrollController();

  /// Rows drawn so far. The table grows as the cashier scrolls, so a store with
  /// years of invoices never builds thousands of table rows at once.
  static const _pageRows = 200;
  int _shown = _pageRows;
  int _matching = 0;

  @override
  void initState() {
    super.initState();
    _vScroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _onScroll() {
    if (!_vScroll.hasClients) return;
    if (_vScroll.position.extentAfter < 400 && _shown < _matching) {
      setState(() => _shown += _pageRows);
    }
  }

  @override
  void dispose() {
    _vScroll.removeListener(_onScroll);
    _vScroll.dispose();
    super.dispose();
  }

  DateTime? get _from => switch (_range) {
    'today' => pkStartOfDay(),
    'week' => DateTime.now().subtract(const Duration(days: 7)),
    'month' => DateTime.now().subtract(const Duration(days: 30)),
    _ => null,
  };

  bool _lastOnline = true;
  int _lastPending = 0;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await context.read<AppState>().loadSales(from: _from);
      if (mounted) {
        setState(() {
          _sales = rows.map(SaleRow.new).toList();
          _shown = _pageRows;
        });
      }
    } catch (e) {
      // Offline is not an error here: the sales still waiting to send are shown
      // above, and this list refreshes on its own when the connection is back.
      final offline = e is AppError && e.isOffline;
      if (mounted && !offline) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Sales rung up on this PC that the server does not have yet, and sales it refused.
  Widget _waitingCard(BuildContext context, AppState state) {
    final queued = state.queuedSales;
    final refused = state.refusedSales;
    if (state.online && queued.isEmpty && refused.isEmpty) return const SizedBox.shrink();
    final sym = state.store?.currencySymbol ?? 'Rs';

    String customerOf(Map<String, dynamic> e) {
      final sale = e['sale'];
      final name = sale is Map ? (sale['customer_name'] ?? '').toString().trim() : '';
      return name.isEmpty ? 'Walk-in sale' : name;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: SectionCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  state.online ? Icons.sync : Icons.cloud_off_outlined,
                  color: state.online ? AppColors.info : AppColors.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.online
                        ? '${queued.length} sale(s) not yet on the server'
                        : 'Offline. Sales rung up now are kept on this PC and sent '
                            'automatically when the connection is back.',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () => showSyncDialog(context),
                  child: const Text('Manage'),
                ),
              ],
            ),
            for (final e in queued.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '•  ${customerOf(e)}  ·  ${money(e['total'], symbol: sym)}  ·  '
                  '${dateTimeFmt.format(parseDate(e['queued_at']) ?? DateTime.now())}',
                ),
              ),
            if (queued.length > 5)
              Text('…and ${queued.length - 5} more. Tap Manage to see them all.'),
            if (refused.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${refused.length} sale(s) were refused by the server. '
                  'Tap Manage to try them again or throw them away.',
                  style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // When the link comes back, or queued sales have just reached the server, show
    // the server's list again so it includes them.
    final cameBack = state.online && !_lastOnline;
    final sentSome = state.online && state.pendingOffline < _lastPending;
    _lastOnline = state.online;
    _lastPending = state.pendingOffline;
    if (cameBack || sentSome) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final filtered = _sales
        .where(
          (s) =>
              _query.isEmpty ||
              s.invoiceNo.toLowerCase().contains(_query.toLowerCase()) ||
              s.customer.toLowerCase().contains(_query.toLowerCase()) ||
              s.cashier.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    final total = filtered
        .where((s) => !s.isVoid)
        .fold<double>(0, (a, s) => a + s.total);
    _matching = filtered.length;
    final visible = filtered.length <= _shown ? filtered : filtered.sublist(0, _shown);

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _waitingCard(context, state),
          SectionCard(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.sm,
                  children: [
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'today', label: Text('Today')),
                        ButtonSegment(value: 'week', label: Text('7 days')),
                        ButtonSegment(value: 'month', label: Text('30 days')),
                        ButtonSegment(value: 'all', label: Text('All')),
                      ],
                      selected: {_range},
                      onSelectionChanged: (s) {
                        setState(() => _range = s.first);
                        _load();
                      },
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    SizedBox(
                      width: 340,
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText:
                              'Search invoice number, customer or cashier',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (v) => setState(() {
                          _query = v;
                          _shown = _pageRows;
                        }),
                      ),
                    ),
                    IconButton(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    StatusPill(
                      text: '${filtered.length} invoices',
                      color: AppColors.info,
                    ),
                    StatusPill(
                      text: 'Takings ${money(total)}',
                      color: AppColors.good,
                    ),
                    if (state.isManager)
                      const Text(
                        'Tap a row to reprint, cancel or refund',
                        style: TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                ? const EmptyState(
                    icon: Icons.receipt_long,
                    title: 'No invoices in this period',
                  )
                : Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return Scrollbar(
                          controller: _vScroll,
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: _vScroll,
                            scrollDirection: Axis.vertical,
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minWidth: constraints.maxWidth,
                                ),
                                child: DataTable(
                                  showCheckboxColumn: false,
                                  headingRowHeight: 36,
                                  dataRowMinHeight: 40,
                                  dataRowMaxHeight: 52,
                                  columnSpacing: 16,
                                  horizontalMargin: 10,
                                  columns: const [
                                    DataColumn(label: Text('Invoice')),
                                    DataColumn(label: Text('When')),
                                    DataColumn(label: Text('Customer')),
                                    DataColumn(label: Text('Cashier')),
                                    DataColumn(label: Text('Till')),
                                    DataColumn(label: Text('Pay')),
                                    DataColumn(
                                      label: Text('Items'),
                                      numeric: true,
                                    ),
                                    DataColumn(
                                      label: Text('Total'),
                                      numeric: true,
                                    ),
                                    DataColumn(label: Text('Status')),
                                  ],
                                  rows: [
                                    for (final s in visible)
                                      DataRow(
                                        onSelectChanged: (_) => _open(s),
                                        cells: [
                                          DataCell(
                                            Text(
                                              s.invoiceNo,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Text(
                                              s.createdAt == null
                                                  ? ''
                                                  : dateTimeFmt.format(
                                                      s.createdAt!,
                                                    ),
                                            ),
                                          ),
                                          DataCell(
                                            Text(
                                              s.customer.isEmpty
                                                  ? 'Walk-in'
                                                  : s.customer,
                                            ),
                                          ),
                                          DataCell(Text(s.cashier)),
                                          DataCell(Text(s.device)),
                                          DataCell(Text(s.payment)),
                                          DataCell(
                                            Text(s.itemCount.toString()),
                                          ),
                                          DataCell(
                                            Text(
                                              num2(s.total),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            StatusPill(
                                              text: s.statusLabel,
                                              color: s.isVoid
                                                  ? AppColors.danger
                                                  : (s.hasRefund || s.isQueued
                                                        ? AppColors.warn
                                                        : AppColors.good),
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(SaleRow row) async {
    final state = context.read<AppState>();
    try {
      final detail = await state.saleDetail(row.id);
      final sale = SaleRow(detail);
      final lines = (detail['lines'] as List)
          .cast<Map<String, dynamic>>()
          .map(SaleLine.new)
          .toList();
      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            0,
          ),
          contentPadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            0,
          ),
          actionsPadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          title: Row(
            children: [
              Text(sale.invoiceNo),
              const SizedBox(width: AppSpacing.sm),
              StatusPill(
                text: sale.statusLabel,
                color: sale.isVoid
                    ? AppColors.danger
                    : (sale.hasRefund ? AppColors.warn : AppColors.good),
              ),
            ],
          ),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KeyValue(
                      k: 'Date',
                      v: sale.createdAt == null
                          ? ''
                          : dateTimeFmt.format(sale.createdAt!),
                    ),
                    KeyValue(
                      k: 'Cashier',
                      v: '${sale.cashier} on ${sale.device}',
                    ),
                    KeyValue(
                      k: 'Customer',
                      v: sale.customer.isEmpty ? 'Walk-in' : sale.customer,
                    ),
                    if (sale.note.isNotEmpty) KeyValue(k: 'Note', v: sale.note),
                    const Divider(height: AppSpacing.lg),
                    // Allow horizontal scrolling for wide tables while the dialog
                    // scrolls vertically for long content.
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        showCheckboxColumn: false,
                        headingRowHeight: 36,
                        dataRowMinHeight: 38,
                        dataRowMaxHeight: 46,
                        columnSpacing: 18,
                        horizontalMargin: 12,
                        columns: const [
                          DataColumn(label: Text('Item')),
                          DataColumn(label: Text('Qty'), numeric: true),
                          DataColumn(label: Text('Price'), numeric: true),
                          DataColumn(label: Text('Disc'), numeric: true),
                          DataColumn(label: Text('Total'), numeric: true),
                          DataColumn(label: Text('Returned'), numeric: true),
                        ],
                        rows: [
                          for (final l in lines)
                            DataRow(
                              cells: [
                                DataCell(Text(l.name)),
                                DataCell(Text(qtyStr(l.qty))),
                                DataCell(Text(num2(l.unitPrice))),
                                DataCell(Text(num2(l.lineDiscount))),
                                DataCell(Text(num2(l.lineTotal))),
                                DataCell(
                                  Text(
                                    l.refundedQty > 0
                                        ? qtyStr(l.refundedQty)
                                        : '—',
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: AppSpacing.lg),
                    KeyValue(k: 'Subtotal', v: num2(sale.subtotal)),
                    if (sale.discount > 0)
                      KeyValue(k: 'Discount', v: '- ${num2(sale.discount)}'),
                    if (sale.tax > 0) KeyValue(k: 'Tax', v: num2(sale.tax)),
                    KeyValue(
                      k: 'Total',
                      v: money(sale.total),
                      bold: true,
                      color: AppColors.good,
                    ),
                    KeyValue(k: 'Paid (${sale.payment})', v: num2(sale.paid)),
                    if (sale.refunded > 0)
                      KeyValue(
                        k: 'Refunded',
                        v: num2(sale.refunded),
                        color: AppColors.warn,
                      ),
                    if (state.isManager && !sale.isVoid)
                      KeyValue(k: 'Profit on this sale', v: num2(sale.profit)),
                    if ((row.raw['voucher_code'] ?? '').toString().isNotEmpty)
                      KeyValue(
                        k: 'Voucher used',
                        v: '${row.raw['voucher_code']}  —  ${money(toD(row.raw['voucher_amount']), symbol: state.store?.currencySymbol ?? 'Rs')}',
                        color: AppColors.good,
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Close'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final full = await state.saleDetail(row.id);
                if (!c.mounted) return;
                await ReceiptPrinter.showPrintPreview(
                  c,
                  sale: SaleResult(full),
                  store: state.store,
                  reprint: true,
                  onPrint: () async {
                    await ReceiptPrinter.printSale(
                      c,
                      result: full,
                      store: state.store,
                      reprint: true,
                    );
                  },
                );
              },
              icon: const Icon(Icons.preview_outlined),
              label: const Text('Preview / duplicate'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  final full = SaleResult(await state.saleDetail(row.id));
                  final st = state.store;
                  if (st == null) return;
                  await ReceiptPrinter.printA4Invoice(
                    sale: full,
                    store: st,
                    customerPhone: (full.raw['customer_phone'] ?? '')
                        .toString(),
                  );
                } catch (e) {
                  if (c.mounted) showError(c, e);
                }
              },
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('A4 invoice'),
            ),
            if (!sale.isVoid && !sale.isQueued)
              OutlinedButton.icon(
                onPressed: () async {
                  Navigator.pop(c);
                  await _replace(state, sale, lines);
                },
                icon: const Icon(Icons.swap_horiz_outlined),
                // it loads the whole invoice into the cart, so say that
                label: const Text('Open in cart to edit'),
              ),
            if (!sale.isVoid && !sale.isQueued)
              OutlinedButton.icon(
                onPressed: () async {
                  Navigator.pop(c);
                  await _refund(state, sale, lines);
                },
                icon: const Icon(Icons.assignment_return_outlined),
                label: const Text('Refund / return'),
              ),
            if (!sale.isVoid && !sale.isQueued)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                ),
                onPressed: () async {
                  Navigator.pop(c);
                  await _void(state, sale);
                },
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancel invoice'),
              ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _void(AppState state, SaleRow sale) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Cancel ${sale.invoiceNo}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This reverses the sale and puts ${sale.itemCount} item(s) back into stock on all PCs. '
              'The invoice stays in the history marked CANCELLED.',
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Reason (required)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () async {
              if (reason.text.trim().isEmpty) {
                showMessage(c, 'Type why this bill is being cancelled', error: true);
                return;
              }
              String? pin;
              for (var attempt = 0; attempt < 3; attempt++) {
                try {
                  await state.api.voidSale(
                    sale.id,
                    reason.text.trim(),
                    managerPin: pin,
                  );
                  if (c.mounted) Navigator.pop(c, true);
                  return;
                } on AppError catch (e) {
                  // a cashier asking to cancel: let a manager approve it here
                  if (!needsManagerApproval(e) || !c.mounted) {
                    if (c.mounted) showError(c, e);
                    return;
                  }
                  final entered = await askManagerPin(
                    c,
                    e.message,
                    title: 'Approve cancellation',
                  );
                  if (entered == null || entered.isEmpty) return;
                  pin = entered;
                } catch (e) {
                  if (c.mounted) showError(c, e);
                  return;
                }
              }
              if (c.mounted) {
                showError(
                  c,
                  AppError('PIN_WRONG', 'The manager PIN was not accepted.'),
                );
              }
            },
            child: const Text('Cancel the invoice'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _load();
      await state.refreshCatalogue();
      if (mounted) showMessage(context, 'Invoice cancelled and stock restored');
    }
  }

  Future<void> _replace(
    AppState state,
    SaleRow sale,
    List<SaleLine> lines,
  ) async {
    final invoiceLines = lines.where((l) => l.qty > 0).toList();
    if (invoiceLines.isEmpty) {
      if (mounted) {
        showMessage(
          context,
          'This invoice has no items to edit in the cart.',
          error: true,
        );
      }
      return;
    }

    if (state.cart.isNotEmpty) {
      final shouldReplace = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Open this invoice in the POS cart?'),
          content: const Text(
            'This will replace the current cart with the invoice items so you can edit them normally.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep current cart'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Open invoice cart'),
            ),
          ],
        ),
      );
      if (shouldReplace != true) return;
    }

    state.clearCart();
    state.cartNote = sale.note;

    final customerId = (sale.raw['customer_id'] ?? '').toString().trim();
    if (customerId.isNotEmpty) {
      Customer? match;
      for (final customer in state.customers) {
        if (customer.id == customerId) {
          match = customer;
          break;
        }
      }
      if (match != null) state.setCustomer(match);
    }

    for (final line in invoiceLines) {
      final productId = (line.raw['product_id'] ?? '').toString().trim();
      final product = productId.isNotEmpty
          ? (state.byId[productId] ??
              PosProduct({
                'id': productId,
                'name': line.name,
                'barcode': line.barcode,
                'unit': line.unit,
                'sale_price': line.unitPrice,
                'cost_price': 0,
                'stock_qty': 0,
                'is_active': true,
                'is_misc_item': false,
              }))
          : PosProduct({
              'id': '',
              'name': line.name,
              'barcode': line.barcode,
              'unit': line.unit,
              'sale_price': line.unitPrice,
              'cost_price': 0,
              'stock_qty': 0,
              'is_active': true,
              'is_misc_item': true,
            });

      state.cart.add(
        CartLine(
          product: product,
          qty: line.qty,
          unitPrice: line.unitPrice,
          lineDiscount: line.lineDiscount,
        ),
      );
    }

    if (!mounted) return;
    state.setNavIndex(0);
  }

  Future<void> _refund(
    AppState state,
    SaleRow sale,
    List<SaleLine> lines,
  ) async {
    final qty = <String, double>{};
    for (final l in lines) {
      qty[l.id] = 0;
    }
    // Damaged or opened goods should be refunded without going back on the shelf.
    var restock = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) {
          final total = lines.fold<double>(
            0,
            (a, l) => a + (qty[l.id] ?? 0) * l.unitPrice,
          );
          return AlertDialog(
            title: Text('Refund items from ${sale.invoiceNo}'),
            content: SizedBox(
              width: 560,
              height: 420,
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Column(
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Enter how many of each item the customer is bringing back.',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Expanded(
                      child: ListView.separated(
                        itemCount: lines.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: AppSpacing.sm),
                        itemBuilder: (c, i) {
                          final l = lines[i];
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      'sold ${qtyStr(l.qty)} • can return ${qtyStr(l.returnable)} • ${num2(l.unitPrice)} each',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 90,
                                child: TextFormField(
                                  key: ValueKey('return-${l.id}'),
                                  initialValue: '0',
                                  decoration: const InputDecoration(
                                    labelText: 'Return',
                                  ),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  onChanged: (v) => setLocal(
                                    () => qty[l.id] = parseAmount(v) ?? 0,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const Divider(height: AppSpacing.lg),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: restock,
                      onChanged: (v) => setLocal(() => restock = v),
                      title: const Text('Put returned items back in stock'),
                      subtitle: Text(
                        'Refunded to ${sale.payment == 'cash' ? 'cash drawer' : sale.payment}',
                      ),
                    ),
                    Text(
                      'Refund total: ${money(total)}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  final items = qty.entries
                      .where((e) => e.value > 0)
                      .map((e) => {'sale_item_id': e.key, 'qty': e.value})
                      .toList();
                  if (items.isEmpty) {
                    showMessage(
                      context,
                      'Enter at least one quantity',
                      error: true,
                    );
                    return;
                  }
                  String? pin;
                  for (var attempt = 0; attempt < 3; attempt++) {
                    try {
                      final res = await state.api.createReturn({
                        'sale_id': sale.id,
                        'items': items,
                        'reason': 'Customer return',
                        // Refund goes back the same way the customer paid
                        // (cash, card, JazzCash, credit…), not always to the drawer.
                        'refund_method': sale.payment,
                        'restock': restock,
                      }, managerPin: pin);
                      if (c.mounted) Navigator.pop(c, true);
                      if (mounted) {
                        showMessage(
                          context,
                          'Refund ${res['return_no']} saved — ${money(toD(res['refund_amount']))} '
                          'and the goods are back in stock',
                        );
                      }
                      return;
                    } on AppError catch (e) {
                      // a refund above what the cashier may do needs a manager
                      if (!needsManagerApproval(e) || !c.mounted) {
                        if (c.mounted) showError(c, e);
                        return;
                      }
                      final entered = await askManagerPin(
                        c,
                        e.message,
                        title: 'Approve refund',
                      );
                      if (entered == null || entered.isEmpty) return;
                      pin = entered;
                    } catch (e) {
                      if (c.mounted) showError(c, e);
                      return;
                    }
                  }
                  if (c.mounted) {
                    showError(
                      c,
                      AppError(
                        'PIN_WRONG',
                        'The manager PIN was not accepted.',
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.check),
                label: Text(restock ? 'Refund and restock' : 'Refund (no restock)'),
              ),
            ],
          );
        },
      ),
    );
    if (ok == true) {
      await _load();
      await state.refreshCatalogue();
    }
  }
}
