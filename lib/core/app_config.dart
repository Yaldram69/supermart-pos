// Local, per-PC settings. Every PC keeps its own Supabase keys, till name
// and printer choice; the shared data lives on the server.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class OfflineQueueReconcileResult {
  const OfflineQueueReconcileResult({
    required this.valid,
    required this.duplicatesRemoved,
    required this.invalidRemoved,
    required this.totalBefore,
    required this.totalAfter,
  });

  final List<Map<String, dynamic>> valid;
  final int duplicatesRemoved;
  final int invalidRemoved;
  final int totalBefore;
  final int totalAfter;
}

class AppConfig {
  /// The version every till reports, shown on the sign-in screen and sent to the server.
  static const appVersion = '1.0.0';

  static const _kUrl = 'sb_url';
  static const _kKey = 'sb_anon_key';
  static const _kDevice = 'device_name';
  static const _kTerminal = 'terminal_no';
  static const _kPaper = 'paper_mm';
  static const _kAutoPrint = 'auto_print';
  static const _kThermalPrinter = 'thermal_printer';
  static const _kRefresh = 'refresh_seconds';
  static const _kQueue = 'offline_queue';
  static const _kLastUser = 'last_user';

  /// Values baked in when the EXE is built (BUILD_EXE.bat passes them as
  /// --dart-define). When they are present the till never asks for anything:
  /// copy the folder to the PC, double-click, sign in, sell.
  static const String buildUrl = String.fromEnvironment('SB_URL');
  static const String buildKey = String.fromEnvironment('SB_KEY');
  static bool get isBuildConfigured => buildUrl.isNotEmpty && buildKey.isNotEmpty;

  static late SharedPreferences _p;

  static Future<void> load() async {
    _p = await SharedPreferences.getInstance();
  }

  // ---------- Supabase connection ----------
  /// Fixes the most common copy-paste mistake: copying the "Data API" URL
  /// (`https://xyz.supabase.co/rest/v1/`) instead of the plain project URL.
  /// Anything with a path on the end makes every request 404, so we keep only
  /// the scheme + host and drop quotes, spaces and trailing slashes.
  static String normalizeUrl(String raw) {
    var v = raw.trim().replaceAll('"', '').replaceAll("'", '');
    if (v.isEmpty) return '';
    if (!v.toLowerCase().startsWith('http')) v = 'https://$v';
    // The key travels with every request, so never send it over plain http.
    // Only a local development server may use http.
    final plain = RegExp(r'^http://(?!localhost|127\.0\.0\.1)', caseSensitive: false);
    v = v.replaceFirst(plain, 'https://');
    final host = RegExp(r'^(https?://[^/\s]+)', caseSensitive: false).firstMatch(v);
    if (host != null) v = host.group(1)!;
    return v.replaceAll(RegExp(r'/+$'), '');
  }

  /// Keys are one long line; strip newlines/spaces that sneak in when pasting.
  static String normalizeKey(String raw) =>
      raw.trim().replaceAll('"', '').replaceAll("'", '').replaceAll(RegExp(r'\s+'), '');

  static String get url {
    final stored = _p.getString(_kUrl) ?? '';
    return normalizeUrl(stored.isNotEmpty ? stored : buildUrl);
  }

  static String get anonKey {
    final stored = _p.getString(_kKey) ?? '';
    return normalizeKey(stored.isNotEmpty ? stored : buildKey);
  }
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
  static Future<void> saveConnection(String url, String key) async {
    await _p.setString(_kUrl, normalizeUrl(url));
    await _p.setString(_kKey, normalizeKey(key));
  }

  static Future<void> clearConnection() async {
    await _p.remove(_kUrl);
    await _p.remove(_kKey);
  }

  // ---------- this PC's identity ----------
  /// The till names itself after the computer, so you do not have to type
  /// anything on the other three PCs. Rename it in Settings if you prefer.
  static String get deviceName {
    final stored = _p.getString(_kDevice) ?? '';
    if (stored.isNotEmpty) return stored;
    try {
      final host = Platform.localHostname;
      return host.isEmpty ? 'Till' : host;
    } catch (_) {
      return 'Till';
    }
  }
  static int get terminalNo => _p.getInt(_kTerminal) ?? 1;
  static Future<void> saveDevice(String name, int terminal) async {
    await _p.setString(_kDevice, name.trim());
    await _p.setInt(_kTerminal, terminal);
  }

  static String get lastUser => _p.getString(_kLastUser) ?? '';
  static Future<void> saveLastUser(String email) => _p.setString(_kLastUser, email);

  // ---------- appearance ----------
  static const _kTheme = 'theme_mode';

