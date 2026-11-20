// The single source of truth for the running app: who is signed in, what the
// till can see, the live catalogue (kept fresh by realtime), and the cart.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/app_config.dart';
import '../core/format.dart';
import '../models.dart';
import '../services/api.dart';
import 'offline_overlay.dart';

class AppState extends ChangeNotifier {
  AppState(this.api) {
    _authSub = api.authChanges.listen((_) {
      // while a restore is running it settles the state itself, when it is done
      if (!_restoring) unawaited(_settleSession());
    });
    unawaited(_restoreSession());
  }

  final Api api;

  /// True while the saved sign-in is being restored. The till waits for it rather
  /// than showing the sign-in screen.
  bool sessionPending = true;
  /// A sign-in is saved on this PC but cannot be confirmed yet (no internet). The till
  /// keeps working from its saved copy, and restores the sign-in when the internet is back.
  bool _savedSessionKept = false;
  bool _restoring = false;

  /// Signed in: confirmed by the server, or saved on this PC and waiting for the internet.
  bool get signedIn => api.isSignedIn || _savedSessionKept;

  /// Restores the saved sign-in. Waits a few seconds for it; if it is still running
  /// (no internet), the till opens from its saved copy and the restore keeps going.
  Future<void> _restoreSession() async {
    if (_restoring) return;
    if (api.isSignedIn) {
      await _settleSession();
      return;
    }
    _restoring = true;
    final attempt = api.restoreSavedSession();
    unawaited(attempt.whenComplete(() {
      _restoring = false;
      unawaited(_settleSession());
    }));
    await attempt.timeout(const Duration(seconds: 6), onTimeout: () => false);
    await _settleSession();
  }

  /// Works out where the till stands and starts the till once a sign-in is confirmed.
  Future<void> _settleSession() async {
    _savedSessionKept = !api.isSignedIn && await api.hasSavedSession();
    sessionPending = false;
    notifyListeners();
    // Start the till when it has nothing loaded yet (a saved sign-in, confirmed or not),
    // and reload it once a confirmed sign-in is back after an offline start.
    if (signedIn && (identity == null || (api.isSignedIn && !online))) unawaited(bootstrap());
  }

  // ---- who / where ----
  Identity? identity;
  StoreSettings? store;
  bool booting = true;
  String? bootError;
  bool online = true;
  int pendingOffline = AppConfig.queueEntries.length;
  /// One plain-language line about the last sync, shown on the sync screen.
  String? syncNotice;
  DateTime? catalogueSyncedAt;

  // ---- catalogue (live across all 4 PCs) ----
  List<PosProduct> catalogue = [];
  List<PosProduct> productCatalogue = [];
  final Map<String, PosProduct> byBarcode = {};
  final Map<String, PosProduct> byId = {};
  List<Map<String, dynamic>> categories = [];
  List<Map<String, dynamic>> subcategories = [];
  List<Customer> customers = [];
  List<Map<String, dynamic>> liveDiscounts = [];
  List<Map<String, dynamic>> devices = [];
  Shift? shift;
  DateTime? _lastProductCatalogueRefreshAt;

  /// Sorted category names, rebuilt whenever the catalogue changes, so the POS
  /// does not re-scan every product on each redraw.
  List<String> categoryNames = [];
  final Map<String, Map<String, dynamic>> _productRowsById = {};
  Map<String, List<Map<String, dynamic>>> _tiersByProduct = {};
  DateTime? _lastTierRefreshAt;
  bool _flushing = false;
  bool _charging = false;
  List<Map<String, dynamic>>? _pendingCacheRows;
  Timer? _cacheSaveTimer;

  /// Live stock/price changes arrive one row at a time over this channel.
  RealtimeChannel? _stockChannel;
  /// Every stock row this till knows about, keyed by product id. Realtime
  /// changes are merged into it instead of re-downloading the whole catalogue.
  final Map<String, Map<String, dynamic>> _catalogueRaw = {};
  final Map<String, Map<String, dynamic>> _pendingRows = {};
  /// The server's admin product and customer rows, before offline changes are laid over them.
  List<Map<String, dynamic>> _adminRowsRaw = [];
  List<Map<String, dynamic>> _serverCustomerRows = [];
  Timer? _applyTimer;
  int _tickCount = 0;
  StreamSubscription<AuthState>? _authSub;
  Timer? _ticker;

  /// True while a sale is being sent. The POS uses this so a second press of
  /// F12 or CHARGE cannot start a second sale.
  bool get charging => _charging;

  // ---- the cart ----
  final List<CartLine> cart = [];
  Customer? cartCustomer;
  int navIndex = 0;
  String invDiscountType = 'none';
  double invDiscountValue = 0;
  String? discountCode;
  String? discountLabel;
  double codeDiscountAmount = 0;
  String cartNote = '';

