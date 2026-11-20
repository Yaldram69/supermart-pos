import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Count the shelves: scan each item, type what is really there, and at the end
/// the system posts the differences to the stock ledger so the books match
/// reality — and tells you what the shortage or extra stock is worth.
class StockTakeScreen extends StatefulWidget {
  const StockTakeScreen({super.key});

  @override
  State<StockTakeScreen> createState() => _StockTakeScreenState();
}

class _StockTakeScreenState extends State<StockTakeScreen> {
  StockTakeRow? _take;
  /// True when the server could not say whether a count is open.
  bool _loadFailed = false;
  List<StockTakeItemRow> _items = [];
  final _barcode = TextEditingController();
  final _qty = TextEditingController();
  final _focusBarcode = FocusNode();
  bool _busy = false;
  String? _lastMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _barcode.dispose();
    _qty.dispose();
    _focusBarcode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final take = await state.api.currentStockTake();
      if (!mounted) return;
      setState(() {
        _take = take == null ? null : StockTakeRow(take);
        _loadFailed = false;
      });
      if (_take != null) await _loadItems();
    } catch (e) {
      // A failed check must not look like "no count open": that would invite a second count.
      if (mounted) {
        setState(() => _loadFailed = true);
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadItems() async {
    final state = context.read<AppState>();
    final t = _take;
    if (t == null) return;
    final res = await state.api.stockTakeDetail(t.id);
    if (!mounted) return;
    setState(() => _items = (res['rows'] as List)
        .map((e) => StockTakeItemRow((e as Map).cast<String, dynamic>()))
        .toList());
  }

  Future<void> _start() async {
    final state = context.read<AppState>();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Start a stock take'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Scan or type what is on the shelf. Nothing changes until you '
                'press Finish, and every difference is written to the stock history.'),
            const SizedBox(height: 16),
            TextField(
              controller: note,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Note (e.g. "monthly count")'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Start counting')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await state.api.startStockTake(note.text.trim());
      await _load();
      if (mounted) _focusBarcode.requestFocus();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _count([String? rawBarcode]) async {
    final state = context.read<AppState>();
    final t = _take;
    if (t == null) return;

    var code = (rawBarcode ?? _barcode.text).trim();
    var qty = parseAmount(_qty.text.trim()) ?? 0;

    // a scale label carries its own weight - use it instead of typing, so the
    // quantity box may be left empty for those
    final scale = state.parseScaleBarcode(code);
    if (scale != null && scale.mode == 'weight') {
      code = scale.code;
      qty = scale.weightKg;
    }

    if (code.isEmpty || qty <= 0) {
      showMessage(context, 'Scan a barcode and type the counted quantity', error: true);
      return;
    }

    try {
      final res = await state.api.stockTakeCount({'take_id': t.id, 'barcode': code, 'qty': qty});
      if (!mounted) return;
      setState(() {
        _lastMessage = '${res['product']}: counted ${num2(toD(res['counted']))} '
            '(book said ${num2(toD(res['expected']))}, difference ${num2(toD(res['variance']))})';
      });
      _barcode.clear();
      _qty.clear();
      await _loadItems();
      _focusBarcode.requestFocus();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _finish() async {
    final state = context.read<AppState>();
    final t = _take;
    if (t == null) return;
    final variances = _items.where((i) => i.variance != 0).length;
    if (!await confirm(context,
        title: 'Finish this stock take?',
        message: '$variances item(s) differ from the books. Their stock will be corrected '
            'now and the change is recorded in the stock history.',
        okLabel: 'Finish and correct stock')) {
      return;
    }
    try {
      final res = await state.api.completeStockTake(t.id);
      await state.refreshCatalogue();
      if (!mounted) return;
      showMessage(context,
          'Stock take ${res['take_no']} finished — ${res['adjusted_items']} item(s) corrected');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _cancel() async {
    final state = context.read<AppState>();
    final t = _take;
    if (t == null) return;
    if (!await confirm(context,
        title: 'Cancel this stock take?',
        message: 'Nothing has been changed yet, so cancelling loses only the counting you did.',
        okLabel: 'Cancel the count')) {
      return;
    }
    try {
      await state.api.cancelStockTake(t.id);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _take;
    final missing = _items.where((i) => i.variance < 0).length;
    final extra = _items.where((i) => i.variance > 0).length;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Stock take', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(width: 12),
            if (t != null) StatusPill(text: t.takeNo, color: AppColors.info, icon: Icons.fact_check_outlined),
            const Spacer(),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            if (t == null && _loadFailed)
              OutlinedButton.icon(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh), label: const Text('Check again'))
            else if (t == null)
              FilledButton.icon(onPressed: _busy ? null : _start, icon: const Icon(Icons.play_arrow), label: const Text('Start a count'))
            else ...[
              OutlinedButton.icon(onPressed: _cancel, icon: const Icon(Icons.close), label: const Text('Cancel count')),
              const SizedBox(width: 8),
              FilledButton.icon(
                  onPressed: _busy ? null : _finish,
                  icon: const Icon(Icons.check),
                  label: const Text('Finish & correct stock')),
            ],
          ]),
          const SizedBox(height: 16),
          if (t == null)
            SectionCard(
              child: const EmptyState(
                icon: Icons.fact_check_outlined,
                title: 'No stock take running',
                message: 'Start a count when you want to check the shelves against the books. '
                    'You can keep selling while counting.',
              ),
            )
          else ...[
            Row(children: [
              StatCard(label: 'Items counted', value: '${_items.length}',
                  icon: Icons.checklist, color: AppColors.info),
              const SizedBox(width: 12),
              StatCard(label: 'Short', value: '$missing',
                  icon: Icons.trending_down, color: missing > 0 ? AppColors.danger : AppColors.good),
              const SizedBox(width: 12),
              StatCard(label: 'Extra', value: '$extra',
                  icon: Icons.trending_up, color: extra > 0 ? AppColors.warn : AppColors.good),
            ]),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Count an item',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _barcode,
                      focusNode: _focusBarcode,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Scan the barcode (or type it)',
                        prefixIcon: Icon(Icons.qr_code_scanner),
                      ),
                      onSubmitted: (v) => _count(v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _qty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(labelText: 'Quantity on shelf'),
                      onSubmitted: (_) => _count(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () => _count(),
                    icon: const Icon(Icons.add),
                    label: const Text('Count'),
                  ),
                ]),
                if (_lastMessage != null) ...[
                  SizedBox(height: 12),
                  Text(_lastMessage!, style: TextStyle(color: AppColors.info)),
                ],
                const SizedBox(height: 8),
                Text(
                  'Tip: for loose items the scale label already contains the weight — '
                  'just scan it and leave the quantity empty.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Counted so far (${_items.length})',
              actions: [IconButton(onPressed: _loadItems, icon: const Icon(Icons.refresh))],
              child: _items.isEmpty
                  ? const EmptyState(icon: Icons.qr_code_scanner, title: 'Nothing counted yet')
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final it = _items[i];
                        final v = it.variance;
                        return ListTile(
                          dense: true,
                          title: Text(it.name),
                          subtitle: Text(
                            'book ${num2(it.expected)}  •  counted ${it.counted == null ? '-' : num2(it.counted!)}'
                            '${it.barcode.isEmpty ? '' : '  •  ${it.barcode}'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Text(
                            v == 0 ? 'matches' : '${v > 0 ? '+' : ''}${num2(v)}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: v == 0 ? AppColors.good : (v < 0 ? AppColors.danger : AppColors.warn),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ]),
      ),
    );
  }
}