  /// The chosen look: light, dark, or follow Windows. Defaults to following
  /// Windows the first time.
  static ThemeMode get themeMode {
    try {
      return switch (_p.getString(_kTheme)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      return ThemeMode.system; // preferences not loaded yet (tests)
    }
  }

  static Future<void> saveThemeMode(ThemeMode mode) => _p.setString(_kTheme, mode.name);

  // ---------- receipt printing ----------
  // Many XPrinter models (XP-80 series) commonly use 80mm thermal rolls.
  // Default to 80mm so a typical XP-80 printer prints without clipping.
  static int get paperMm => _p.getInt(_kPaper) ?? 80;
  static Future<void> setPaperMm(int mm) => _p.setInt(_kPaper, mm);

  /// The Windows printer that receives thermal receipts. Empty means the default printer.
  static String get thermalPrinter => _p.getString(_kThermalPrinter) ?? '';
  static Future<void> setThermalPrinter(String name) => _p.setString(_kThermalPrinter, name.trim());

  static bool get autoPrint => _p.getBool(_kAutoPrint) ?? true;
  static Future<void> setAutoPrint(bool v) => _p.setBool(_kAutoPrint, v);

  // safety net in case realtime is blocked by the shop's network
  // ---------- offline catalogue (so a restart without internet can still sell)
  // The till keeps a copy of the product list on disk. If the PC restarts while
  // the internet is down, it opens with yesterday's prices instead of an empty
  // screen - you can keep selling and the sales sync when the line comes back.
  static const _kCatalogue = 'catalogue_cache_v1';
  static const _kCatalogueAt = 'catalogue_cache_at';
  static const _kProductCatalogue = 'product_catalogue_cache_v1';
  static const _kProductCatalogueAt = 'product_catalogue_cache_at';

  static List<Map<String, dynamic>> get cachedCatalogue {
    final raw = _p.getString(_kCatalogue);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map>();
      return list.map((e) => e.cast<String, dynamic>()).toList();
    } catch (_) {
      return const [];
    }
  }

  static DateTime? get cachedCatalogueAt {
    final v = _p.getString(_kCatalogueAt);
    return v == null ? null : DateTime.tryParse(v);
  }

  static Future<void> saveCatalogue(List<Map<String, dynamic>> rows) async {
    try {
      await _p.setString(_kCatalogue, jsonEncode(rows));
      await _p.setString(_kCatalogueAt, DateTime.now().toIso8601String());
    } catch (_) {
      // cache is a convenience - never break a sale because of it
    }
  }

  static Future<void> clearCatalogue() async {
    await _p.remove(_kCatalogue);
    await _p.remove(_kCatalogueAt);
  }