  static String? _cleanOptionalText(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool get isManager => identity?.isManager ?? false;
  bool get isAdmin => identity?.isAdmin ?? false;
  bool get isSuperAdmin => identity?.isSuperAdmin ?? false;
  PermissionSet get permissions => identity?.permissions ?? PermissionSet.forRole('cashier');
  bool canPerform(String action) => permissions.canPerform(action);
  bool get canApproveDiscount => canPerform('approve_discount');
  bool get canVoidSale => canPerform('void_sale');
  bool get canRefundSale => canPerform('refund_sale');
  bool get canAdjustStock => canPerform('adjust_stock');
  bool get canManageStaff => canPerform('manage_staff');
  bool get canOpenSettings => canPerform('open_settings');
  bool get canCloseShift => canPerform('close_shift');
  bool get hasOpenShift => shift?.isOpen ?? false;

  // ================================================================ boot
  /// Opens the till on the last known catalogue immediately, so a restart in
  /// the middle of a power cut does not leave the counter unable to sell.
  void loadCachedCatalogue() {
    if (catalogue.isNotEmpty) return;
    final rows = AppConfig.cachedCatalogue;
    if (rows.isEmpty) return;
    // the saved copy is the base that offline changes and realtime rows are merged into
    _catalogueRaw
      ..clear()
      ..addEntries(rows
          .where((row) => row['product_id'] != null)
          .map((row) => MapEntry(row['product_id'].toString(), row)));
    _useRows(rows, fromCache: true);
  }

  void loadCachedProductCatalogue() {
    if (productCatalogue.isNotEmpty) return;
    final rows = AppConfig.cachedProductCatalogue;
    if (rows.isEmpty) return;
    _setProductRows(rows);
  }

  /// Keeps the admin product list (with cost prices) and indexes it by id.
  void _setProductRows(List<Map<String, dynamic>> rows) {
    _adminRowsRaw = rows;
    final laidOver = subtractQueuedSales(
      overlayProducts(rows, ops: AppConfig.opEntries, ids: AppConfig.idMap),
      sales: _queuedSalePayloads(),
      ids: AppConfig.idMap,
    );
    final fresh = laidOver.where((row) {
      final deleted = row['is_deleted'] == true || row['is_deleted'] == 'true';
      final inactive = row['is_active'] == false || row['is_active'] == 'false';
      return !deleted && !inactive;
    }).toList();
    _productRowsById
      ..clear()
      ..addEntries(fresh
          .where((row) => (row['id'] ?? row['product_id']) != null)
          .map((row) => MapEntry((row['id'] ?? row['product_id']).toString(), row)));
    _attachExtras(fresh);
    productCatalogue = fresh.map(PosProduct.new).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _reindexBarcodeMap();
  }

  static bool shouldAllowOfflineBoot({
    required bool hasCachedCatalogue,
    required Object? error,
  }) {
    if (!hasCachedCatalogue) return false;
    if (error is AppError) return error.isOffline;
    return false;
  }

  // Compiled once. These run per product on every search keystroke and per
  // product when the barcode index is rebuilt, so compiling them each time was
  // a large share of the search cost.
  static final RegExp _whitespace = RegExp(r'[\r\n\t\s]+');
  static final RegExp _notAlnumUpper = RegExp(r'[^A-Za-z0-9]');
  static final RegExp _leadingZeros = RegExp(r'^0+');
  static final RegExp _nonSearchChar = RegExp(r'[^a-z0-9]+');
  static final RegExp _runOfSpaces = RegExp(r'\s+');
  static final RegExp _vowel = RegExp(r'[aeiou]');

  static String normalizeBarcodeInput(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final compact = trimmed.toUpperCase().replaceAll(_whitespace, '');
    return compact.replaceAll(_notAlnumUpper, '');
  }

  static bool matchesBarcode(String scannedCode, String productBarcode) {
    final code = normalizeBarcodeInput(scannedCode);
    final productCode = normalizeBarcodeInput(productBarcode);
    if (code.isEmpty || productCode.isEmpty) return false;
    if (code == productCode) return true;

    final strippedCode = code.replaceFirst(_leadingZeros, '');
    final strippedProductCode = productCode.replaceFirst(_leadingZeros, '');
    if (strippedCode.isEmpty || strippedProductCode.isEmpty) return false;

    return strippedCode == strippedProductCode ||
        strippedCode.endsWith(strippedProductCode) ||
        strippedProductCode.endsWith(strippedCode) ||
        code.endsWith(productCode) ||
        productCode.endsWith(code);
  }

  static String _normalizeSearchText(String value) =>
      value.toLowerCase().replaceAll(_nonSearchChar, '');

  static List<String> _searchTokens(String value) => value
      .toLowerCase()
      .replaceAll(_nonSearchChar, ' ')
      .split(_runOfSpaces)
      .where((token) => token.trim().isNotEmpty)
      .toList();

  // The searchable forms of one piece of text, worked out once and kept. The
  // scoring rules below read these instead of re-normalising every product on
  // every keystroke, which made search on a large catalogue take hundreds of ms.
  static final Expando<_ProductSearch> _searchCache = Expando<_ProductSearch>();

  static _ProductSearch _searchFor(PosProduct p) {
    var s = _searchCache[p];
    if (s == null) {
      s = _ProductSearch(p);
      _searchCache[p] = s;
    }
    return s;
  }

  /// Scores one product against the query. Same rules as before, but every
  /// product text is already normalised (see [_SearchText]).
  static int _scoreName(_SearchText h, _SearchQuery q) {
    if (q.norm.isEmpty) return 100;
    if (h.norm == q.norm) return 10;
    if (h.norm.startsWith(q.norm)) return 9;
    if (q.norm.length >= 4 && h.norm.contains(q.norm)) return 8;
    if (q.compact.length >= 3 && h.compact.contains(q.compact)) return 7;

    final tokens = h.tokens;
    if (tokens.any((t) => t == q.norm || t.startsWith(q.norm))) return 7;
    if (q.norm.length >= 4 && tokens.any((t) => t.contains(q.norm))) return 6;

    if (q.tokens.isNotEmpty &&
        q.tokens.every((qt) => tokens.any((t) => t == qt || t.startsWith(qt)))) {
      return 5;
    }
    if (q.tokens.isNotEmpty &&
        q.tokens.any((qt) => qt.length >= 4 && tokens.any((t) => t.contains(qt)))) {
      return 4;
    }
    return 0;
  }

  static int _scoreCode(_SearchText h, _SearchQuery q) {
    if (q.norm.isEmpty) return 100;
    if (h.lower.contains(q.norm)) return 5;
    if (q.compact.length >= 3 && h.compact.contains(q.compact)) return 4;
    return 0;
  }

  static List<PosProduct> filterPosProducts(
    List<PosProduct> source, {
    String query = '',
    String filter = 'all',
    String? category,
  }) {
    final term = query.trim();
    final hasCategory = category != null && category.isNotEmpty;

    // Browsing (no search text): keep the source order, which is already by name.
    if (term.isEmpty) {
      return source.where((p) {
        if (filter == 'low' && !p.isLow) return false;
        if (filter == 'out' && !p.isOut) return false;
        if (hasCategory && p.categoryName != category) return false;
        return true;
      }).toList();
    }

    // Searching: the query is normalised once; each product is scored once.
    final q = _SearchQuery(term);
    final scored = <(PosProduct, int, String)>[];
    for (final p in source) {
      if (filter == 'low' && !p.isLow) continue;
      if (filter == 'out' && !p.isOut) continue;
      if (hasCategory && p.categoryName != category) continue;
      final s = _searchFor(p);
      final score = _bestScore(s, q);
      if (score > 0) scored.add((p, score, s.name.lower));
    }
    scored.sort((a, b) {
      if (a.$2 != b.$2) return b.$2.compareTo(a.$2);
      return a.$3.compareTo(b.$3);
    });
    return [for (final s in scored) s.$1];
  }

  static int _bestScore(_ProductSearch s, _SearchQuery q) {
    var best = _scoreName(s.name, q);
    if (best >= 10) return best;
    final category = _scoreName(s.category, q);
    if (category > best) best = category;
    final barcode = _scoreCode(s.barcode, q);
    if (barcode > best) best = barcode;
    final sku = _scoreCode(s.sku, q);
    if (sku > best) best = sku;
    return best;
  }

  static bool matchesCategoryFilter({
    required AdminProduct product,
    String? category,
    String? subcategory,
    List<Map<String, dynamic>> categories = const [],
    List<Map<String, dynamic>> subcategories = const [],
  }) {
    final selectedCategory = category?.trim();
    final selectedSubcategory = subcategory?.trim();

    if ((selectedCategory == null || selectedCategory.isEmpty) &&
        (selectedSubcategory == null || selectedSubcategory.isEmpty)) {
      return true;
    }

    final productCategory = product.categoryName.trim();
    final productCategoryId = product.raw['category_id']?.toString().trim();

    if (selectedSubcategory != null && selectedSubcategory.isNotEmpty) {
      if (productCategory == selectedSubcategory) return true;
      if (productCategoryId == null || productCategoryId.isEmpty) return false;
      return subcategories.any((row) =>
          row['name']?.toString().trim() == selectedSubcategory &&
          row['id']?.toString().trim() == productCategoryId);
    }

    if (selectedCategory != null && selectedCategory.isNotEmpty) {
      if (productCategory == selectedCategory) return true;

      final parentId = categories
          .firstWhere(
            (row) => row['name']?.toString().trim() == selectedCategory,
            orElse: () => const <String, dynamic>{},
          )['id']
          ?.toString()
          .trim();

      if (parentId == null || parentId.isEmpty) return false;

      return subcategories.any((row) {
        final rowId = row['id']?.toString().trim();
        final rowParentId = row['parent_id']?.toString().trim();
        return rowParentId == parentId &&
            (row['name']?.toString().trim() == productCategory || rowId == productCategoryId);
      });
    }

    return true;
  }

  static List<AdminProduct> filterAdminProducts(
    List<AdminProduct> source, {
    String query = '',
    String filter = 'all',
    String? category,
    String? subcategory,
    List<Map<String, dynamic>> categories = const [],
    List<Map<String, dynamic>> subcategories = const [],
  }) {
    // The source must already be sorted by name (the products screen does this once
    // when it loads), so filtering on every keystroke does not re-sort.
    final term = query.trim().toLowerCase();
    return source.where((p) {
      if (filter == 'low' && !p.isLow) return false;
      if (filter == 'out' && p.stockQty > 0) return false;
      if (filter == 'inactive' && p.isActive) return false;
      if (!matchesCategoryFilter(
        product: p,
        category: category,
        subcategory: subcategory,
        categories: categories,
        subcategories: subcategories,
      )) {
        return false;
      }
      if (term.isEmpty) return true;
      return p.name.toLowerCase().contains(term) ||
          p.barcode.toLowerCase().contains(term) ||
          p.sku.toLowerCase().contains(term) ||
          p.categoryName.toLowerCase().contains(term);
    }).toList();
  }

  void _reindexBarcodeMap() {
    byBarcode.clear();
    byId.clear();

    for (final p in catalogue) {
      final normalized = normalizeBarcodeInput(p.barcode);
      if (normalized.isNotEmpty) {
        byBarcode[normalized] = p;
        final stripped = normalized.replaceFirst(_leadingZeros, '');
        if (stripped.isNotEmpty && !byBarcode.containsKey(stripped)) byBarcode[stripped] = p;
      }
      if (p.id.isNotEmpty) byId[p.id] = p;
    }

    for (final p in productCatalogue) {
      final normalized = normalizeBarcodeInput(p.barcode);
      if (normalized.isNotEmpty && !byBarcode.containsKey(normalized)) {
        byBarcode[normalized] = p;
      }
      final stripped = normalized.replaceFirst(_leadingZeros, '');
      if (stripped.isNotEmpty && !byBarcode.containsKey(stripped)) {
        byBarcode[stripped] = p;
      }
      if (p.id.isNotEmpty && !byId.containsKey(p.id)) byId[p.id] = p;
    }
  }

  void _useRows(List<Map<String, dynamic>> rows, {bool fromCache = false}) {
    final laidOver = subtractQueuedSales(
      overlayProducts(rows, ops: AppConfig.opEntries, ids: AppConfig.idMap),
      sales: _queuedSalePayloads(),
      ids: AppConfig.idMap,
    );
    final fresh = laidOver.where((row) {
      final deleted = row['is_deleted'] == true || row['is_deleted'] == 'true';
      final inactive = row['is_active'] == false || row['is_active'] == 'false';
      return !deleted && !inactive;
    }).toList();

    _attachExtras(fresh);
    catalogue = fresh.map(PosProduct.new).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _reindexBarcodeMap();
    _rebuildCategoryNames();
    catalogueSyncedAt = fromCache ? AppConfig.cachedCatalogueAt : DateTime.now();
    if (fromCache) online = false;
  }

  void _rebuildCategoryNames() {
    final names = <String>{};
    for (final p in catalogue) {
      final c = p.categoryName.trim();
      if (c.isNotEmpty) names.add(c);
    }
    categoryNames = names.toList()..sort();
  }

  /// Puts the price tiers and the (admin-only) cost price onto each catalogue
  /// row, so search and the cart never need a network call per product.
  void _attachExtras(List<Map<String, dynamic>> rows) {
    for (final row in rows) {
      final id = (row['id'] ?? row['product_id'])?.toString() ?? '';
      if (id.isEmpty) continue;
      row['price_tiers'] = _tiersByProduct[id] ?? const <Map<String, dynamic>>[];
      final full = _productRowsById[id];
      if (full != null && full['cost_price'] != null) {
        row['cost_price'] = full['cost_price'];
      }
    }
  }

  /// Writes the catalogue to disk at most every 2 seconds. Realtime can fire
  /// many times in a busy minute; encoding the whole list each time stalls the till.
  void _scheduleCatalogueSave(List<Map<String, dynamic>> rows) {
    _pendingCacheRows = rows;
    _cacheSaveTimer?.cancel();
    _cacheSaveTimer = Timer(const Duration(seconds: 2), () {
      final pending = _pendingCacheRows;
      _pendingCacheRows = null;
      if (pending != null) unawaited(AppConfig.saveCatalogue(pending));
    });
  }

  void applyCostPriceOverride(PosProduct product, Map<String, dynamic> row) {
    final rawId = (row['id'] ?? row['product_id'])?.toString();
    if (rawId == null || rawId.isEmpty || product.id != rawId) return;
    if (row['cost_price'] == null) return;
    product.raw['cost_price'] = row['cost_price'];
  }

  Future<void> hydrateProductCostIfMissing(PosProduct product) async {
    if (product.id.isEmpty || product.costPrice > 0) return;
    try {
      final row = await api.client
          .from('products')
          .select('id, cost_price')
          .eq('id', product.id)
          .maybeSingle();
      if (row == null || row['cost_price'] == null) return;
      product.raw['cost_price'] = row['cost_price'];
      notifyListeners();
    } catch (_) {
      // The cashier-safe mirror is still valid for normal selling; a cost lookup
      // failure should not block the till from working.
    }
  }

  /// Reloads every product (with cost prices) from the server, all pages.
  /// Throttled to once every 2 minutes unless [force] is set.
  Future<void> refreshProductCatalogue({bool silent = false, bool force = false}) async {
    final now = DateTime.now();
    final cacheFreshEnough = _lastProductCatalogueRefreshAt != null &&
        now.difference(_lastProductCatalogueRefreshAt!) < const Duration(minutes: 2);
    if (!force && cacheFreshEnough) return;

    try {
      api.requireSignIn();
      final rows = await api.adminProducts(limit: 0, search: '');
      _setProductRows(rows);
      _lastProductCatalogueRefreshAt = now;
      // the POS list picks up the cost prices straight away
      _refreshCostsOnCatalogue();
      unawaited(AppConfig.saveProductCatalogue(
        rows.where((row) => row['is_deleted'] != true && row['is_active'] != false).toList(),
      ));
      if (!silent) notifyListeners();
    } catch (_) {
      if (!silent) rethrow;
    }
  }

  /// Copies cost prices from the admin product list onto the POS catalogue.
  /// Works from memory, so it costs no network call.
  void _refreshCostsOnCatalogue() {
    if (_productRowsById.isEmpty) return;
    for (final product in catalogue) {
      final full = _productRowsById[product.id];
      if (full != null && full['cost_price'] != null) {
        product.raw['cost_price'] = full['cost_price'];
      }
    }
  }

  /// Makes sure every catalogue product carries its cost price. Costs come from
  /// the admin product list already in memory; the list is only fetched when a
  /// product's cost is missing from it, or when [force] asks for it.
  Future<void> hydrateActualCostsFromProducts({bool force = false}) async {
    if (!signedIn) return;
    final missing = catalogue.any((p) =>
        p.id.isNotEmpty && p.costPrice <= 0 && !_productRowsById.containsKey(p.id));
    if (force || missing) {
      try {
        await refreshProductCatalogue(silent: true, force: true);
      } catch (_) {
        // the till keeps selling on the cost it already has
      }
    }
    _refreshCostsOnCatalogue();
    notifyListeners();
  }

  /// Refreshes the quantity-break prices (one request for all products).
  /// Throttled to once a minute unless [force] is set.
  Future<void> refreshPriceTiers({bool force = false}) async {
    final now = DateTime.now();
    if (!force && _lastTierRefreshAt != null &&
        now.difference(_lastTierRefreshAt!) < const Duration(minutes: 1)) {
      return;
    }
    try {
      api.requireSignIn();
      _tiersByProduct = await api.allPriceTiers();
      _lastTierRefreshAt = now;
    } catch (_) {
      // tiers are optional for display; the server still applies them on charge
    }
  }

  /// Call after anything that changes products, prices, stock or tiers
  /// (sale, stock count, product edit, delete). Every screen then shows the same
  /// figures straight away instead of waiting for the next timer tick.
  Future<void> reloadProducts() async {
    await refreshPriceTiers(force: true);
    await refreshProductCatalogue(silent: true, force: true);
    await refreshCatalogue(silent: true);
    notifyListeners();
  }

  /// Loads the till. Only one start-up runs at a time, even when the sign-in and the
  /// screen both ask for it.
  Future<void>? _bootstrapRun;
  Future<void> bootstrap() => _bootstrapRun ??= _runBootstrap().whenComplete(() => _bootstrapRun = null);

  Future<void> _runBootstrap() async {
    booting = true;
    bootError = null;
    notifyListeners();
    try {
      loadCachedCatalogue(); // keep the till usable even if the line is shaky
      loadCachedProductCatalogue();
      // A till that has been online before can start with no internet: the
      // cashier, store, shift and customers were saved on that visit.
      final hasCache = catalogue.isNotEmpty ||
          productCatalogue.isNotEmpty ||
          AppConfig.loadCache('identity') != null;

      Future<void> safeIdentity() async {
        try {
          final id = await api.identity();
          identity = Identity(id);
          store = StoreSettings((id['store'] as Map?)?.cast<String, dynamic>() ?? {});
          // remembered for starting up with no internet
          unawaited(AppConfig.saveCache('identity', id));
          unawaited(AppConfig.saveCache('store', id['store']));
        } on AppError catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        } catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        }
      }

      Future<void> safeRegisterDevice() async {
        try {
          await api.registerDevice(
            name: AppConfig.deviceName.isEmpty ? 'Counter-1' : AppConfig.deviceName,
            terminalNo: AppConfig.terminalNo,
          );
        } on AppError catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        } catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        }
      }

      Future<void> safeCatalogueRefresh() async {
        try {
          await refreshCatalogue(silent: true);
        } on AppError catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        } catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        }
      }

      Future<void> safeReferenceRefresh() async {
        try {
          await refreshReference();
        } on AppError catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        } catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        }
      }

      Future<void> safeShiftRefresh() async {
        try {
          await currentShift();
        } on AppError catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        } catch (e) {
          if (shouldAllowOfflineBoot(hasCachedCatalogue: hasCache, error: e)) return;
          rethrow;
        }
      }

      await Future.wait([
        safeIdentity(),
        safeRegisterDevice(),
        safeCatalogueRefresh(),
        safeReferenceRefresh(),
        safeShiftRefresh(),
      ]);
      _restoreOfflineCaches(); // fills only what could not be fetched just now
      unawaited(refreshProductCatalogue(silent: true, force: true));
      _listenToStock();
      _startTicker();
      unawaited(hydrateActualCostsFromProducts());
      unawaited(flushOfflineQueue());
    } on AppError catch (e) {
      if (shouldAllowOfflineBoot(hasCachedCatalogue: catalogue.isNotEmpty, error: e)) {
        online = false;
        bootError = null;
      } else {
        bootError = e.message;
      }
    } catch (e) {
      if (shouldAllowOfflineBoot(hasCachedCatalogue: catalogue.isNotEmpty, error: e)) {
        online = false;
        bootError = null;
      } else {
        bootError = e.toString();
      }
    } finally {
      booting = false;
      notifyListeners();
    }
  }

  Future<void> signIn(String email, String password) async {
    await api.signIn(email, password);
    await AppConfig.saveLastUser(email);
    await bootstrap();
  }

  /// Resets everything that belongs to the person who was signed in, so the next
  /// cashier starts clean: no customer, discount, note, cost prices or stale lists.
  Future<void> signOut() async {
    _stopStockChannel();
    _cacheSaveTimer?.cancel();
    _ticker?.cancel();
    await api.signOut();
    _savedSessionKept = false;
    identity = null;
    store = null;
    shift = null;
    catalogue = [];
    productCatalogue = [];
    categoryNames = [];
    byBarcode.clear();
    byId.clear();
    _productRowsById.clear();
    _tiersByProduct = {};
    _lastProductCatalogueRefreshAt = null;
    _lastTierRefreshAt = null;
    categories = [];
    subcategories = [];
    customers = [];
    _serverCustomerRows = [];
    _adminRowsRaw = [];
    liveDiscounts = [];
    devices = [];
    cart.clear();
    cartCustomer = null;
    invDiscountType = 'none';
    invDiscountValue = 0;
    discountCode = null;
    discountLabel = null;
    codeDiscountAmount = 0;
    cartNote = '';
    navIndex = 0;
    await AppConfig.clearCatalogue();
    await AppConfig.clearProductCatalogue();
    notifyListeners();
  }

  /// After the owner empties the store: the till forgets the old products,
  /// categories, discounts, shift and cart, then loads the fresh store from the server.
  Future<void> resetAfterPurge() async {
    cart.clear();
    cartCustomer = null;
    shift = null;
    catalogue = [];
    productCatalogue = [];
    categoryNames = [];
    byBarcode.clear();
    byId.clear();
    _productRowsById.clear();
    _tiersByProduct = {};
    _lastProductCatalogueRefreshAt = null;
    _lastTierRefreshAt = null;
    categories = [];
    subcategories = [];
    liveDiscounts = [];
    await AppConfig.clearCatalogue();
    await AppConfig.clearProductCatalogue();
    await AppConfig.saveCache('reference', null);
    await AppConfig.saveCache('shift', null);
    notifyListeners();
    await bootstrap();
  }

  // ======================================================== sync engine
  /// Realtime keeps every till's stock figure identical. The timer is a
  /// safety net for shops whose router blocks websockets.
  void _listenToStock() {
    _stopStockChannel();
    try {
      // Postgres sends only the changed row, not the whole table. The rows are
      // merged into memory in small batches, so a busy minute costs one redraw.
      _stockChannel = api.client
          .channel('pos-stock-levels')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'stock_levels',
            callback: _onStockRowChanged,
          )
          .subscribe();
    } catch (_) {
      // silent: the periodic reconciliation still keeps the tills in step
    }
  }

  void _stopStockChannel() {
    final channel = _stockChannel;
    _stockChannel = null;
    _applyTimer?.cancel();
    _pendingRows.clear();
    if (channel != null) unawaited(api.client.removeChannel(channel));
  }

  void _onStockRowChanged(PostgresChangePayload payload) {
    if (payload.eventType == PostgresChangeEvent.delete) {
      final id = payload.oldRecord['product_id']?.toString();
      if (id == null || id.isEmpty) return;
      // A removed row simply stops being sellable.
      _pendingRows[id] = {...?_catalogueRaw[id], 'is_active': false, 'is_deleted': true};
    } else {
      final row = payload.newRecord;
      final id = row['product_id']?.toString();
      if (id == null || id.isEmpty) return;
      _pendingRows[id] = row;
    }
    _applyTimer?.cancel();
    _applyTimer = Timer(const Duration(milliseconds: 150), _applyPendingRows);
  }

  /// Merges the batched realtime rows into the catalogue and redraws once.
  void _applyPendingRows() {
    if (_pendingRows.isEmpty) return;
    _catalogueRaw.addAll(_pendingRows);
    _pendingRows.clear();
    final syncedAt = catalogueSyncedAt;
    _useRows(_catalogueRaw.values.toList());
    catalogueSyncedAt = syncedAt; // the last full reload time, not this merge
    online = true;
    _scheduleCatalogueSave(_catalogueRaw.values.toList());
    notifyListeners();
  }

  /// Every 20 seconds: cheap work only (queue counts, offline flush). The full
  /// catalogue is reconciled every 5 minutes, which catches anything a dropped
  /// realtime connection missed.
  void _startTicker() {
    _ticker?.cancel();
    _tickCount = 0;
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) async {
      _tickCount++;
      final before = pendingOffline;
      _updateQueueCounts();
      // keep trying to confirm a saved sign-in while the internet is away
      if (_savedSessionKept && !api.isSignedIn && !_restoring) unawaited(_restoreSession());
      if (AppConfig.queueEntries.isNotEmpty) unawaited(flushOfflineQueue());
      if (_tickCount % 15 == 0) {
        await refreshCatalogue(silent: true);
        await refreshPriceTiers(force: true);
        // product details and cost prices, at most every 10 minutes
        unawaited(refreshProductCatalogue(silent: true, force: _tickCount % 30 == 0));
      }
      // Redraw the whole till only when something visible changed. A tick that
      // changes nothing used to rebuild every screen for no reason.
      if (pendingOffline != before || _tickCount % 15 == 0) notifyListeners();
    });
  }

  Future<void> refreshCatalogue({bool silent = false, bool forceReload = false}) async {
    try {
      api.requireSignIn();
      final rows = await api.catalogue();
      final cameBack = !online;
      await refreshPriceTiers();
      // the full reload becomes the base that realtime rows are merged into
      _catalogueRaw
        ..clear()
        ..addEntries(rows
            .where((row) => row['product_id'] != null)
            .map((row) => MapEntry(row['product_id'].toString(), row)));
      _useRows(_catalogueRaw.values.toList());
      online = true;
      // the link just came back: send everything that was queued while it was down
      if (cameBack && AppConfig.queueEntries.isNotEmpty) unawaited(flushOfflineQueue());
      if (forceReload || rows.isNotEmpty) {
        _scheduleCatalogueSave(rows);
      }
      if (!silent) notifyListeners();
    } on AppError catch (e) {
      online = !e.isOffline;
      if (!silent) rethrow;
    }
  }

  Future<void> refreshReference() async {
    try {
      api.requireSignIn();
      final futures = await Future.wait([
        api.categories(),
        api.customers(),
        api.discounts(),
        api.devices(),
      ]);

      final categoryRows = (futures[0] as List)
          .cast<Map<String, dynamic>>()
          .map((row) {
            final normalized = <String, dynamic>{...row};
            final rawParent = row['parent_id'];
            if (rawParent == null) {
              normalized['parent_id'] = null;
            } else {
              final parentText = rawParent.toString().trim();
              normalized['parent_id'] = parentText.isEmpty ? null : parentText;
            }
            return normalized;
          })
          .toList();

      final customerRows = (futures[1] as List).cast<Map<String, dynamic>>();
      categories = categoryRows
          .where((row) => row['parent_id'] == null)
          .toList();
      subcategories = categoryRows
          .where((row) => row['parent_id'] != null)
          .toList();
      _serverCustomerRows = customerRows;
      customers = overlayCustomers(customerRows, ops: AppConfig.opEntries, ids: AppConfig.idMap)
          .map(Customer.new)
          .toList();
      liveDiscounts = (futures[2] as List).cast<Map<String, dynamic>>();
      devices = (futures[3] as List).cast<Map<String, dynamic>>();
      online = true;
      // remembered for starting up with no internet
      unawaited(AppConfig.saveCache('reference', {
        'categories': categoryRows,
        'customers': customerRows,
        'discounts': liveDiscounts,
        'devices': devices,
      }));
      notifyListeners();
    } on AppError catch (e) {
      online = !e.isOffline;
    }
  }

  Future<Shift?> currentShift() async {
    final s = await api.currentShift();
    shift = s == null ? null : Shift(s);
    unawaited(AppConfig.saveCache('shift', s));
    notifyListeners();
    return shift;
  }

  int get catalogLimitForSync => (catalogue.isNotEmpty ? catalogue.length : 250).clamp(250, 1500);

  // ================================================================ cart
  PosProduct? findByBarcode(String code) {
    final raw = normalizeBarcodeInput(code);
    if (raw.isEmpty) return null;

    final direct = byBarcode[raw] ?? byBarcode[raw.replaceFirst(_leadingZeros, '')];
    if (direct != null) return direct;

    for (final p in catalogue) {
      if (matchesBarcode(raw, p.barcode)) return p;
    }
    for (final p in productCatalogue) {
      if (matchesBarcode(raw, p.barcode)) return p;
    }
    return null;
  }

  Future<void> hydratePriceTiers(PosProduct product) async {
    if (product.id.isEmpty || product.raw.containsKey('price_tiers')) return;
    try {
      final tiers = await api.priceTiers(product.id);
      product.raw['price_tiers'] = tiers;
      notifyListeners();
    } catch (_) {
      // The tier fetch is optional for live cart display; the server still enforces
      // the quantity rule when the sale is charged.
    }
  }

  List<PosProduct> search(String q, {int limit = 0}) {
    final list = filterPosProducts(catalogue, query: q);
    return limit > 0 ? list.take(limit).toList() : list;
  }

  /// Searches the live POS catalogue (the same list the sale uses), so a product
  /// that was just sold or re-stocked shows its current figures in search.
  List<PosProduct> searchProductCache(String q, {int limit = 0}) {
    final list = filterPosProducts(catalogue.isNotEmpty ? catalogue : productCatalogue, query: q);
    return limit > 0 ? list.take(limit).toList() : list;
  }

  /// Searches the whole loaded catalogue, instantly, from memory. Only when the
  /// search matches nothing here does it ask the server, in case a product was
  /// added on another till since the last sync.
  Future<List<PosProduct>> searchFull(String q, {int limit = 0}) async {
    final term = q.trim();
    final local = searchProductCache(term, limit: limit);
    if (local.isNotEmpty || term.isEmpty) return local;
    if (catalogue.isEmpty && productCatalogue.isEmpty) return local;

    try {
      final rows = await api.adminProducts(search: term, limit: 0);
      _attachExtras(rows);
      final remote = filterPosProducts(rows.map(PosProduct.new).toList(), query: term);
      return limit > 0 ? remote.take(limit).toList() : remote;
    } catch (_) {
      return local;
    }
  }

  CartLine? addToCart(PosProduct p, {double qty = 1}) {
    final pid = p.id.trim();
    final isMisc = p.raw['is_misc_item'] == true;
    if (!isMisc && pid.isEmpty) {
      throw AppError('INVALID_PRODUCT', 'One cart item is missing a valid product reference.');
    }

    // Cost and tiers come from the loaded catalogue; only fetch a cost one-off
    // when no product list has loaded at all.
    if (!isMisc && p.costPrice <= 0 && productCatalogue.isEmpty) {
      unawaited(hydrateProductCostIfMissing(p));
    }

    final existing = cart.indexWhere((l) =>
        l.product.id == p.id &&
        l.product.name == p.name &&
        l.product.unit == p.unit &&
        l.lineDiscount == 0);
    if (existing >= 0) {
      cart[existing].qty += qty;
      notifyListeners();
      return cart[existing];
    }
    final line = CartLine(product: p, qty: qty);
    cart.add(line);
    notifyListeners();
    return line;
  }

  void setQty(CartLine line, double qty) {
    if (qty <= 0) {
      cart.remove(line);
    } else {
      line.qty = qty;
    }
    notifyListeners();
  }

  /// Any price the cashier types is allowed, except a negative one (or junk).
  void setPrice(CartLine line, double price) {
    if (!(price >= 0)) {
      throw AppError('NEGATIVE_PRICE', 'A price cannot be negative.');
    }
    line.unitPrice = price;
    notifyListeners();
  }

  void setLineDiscount(CartLine line, double amount) {
    line.lineDiscount = amount.clamp(0, line.gross);
    notifyListeners();
  }

  void removeLine(CartLine line) {
    cart.remove(line);
    notifyListeners();
  }

  void setNavIndex(int index) {
    navIndex = index;
    notifyListeners();
  }

  /// Light, dark or follow Windows. Saved on this PC and applied at once.
  ThemeMode get themeMode => AppConfig.themeMode;

  Future<void> setThemeMode(ThemeMode mode) async {
    await AppConfig.saveThemeMode(mode);
    notifyListeners();
  }

  /// Replaces the store settings after a save and tells every screen.
  void replaceStore(StoreSettings value) {
    store = value;
    notifyListeners();
  }

  void clearCart() {
    cart.clear();
    cartCustomer = null;
    invDiscountType = 'none';
    invDiscountValue = 0;
    discountCode = null;
    discountLabel = null;
    codeDiscountAmount = 0;
    cartNote = '';
    notifyListeners();
  }

  void setCustomer(Customer? c) {
    cartCustomer = c;
    notifyListeners();
  }

  void setInvoiceDiscount(String type, double value, {String? code, String? label, double amount = 0}) {
    invDiscountType = type;
    invDiscountValue = value;
    discountCode = code;
    discountLabel = label;
    codeDiscountAmount = amount;
    notifyListeners();
  }

  // ---- the same arithmetic the server does, so the screen never lies ----
  double get subtotal => round2(cart.fold(0.0, (a, l) => a + l.net));
  double get cartProfit => cart.fold(0.0, (a, l) {
    if (l.product.raw['is_misc_item'] == true || l.product.id.trim().isEmpty) return a;
    return a + (l.net - (l.product.costPrice * l.qty));
  });
  double get lineDiscountTotal => cart.fold(0.0, (a, l) => a + l.lineDiscount);
  /// Tax is worked out line by line and rounded per line, as the server does.
  double get taxTotal => round2(cart.fold(0.0, (a, l) {
        final pct = l.product.taxPercent ?? store?.taxPercent;
        return a + l.taxFor(pct, inclusive: store?.taxInclusive ?? false);
      }));

  double get invoiceDiscountAmount {
    final sub = subtotal;
    final raw = switch (invDiscountType) {
      'percent' => round2(sub * invDiscountValue / 100),
      'amount' => invDiscountValue,
      'code' => codeDiscountAmount,
      _ => 0.0,
    };
    return round2(raw.clamp(0, sub).toDouble());
  }

  double get total {
    final afterDiscount = subtotal - invoiceDiscountAmount;
    final withTax = afterDiscount + (store?.taxInclusive ?? false ? 0 : taxTotal);
    return round2(withTax.clamp(0, double.infinity).toDouble());
  }

  double get totalDiscount => lineDiscountTotal + invoiceDiscountAmount;

  /// Measured against the gross bill — the same rule the server enforces when
  /// it checks a cashier's discount limit.
  double get effectiveDiscountPercent {
    final gross = subtotal + lineDiscountTotal;
    return gross <= 0 ? 0 : (totalDiscount / gross * 100);
  }

  // ============================================================== charge
  /// Returns the saved sale. With no internet the sale is kept on this PC and a receipt
  /// with a provisional invoice number (raw['offline'] == true) is returned instead.
  Future<SaleResult> charge({
    required String method,
    required double paid,
    String? paymentRef,
    String? managerPin,
    String? voucherCode,
  }) async {
    // A second press while the first sale is still going must not start another sale.
    if (_charging) throw AppError('BUSY', 'This sale is already being saved. Please wait.');
    if (cart.isEmpty) throw AppError('EMPTY_CART', 'The cart is empty.');

    final payload = <String, dynamic>{
      'client_uuid': const Uuid().v4(),
      'manager_pin': _cleanOptionalText(managerPin),
      'device_name': _cleanOptionalText(AppConfig.deviceName),
      'payment_method': method,
      'payment_ref': _cleanOptionalText(paymentRef),
      'paid_amount': paid,
      'customer_id': cartCustomer?.id,
      'customer_name': cartCustomer?.name,
      'note': _cleanOptionalText(cartNote),
      'invoice_discount_type': invDiscountType,
      'invoice_discount_value': invDiscountValue,
      'discount_code': _cleanOptionalText(discountCode),
      'voucher_code': _cleanOptionalText(voucherCode),
      'items': cart.map((l) => l.toPayload()).toList(),
      // the drawer this sale belongs to, so it still lands there if sent later
      'shift_id': shift?.id,
    };

    final soldIds = cart.map((l) => l.product.id).where((id) => id.isNotEmpty).toSet().toList();
    // Worked out now, while the cart still holds the sale, for the receipt if the server is unreachable.
    final receipt = _receiptFor(method: method, paid: paid);
    _charging = true;
    notifyListeners();
    try {
      final res = await api.createSale(payload);
      online = true;
      _updateQueueCounts();
      // The sale is saved. Refresh the shelves in the background: a failure there
      // must never be reported as a failed sale (the cashier would ring it again).
      unawaited(_refreshAfterSale(soldIds));
      if (AppConfig.queueEntries.isNotEmpty) unawaited(flushOfflineQueue());
      notifyListeners();
      return res;
    } catch (e) {
      if (!_isOfflineError(e)) rethrow;
      // Keep the sale with who rang it, in which shift and for how much. It is
      // sent when the link is back and that cashier is signed in.
      final queued = Map<String, dynamic>.from(payload)
        ..remove('manager_pin')
        ..['offline_created'] = true;
      final invoiceNo = await AppConfig.nextOfflineInvoiceNo();
      final saved = {
        ...receipt,
        'id': 'queued:${queued['client_uuid']}',
        'invoice_no': invoiceNo,
        'offline': true,
      };
      await AppConfig.enqueue({
        'sale': queued,
        'receipt': saved,
        'queued_at': DateTime.now().toIso8601String(),
        'queued_by': _cashierId,
        'queued_by_name': identity?.fullName ?? '',
        'total': receipt['total'],
        'paid': paid,
        'attempts': 0,
      });
      _updateQueueCounts();
      online = false;
      _relayOfflineChanges();
      return SaleResult(saved);
    } finally {
      _charging = false;
      notifyListeners();
    }
  }

  Future<void> _refreshAfterSale([List<String> soldProductIds = const []]) async {
    try {
      // Only the products that moved; realtime covers the rest of the till.
      final fresh = await api.stockRowsFor(soldProductIds);
      for (final row in fresh) {
        final id = row['product_id']?.toString();
        if (id != null) _pendingRows[id] = row;
      }
      _applyPendingRows();
      await refreshReference();
    } catch (_) {
      // the next timer tick brings the figures up to date
    }
  }

  // ================================================================ offline sales
  /// Sales waiting to be sent, oldest first (for the sync screen and invoices).
  List<Map<String, dynamic>> get queuedSales => AppConfig.queueEntries;

  /// Sales the server refused, with the reason. Kept until retried or discarded.
  List<Map<String, dynamic>> get refusedSales => AppConfig.rejectedEntries;

  int get rejectedOfflineCount => AppConfig.rejectedEntries.length;

  void _updateQueueCounts() => pendingOffline = AppConfig.queueEntries.length +
      AppConfig.opEntries.where((o) => o['refused'] != true).length;

  /// The cashier this PC is selling for. Known even with no internet, from the
  /// copy saved on the last online start.
  String get _cashierId {
    if ((identity?.id ?? '').isNotEmpty) return identity!.id;
    final cached = AppConfig.loadCache('identity');
    return cached is Map ? (cached['id'] ?? '').toString() : '';
  }

  /// Starts the till from the copies saved on the last online visit, so it can ring
  /// sales with no internet: who is signed in, the store, the open shift, customers
  /// and categories. Only fills what is missing; live data always wins.
  void _restoreOfflineCaches() {
    Map<String, dynamic>? asMap(Object? v) => v is Map ? v.cast<String, dynamic>() : null;
    List<Map<String, dynamic>> asRows(Object? v) => v is List
        ? v.cast<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : <Map<String, dynamic>>[];

    if (identity == null) {
      final id = asMap(AppConfig.loadCache('identity'));
      if (id != null) identity = Identity(id);
    }
    if (store == null) {
      final st = asMap(AppConfig.loadCache('store'));
      if (st != null) store = StoreSettings(st);
    }
    if (shift == null) {
      final sh = asMap(AppConfig.loadCache('shift'));
      if (sh != null) shift = Shift(sh);
    }
    final ref = asMap(AppConfig.loadCache('reference'));
    if (ref != null) {
      if (categories.isEmpty && subcategories.isEmpty) {
        final rows = asRows(ref['categories']);
        categories = rows.where((r) => r['parent_id'] == null).toList();
        subcategories = rows.where((r) => r['parent_id'] != null).toList();
      }
      if (customers.isEmpty) {
        _serverCustomerRows = asRows(ref['customers']);
        customers = overlayCustomers(_serverCustomerRows, ops: AppConfig.opEntries, ids: AppConfig.idMap)
            .map(Customer.new)
            .toList();
      }
      if (liveDiscounts.isEmpty) liveDiscounts = asRows(ref['discounts']);
      if (devices.isEmpty) devices = asRows(ref['devices']);
    }
    _updateQueueCounts();
    notifyListeners();
  }

  /// Errors that mean "not now": the sale itself is fine, so keep it and wait.
  static bool _retryLater(AppError e) {
    if (e.isOffline) return true;
    if (const {'BAD_LOGIN', 'BAD_KEY', 'BAD_SERVER_URL'}.contains(e.code)) return true;
    final t = e.message.toLowerCase();
    return t.contains('jwt') ||
        t.contains('refresh token') ||
        t.contains('not authenticated') ||
        t.contains('session');
  }

  static const _maxAttempts = 5;

  /// Sends every queued sale to the server, oldest first.
  ///  - A sale leaves the queue only once the server has it. Sending a sale the
  ///    server already has is harmless: it answers with the same sale (duplicate).
  ///  - No internet or an expired session: stop and keep everything, in order.
  ///  - The server refuses the sale on its rules: it moves to the refused list with
  ///    the reason, and nothing is deleted.
  ///  - A sale rung up by another cashier waits until that cashier signs in.
  /// Sales queued while this runs are kept, because each removal reads the queue fresh.
  Future<int> flushOfflineQueue({bool manual = false}) async {
    if (_flushing || !signedIn) return 0;
    final me = _cashierId;
    if (me.isEmpty) return 0;

    _flushing = true;
    var sent = 0;
    var refused = 0;
    var waiting = 0;
    String? trouble;
    try {
      // Customers and products first: a sale can refer to one of them by its new id.
      for (final op in AppConfig.opEntries) {
        if (op['refused'] == true) continue;
        final owner = (op['queued_by'] ?? '').toString();
        if (owner.isNotEmpty && owner != me) {
          waiting++;
          continue;
        }
        final opId = op['id'].toString();
        final ids = AppConfig.idMap;
        final p = (op['p'] as Map).cast<String, dynamic>();
        final missing = unresolvedLocalIds([p['id'], p['product_id']], ids);
        if (missing.isNotEmpty) {
          if (_waitingForSave(missing)) {
            waiting++;
            continue;
          }
          await AppConfig.updateOp(opId, {
            'refused': true,
            'refused_reason': 'The customer or product this change refers to was never saved on the server.',
          });
          refused++;
          continue;
        }
        try {
          final res = await _sendOp(op, ids);
          final tempId = op['temp_id']?.toString();
          if (tempId != null && res['id'] != null) {
            await AppConfig.rememberId(tempId, res['id'].toString());
          }
          await AppConfig.removeOp(opId);
          sent++;
          online = true;
        } on AppError catch (e) {
          if (_retryLater(e)) {
            trouble = e.isOffline ? 'offline' : 'session';
            online = !e.isOffline;
            break;
          }
          // the server refused the change on its rules: keep it with the reason
          await AppConfig.updateOp(opId, {'refused': true, 'refused_reason': e.message});
          refused++;
        } catch (e) {
          trouble = 'error';
          break;
        }
      }

      for (final entry in AppConfig.queueEntries) {
        final uuid = AppConfig.saleUuid(entry);
        final owner = (entry['queued_by'] ?? '').toString();
        if (owner.isNotEmpty && owner != me) {
          waiting++;
          continue;
        }
        final ids = AppConfig.idMap;
        final sale = remapSale(Map<String, dynamic>.from(entry['sale'] as Map), ids);
        final missing = unresolvedLocalIds(saleReferences(sale), ids);
        if (missing.isNotEmpty) {
          if (_waitingForSave(missing)) {
            waiting++;
            continue;
          }
          await AppConfig.moveToRejected(
            entry,
            'A customer or product in this sale was never saved on the server.',
          );
          await AppConfig.removeQueued(uuid);
          refused++;
          continue;
        }
        try {
          await api.createSale(sale);
          sent++;
          online = true;
          await AppConfig.removeQueued(uuid);
        } on AppError catch (e) {
          if (_retryLater(e)) {
            trouble = e.isOffline ? 'offline' : 'session';
            online = !e.isOffline;
            break;
          }
          final attempts = ((entry['attempts'] as num?)?.toInt() ?? 0) + 1;
          if (e.code == 'ERROR' && attempts < _maxAttempts) {
            // an unexpected server failure: keep it queued and try again later
            await AppConfig.updateQueued(uuid, {'attempts': attempts, 'last_error': e.message});
            continue;
          }
          // refused on the rules, or failing again and again: keep it with the reason
          await AppConfig.moveToRejected({...entry, 'attempts': attempts}, e.message);
          await AppConfig.removeQueued(uuid);
          refused++;
        } catch (e) {
          trouble = 'error';
          break;
        }
      }
    } finally {
      _flushing = false;
    }
    _updateQueueCounts();
    _relayOfflineChanges();
    syncNotice = _syncMessage(
      sent: sent,
      refused: refused,
      waiting: waiting,
      trouble: trouble,
      left: pendingOffline,
    );
    if (sent > 0) {
      // the server now has the new customers, products and sales: fetch them again
      unawaited(refreshCatalogue(silent: true));
      unawaited(refreshProductCatalogue(silent: true, force: true));
      unawaited(refreshReference());
    }
    notifyListeners();
    return sent;
  }

  /// True while a change still waiting to be sent is the one that creates [missing] ids.
  bool _waitingForSave(List<String> missing) => AppConfig.opEntries.any(
        (o) => o['refused'] != true && missing.contains(o['temp_id']),
      );

  /// Sends one queued customer or product change, with its local ids swapped for the server's.
  Future<Map<String, dynamic>> _sendOp(Map<String, dynamic> op, Map<String, String> ids) async {
    final p = Map<String, dynamic>.from(op['p'] as Map);
    String real(Object? v) => ids[v.toString()] ?? v.toString();
    switch (op['op']) {
      case 'save_customer':
        if (p['id'] != null) p['id'] = real(p['id']);
        return api.saveCustomer(p);
      case 'save_product':
        if (p['id'] != null) p['id'] = real(p['id']);
        return api.saveProduct(p);
      case 'delete_product':
        await api.deleteProduct(real(p['id']));
        return {};
      case 'adjust_stock':
        await api.adjustStock(real(p['id']), toD(p['new_qty']), (p['reason'] ?? '').toString());
        return {};
    }
    throw AppError('ERROR', 'Unknown offline change: ${op['op']}');
  }

  /// Sends a refused customer or product change again (e.g. after fixing the duplicate).
  Future<void> retryRefusedChange(String id) async {
    await AppConfig.updateOp(id, {'refused': false, 'refused_reason': null});
    _updateQueueCounts();
    notifyListeners();
    unawaited(flushOfflineQueue(manual: true));
  }

  /// Drops a refused customer or product change for good. Only call after the user confirms.
  Future<void> discardRefusedChange(String id) async {
    await AppConfig.removeOp(id);
    _relayOfflineChanges();
  }

  // ============================================================ offline work
  bool _isOfflineError(Object e) => (e is AppError ? e : AppError.parse(e)).isOffline;

  List<Map<String, dynamic>> _queuedSalePayloads() =>
      [for (final e in AppConfig.queueEntries) e['sale'] as Map<String, dynamic>];

  /// Lays the offline changes over the shop data this till holds, and redraws.
  void _relayOfflineChanges() {
    _setProductRows(_adminRowsRaw);
    _useRows(_catalogueRaw.values.toList());
    customers = overlayCustomers(_serverCustomerRows, ops: AppConfig.opEntries, ids: AppConfig.idMap)
        .map(Customer.new)
        .toList();
    _updateQueueCounts();
    notifyListeners();
  }

  /// The receipt of the cart as it stands, worked out with the same arithmetic the
  /// server uses, for a sale that has to wait until the internet is back.
  Map<String, dynamic> _receiptFor({required String method, required double paid}) {
    final sale = total;
    final change = method == 'cash' && paid > sale ? round2(paid - sale) : 0.0;
    return {
      'created_at': DateTime.now().toIso8601String(),
      'device_name': AppConfig.deviceName,
      'cashier_name': identity?.fullName ?? '',
      'customer_id': cartCustomer?.id,
      'customer_name': cartCustomer?.name ?? '',
      'payment_method': method,
      'subtotal': subtotal,
      'line_discount_total': lineDiscountTotal,
      'invoice_discount_amount': invoiceDiscountAmount,
      'tax_amount': taxTotal,
      'total': sale,
      'paid_amount': paid,
      'change_amount': change,
      'item_count': cart.length,
      'status': 'queued',
      'lines': [for (final l in cart) _receiptLine(l)],
    };
  }

  Map<String, dynamic> _receiptLine(CartLine l) {
    final pct = l.product.taxPercent ?? store?.taxPercent;
    final inclusive = store?.taxInclusive ?? false;
    final tax = l.taxFor(pct, inclusive: inclusive);
    return {
      if (l.product.id.isNotEmpty) 'product_id': l.product.id,
      'name_snapshot': l.product.name,
      'barcode_snapshot': l.product.barcode,
      'unit': l.product.unit,
      'qty': l.qty,
      'unit_price': l.effectiveUnitPrice,
      'line_discount': l.lineDiscount,
      'tax_amount': tax,
      'line_total': inclusive ? l.net : round2(l.net + tax),
    };
  }

  static int _newestFirst(Map<String, dynamic> a, Map<String, dynamic> b) =>
      (parseDate(b['created_at']) ?? DateTime(1900)).compareTo(parseDate(a['created_at']) ?? DateTime(1900));

  static bool _inRange(Map<String, dynamic> row, DateTime? from, String? customerId) {
    if (from != null) {
      final at = parseDate(row['created_at']);
      if (at == null || at.isBefore(from)) return false;
    }
    return customerId == null || row['customer_id']?.toString() == customerId;
  }

  /// The invoice-list row of a sale still waiting to be sent: its receipt, under a 'queued:' id.
  Map<String, dynamic> _queuedRow(Map<String, dynamic> entry) {
    final uuid = AppConfig.saleUuid(entry);
    final receipt = entry['receipt'];
    if (receipt is Map) return {...receipt.cast<String, dynamic>(), 'id': 'queued:$uuid'};
    // a sale queued by an older version has no saved receipt
    final sale = (entry['sale'] as Map).cast<String, dynamic>();
    return {
      'id': 'queued:$uuid',
      'invoice_no': 'WAITING',
      'created_at': entry['queued_at'],
      'status': 'queued',
      'total': entry['total'],
      'paid_amount': entry['paid'],
      'payment_method': sale['payment_method'],
      'customer_id': sale['customer_id'],
      'customer_name': sale['customer_name'] ?? '',
      'cashier_name': entry['queued_by_name'] ?? '',
      'device_name': AppConfig.deviceName,
      'item_count': (sale['items'] as List?)?.length ?? 0,
      'lines': <Map<String, dynamic>>[],
    };
  }

  /// Invoices for the invoice list and a customer's history: the server's when it can
  /// be reached (kept on this PC for later), the saved copy when it cannot. Sales still
  /// waiting to be sent are always included.
  Future<List<Map<String, dynamic>>> loadSales({DateTime? from, String? customerId}) async {
    List<Map<String, dynamic>> server;
    try {
      api.requireSignIn();
      server = await api.salesList(from: from, customerId: customerId);
      unawaited(_rememberSales(server));
      unawaited(_prefetchSaleDetails(server));
    } catch (e) {
      if (!_isOfflineError(e)) rethrow;
      server = AppConfig.cachedSales.where((r) => _inRange(r, from, customerId)).toList();
    }
    final queued = <Map<String, dynamic>>[];
    for (final entry in AppConfig.queueEntries) {
      final row = _queuedRow(entry);
      if (_inRange(row, from, customerId)) queued.add(row);
    }
    return [...queued, ...server]..sort(_newestFirst);
  }

  Future<void> _rememberSales(List<Map<String, dynamic>> rows) async {
    final byId = {for (final r in AppConfig.cachedSales) r['id'].toString(): r};
    for (final r in rows) {
      byId[r['id'].toString()] = r;
    }
    await AppConfig.saveSalesCache(byId.values.toList()..sort(_newestFirst));
  }

  /// Saves the lines of the newest invoices that are not on this PC yet, so they can be
  /// opened with no internet. Stops at the first failure.
  Future<void> _prefetchSaleDetails(List<Map<String, dynamic>> rows) async {
    for (final r in rows.take(60)) {
      final id = r['id']?.toString() ?? '';
      if (id.isEmpty || AppConfig.cachedSaleDetail(id) != null) continue;
      try {
        await AppConfig.saveSaleDetail(id, await api.saleDetail(id));
      } catch (_) {
        return;
      }
    }
  }

  /// One invoice with its lines. A sale still waiting to be sent is shown from its receipt.
  Future<Map<String, dynamic>> saleDetail(String id) async {
    if (id.startsWith('queued:')) {
      final uuid = id.substring('queued:'.length);
      final hit = AppConfig.queueEntries.where((e) => AppConfig.saleUuid(e) == uuid).toList();
      if (hit.isEmpty) {
        throw AppError('NOT_FOUND', 'This sale has already reached the server. Reopen the invoice list.');
      }
      return _queuedRow(hit.first);
    }
    try {
      api.requireSignIn();
      final detail = await api.saleDetail(id);
      unawaited(AppConfig.saveSaleDetail(id, detail));
      return detail;
    } catch (e) {
      if (!_isOfflineError(e)) rethrow;
      final saved = AppConfig.cachedSaleDetail(id);
      if (saved != null) return saved;
      throw AppError('OFFLINE',
          'This invoice was not opened while the internet was on, so it cannot be shown now.');
    }
  }

  /// Saves a customer. With no internet it is kept on this PC and sent when the
  /// connection is back, and the till shows it straight away.
  Future<Map<String, dynamic>> persistCustomer(Map<String, dynamic> p) async {
    try {
      return await api.saveCustomer(p);
    } catch (e) {
      if (!_isOfflineError(e)) rethrow;
      final id = await _queueChange('save_customer', p, isNew: p['id'] == null);
      return {'id': id, 'queued': true};
    }
  }

  /// Saves a product. With no internet it is kept on this PC and sent when the
  /// connection is back, and the till shows it straight away.
  Future<Map<String, dynamic>> persistProduct(Map<String, dynamic> p) async {
    try {
      return await api.saveProduct(p);
    } catch (e) {
      if (!_isOfflineError(e)) rethrow;
      final id = await _queueChange('save_product', p, isNew: p['id'] == null);
      return {'id': id, 'queued': true};
    }
  }

  Future<void> persistStockCount(String productId, double counted, String reason) async {
    try {
      await api.adjustStock(productId, counted, reason);
    } catch (e) {
      if (!_isOfflineError(e)) rethrow;
      await _queueChange(
        'adjust_stock',
        {'id': productId, 'new_qty': counted, 'reason': reason},
        isNew: false,
      );
    }
  }

  Future<void> persistProductRemoval(String productId) async {
    try {
      await api.deleteProduct(productId);
    } catch (e) {
      if (!_isOfflineError(e)) rethrow;
      await _queueChange('delete_product', {'id': productId}, isNew: false);
    }
  }

  /// Keeps a change made with no internet and lays it over the shop data. Returns the
  /// id the till shows: a new temporary id for a new customer or product.
  Future<String?> _queueChange(String op, Map<String, dynamic> p, {required bool isNew}) async {
    final tempId = isNew ? '$offlineIdPrefix${const Uuid().v4()}' : null;
    await AppConfig.enqueueOp({
      'id': const Uuid().v4(),
      'op': op,
      'p': p,
      'temp_id': ?tempId,
      'queued_by': _cashierId,
      'queued_by_name': identity?.fullName ?? '',
      'queued_at': DateTime.now().toIso8601String(),
      'attempts': 0,
    });
    _relayOfflineChanges();
    return tempId ?? p['id']?.toString();
  }

  /// Suppliers for the pickers. The list is kept on this PC so it still shows with no internet.
  Future<List<Map<String, dynamic>>> loadSuppliers() async {
    try {
      api.requireSignIn();
      final rows = await api.suppliers();
      unawaited(AppConfig.saveCache('suppliers', rows));
      return rows;
    } catch (e) {
      if (!_isOfflineError(e)) rethrow;
      final saved = AppConfig.loadCache('suppliers');
      return saved is List ? saved.cast<Map>().map((m) => m.cast<String, dynamic>()).toList() : [];
    }
  }

  String _syncMessage({
    required int sent,
    required int refused,
    required int waiting,
    required String? trouble,
    required int left,
  }) {
    final parts = <String>[
      if (sent > 0) '$sent queued sale(s) sent to the server.',
      if (refused > 0) '$refused sale(s) were refused and are in the refused list.',
      if (waiting > 0) '$waiting sale(s) wait for their cashier to sign in.',
      if (trouble == 'offline' && left > 0)
        'Still offline: $left sale(s) will be sent when the connection is back.',
      if (trouble == 'session' && left > 0) 'Sign in again to send $left queued sale(s).',
    ];
    if (parts.isNotEmpty) return parts.join(' ');
    return left == 0 ? 'Nothing waiting to send.' : '$left sale(s) waiting to send.';
  }

  /// Moves a refused sale back to the queue and sends it again (e.g. after the stock
  /// has been corrected).
  Future<void> retryRefused(String clientUuid) async {
    await AppConfig.restoreRejected(clientUuid);
    _updateQueueCounts();
    notifyListeners();
    unawaited(flushOfflineQueue(manual: true));
  }

  /// Drops a refused sale for good. Only call this after the cashier confirms.
  Future<void> discardRefused(String clientUuid) async {
    await AppConfig.discardRejected(clientUuid);
    notifyListeners();
  }

  // ================================================================ shifts
  Future<void> openShift(double floatAmount) async {
    await api.openShift(floatAmount);
    await currentShift();
  }

  Future<Map<String, dynamic>> closeShift(double counted, String? note) async {
    if (shift == null) throw AppError('NO_SHIFT', 'There is no open shift.');
    final res = await api.closeShift(shift!.id, counted, note);
    await currentShift();
    return res;
  }

  @override
  void dispose() {
    _stopStockChannel();
    _authSub?.cancel();
    _ticker?.cancel();
    _cacheSaveTimer?.cancel();
    super.dispose();
  }

  // ======================================================== held / parked bills
  /// Park the current bill so the next customer can be served, then bring it
  /// back with F9. Held bills survive a restart (they are stored on this PC).
  List<Map<String, dynamic>> get heldBills => AppConfig.heldBills;

  Future<void> holdCurrentBill({String? note}) async {
    if (cart.isEmpty) return;
    final bills = List<Map<String, dynamic>>.from(AppConfig.heldBills);
    bills.add({
      'id': const Uuid().v4(),
      'at': DateTime.now().toIso8601String(),
      'note': note == null || note.trim().isEmpty ? null : note,
      'customer_id': cartCustomer?.id,
      'customer_name': cartCustomer?.name,
      'lines': cart.map((l) => {
            'product_id': l.product.id,
            'name': l.product.name,
            'barcode': l.product.barcode,
            'unit': l.product.unit,
            'qty': l.qty,
            'unit_price': l.unitPrice,
            'line_discount': l.lineDiscount,
            'cost_price': l.product.costPrice,
            'is_weighed': l.product.isWeighed,
            'is_misc_item': l.product.raw['is_misc_item'] == true,
          }).toList(),
    });
    await AppConfig.saveHeldBills(bills);
    clearCart();
  }

  Future<int> resumeBill(String id) async {
    final bills = List<Map<String, dynamic>>.from(AppConfig.heldBills);
    final idx = bills.indexWhere((b) => b['id'] == id);
    if (idx < 0) return 0;
    final bill = bills.removeAt(idx);
    await AppConfig.saveHeldBills(bills);
    clearCart();
    for (final raw in (bill['lines'] as List)) {
      final line = (raw as Map).cast<String, dynamic>();
      final productId = (line['product_id'] ?? '').toString().trim();
      final product = productId.isNotEmpty
          ? (byId[productId] ?? _ghostProduct(line))
          : PosProduct({
              'id': '',
              'name': (line['name'] ?? 'Custom item').toString(),
              'barcode': (line['barcode'] ?? '').toString(),
              'unit': (line['unit'] ?? 'pcs').toString(),
              'sale_price': toD(line['unit_price']),
              'cost_price': toD(line['cost_price']),
              'stock_qty': 0,
              'is_active': true,
              'is_misc_item': true,
            });
      cart.add(CartLine(
        product: product,
        qty: toD(line['qty']),
        unitPrice: toD(line['unit_price']),
        lineDiscount: toD(line['line_discount']),
      ));
    }
    final cid = bill['customer_id'];
    if (cid != null) cartCustomer = customers.where((c) => c.id == cid).firstOrNull;
    notifyListeners();
    return cart.length;
  }

  Future<void> dropHeldBill(String id) async {
    final bills = List<Map<String, dynamic>>.from(AppConfig.heldBills)
      ..removeWhere((b) => b['id'] == id);
    await AppConfig.saveHeldBills(bills);
    notifyListeners();
  }

  /// A held line whose product was removed from the catalogue in the meantime.
  PosProduct _ghostProduct(Map<String, dynamic> line) => PosProduct({
        'id': line['product_id'],
        'name': line['name'],
        'barcode': line['barcode'],
        'unit': line['unit'],
        'sale_price': line['unit_price'],
        'stock_qty': 0,
        'is_active': false,
      });

  // ======================================================== scale barcodes
  /// Many shops print their own barcode for loose goods (atta, sugar, meat).
  /// The label looks like a normal EAN-13 but hides the weight (or price):
  ///   `<prefix><code><weight in grams><check digit>`
  /// This splits it using the prefix saved in Settings.
  ScaleScan? parseScaleBarcode(String code) {
    final prefix = store?.scaleBarcodePrefix ?? '';
    final raw = code.trim();
    if (prefix.isEmpty || raw.length < 7 || !raw.startsWith(prefix)) return null;
    final body = raw.substring(prefix.length);
    // keep the last 1 (checksum) or 2 digits out of the value part
    String value;
    String lookup;
    if (body.length >= 7) {
      value = body.substring(0, 5);       // e.g. 01250
      lookup = body.substring(5, body.length - 1);
    } else {
      value = body.substring(0, body.length - 1);
      lookup = '';
    }
    final n = double.tryParse(value);
    if (n == null) return null;

    if ((store?.scaleBarcodeMode ?? 'weight') == 'price') {
      final rupees = n / 100;             // 01250 -> Rs 12.50
      return ScaleScan(code: lookup, mode: 'price', value: rupees,
          weightKg: 0, label: 'Rs ${rupees.toStringAsFixed(2)}');
    }
    final kg = n / 1000;                   // 01250 -> 1.25 kg
    return ScaleScan(code: lookup, mode: 'weight', value: kg,
        weightKg: kg, label: '${kg.toStringAsFixed(3)} kg');
  }

  // ======================================================== loyalty redemption
  final double _pointValue = 0;
  double get loyaltyPointValue => store?.loyaltyPointValue ?? _pointValue;

  Future<Map<String, dynamic>> redeemPoints(int points) async {
    final c = cartCustomer;
    if (c == null) throw AppError('NO_CUSTOMER', 'Attach a customer to the bill first.');
    final res = await api.redeemLoyaltyPoints(c.id, points);
    notifyListeners();
    return res;
  }
}

