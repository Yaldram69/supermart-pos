import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/reporting.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/premium.dart';
import '../widgets/receipt.dart';

bool canViewCartPriceInsights(AppState state) {
  final role = state.identity?.role.toLowerCase() ?? '';
  return state.isManager || state.isAdmin || state.isSuperAdmin || role == 'cashier';
}

String priceTooltipMessage(CartLine line, String symbol) {
  final buffer = StringBuffer('Actual cost price: ${money(line.product.costPrice, symbol: symbol)}');
  if (line.product.salePrice != line.product.costPrice) {
    buffer.write('\nShelf price: ${money(line.product.salePrice, symbol: symbol)}');
  }
  final effective = line.effectiveUnitPrice;
  if (effective != line.product.salePrice) {
    buffer.write('\nTier price for ${qtyStr(line.qty)}: ${money(effective, symbol: symbol)}');
  }
  return buffer.toString();
}

String productPriceTooltipMessage(PosProduct p, String symbol) {
  final buffer = StringBuffer('Actual cost price: ${money(p.costPrice, symbol: symbol)}');
  if (p.salePrice != p.costPrice) {
    buffer.write('\nShelf price: ${money(p.salePrice, symbol: symbol)}');
  }

  final tiers = p.priceTiers
      .where((tier) => toD(tier['min_qty']) > 0)
      .toList()
    ..sort((a, b) => toD(b['min_qty']).compareTo(toD(a['min_qty'])));
  if (tiers.isNotEmpty) {
    final top = tiers.first;
    buffer.write('\nBulk price: ${num2(toD(top['min_qty']))}+ @ ${money(toD(top['price']), symbol: symbol)}');
  }

  if (p.wholesaleMinQty > 0 && p.wholesalePrice > 0) {
    buffer.write('\nWholesale: ${num2(p.wholesaleMinQty)}+ @ ${money(p.wholesalePrice, symbol: symbol)}');
  }

  return buffer.toString();
}

String subtotalProfitTooltipMessage(AppState state, String symbol) =>
    'Total profit: ${money(state.cartProfit, symbol: symbol)}';