  static List<Map<String, dynamic>> get cachedProductCatalogue {
    final raw = _p.getString(_kProductCatalogue);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map>();
      return list.map((e) => e.cast<String, dynamic>()).toList();
    } catch (_) {
      return const [];
    }
  }

  static DateTime? get cachedProductCatalogueAt {
    final v = _p.getString(_kProductCatalogueAt);
    return v == null ? null : DateTime.tryParse(v);
  }

  static Future<void> saveProductCatalogue(List<Map<String, dynamic>> rows) async {
    try {
      await _p.setString(_kProductCatalogue, jsonEncode(rows));
      await _p.setString(_kProductCatalogueAt, DateTime.now().toIso8601String());
    } catch (_) {
      // product cache is a convenience - never block the till from selling
    }
  }

  static Future<void> clearProductCatalogue() async {
    await _p.remove(_kProductCatalogue);
    await _p.remove(_kProductCatalogueAt);
  }

  // ---------- held (parked) bills: serve the next customer, resume later
  static const _kHeld = 'held_bills_v1';

  static List<Map<String, dynamic>> get heldBills {
    final raw = _p.getString(_kHeld);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map>();
      return list.map((e) => e.cast<String, dynamic>()).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveHeldBills(List<Map<String, dynamic>> bills) async =>
      _p.setString(_kHeld, jsonEncode(bills));

  // ---------- backup reminder
  static const _kBackupAt = 'last_backup_at';
  static DateTime? get lastBackupAt {
    final v = _p.getString(_kBackupAt);
    return v == null ? null : DateTime.tryParse(v);
  }
  static Future<void> markBackupDone() =>
      _p.setString(_kBackupAt, DateTime.now().toIso8601String());

  static int get refreshSeconds => _p.getInt(_kRefresh) ?? 20;
  static Future<void> setRefreshSeconds(int s) => _p.setInt(_kRefresh, s);

  /// Drops empty or incomplete sales and any sale that appears twice (same client_uuid).
  static OfflineQueueReconcileResult reconcileQueue(List<Map<String, dynamic>> queue) {
    final valid = <Map<String, dynamic>>[];
    final seen = <String>{};
    var duplicatesRemoved = 0;
    var invalidRemoved = 0;

    for (final payload in queue) {
      if (payload.isEmpty) {
        invalidRemoved++;
        continue;
      }
      final items = payload['items'];
      final method = (payload['payment_method'] ?? payload['method'] ?? '').toString().trim();
      final clientUuid = (payload['client_uuid'] ?? payload['sale_uuid'] ?? '').toString().trim();
      final hasItems = items is List && items.isNotEmpty;
      if (!hasItems || method.isEmpty) {
        invalidRemoved++;
        continue;
      }
      if (clientUuid.isNotEmpty && !seen.add(clientUuid)) {
        duplicatesRemoved++;
        continue;
      }
      valid.add(Map<String, dynamic>.from(payload));
    }

    return OfflineQueueReconcileResult(
      valid: valid,
      duplicatesRemoved: duplicatesRemoved,
      invalidRemoved: invalidRemoved,
      totalBefore: queue.length,
      totalAfter: valid.length,
    );
  }

  // ---------- offline sales ----------
  // One entry per sale that could not reach the server:
  //   sale        the exact payload create_sale receives (client_uuid = its id)
  //   queued_at   when it was rung up on this PC
  //   queued_by   the cashier it belongs to; only that cashier's session sends it
  //   total       what the customer was charged, for the screens
  //   attempts    failed sends for a reason other than "no internet"
  //   last_error  the most recent such reason
  // Entries written by older versions are bare sale payloads; they are wrapped here.
  static const _kRejected = 'offline_rejected_v1';

  /// The client_uuid of a queued or refused sale, or '' if it has none.
  static String saleUuid(Map<String, dynamic> entry) =>
      ((entry['sale'] as Map?)?['client_uuid'] ?? '').toString();

  /// Every sale still waiting to be sent, oldest first. Duplicates are dropped and
  /// a sale without an id is given one, so a sale can never be sent under two ids.
  static List<Map<String, dynamic>> get queueEntries {
    final raw = _p.getString(_kQueue);
    if (raw == null || raw.isEmpty) return [];
    try {
      final rows = (jsonDecode(raw) as List).cast<Map>();
      final entries = <Map<String, dynamic>>[];
      for (final row in rows) {
        final m = row.cast<String, dynamic>();
        final entry = m['sale'] is Map ? m : <String, dynamic>{'sale': m};
        final sale = (entry['sale'] as Map).cast<String, dynamic>();
        if (saleUuid(entry).isEmpty) sale['client_uuid'] = const Uuid().v4();
        entries.add({...entry, 'sale': sale});
      }
      final keep = reconcileQueue([for (final e in entries) e['sale'] as Map<String, dynamic>])
          .valid
          .map((s) => s['client_uuid'].toString())
          .toSet();
      final seen = <String>{};
      return [
        for (final e in entries)
          if (keep.contains(saleUuid(e)) && seen.add(saleUuid(e))) e,
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeQueue(List<Map<String, dynamic>> entries) =>
      _p.setString(_kQueue, jsonEncode(entries));

  /// Adds one sale to the end of the queue. Reads the stored queue first, so a
  /// sale queued during a send is never overwritten.
  static Future<void> enqueue(Map<String, dynamic> entry) =>
      _writeQueue([...queueEntries, entry]);

  /// Takes one sale out of the queue once the server has it.
  static Future<void> removeQueued(String clientUuid) async {
    if (clientUuid.isEmpty) return;
    await _writeQueue(queueEntries.where((e) => saleUuid(e) != clientUuid).toList());
  }

  /// Changes fields of one queued sale (attempts, last_error, ...).
  static Future<void> updateQueued(String clientUuid, Map<String, dynamic> changes) =>
      _writeQueue(queueEntries
          .map((e) => saleUuid(e) == clientUuid ? {...e, ...changes} : e)
          .toList());

  /// Sales the server refused for a business reason (stock gone, rule...). They are
  /// kept with the reason until someone retries or discards them. Never auto-deleted.
  static List<Map<String, dynamic>> get rejectedEntries {
    final raw = _p.getString(_kRejected);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _writeRejected(List<Map<String, dynamic>> entries) =>
      _p.setString(_kRejected, jsonEncode(entries));

  static Future<void> moveToRejected(Map<String, dynamic> entry, String reason) =>
      _writeRejected([
        ...rejectedEntries,
        {
          ...entry,
          'refused_at': DateTime.now().toIso8601String(),
          'refused_reason': reason,
        },
      ]);

  /// Puts a refused sale back in the queue to be sent again.
  static Future<void> restoreRejected(String clientUuid) async {
    final list = rejectedEntries;
    final hit = list.where((e) => saleUuid(e) == clientUuid).toList();
    if (hit.isEmpty) return;
    final back = Map<String, dynamic>.from(hit.first)
      ..remove('refused_at')
      ..remove('refused_reason')
      ..['attempts'] = 0
      ..remove('last_error');
    await _writeRejected(list.where((e) => saleUuid(e) != clientUuid).toList());
    await enqueue(back);
  }

  /// Drops a refused sale for good. Only called after the cashier confirms.
  static Future<void> discardRejected(String clientUuid) =>
      _writeRejected(rejectedEntries.where((e) => saleUuid(e) != clientUuid).toList());

  // ---------- cached copies for starting up with no internet ----------
  static Future<void> saveCache(String key, Object? value) async {
    try {
      await _p.setString('cache_$key', jsonEncode(value));
    } catch (_) {
      // a cache is a convenience; never break selling because of it
    }
  }

  static dynamic loadCache(String key) {
    final raw = _p.getString('cache_$key');
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  // ---------- offline work on customers and products ----------
  // Changes made with no internet, waiting for the server. Each entry:
  //   id           local id of the entry
  //   op           save_customer | save_product | delete_product | adjust_stock
  //   p            the payload the server function receives
  //   temp_id      for a new customer or product: the id the till shows until the server answers
  //   queued_by    the cashier it belongs to; only that cashier's session sends it
  //   refused      true when the server refused it; kept until retried or thrown away
  //   refused_reason, attempts, queued_at
  static const _kOps = 'offline_ops_v1';
  static const _kSalesCache = 'sales_history_v1';
  static const _kSaleDetails = 'sale_details_v1';
  static const _kInvoiceSeq = 'offline_invoice_seq';
  static const _kIdMap = 'offline_id_map_v1';

  static Map<String, dynamic> _readMap(String key) {
    final raw = _p.getString(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  static List<Map<String, dynamic>> _readList(String key) {
    final raw = _p.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  static List<Map<String, dynamic>> get opEntries => _readList(_kOps);

  static Future<void> _writeOps(List<Map<String, dynamic>> ops) =>
      _p.setString(_kOps, jsonEncode(ops));

  static Future<void> enqueueOp(Map<String, dynamic> op) => _writeOps([...opEntries, op]);

  static Future<void> updateOp(String id, Map<String, dynamic> changes) =>
      _writeOps(opEntries.map((o) => o['id'] == id ? {...o, ...changes} : o).toList());

  static Future<void> removeOp(String id) =>
      _writeOps(opEntries.where((o) => o['id'] != id).toList());

  /// Server id of every customer or product the till created offline, by its local id.
  static Map<String, String> get idMap =>
      _readMap(_kIdMap).map((k, v) => MapEntry(k, v.toString()));

  static Future<void> rememberId(String localId, String serverId) async {
    final all = _readMap(_kIdMap)..[localId] = serverId;
    await _p.setString(_kIdMap, jsonEncode(all));
  }

  /// The most recent invoices the server returned, kept so the invoice list works offline.
  static List<Map<String, dynamic>> get cachedSales => _readList(_kSalesCache);

  static Future<void> saveSalesCache(List<Map<String, dynamic>> rows) =>
      _p.setString(_kSalesCache, jsonEncode(rows.take(3000).toList()));

  static Map<String, dynamic>? cachedSaleDetail(String saleId) =>
      (_readMap(_kSaleDetails)[saleId] as Map?)?.cast<String, dynamic>();

  /// Keeps the lines of the newest 300 invoices opened or fetched on this PC.
  static Future<void> saveSaleDetail(String saleId, Map<String, dynamic> detail) async {
    final all = _readMap(_kSaleDetails)..remove(saleId)..[saleId] = detail;
    while (all.length > 300) {
      all.remove(all.keys.first);
    }
    await _p.setString(_kSaleDetails, jsonEncode(all));
  }

  /// Next provisional invoice number for a sale made with no internet, e.g. OFF-0001.
  /// The server gives the real invoice number when the sale is sent.
  static Future<String> nextOfflineInvoiceNo() async {
    final next = (_p.getInt(_kInvoiceSeq) ?? 0) + 1;
    await _p.setInt(_kInvoiceSeq, next);
    return 'OFF-${next.toString().padLeft(4, '0')}';
  }
}