class ScaleScan {
  ScaleScan({required this.code, required this.mode, required this.value,
      required this.weightKg, required this.label});

  /// The product code hidden inside the label (what to look up in the catalogue)
  final String code;

  /// 'weight' or 'price'
  final String mode;

  /// weight in kg, or rupees if mode == 'price'
  final double value;
  final double weightKg;
  final String label;
}

/// One piece of text in its searchable forms: lowercase, normalised, without
/// vowels (for typo-tolerant matching) and as words.
class _SearchText {
  _SearchText(String raw)
      : lower = raw.toLowerCase(),
        norm = AppState._normalizeSearchText(raw),
        compact = AppState._normalizeSearchText(raw).replaceAll(AppState._vowel, ''),
        tokens = AppState._searchTokens(raw);

  final String lower;
  final String norm;
  final String compact;
  final List<String> tokens;
}

/// The typed query, prepared once per search.
class _SearchQuery {
  _SearchQuery(String raw)
      : norm = AppState._normalizeSearchText(raw),
        compact = AppState._normalizeSearchText(raw).replaceAll(AppState._vowel, ''),
        tokens = AppState._searchTokens(raw);

  final String norm;
  final String compact;
  final List<String> tokens;
}

/// The searchable parts of one product, cached per product object.
class _ProductSearch {
  _ProductSearch(PosProduct p)
      : name = _SearchText(p.name),
        category = _SearchText(p.categoryName),
        barcode = _SearchText(p.barcode),
        sku = _SearchText(p.sku);

  final _SearchText name;
  final _SearchText category;
  final _SearchText barcode;
  final _SearchText sku;
}