/// The till screen. A USB barcode scanner just types the number and presses
/// Enter, which is why the barcode box keeps the focus all the time.
class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final _barcode = TextEditingController();
  final _barcodeFocus = FocusNode();
  final _globalKeyFocus = FocusNode();
  final _search = TextEditingController();
  final StringBuffer _scannerBuffer = StringBuffer();
  String _query = '';
  List<PosProduct> _results = [];
  bool _searching = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _barcodeFocus.requestFocus();
        _globalKeyFocus.requestFocus();
      }
      // If there is no cached product data yet, prefetch the fuller product list
      // so the billing view can show items instantly without waiting for the user
      // to type a search query.
      if (mounted) {
        final state = context.read<AppState>();
        if (state.productCatalogue.isEmpty && state.catalogue.isEmpty) {
          setState(() => _searching = true);
          state.searchFull('', limit: 200).then((list) {
            if (!mounted) return;
            setState(() {
              _results = list;
              _searching = false;
            });
          }).catchError((_) {
            if (!mounted) return;
            setState(() => _searching = false);
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _barcode.dispose();
    _barcodeFocus.dispose();
    _globalKeyFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  void _handleGlobalBarcodeScan(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    // Keys typed into any text field belong to that field. The old check looked
    // for EditableText on the focus node itself, which never matched, so typed
    // text leaked into the scan buffer.
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext != null &&
        focusContext.findAncestorStateOfType<EditableTextState>() != null) {
      return;
    }

    // Enter is checked first: on Windows it arrives as '\r', a non-empty
    // character, which used to be swallowed and never flushed the scan.
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final value = _scannerBuffer.toString().trim();
      _scannerBuffer.clear();
      if (value.isEmpty) return;
      final state = context.read<AppState>();
      unawaited(_onBarcode(value, state));
      return;
    }

    final character = event.character;
    if (character != null && character.isNotEmpty && !character.startsWith('\u0000')) {
      final cleaned = character.replaceAll(RegExp(r'\s+'), '');
      if (cleaned.isNotEmpty) {
        _scannerBuffer.write(cleaned);
      }
    }
  }

  /// Clears the search box and the results, however the search was cleared.
  void _clearSearch(AppState state) {
    _search.clear();
    _onQueryChanged('', state);
  }

  void _onQueryChanged(String v, AppState state) {
    _searchDebounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _query = v;
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() {
      _query = v;
      _searching = true;
    });

    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      // A till shows the best matches; a one-letter query must not return the
      // whole catalogue (limit 0 means unlimited).
      state.searchFull(v, limit: 200).then((list) {
        if (!mounted) return;
        setState(() {
          _results = list;
          _searching = false;
        });
      }).catchError((_) {
        if (!mounted) return;
        setState(() {
          _results = [];
          _searching = false;
        });
      });
    });
  }

  List<String> _categorySuggestions(AppState state) {
    final categories = state.categoryNames;
    if (categories.isEmpty) return const [];

    if (_query.trim().isEmpty) {
      return categories.take(6).toList();
    }

    // Categories whose name matches, plus categories of the products just found.
    // Both are cheap: no full re-scan of the catalogue per category.
    final needle = _query.trim().toLowerCase();
    final suggestions = <String>{
      for (final category in categories)
        if (category.toLowerCase().contains(needle)) category,
      for (final p in _results)
        if (p.categoryName.trim().isNotEmpty) p.categoryName.trim(),
    };
    return suggestions.take(6).toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final shortcuts = buildKeyboardShortcutGuide();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f2): () => _barcodeFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f4): () => _pickCustomer(state),
        const SingleActivator(LogicalKeyboardKey.f6): () => _invoiceDiscount(state),
        const SingleActivator(LogicalKeyboardKey.f8): () => _holdBill(state),
        const SingleActivator(LogicalKeyboardKey.f9): () => _resumeBill(state),
        const SingleActivator(LogicalKeyboardKey.f12): () => _charge(state),
        const SingleActivator(LogicalKeyboardKey.escape): () => _clearSearch(context.read<AppState>()),
      },
      child: Focus(
        autofocus: true,
        child: KeyboardListener(
          focusNode: _globalKeyFocus,
          onKeyEvent: _handleGlobalBarcodeScan,
          child: SizedBox.expand(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.page),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.info.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.info.withValues(alpha: 0.22)),
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final shortcut in shortcuts)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: AppColors.info.withValues(alpha: 0.28)),
                            ),
                            // Text.rich (not RichText) so the spans inherit the app's font
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${shortcut.key} ',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.info,
                                    ),
                                  ),
                                  TextSpan(
                                    text: shortcut.action,
                                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(height: AppSpacing.lg),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 4, child: _catalogueSide(state)),
                        SizedBox(width: AppSpacing.lg),
                        Expanded(flex: 4, child: _cartSide(state)),
                        SizedBox(width: AppSpacing.lg),
                        SizedBox(width: 320, child: _totalsSide(state)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ catalogue
  Widget _catalogueSide(AppState state) {
    // When the search box is empty, show the full local catalogue initially.
    // Browsing shows the whole catalogue (the list is lazy, so this stays fast).
    final results = _query.trim().isEmpty && !_searching
      ? (state.catalogue.isNotEmpty ? state.catalogue : state.productCatalogue)
      : _results;
    final sym = state.store?.currencySymbol ?? 'Rs';

    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _barcode,
                  focusNode: _barcodeFocus,
                  autofocus: true,
                  style: const TextStyle(fontSize: 20, letterSpacing: 1.2, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    labelText: 'Scan barcode  (F2)',
                    prefixIcon: const Icon(Icons.qr_code_scanner),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: 'Add what was typed',
                      onPressed: () => _onBarcode(_barcode.text, state),
                    ),
                  ),
                  onSubmitted: (v) => _onBarcode(v, state),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: '…or type a product name to look it up',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => _onQueryChanged(v, state),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: () => _addMiscItem(state),
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    label: const Text('Custom item'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (state.catalogue.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Categories',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final category in _categorySuggestions(state))
                        FilterChip(
                          label: Text(category),
                          selected: _query.trim().toLowerCase() == category.toLowerCase(),
                          onSelected: (_) {
                            final next = category;
                            _search.text = next;
                            _query = next;
                            _onQueryChanged(next, state);
                          },
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        SizedBox(height: AppSpacing.lg),
        Expanded(
            child: SectionCard(
            title: _query.trim().isEmpty && !_searching
              ? 'Tap an item to add it' // initial full catalogue
              : _searching
                ? 'Searching…'
                : '${results.length} match(es)',
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: results.isEmpty
                ? const EmptyState(
                    icon: Icons.search_off,
                    title: 'No product found',
                    message: 'Check the spelling, or scan the barcode again.')
                : Expanded(
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: ListView.separated(
                        itemCount: results.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (c, i) {
                                final p = results[i];
                                final out = p.stockQty <= 0 && !(state.store?.allowNegativeStock ?? false);
                                return ListTile(
                                  dense: true,
                                  enabled: !out,
                                  onTap: () {
                                    _handleProductTap(state, p);
                                    _barcodeFocus.requestFocus();
                                  },
                                  title: Text(p.name.isEmpty ? (p.raw['name']?.toString() ?? '(no name)') : p.name,
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                                  subtitle: Text(
                                    '${p.barcode.isEmpty ? p.categoryName : p.barcode}  •  ${qtyStr(p.stockQty)} ${p.unit} in stock',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: out ? AppColors.danger : (p.isLow ? AppColors.warn : Theme.of(context).colorScheme.onSurface),
                                    ),
                                  ),
                                  trailing: canViewCartPriceInsights(state)
                                      ? Tooltip(
                                          message: productPriceTooltipMessage(p, sym),
                                          preferBelow: true,
                                          child: Text(
                                            money(p.priceForQty(1, fallback: p.salePrice), symbol: sym) +
                                                ((p.wholesaleMinQty > 0 && p.wholesalePrice > 0)
                                                    ? '   (${num2(p.wholesaleMinQty)}+ @ ${money(p.wholesalePrice, symbol: sym)})'
                                                    : (p.raw['price_tiers'] != null && (p.raw['price_tiers'] as List).isNotEmpty
                                                        ? '   (${(p.priceTiers.where((tier) => toD(tier['min_qty']) > 0).toList()..sort((a, b) => toD(b['min_qty']).compareTo(toD(a['min_qty'])))).first['min_qty']}+ @ ${money(toD((p.priceTiers.where((tier) => toD(tier['min_qty']) > 0).toList()..sort((a, b) => toD(b['min_qty']).compareTo(toD(a['min_qty'])))).first['price']), symbol: sym)})'
                                                        : '')),
                                            style: const TextStyle(fontWeight: FontWeight.w700),
                                          ),
                                        )
                                      : Text(
                                          money(p.priceForQty(1, fallback: p.salePrice), symbol: sym) +
                                              ((p.wholesaleMinQty > 0 && p.wholesalePrice > 0)
                                                  ? '   (${num2(p.wholesaleMinQty)}+ @ ${money(p.wholesalePrice, symbol: sym)})'
                                                  : (p.raw['price_tiers'] != null && (p.raw['price_tiers'] as List).isNotEmpty
                                                      ? '   (${(p.priceTiers.where((tier) => toD(tier['min_qty']) > 0).toList()..sort((a, b) => toD(b['min_qty']).compareTo(toD(a['min_qty'])))).first['min_qty']}+ @ ${money(toD((p.priceTiers.where((tier) => toD(tier['min_qty']) > 0).toList()..sort((a, b) => toD(b['min_qty']).compareTo(toD(a['min_qty'])))).first['price']), symbol: sym)})'
                                                      : '')),
                                          style: const TextStyle(fontWeight: FontWeight.w700),
                                        ),
                                );
                        },
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- cart
  Widget _cartSide(AppState state) {
    final sym = state.store?.currencySymbol ?? 'Rs';

    return LayoutBuilder(
      builder: (context, constraints) {
        final headerHeight = 56.0;
        final footerHeight = state.cart.isNotEmpty ? 62.0 : 0.0;
        final listHeight = constraints.maxHeight > 0
            ? constraints.maxHeight - headerHeight - footerHeight - 18.0
            : 220.0;

        return SectionCard(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
          title: null,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(children: [
                  const Icon(Icons.shopping_cart_outlined),
                  const SizedBox(width: 8),
                  Text('Cart (${state.cart.length})',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (state.cart.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        if (await confirm(context,
                            title: 'Empty the cart?',
                            message: 'This clears every line. Nothing has been charged yet.',
                            okLabel: 'Clear cart')) {
                          state.clearCart();
                        }
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear'),
                    ),
                ]),
              ),
              const Divider(height: 1),
              SizedBox(
                // A floor, not clamp(): clamp throws when the window is shorter than its bounds.
                height: listHeight < 120.0 ? 120.0 : listHeight,
                child: state.cart.isEmpty
                    ? const EmptyState(
                        icon: Icons.qr_code_scanner,
                        title: 'Scan the first item',
                        message: 'The cart total appears here, and the stock drops on all 4 PCs the moment you charge.')
                    : Scrollbar(
                        thumbVisibility: true,
                        child: ListView.separated(
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: state.cart.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) => _cartRow(state, state.cart[index], sym),
                        ),
                      ),
              ),
              if (state.cart.isNotEmpty) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Row(children: [
                    Text('${state.cart.length} line(s)'),
                    const Spacer(),
                    Text('Subtotal ${money(state.subtotal, symbol: sym)}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _cartRow(AppState state, CartLine line, String sym) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(line.product.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Remove',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => state.removeLine(line),
            ),
          ]),
          Row(children: [
            QtyStepper(
              qty: line.qty,
              step: line.product.isWeightLike ? 0.5 : 1,
              onChanged: (q) => state.setQty(line, q),
            ),
            Text('${line.product.unit}  ', style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            if (canViewCartPriceInsights(state))
              Tooltip(
                message: priceTooltipMessage(line, sym),
                preferBelow: true,
                child: TextButton(
                  onPressed: () => _editLine(state, line, sym),
                  child: Text(money(line.effectiveUnitPrice, symbol: sym),
                      style: const TextStyle(decoration: TextDecoration.underline)),
                ),
              )
            else
              Tooltip(
                message: priceTooltipMessage(line, sym),
                preferBelow: true,
                child: Text(money(line.effectiveUnitPrice, symbol: sym)),
              ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: Text(money(line.net, symbol: sym),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ]),
          Row(children: [
            Text('In stock: ${qtyStr(line.product.stockQty)} ${line.product.unit}',
                style: TextStyle(
                    fontSize: 11,
                    color: line.product.stockQty < line.qty ? AppColors.danger : Theme.of(context).colorScheme.outline)),
            Spacer(),
            if (line.lineDiscount > 0)
              Text('line discount ${money(line.lineDiscount, symbol: sym)}',
                  style: TextStyle(fontSize: 11, color: AppColors.warn)),
          ]),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- totals
  Widget _totalsSide(AppState state) {
    final sym = state.store?.currencySymbol ?? 'Rs';
    return Column(
      children: [
        SectionCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () => _pickCustomer(state),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  ),
                  child: Row(children: [
                    const Icon(Icons.person_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.cartCustomer == null
                            ? 'Walk-in customer  (F4)'
                            : '${state.cartCustomer!.name}${state.cartCustomer!.balance > 0 ? ' — owes ${num2(state.cartCustomer!.balance)}' : ''}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 2,
                      ),
                    ),
                    if (state.cartCustomer != null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => state.setCustomer(null),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _invoiceDiscount(state),
                icon: const Icon(Icons.percent, size: 18),
                label: Text(state.invDiscountType == 'none'
                    ? 'Add bill discount  (F6)'
                    : 'Discount: ${state.discountLabel ?? '${num2(state.invoiceDiscountAmount)} $sym'}'),
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.lg),
        Expanded(
          child: SectionCard(
            expand: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (canViewCartPriceInsights(state))
                  Tooltip(
                    message: subtotalProfitTooltipMessage(state, sym),
                    preferBelow: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: Text('Subtotal', style: Theme.of(context).textTheme.bodyMedium)),
                          Text(money(state.subtotal, symbol: sym),
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                                fontFeatures: [FontFeature.tabularFigures()],
                              )),
                        ],
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text('Subtotal', style: Theme.of(context).textTheme.bodyMedium)),
                        Text(money(state.subtotal, symbol: sym),
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                              fontFeatures: [FontFeature.tabularFigures()],
                            )),
                      ],
                    ),
                  ),
                if (state.lineDiscountTotal > 0)
                  KeyValue(k: 'Line discounts', v: '- ${money(state.lineDiscountTotal, symbol: sym)}'),
                if (state.invoiceDiscountAmount > 0)
                  KeyValue(k: 'Bill discount', v: '- ${money(state.invoiceDiscountAmount, symbol: sym)}'),
                if ((state.store?.showTax ?? false))
                  KeyValue(
                      k: '${state.store?.taxLabel ?? 'Tax'} (${num2(state.store?.taxPercent)}%)',
                      v: money(state.taxTotal, symbol: sym)),
                const Divider(height: 18),
                AmountDueCard(
                  total: state.total,
                  symbol: sym,
                  items: state.cart.length,
                  units: state.cart.fold<double>(0, (a, l) => a + l.qty),
                  discount: (state.lineDiscountTotal + state.invoiceDiscountAmount) > 0
                      ? 'You saved ${money(state.lineDiscountTotal + state.invoiceDiscountAmount, symbol: sym)}'
                      : null,
                ),
                if (state.effectiveDiscountPercent > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Discount given: ${num2(state.effectiveDiscountPercent)}%'
                      '   (your limit ${num2(state.identity?.maxDiscountPercent)}%)',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: state.effectiveDiscountPercent > (state.identity?.maxDiscountPercent ?? 0)
                            ? AppColors.warn
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const Spacer(),
                SizedBox(
                  height: 66,
                  child: FilledButton.icon(
                    onPressed: state.cart.isEmpty ? null : () => _charge(state),
                    icon: const Icon(Icons.payments_outlined, size: 26),
                    label: const Text('CHARGE  (F12)', style: TextStyle(fontSize: 18)),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: state.cart.isEmpty ? null : () => _holdBill(state),
                        icon: const Icon(Icons.pause_circle_outline, size: 18),
                        label: const Text('Hold'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: state.heldBills.isEmpty ? null : () => _resumeBill(state),
                        icon: const Icon(Icons.restore, size: 18),
                        label: const Text('Resume'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Stock drops on every counter the instant this is charged.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- actions
  Future<void> _onBarcode(String value, AppState state) async {
    var code = AppState.normalizeBarcodeInput(value);
    _barcode.clear();
    _barcodeFocus.requestFocus();
    if (code.isEmpty) return;

    // A label printed by the weighing scale hides the weight (or the price)
    // inside the barcode. Unpack it so loose goods need no typing at all.
    double? scaleQty;
    double? scalePrice;
    final scan = state.parseScaleBarcode(code);
    if (scan != null) {
      code = scan.code;
      if (scan.mode == 'weight') {
        scaleQty = scan.weightKg;
      } else {
        scalePrice = scan.value;
      }
    }

    var p = state.findByBarcode(code);
    if (p == null && code.isNotEmpty) {
      for (final candidate in [...state.catalogue, ...state.productCatalogue]) {
        if (AppState.matchesBarcode(code, candidate.barcode)) {
          p = candidate;
          break;
        }
      }
    }
    if (p == null) {
      SystemSound.play(SystemSoundType.alert);
      if (mounted) {
        showMessage(context, 'No product with barcode "$code". Add it in Products first.', error: true);
      }
      return;
    }

    if (scaleQty != null) {
      _addProduct(state, p, qty: scaleQty);
      if (mounted) showMessage(context, '${p.name}: ${num2(scaleQty)} ${p.unit} from the scale label');
      return;
    }
    if (scalePrice != null && p.salePrice > 0) {
      _addProduct(state, p, qty: double.parse((scalePrice / p.salePrice).toStringAsFixed(3)));
      return;
    }

    if (p.isWeightLike) {
      await _addWeighed(state, p);       // ask for the weight instead of assuming 1
      return;
    }
    _addProduct(state, p);
  }

  /// Loose goods (atta, sugar, fruit): ask how much is on the scale.
  Future<void> _addWeighed(AppState state, PosProduct p) async {
    final isWeightProduct = p.isWeightLike;
    final unitPrice = TextEditingController(text: p.salePrice.toStringAsFixed(2));
    final amount = TextEditingController(text: p.salePrice.toStringAsFixed(2));
    final quantity = TextEditingController(text: isWeightProduct ? '1000' : '1');
    bool syncing = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setLocal) {
          void syncFromQuantity() {
            if (syncing) return;
            syncing = true;
            final raw = parseAmount(quantity.text) ?? 0;
            final pricePerUnit = parseAmount(unitPrice.text) ?? p.salePrice;
            if (isWeightProduct) {
              final grams = raw;
              final total = (grams / 1000.0) * pricePerUnit;
              amount.text = total.toStringAsFixed(2);
            } else {
              final count = raw;
              final total = count * pricePerUnit;
              amount.text = total.toStringAsFixed(2);
            }
            syncing = false;
          }

          void syncFromAmount() {
            if (syncing) return;
            syncing = true;
            final rupees = parseAmount(amount.text) ?? 0;
            final pricePerUnit = parseAmount(unitPrice.text) ?? p.salePrice;
            if (isWeightProduct) {
              final grams = pricePerUnit > 0 ? (rupees / pricePerUnit) * 1000.0 : 0;
              quantity.text = grams.toStringAsFixed(2);
            } else {
              final count = pricePerUnit > 0 ? rupees / pricePerUnit : 0;
              quantity.text = count.toStringAsFixed(3);
            }
            syncing = false;
          }

            final unitLabel = p.unit.trim().isEmpty ? 'pcs' : p.unit;
            final pricePerUnitPreview = parseAmount(unitPrice.text) ?? p.salePrice;
            final previewValue = isWeightProduct
              ? (parseAmount(quantity.text) ?? 0) / 1000 * pricePerUnitPreview
              : (parseAmount(quantity.text) ?? 0) * pricePerUnitPreview;

          return AlertDialog(
            title: Text('${p.name} — ${isWeightProduct ? 'by weight' : 'quick add'}'),
            contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            content: SizedBox(
              width: 380,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Price ${money(p.salePrice, symbol: state.store?.currencySymbol ?? 'Rs')} per $unitLabel'),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: unitPrice,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Price to charge (per $unitLabel)',
                  ),
                  onChanged: (_) => setLocal(syncFromQuantity),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: quantity,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: isWeightProduct ? 'Weight in grams' : 'Qty in $unitLabel',
                  ),
                  onChanged: (_) => setLocal(syncFromQuantity),
                  onSubmitted: (_) => Navigator.pop(c, true),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Amount (${state.store?.currencySymbol ?? 'Rs'})',
                  ),
                  onChanged: (_) => setLocal(syncFromAmount),
                ),
                const SizedBox(height: AppSpacing.md),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: Theme.of(c).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isWeightProduct
                        ? '${num2(parseAmount(quantity.text) ?? 0)} g = ${money(previewValue, symbol: state.store?.currencySymbol ?? 'Rs')}'
                        : '${num2(parseAmount(quantity.text) ?? 0)} $unitLabel = ${money(previewValue, symbol: state.store?.currencySymbol ?? 'Rs')}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add to bill')),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;

    final qtyValue = parseAmount(quantity.text) ?? 0;
    final amountValue = parseAmount(amount.text) ?? 0;
    final unitPriceValue = parseAmount(unitPrice.text) ?? p.salePrice;
    final qty = isWeightProduct
        ? (qtyValue > 0 ? qtyValue / 1000 : (amountValue > 0 ? p.weightKgForPrice(amountValue) : 0.0))
        : (qtyValue > 0 ? qtyValue : (amountValue > 0 ? (unitPriceValue > 0 ? amountValue / unitPriceValue : 0.0) : 0.0));
    if (qty <= 0) return;
    if (!(unitPriceValue >= 0)) {
      showMessage(context, 'A price cannot be negative.', error: true);
      return;
    }
    _addProduct(state, p, qty: qty);
    // apply custom unit price if different from product salePrice
    if ((unitPriceValue - p.salePrice).abs() > 0.0001) {
      final lastLine = state.cart.isNotEmpty ? state.cart.last : null;
      if (lastLine != null && lastLine.product.id == p.id) {
        state.setPrice(lastLine, unitPriceValue);
      }
    }
  }

  // ------------------------------------------------- held (parked) bills
  Future<void> _holdBill(AppState state) async {
    if (state.cart.isEmpty) {
      showMessage(context, 'There is nothing in the bill to hold', error: true);
      return;
    }
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hold this bill'),
        contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${state.cart.length} item(s) worth '
                '${money(state.total, symbol: state.store?.currencySymbol ?? 'Rs')} will be parked. '
                'Bring it back with F9.'),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: note,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name / note (optional)'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Hold bill')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await state.holdCurrentBill(note: note.text.trim());
    if (mounted) showMessage(context, 'Bill held — press F9 to bring it back');
  }

  Future<void> _resumeBill(AppState state) async {
    final bills = state.heldBills;
    if (bills.isEmpty) {
      showMessage(context, 'No held bills on this till');
      return;
    }
    final sym = state.store?.currencySymbol ?? 'Rs';
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Held bills'),
        content: SizedBox(
          width: 520,
          height: 340,
          child: ListView.separated(
            itemCount: bills.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (c, i) {
              final b = bills[i];
              final lines = (b['lines'] as List);
              final total = lines.fold<double>(
                  0, (a, l) => a + toD((l as Map)['qty']) * toD(l['unit_price']));
              return ListTile(
                leading: const Icon(Icons.pause_circle_outline),
                title: Text('${b['note'] == null || (b['note'] as String).isEmpty ? 'Bill' : b['note']}'
                    '${b['customer_name'] == null ? '' : '  •  ${b['customer_name']}'}'),
                subtitle: Text('${lines.length} item(s)  •  ${money(total, symbol: sym)}  •  '
                    '${agoLabel(DateTime.tryParse(b['at'] as String))}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, b['id'] as String),
                    child: const Text('Resume'),
                  ),
                  IconButton(
                    tooltip: 'Throw away',
                    onPressed: () async {
                      Navigator.pop(c);
                      await state.dropHeldBill(b['id'] as String);
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ]),
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
    if (picked == null || !mounted) return;
    if (state.cart.isNotEmpty) {
      if (!await confirm(context,
          title: 'Replace the current bill?',
          message: 'Hold the current bill first if you still need it.',
          okLabel: 'Replace')) {
        return;
      }
    }
    final n = await state.resumeBill(picked);
    if (mounted) showMessage(context, 'Bill brought back — $n item(s)');
  }

  Future<void> _handleProductTap(AppState state, PosProduct p) async {
    await _addWeighed(state, p);
  }

  void _addProduct(AppState state, PosProduct p, {double qty = 1}) {
    if (!(p.raw['is_misc_item'] == true) && p.stockQty <= 0 && !(state.store?.allowNegativeStock ?? false)) {
      showMessage(context, '${p.name} is out of stock.', error: true);
      SystemSound.play(SystemSoundType.alert);
      return;
    }
    state.addToCart(p, qty: qty);
    SystemSound.play(SystemSoundType.click);
  }

  Future<void> _addMiscItem(AppState state) async {
    final name = TextEditingController();
    final qty = TextEditingController(text: '1');
    final price = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add custom item'),
        contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Item name'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Quantity'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Price per item'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Add to cart'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;
    final itemName = name.text.trim();
    final itemQty = parseAmount(qty.text) ?? 1;
    final itemPrice = parseAmount(price.text) ?? 0;
    if (itemName.isEmpty) {
      showMessage(context, 'Please enter the item name.', error: true);
      return;
    }
    if (itemPrice <= 0) {
      showMessage(context, 'Please enter a price greater than zero.', error: true);
      return;
    }
    if (itemQty <= 0) {
      showMessage(context, 'The quantity must be more than zero.', error: true);
      return;
    }
    _addProduct(
      state,
      PosProduct({
        'id': '',
        'name': itemName,
        'barcode': '',
        'unit': 'pcs',
        'sale_price': itemPrice,
        'cost_price': 0,
        'stock_qty': 0,
        'is_active': true,
        'is_misc_item': true,
      }),
      qty: itemQty,
    );
  }

  Future<void> _pickCustomer(AppState state) async {
    final search = TextEditingController();
    final picked = await showDialog<Customer?>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) {
          final list = state.customers
              .where((x) =>
                  search.text.isEmpty ||
                  x.name.toLowerCase().contains(search.text.toLowerCase()) ||
                  x.phone.contains(search.text))
              .take(40)
              .toList();
          return AlertDialog(
            title: const Text('Attach a customer'),
            contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            content: SizedBox(
              width: 460,
              height: 460,
              child: Column(children: [
                TextField(
                  controller: search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search by name or phone number',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: AppSpacing.sm),
                Expanded(
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (c, i) {
                      final cust = list[i];
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          child: Text(cust.name.characters.first.toUpperCase()),
                        ),
                        title: Text(cust.name),
                        subtitle: Text(
                          '${cust.phone.isEmpty ? 'no phone' : cust.phone}  •  owes ${money(cust.balance)}'
                          '${cust.creditLimit > 0 ? ' (limit ${num2(cust.creditLimit)})' : ''}',
                        ),
                        onTap: () => Navigator.pop(c, cust),
                      );
                    },
                  ),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
              TextButton(
                onPressed: () => Navigator.pop(c, null),
                child: const Text('Walk-in (no account)'),
              ),
              FilledButton(
                onPressed: () => _newCustomer(state).then((c2) {
                  if (c2 != null && c.mounted) Navigator.pop(c, c2);
                }),
                child: const Text('New customer'),
              ),
            ],
          );
        },
      ),
    );
    if (picked != null) state.setCustomer(picked);
  }

  Future<Customer?> _newCustomer(AppState state) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final limit = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New customer'),
        contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: AppSpacing.sm),
          TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone number')),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: limit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Credit (udhaar) limit — 0 for none'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return null;
    try {
      final res = await state.api.saveCustomer({
        'name': name.text,
        'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
        'credit_limit': parseAmount(limit.text) ?? 0,
      });
      await state.refreshReference();
      final cust = Customer(res);
      state.setCustomer(cust);
      return cust;
    } catch (e) {
      if (mounted) showError(context, e);
      return null;
    }
  }

  Future<void> _editLine(AppState state, CartLine line, String sym) async {
    final price = TextEditingController(text: line.unitPrice.toStringAsFixed(2));
    final disc = TextEditingController(text: line.lineDiscount.toStringAsFixed(2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(line.product.name),
        contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: price,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Unit price (shelf price ${num2(line.product.salePrice)})',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: disc,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Discount on this line (Rs)'),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'Any discount counts towards the discount limit, and a manager PIN is checked by the server.',
            style: TextStyle(fontSize: 11.5),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Apply')),
        ],
      ),
    );
    if (ok == true && mounted) {
      final newPrice = parseAmount(price.text);
      if (newPrice == null || !(newPrice >= 0)) {
        showMessage(context, 'Enter a price of zero or more.', error: true);
        return;
      }
      state.setPrice(line, newPrice);
      state.setLineDiscount(line, parseAmount(disc.text) ?? 0);
    }
  }

  Future<void> _invoiceDiscount(AppState state) async {
    final code = TextEditingController();
    final value = TextEditingController();
    String kind = state.invDiscountType == 'none' ? 'percent' : state.invDiscountType;
    String? info;

    final applied = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: const Text('Bill discount'),
          contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'none', label: Text('None')),
                  ButtonSegment(value: 'percent', label: Text('% off')),
                  ButtonSegment(value: 'amount', label: Text('Rs off')),
                  ButtonSegment(value: 'code', label: Text('Code')),
                ],
                selected: {kind},
                onSelectionChanged: (s) => setLocal(() => kind = s.first),
              ),
              const SizedBox(height: AppSpacing.md),
              if (kind == 'percent' || kind == 'amount')
                TextField(
                  controller: value,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: kind == 'percent' ? 'Percent off the whole bill' : 'Rupees off the whole bill',
                  ),
                ),
              if (kind == 'code')
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: code,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Discount code'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      try {
                        final res = await state.api
                            .checkDiscountCode(code.text.trim(), state.subtotal);
                        state.setInvoiceDiscount('code', toD(res['value']),
                            code: res['code']?.toString(),
                            label: '${res['code']} (${res['name']})',
                            amount: toD(res['amount']));
                        if (c.mounted) Navigator.pop(c, true);
                      } catch (e) {
                        setLocal(() => info = e.toString());
                      }
                    },
                    child: const Text('Check'),
                  ),
                ]),
              if (info != null) ...[
                SizedBox(height: AppSpacing.sm),
                Text(info!, style: TextStyle(color: AppColors.danger, fontSize: 12)),
              ],
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Cashiers can give up to ${num2(state.identity?.maxDiscountPercent)}%. '
                'Anything more is refused by the server unless a manager applies it.',
                style: const TextStyle(fontSize: 11.5),
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () {
                state.setInvoiceDiscount('none', 0);
                Navigator.pop(c, false);
              },
              child: const Text('Remove discount'),
            ),
            FilledButton(
              onPressed: () {
                if (kind == 'percent' || kind == 'amount') {
                  state.setInvoiceDiscount(kind, parseAmount(value.text) ?? 0);
                }
                Navigator.pop(c, true);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (applied == true && mounted) setState(() {});
  }

  // -------------------------------------------------------------- charge

  bool _paying = false;

  /// One checkout at a time. A second F12 or CHARGE while the payment dialog or
  /// the sale is still open is ignored, so the same bill cannot be rung twice.
  Future<void> _charge(AppState state) async {
    if (_paying || state.charging || state.cart.isEmpty) return;
    _paying = true;
    try {
      await _chargeFlow(state);
    } finally {
      _paying = false;
    }
  }

  Future<void> _chargeFlow(AppState state) async {
    if (state.cart.isEmpty) return;
    final sym = state.store?.currencySymbol ?? 'Rs';
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (c) => _PaymentDialog(total: state.total, sym: sym, state: state),
    );
    if (result == null) return;

    final method = result['method'] as String;
    final paid = toD(result['paid']);
    final ref = (result['ref'] ?? '') as String;
    final voucher = (result['voucher'] ?? '') as String;
    SaleResult? sale;
    String? pin;

    // Up to 3 tries: a refusal that a manager can approve with their PIN
    // (discount over the cashier's limit) sends us back here with the PIN.
    for (var attempt = 0; attempt < 3 && sale == null; attempt++) {
      try {
        sale = await state.charge(method: method, paid: paid, paymentRef: ref,
            managerPin: pin, voucherCode: voucher);
      } on AppError catch (e) {
        if (!needsManagerApproval(e) || !mounted) {
          if (mounted) {
            showError(context, e);
            _barcodeFocus.requestFocus();
          }
          return;
        }
        final entered = await askManagerPin(context, e.message);
        if (entered == null || entered.isEmpty) return;   // manager cancelled
        pin = entered;
      } catch (e) {
        if (mounted) {
          showError(context, e);
          _barcodeFocus.requestFocus();
        }
        return;
      }
    }

    final done = sale;
    if (done == null) return;

    state.clearCart();
    if (!mounted) return;
    if (state.store == null) return;

    // One receipt per sale: the dialog only decides whether to print it.
    final printReceipt = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Row(children: [
          Icon(Icons.check_circle, color: AppColors.good, size: 28),
          const SizedBox(width: 12),
          Expanded(child: Text('Invoice ${done.invoiceNo}')),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          KeyValue(k: 'Total', v: money(done.total, symbol: sym), bold: true),
          KeyValue(k: 'Received', v: money(done.paid, symbol: sym)),
          KeyValue(k: 'Change to give', v: money(done.change, symbol: sym),
              bold: true, color: AppColors.good),
          if (done.raw['offline'] == true)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'No internet: the sale is saved on this PC and goes to the server when the '
                'connection is back. The invoice number will change then.',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No receipt')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(c, true),
            icon: const Icon(Icons.print),
            label: const Text('Print receipt'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (printReceipt == true && state.store != null) {
      await ReceiptPrinter.printSale(context, result: done.raw, store: state.store);
    }
    _barcodeFocus.requestFocus();
  }

}

/// Payment screen: cash with quick notes, card, wallet, or udhaar (credit).
class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.total, required this.sym, required this.state});
  final double total;
  final String sym;
  final AppState state;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  String _method = 'cash';
  final _paid = TextEditingController();
  final _ref = TextEditingController();
  final _voucher = TextEditingController();
  double _voucherBalance = 0;
  bool _checking = false;

  double get _voucherUse =>
      _voucherBalance > widget.total ? widget.total : _voucherBalance;
  double get _due => (widget.total - _voucherUse) < 0 ? 0 : widget.total - _voucherUse;

  @override
  void initState() {
    super.initState();
    _paid.text = widget.total.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _paid.dispose();
    _ref.dispose();
    _voucher.dispose();
    super.dispose();
  }

  /// Cash must cover the amount due before the sale can be completed.
  bool _cashCovers(double paid) => paid + 0.005 >= _due;

  void _complete(double paid) {
    Navigator.pop(context, {
      'method': _method,
      'paid': _method == 'credit' ? 0 : (_method == 'cash' ? paid : _due),
      'ref': _ref.text.trim().isEmpty ? null : _ref.text.trim(),
      'voucher': _voucherUse > 0 ? _voucher.text.trim() : null,
    });
  }

  Future<void> _checkVoucher() async {
    final code = _voucher.text.trim();
    if (code.isEmpty) return;
    setState(() => _checking = true);
    try {
      final res = await widget.state.api.voucherBalance(code);
      if (!mounted) return;
      setState(() {
        _voucherBalance = toD(res['balance']);
        _paid.text = _due.toStringAsFixed(2);
      });
      showMessage(context,
          'Voucher ${res['code']}: ${money(toD(res['balance']), symbol: widget.sym)} available');
    } catch (e) {
      if (!mounted) return;
      setState(() => _voucherBalance = 0);
      showError(context, e);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paid = parseAmount(_paid.text) ?? 0;
    final change = paid - _due;
    final needsCustomer = _method == 'credit';
    final ok = !needsCustomer || widget.state.cartCustomer != null;
    final short = _method == 'cash' && !_cashCovers(paid);
    final canComplete = ok && !short;

    return AlertDialog(
      title: Row(children: [
        const Text('Take payment'),
        const Spacer(),
        Text(money(widget.total, symbol: widget.sym),
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ]),
      contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.state.cartCustomer != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text('Customer: ${widget.state.cartCustomer!.name}'),
            ),
          if (_method != 'credit')
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _voucher,
                    decoration: const InputDecoration(
                      labelText: 'Gift voucher / store credit code (optional)',
                      prefixIcon: Icon(Icons.card_giftcard_outlined),
                      hintText: 'GV-XXXXXX',
                    ),
                    onSubmitted: (_) => _checkVoucher(),
                  ),
                ),
                const SizedBox(width: 8),
                _checking
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : OutlinedButton(onPressed: _checkVoucher, child: const Text('Check')),
              ]),
            ),
          if (_voucherUse > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppColors.good.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  Icon(Icons.card_giftcard, size: 18, color: AppColors.good),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Voucher pays ${money(_voucherUse, symbol: widget.sym)} — '
                      'collect ${money(_due, symbol: widget.sym)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove voucher',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() {
                      _voucher.clear();
                      _voucherBalance = 0;
                      _paid.text = widget.total.toStringAsFixed(2);
                    }),
                  ),
                ]),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in const [
                ('cash', 'Cash', Icons.payments_outlined),
                ('card', 'Card', Icons.credit_card),
                ('jazzcash', 'JazzCash', Icons.phone_android),
                ('easypaisa', 'Easypaisa', Icons.phone_iphone),
                ('bank_transfer', 'Bank', Icons.account_balance),
                ('credit', 'Udhaar (credit)', Icons.receipt),
              ])
                ChoiceChip(
                  selected: _method == m.$1,
                  onSelected: (_) => setState(() => _method = m.$1),
                  avatar: Icon(m.$3, size: 18, color: _method == m.$1 ? Theme.of(context).colorScheme.onPrimary : null),
                  selectedColor: m.$1 == 'credit' ? AppColors.credit : AppColors.cash,
                  labelStyle: TextStyle(color: _method == m.$1 ? Theme.of(context).colorScheme.onPrimary : null),
                  label: Text(m.$2),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_method == 'cash') ...[
            TextField(
              controller: _paid,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: 'Cash received',
                prefixIcon: const Icon(Icons.currency_exchange),
              ),
              onChanged: (_) => setState(() {}),
              // Enter in the cash box is the cashier's natural "done" key.
              onSubmitted: (_) {
                if (canComplete) _complete(paid);
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final note in const [50, 100, 200, 500, 1000, 5000])
                  OutlinedButton(
                    onPressed: () => setState(() {
                      final current = parseAmount(_paid.text) ?? 0;
                      _paid.text = (current + note).toStringAsFixed(2);
                    }),
                    child: Text('+$note'),
                  ),
                OutlinedButton(
                  onPressed: () => setState(() => _paid.text = _due.toStringAsFixed(2)),
                  child: const Text('Exact'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              change >= 0
                  ? 'Change to give: ${money(change, symbol: widget.sym)}'
                  : 'Short by ${money(-change, symbol: widget.sym)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: change >= 0 ? AppColors.good : AppColors.danger,
              ),
            ),
          ],
          if (_method != 'cash' && _method != 'credit') ...[
            TextField(
              controller: _ref,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Reference / approval code (optional)',
                prefixIcon: Icon(Icons.tag),
              ),
            ),
          ],
          if (needsCustomer && !ok)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text(
                'Udhaar needs a customer account — attach one from the cart (F4).',
                style: TextStyle(color: AppColors.credit, fontWeight: FontWeight.w600),
              ),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: canComplete ? () => _complete(paid) : null,
          icon: const Icon(Icons.check),
          label: const Text('Complete sale'),
        ),
      ],
    );
  }
}

