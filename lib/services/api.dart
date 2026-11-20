// Thin wrapper over Supabase. Every write goes through an RPC, so the server
// validates the rules (stock, discount limits, credit limits) for all 4 PCs.
import 'dart:async';
import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_config.dart';
import '../core/format.dart';
import '../models.dart';
import 'secure_session.dart';

class Api {
  Api(this.client);

  final SupabaseClient client;

  /// Starts the Supabase client with this till's saved server and the encrypted
  /// session store. Used by first-run setup and by normal start-up, so the two
  /// can never disagree about where the session is kept.
  static Future<void> initializeClient() => Supabase.initialize(
        url: AppConfig.url,
        publishableKey: AppConfig.anonKey,
        authOptions: FlutterAuthClientOptions(localStorage: SecureSessionStorage()),
      );

  /// Checks the two values really point at a live Supabase project, BEFORE we
  /// save them. Returns null when everything is fine, otherwise a sentence
  /// explaining what is wrong (this is what catches a pasted /rest/v1 URL).
  static Future<String?> checkServer(String rawUrl, String rawKey) async {
    final url = AppConfig.normalizeUrl(rawUrl);
    final key = AppConfig.normalizeKey(rawKey);
    if (url.isEmpty) return 'Paste your Supabase project URL first.';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return '"$url" is not a valid web address.';
    }
    if (!uri.host.contains('.')) return '"$url" is not a valid web address.';
    if (key.length < 30) {
      return 'That does not look like a full key — copy the whole value.';
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(Uri.parse('$url/auth/v1/health'));
      req.headers.set('apikey', key);
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode == 200) return null;
      if (res.statusCode == 401 || res.statusCode == 403) {
        return 'The project is there, but the key is not accepted. Copy the '
            '"anon public" or "publishable" key again (not the service_role one).';
      }
      if (res.statusCode == 404) {
        return 'No Supabase project answers at $url (404). Check the URL letter for letter.';
      }
      return 'The server answered with code ${res.statusCode}. Try again in a minute.';
    } on SocketException catch (e) {
      return 'Could not reach $url — ${e.osError?.message ?? 'no internet connection'}.';
    } catch (e) {
      return 'Could not reach $url — $e';
    } finally {
      client.close(force: true);
    }
  }

  /// A wrong Server URL can otherwise leave a request hanging for minutes,
  /// which looks like a frozen app. Nothing here should ever wait longer.
  static const _timeout = Duration(seconds: 25);

  // ---------------------------------------------------------------- core
  Future<dynamic> call(String fn, [Map<String, dynamic>? params]) async {
    requireSignIn();
    try {
      return await client.rpc(fn, params: params).timeout(_timeout);
    } on PostgrestException catch (e) {
      // Supabase often returns a very short PostgreSQL message. Preserve the
      // RPC name and server diagnostics so a database failure can be fixed at
      // its source instead of appearing as the same generic error everywhere.
      final extra = <String>[
        if ((e.code ?? '').isNotEmpty) 'code=${e.code}',
        if (e.details.toString().isNotEmpty && e.details.toString() != 'null')
          'details=${e.details}',
        if (e.hint.toString().isNotEmpty && e.hint.toString() != 'null')
          'hint=${e.hint}',
      ];
      final detail = extra.isEmpty ? '' : ' [${extra.join('; ')}]';
      throw AppError.parse('RPC $fn failed: ${e.message}$detail');
    } on AuthException catch (e) {
      throw AppError.parse(e.message);
    } catch (e) {
      if (e is AppError) rethrow;
      if (e is SocketException) {
        throw AppError('OFFLINE', 'No connection to the server.');
      }
      if (e is TimeoutException) {
        throw AppError(
          'OFFLINE',
          'The server did not answer in 25 seconds. Check the internet, or the Server URL '
              'in Settings if this keeps happening.',
        );
      }
      throw AppError.parse(e);
    }
  }

  /// PostgREST `or=` value quoting: wrap in double quotes and escape backslash
  /// and double quote inside it.
  static String _orQuoted(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  static Map<String, dynamic> _map(dynamic v) =>
      v == null ? {} : (v as Map).cast<String, dynamic>();

  static List<Map<String, dynamic>> _list(dynamic v) =>
      v == null ? [] : (v as List).cast<Map<String, dynamic>>();

  static Map<String, dynamic> prepareBulkImportRowForPersistence(
    Map<String, dynamic> row,
  ) {
    final normalized = <String, dynamic>{...row};

    final categoryName =
        (normalized['category_name'] ?? normalized['category'] ?? '')
            .toString()
            .trim();
    if (categoryName.isNotEmpty) {
      normalized['category_name'] = categoryName;
    }

    final subcategoryName =
        (normalized['subcategory_name'] ??
                normalized['item_name'] ??
                normalized['item'] ??
                normalized['subcategory'] ??
                '')
            .toString()
            .trim();
    if (subcategoryName.isNotEmpty) {
      normalized['subcategory_name'] = subcategoryName;
    }

    final supplierName =
        (normalized['supplier_name'] ?? normalized['supplier'] ?? '')
            .toString()
            .trim();
    if (supplierName.isNotEmpty) {
      normalized['supplier_name'] = supplierName;
    }

    if (normalized['category_id'] == null &&
        categoryName.isEmpty &&
        normalized['category'] != null) {
      final fallback = normalized['category'].toString().trim();
      if (fallback.isNotEmpty) normalized['category_name'] = fallback;
    }

    if (normalized['supplier_id'] == null &&
        supplierName.isEmpty &&
        normalized['supplier'] != null) {
      final fallback = normalized['supplier'].toString().trim();
      if (fallback.isNotEmpty) normalized['supplier_name'] = fallback;
    }

    return normalized;
  }

  // ---------------------------------------------------------------- auth
  Future<void> signIn(String email, String password) async {
    try {
      await client.auth
          .signInWithPassword(email: email.trim(), password: password)
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw AppError(
        'BAD_SERVER_URL',
        'Signing in timed out. That usually means the Server URL is wrong - it must be '
            'only https://your-project.supabase.co with nothing after it. Fix it with '
            '"Change server settings for this PC".',
      );
    } catch (e) {
      throw AppError.parse(e);
    }
  }

  Future<void> signOut() async {
    try {
      await client.auth.signOut();
    } catch (_) {
      // signing out locally is enough
    }
  }

  bool get isSignedIn => client.auth.currentSession != null;

  /// Fires when the saved sign-in has been restored, and on every later sign-in or sign-out.
  Stream<AuthState> get authChanges => client.auth.onAuthStateChange;

  /// True when a sign-in is saved on this PC (even if its token has expired).
  Future<bool> hasSavedSession() async {
    try {
      return await SecureSessionStorage().hasSavedSession();
    } catch (_) {
      return false; // no storage available on this platform: nothing saved
    }
  }

  /// Signs back in with the session saved on this PC. An expired token is refreshed
  /// when the internet is there. With no internet the saved session is kept for later,
  /// and the till keeps working from its saved copy. Returns true when the sign-in is live.
  Future<bool> restoreSavedSession() async {
    try {
      final saved = await SecureSessionStorage().savedSession();
      if (saved == null) return false;
      await client.auth.recoverSession(saved);
      return client.auth.currentSession != null;
    } catch (_) {
      // no internet, or the sign-in was revoked (then the library has removed it)
      return false;
    }
  }

  /// Nothing may ask the server for data while the sign-in is not confirmed: the server
  /// would answer as an anonymous visitor and return empty lists. Treated as "offline".
  void requireSignIn() {
    if (client.auth.currentSession == null) {
      throw AppError('OFFLINE', 'Waiting for the internet to confirm the sign-in.');
    }
  }

  // ------------------------------------------------------- identity/store
  Future<Map<String, dynamic>> identity() async =>
      _map(await call('my_identity'));

  Future<Map<String, dynamic>> registerDevice({
    required String name,
    required int terminalNo,
    String? version,
  }) async => _map(
    await call('register_device', {
      'p_name': name,
      'p_hostname': name,
      'p_terminal_no': terminalNo,
      'p_app_version': version ?? AppConfig.appVersion,
    }),
  );

  Future<List<Map<String, dynamic>>> devices() async =>
      _list(await call('list_devices'));

  // ------------------------------------------------------------ catalogue
  /// The cost-free catalogue mirror every till is allowed to read.
  /// Pages through the WHOLE catalogue. The server caps one request at 1000 rows,
  /// so a single select silently drops every product past the first 1000.
  /// Fresh stock rows for just these products (used after a sale), so a till
  /// never downloads the whole catalogue to see the few lines it sold.
  Future<List<Map<String, dynamic>>> stockRowsFor(List<String> productIds) async {
    if (productIds.isEmpty) return [];
    try {
      return _list(await client
          .from('stock_levels')
          .select()
          .inFilter('product_id', productIds));
    } catch (e) {
      throw AppError.parse(e);
    }
  }

  Future<List<Map<String, dynamic>>> catalogue() async {
    try {
      const pageSize = 1000;
      final rows = <Map<String, dynamic>>[];
      var offset = 0;
      while (true) {
        final page = _list(
          await client
              .from('stock_levels')
              .select()
              .eq('is_active', true)
              .eq('is_deleted', false)
              .order('product_id')
              .range(offset, offset + pageSize - 1),
        );
        rows.addAll(page);
        offset += page.length;
        if (page.length < pageSize) break;
      }
      return rows;
    } catch (e) {
      throw AppError.parse(e);
    }
  }

  /// Every active quantity-break price in one request, grouped by product.
  Future<Map<String, List<Map<String, dynamic>>>> allPriceTiers() async {
    final rows = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final page = _list(
        await client
            .from('price_tiers')
            .select()
            .order('min_qty')
            .range(offset, offset + 999),
      );
      rows.addAll(page);
      offset += page.length;
      if (page.length < 1000) break;
    }
    final byProduct = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final pid = row['product_id']?.toString();
      if (pid == null || pid.isEmpty) continue;
      (byProduct[pid] ??= []).add(row);
    }
    return byProduct;
  }

  Future<List<Map<String, dynamic>>> adminProducts({
    int offset = 0,
    int limit = 0,
    String? search,
    String? category,
    String? filter,
  }) async {
    final totalLimit = limit > 0 ? limit : null;
    final rows = <Map<String, dynamic>>[];
    var currentOffset = offset;
    final searchTerm = search?.trim();

    while (true) {
      final remaining = totalLimit == null ? null : totalLimit - rows.length;
      if (remaining != null && remaining <= 0) break;

      final pageLimit = remaining == null ? 1000 : remaining.clamp(1, 1000);

      var query = client
          .from('v_products_admin')
          .select()
          .eq('is_active', true)
          .eq('is_deleted', false);

      if (searchTerm != null && searchTerm.isNotEmpty) {
        // Each value is double-quoted, so a comma or bracket typed by a cashier
        // cannot change the shape of the filter.
        final pattern = _orQuoted('%$searchTerm%');
        query = query.or(
          'name.ilike.$pattern,barcode.ilike.$pattern,sku.ilike.$pattern,category_name.ilike.$pattern',
        );
      }

      if (category != null && category.trim().isNotEmpty) {
        query = query.eq('category_name', category);
      }

      final page = _list(
        await query
            .order('name', ascending: true)
            .range(currentOffset, currentOffset + pageLimit - 1),
      );
      if (page.isEmpty) break;

      rows.addAll(page);
      if (page.length < pageLimit) break;
      currentOffset += page.length;
      if (totalLimit != null && rows.length >= totalLimit) break;
    }

    return rows;
  }

  Future<List<Map<String, dynamic>>> lowStock() async =>
      _list(await client.from('v_low_stock').select());

  Future<List<Map<String, dynamic>>> categories() async => _list(
    await client
        .from('categories')
        .select()
        .eq('is_active', true)
        .order('sort_order'),
  );

  Future<List<Map<String, dynamic>>> suppliers() async => _list(
    await client.from('suppliers').select().eq('is_active', true).order('name'),
  );

  Future<List<Map<String, dynamic>>> customers() async => _list(
    await client.from('customers').select().eq('is_active', true).order('name'),
  );

  Future<List<Map<String, dynamic>>> discounts({bool all = false}) async {
    var q = client.from('discounts').select();
    if (!all) q = q.eq('is_active', true);
    return _list(await q.order('name'));
  }

  Future<List<Map<String, dynamic>>> employees() async =>
      _list(await client.from('profiles').select().order('full_name'));

  Future<List<Map<String, dynamic>>> movements({int limit = 300}) async =>
      _list(await client.from('v_stock_movements').select().limit(limit));

  // ---------------------------------------------------------------- sales
  /// Sells through `pos_sale`, the PIN-aware wrapper: if the payload carries a
  /// `manager_pin` the sale is re-run as that manager for the moment it needs
  /// (discount above the cashier's limit), and the approval is audited.
  Future<SaleResult> createSale(Map<String, dynamic> payload) async {
    // A normal sale does not need the PIN-elevation wrapper. Calling the core
    // RPC directly avoids an extra server-side function layer; pos_sale is
    // retained only for manager-approved sales.
    final hasManagerPin =
        (payload['manager_pin'] as String?)?.trim().isNotEmpty ?? false;
    final fn = hasManagerPin ? 'pos_sale' : 'create_sale';
    final sale = SaleResult(_map(await call(fn, {'p': payload})));
    if ((sale.customer).isEmpty && (payload['customer_name'] ?? '').toString().trim().isNotEmpty) {
      sale.raw['customer_name'] = payload['customer_name'];
    }
    return sale;
  }

  /// Every sale in the range, newest first. limit 0 = no cap: pages through the
  /// whole result so a long date range is never silently cut short.
  Future<List<Map<String, dynamic>>> salesList({
    DateTime? from,
    DateTime? to,
    String? status,
    String? customerId,
    int limit = 0,
  }) async {
    const pageSize = 1000;
    final rows = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      var q = client.from('v_sales_list').select();
      // UTC instants, so the server compares the same moment the PC means
      if (from != null) q = q.gte('created_at', from.toUtc().toIso8601String());
      if (to != null) q = q.lte('created_at', to.toUtc().toIso8601String());
      if (status == 'void') q = q.eq('status', 'void');
      // filter in the database by id, not by name in the app
      if (customerId != null) q = q.eq('customer_id', customerId);
      final want = limit > 0 ? (limit - rows.length).clamp(1, pageSize) : pageSize;
      final page = _list(
        await q
            .order('created_at', ascending: false)
            .range(offset, offset + want - 1),
      );
      rows.addAll(page);
      offset += page.length;
      if (page.length < want) break;
      if (limit > 0 && rows.length >= limit) break;
    }
    return rows;
  }

  Future<Map<String, dynamic>> saleDetail(String saleId) async {
    final sale = _map(
      await client.from('sales').select().eq('id', saleId).single(),
    );
    final items = _list(
      await client.from('sale_items').select().eq('sale_id', saleId),
    );
    sale['lines'] = items;
    return sale;
  }

  /// Cancels a bill. A cashier who is over their limit can hand the decision to
  /// a manager by passing that manager's `managerPin`.
  Future<Map<String, dynamic>> voidSale(
    String saleId,
    String reason, {
    String? managerPin,
  }) async => _map(
    await call('pos_void_sale', {
      'p_sale_id': saleId,
      'p_reason': reason,
      'p_pin': managerPin,
    }),
  );

  /// Refunds (full or single item). Same PIN rule as a sale: `manager_pin` in
  /// the payload, or `managerPin`, is accepted for approval.
  Future<Map<String, dynamic>> createReturn(
    Map<String, dynamic> payload, {
    String? managerPin,
  }) async => _map(
    await call('pos_create_return', {
      'p': payload,
      'p_pin': managerPin ?? payload['manager_pin'],
    }),
  );

  Future<List<Map<String, dynamic>>> returnsList({int limit = 300}) async =>
      _list(await client.from('v_returns_list').select().limit(limit));

  // --------------------------------------------------------------- shifts
  Future<Map<String, dynamic>> openShift(double floatAmount) async {
    final store = await call('open_shift', {'p_opening_float': floatAmount});
    return _map(store);
  }

  Future<Map<String, dynamic>?> currentShift() async {
    final row = _map(await call('current_shift'));
    return row.isEmpty ? null : row;
  }

  Future<Map<String, dynamic>> shiftSummary(String shiftId) async =>
      _map(await call('shift_summary', {'p_shift_id': shiftId}));

  Future<Map<String, dynamic>> closeShift(
    String shiftId,
    double counted,
    String? note,
  ) async => _map(
    await call('close_shift', {
      'p_shift_id': shiftId,
      'p_counted_cash': counted,
      'p_note': note,
    }),
  );

  // ------------------------------------------------------------- products
  Future<Map<String, dynamic>> saveProduct(Map<String, dynamic> p) async =>
      _map(await call('save_product', {'p': p}));

  Future<Map<String, dynamic>> deleteProduct(String id) async =>
      _map(await call('delete_product', {'p_id': id}));

  /// Owner only. Permanently empties the store for a fresh start, keeping the customer
  /// list (balances reset). See supabase/10_delete_all_products.sql for what goes.
  Future<Map<String, dynamic>> deleteAllProducts({String? device}) async =>
      _map(await call('delete_all_products', {'p_device': device}));

  /// Checks the signed-in user's password by signing in again with it. Throws
  /// BAD_LOGIN for a wrong password. The new session replaces the old one.
  Future<void> confirmPassword(String password) async {
    final email = client.auth.currentUser?.email;
    if (email == null || email.isEmpty) {
      throw AppError('BAD_LOGIN', 'Sign in again before deleting products.');
    }
    await signIn(email, password);
  }

  Future<Map<String, dynamic>> adjustStock(
    String productId,
    double newQty,
    String reason,
  ) async => _map(
    await call('adjust_stock', {
      'p_product_id': productId,
      'p_new_qty': newQty,
      'p_reason': reason,
    }),
  );

  Future<Map<String, dynamic>> saveCategory(Map<String, dynamic> c) async =>
      _map(await call('save_category', {'p': c}));

  Future<Map<String, dynamic>> deleteCategory(String id) async =>
      _map(await call('delete_category', {'p_id': id}));

  Future<Map<String, dynamic>> saveSupplier(Map<String, dynamic> s) async =>
      _map(await call('save_supplier', {'p': s}));

  Future<Map<String, dynamic>> saveCustomer(Map<String, dynamic> c) async =>
      _map(await call('save_customer', {'p': c}));

  Future<Map<String, dynamic>> collectCustomerPayment(
    String customerId,
    double amount,
    String method,
  ) async => _map(
    await call('receive_customer_payment', {
      'p_customer_id': customerId,
      'p_amount': amount,
      'p_method': method,
    }),
  );

  Future<Map<String, dynamic>> bulkImport(
    List<Map<String, dynamic>> rows,
  ) async {
    final prepared = rows.map(prepareBulkImportRowForPersistence).toList();
    return _map(await call('bulk_import_products', {'p_rows': prepared}));
  }

  // ------------------------------------------------------------ discounts
  Future<Map<String, dynamic>> saveDiscount(Map<String, dynamic> d) async =>
      _map(await call('save_discount', {'p': d}));

  Future<Map<String, dynamic>> deleteDiscount(String id) async =>
      _map(await call('delete_discount', {'p_id': id}));

  Future<Map<String, dynamic>> checkDiscountCode(
    String code,
    double subtotal,
  ) async => _map(
    await call('check_discount_code', {'p_code': code, 'p_subtotal': subtotal}),
  );

  // ------------------------------------------------- admin / staff / store
  Future<Map<String, dynamic>> saveEmployee(Map<String, dynamic> e) async =>
      _map(await call('save_employee', {'p': e}));

  Future<Map<String, dynamic>> saveStoreSettings(
    Map<String, dynamic> s,
  ) async => _map(await call('save_store_settings', {'p': s}));

  Future<Map<String, dynamic>> saveExpense(Map<String, dynamic> e) async =>
      _map(await call('save_expense', {'p': e}));

  Future<Map<String, dynamic>> expenses({
    DateTime? from,
    DateTime? to,
    int limit = 5000,
  }) async => _map(
    await call('list_expenses', {
      'p_from': (from ?? DateTime.now().subtract(const Duration(days: 30)))
          .pkDay,
      'p_to': (to ?? DateTime.now()).pkDay,
      'p_limit': limit,
    }),
  );

  Future<void> deleteExpense(String id) async =>
      call('delete_expense', {'p_id': id});

  Future<Map<String, dynamic>> receivePurchase(Map<String, dynamic> p) async =>
      _map(await call('receive_purchase', {'p': p}));

  Future<List<Map<String, dynamic>>> purchases({int limit = 2000}) async =>
      _list(await call('purchases', {'p_limit': limit}));

  Future<Map<String, dynamic>> resetDemoData(String confirm) async =>
      _map(await call('reset_demo_data', {'p_confirm': confirm}));

  // --------------------------------------------------------------- reports
  Future<Dashboard> dashboard({int days = 7}) async =>
      Dashboard(_map(await call('dashboard_stats', {'p_days': days})));

  Future<SalesReport> salesReport(DateTime from, DateTime to) async =>
      SalesReport(
        _map(
          await call('sales_report', {
            'p_from': from.pkDay,
            'p_to': to.pkDay,
          }),
        ),
      );

  // ------------------------------------------------------- activity log
  Future<List<Map<String, dynamic>>> activity({
    int limit = 300,
    DateTime? from,
    DateTime? to,
    String? actorId,
    String? action,
  }) async => _list(
    (await call('list_activity', {
      'p_limit': limit,
      'p_from': from?.pkDay,
      'p_to': to?.pkDay,
      'p_actor': actorId,
      'p_action': action,
    }))['rows'],
  );

  // ------------------------------------------------------- manager PIN
  Future<bool> pinReady() async => (await call('pin_ready')) == true;

  /// Checks a manager PIN before the action that needs it is sent. The server
  /// counts every wrong try, so five in 15 minutes locks the cashier out.
  /// Returns { ok, locked, attempts_left?, locked_until?, message? }.
  Future<Map<String, dynamic>> verifyManagerPin(String pin, String device) async =>
      _map(await call('verify_manager_pin', {'p': {'pin': pin}, 'p_device': device}));

  Future<Map<String, dynamic>> setManagerPin(
    String pin, {
    String? profileId,
  }) async {
    final payload = <String, dynamic>{'pin': pin};
    if (profileId != null) payload['profile_id'] = profileId;
    return _map(await call('set_manager_pin', {'p': payload}));
  }

  Future<void> clearManagerPin({String? profileId}) async =>
      call('clear_manager_pin', {
        'p': {'profile_id': profileId},
      });

  // ------------------------------------------------------- supplier payables
  Future<Map<String, dynamic>> supplierPayables() async =>
      _map(await call('supplier_payables'));

  Future<Map<String, dynamic>> paySupplier(Map<String, dynamic> p) async =>
      _map(await call('pay_supplier', {'p': p}));

  Future<Map<String, dynamic>> supplierLedger(
    String supplierId, {
    int limit = 200,
  }) async => _map(
    await call('supplier_ledger', {
      'p_supplier_id': supplierId,
      'p_limit': limit,
    }),
  );

  // ------------------------------------------------------- stock take
  Future<Map<String, dynamic>> startStockTake([String? note]) async =>
      _map(await call('start_stock_take', {'p_note': note}));

  Future<Map<String, dynamic>?> currentStockTake() async {
    final res = await call('current_stock_take');
    return res == null ? null : _map(res);
  }

  Future<Map<String, dynamic>> stockTakeCount(Map<String, dynamic> p) async =>
      _map(await call('stock_take_count', {'p': p}));

  Future<Map<String, dynamic>> stockTakeDetail(String takeId) async =>
      _map(await call('stock_take_detail', {'p_take_id': takeId}));

  Future<Map<String, dynamic>> completeStockTake(String takeId) async =>
      _map(await call('complete_stock_take', {'p_take_id': takeId}));

  Future<void> cancelStockTake(String takeId) async =>
      call('cancel_stock_take', {'p_take_id': takeId});

  // ------------------------------------------------------- reorder / drafts
  Future<List<Map<String, dynamic>>> reorderList() async =>
      _list((await call('reorder_list'))['rows']);

  Future<Map<String, dynamic>> createPurchaseOrder(
    Map<String, dynamic> p,
  ) async => _map(await call('create_purchase_order', {'p': p}));

  Future<List<Map<String, dynamic>>> draftPurchases() async =>
      _list((await call('draft_purchases'))['rows']);

  Future<void> deletePurchase(String id) async =>
      call('delete_purchase', {'p_id': id});

  // ------------------------------------------------------- backup
  Future<Map<String, dynamic>> backupBundle({
    DateTime? from,
    DateTime? to,
    int rowLimit = 20000,
  }) async => _map(
    await call('backup_bundle', {
      'p_from': (from ?? DateTime.now().subtract(const Duration(days: 365)))
          .pkDay,
      'p_to': (to ?? DateTime.now()).pkDay,
      'p_row_limit': rowLimit,
    }),
  );

  // ------------------------------------------------------- weighing + loyalty
  Future<Map<String, dynamic>> setProductWeighed(
    String id,
    bool isWeighed,
  ) async => _map(
    await call('set_product_weighed', {
      'p': {'id': id, 'is_weighed': isWeighed},
    }),
  );

  Future<Map<String, dynamic>> saveScaleSettings(
    Map<String, dynamic> p,
  ) async => _map(await call('save_scale_settings', {'p': p}));

  Future<Map<String, dynamic>> loyaltyBalance(String customerId) async =>
      _map(await call('loyalty_balance', {'p_customer_id': customerId}));

  Future<Map<String, dynamic>> redeemLoyaltyPoints(
    String customerId,
    int points,
  ) async => _map(
    await call('redeem_loyalty_points', {
      'p': {'customer_id': customerId, 'points': points},
    }),
  );

  // ============================================================ expiry / batches
  Future<Map<String, dynamic>> listBatches({String? productId}) async => _map(
    await call('list_batches', {
      'p': productId == null ? {} : {'product_id': productId},
    }),
  );

  Future<Map<String, dynamic>> expiringStock({int days = 30}) async => _map(
    await call('expiring_stock', {
      'p': {'days': days},
    }),
  );

  Future<Map<String, dynamic>> writeOffStock(Map<String, dynamic> p) async =>
      _map(await call('write_off_stock', {'p': p}));

  // ============================================================ price tiers
  Future<List<Map<String, dynamic>>> priceTiers(String productId) async =>
      _list(
        await client
            .from('price_tiers')
            .select()
            .eq('product_id', productId)
            .order('min_qty'),
      );

  Future<Map<String, dynamic>> savePriceTier(Map<String, dynamic> t) async =>
      _map(await call('save_price_tier', {'p': t}));

  Future<void> deletePriceTier(String id) async => call('delete_price_tier', {
    'p': {'id': id},
  });

  // ============================================================ offers
  Future<List<Map<String, dynamic>>> offers() async =>
      _list((await call('list_offers'))['rows']);

  Future<Map<String, dynamic>> saveOffer(Map<String, dynamic> p) async =>
      _map(await call('save_offer', {'p': p}));

  Future<void> deleteOffer(String id) async => call('delete_offer', {
    'p': {'id': id},
  });

  // ============================================================ vouchers
  Future<List<Map<String, dynamic>>> vouchers({String? q}) async => _list(
    (await call('list_vouchers', {
      'p': q == null ? {} : {'q': q},
    }))['rows'],
  );

  Future<Map<String, dynamic>> issueVoucher(Map<String, dynamic> p) async =>
      _map(await call('issue_voucher', {'p': p}));

  Future<Map<String, dynamic>> voucherBalance(String code) async => _map(
    await call('voucher_balance', {
      'p': {'code': code},
    }),
  );

  Future<void> cancelVoucher(String id) async => call('cancel_voucher', {
    'p': {'id': id},
  });

  // ============================================================ purchase returns
  Future<Map<String, dynamic>> createPurchaseReturn(
    Map<String, dynamic> p,
  ) async => _map(await call('create_purchase_return', {'p': p}));

  Future<List<Map<String, dynamic>>> purchaseReturns({int limit = 2000}) async =>
      _list(
        (await call('list_purchase_returns', {
          'p': {'limit': limit},
        }))['rows'],
      );

  // ============================================================ reports
  Future<Map<String, dynamic>> profitByProduct({
    required DateTime from,
    required DateTime to,
    int limit = 5000,
    String order = 'profit',
  }) async => _map(
    await call('profit_by_product', {
      'p': {
        'from': from.pkDay,
        'to': to.pkDay,
        'limit': limit,
        'order': order,
      },
    }),
  );

  Future<Map<String, dynamic>> cashierPerformance({
    required DateTime from,
    required DateTime to,
  }) async => _map(
    await call('cashier_performance', {
      'p': {
        'from': from.pkDay,
        'to': to.pkDay,
      },
    }),
  );

  Future<Map<String, dynamic>> deadStock({int days = 60}) async => _map(
    await call('dead_stock', {
      'p': {'days': days},
    }),
  );
}
