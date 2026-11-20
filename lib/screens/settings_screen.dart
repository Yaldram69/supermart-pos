import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'products_screen.dart';

import '../core/app_config.dart';
import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/receipt.dart';
import '../widgets/sync_dialog.dart';

/// Store settings, this PC's identity, the printer, the tills that are online
/// and anything waiting to be sent to the server.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _scalePrefix = TextEditingController();
  final _pointValue = TextEditingController();
  String _scaleMode = 'weight';
  bool _pinSet = false;
  bool _loadedOnce = false;
  bool _backupBusy = false;
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _ntn = TextEditingController();
  final _tax = TextEditingController();
  final _taxLabel = TextEditingController();
  final _footer = TextEditingController();
  final _header = TextEditingController();
  final _cashierDiscount = TextEditingController();
  final _expiryDays = TextEditingController();
  final _invoiceNote = TextEditingController();
  final _terms = TextEditingController();
  bool _blockExpired = false;
  bool _requireExpiry = false;
  bool _enableBatches = true;
  bool _enableTiers = true;
  
  bool _allowZeroStock = false;
  final _device = TextEditingController(text: AppConfig.deviceName);
  bool _loaded = false;
  bool _shopRulesFilled = false;

  @override
  void dispose() {
    for (final c in [
      _scalePrefix, _pointValue, _name, _address, _phone, _ntn, _tax, _taxLabel,
      _footer, _header, _cashierDiscount, _expiryDays, _invoiceNote, _terms, _device,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final state = context.read<AppState>();
      try {
        await state.refreshReference();
      } catch (e) {
        // the form still opens on what is already known; a failed load must not spin forever
        if (mounted) showError(context, e);
      }
      final s = state.store;
      if (s != null) {
        _name.text = s.name;
        _address.text = s.address;
        _phone.text = s.phone;
        _ntn.text = s.ntn;
        _tax.text = num2(s.taxPercent);
        _taxLabel.text = s.taxLabel;
        _footer.text = s.receiptFooter;
        _header.text = s.receiptHeader;
        _cashierDiscount.text = num2(s.maxCashierDiscountPercent);
        _allowZeroStock = s.allowNegativeStock;
      }
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedOnce) return;
    _loadedOnce = true;
    final store = context.read<AppState>().store;
    _scalePrefix.text = store?.scaleBarcodePrefix ?? '';
    _scaleMode = store?.scaleBarcodeMode ?? 'weight';
    _pointValue.text = (store?.loyaltyPointValue ?? 0).toStringAsFixed(2);
    context
        .read<AppState>()
        .api
        .pinReady()
        .then((v) {
          if (mounted) setState(() => _pinSet = v);
        })
        .catchError((_) {});
  }

  Future<void> _setPin(AppState state) async {
    final pin = TextEditingController();
    final again = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Set your manager PIN'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '4 to 8 digits. Cashiers will type this to get your approval '
                'for a discount or refund.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pin,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                decoration: const InputDecoration(labelText: 'PIN'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: again,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                decoration: const InputDecoration(labelText: 'Type it again'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );
    // Read the values, then release the controllers.
    final newPin = pin.text.trim();
    final confirmPin = again.text.trim();
    pin.dispose();
    again.dispose();
    if (ok != true || !mounted) return;
    // Same rule the server enforces (set_manager_pin): 4 to 8 digits.
    if (!RegExp(r'^[0-9]{4,8}$').hasMatch(newPin)) {
      showMessage(context, 'A PIN must be 4 to 8 digits, numbers only', error: true);
      return;
    }
    if (newPin != confirmPin) {
      showMessage(context, 'The two PINs do not match', error: true);
      return;
    }
    try {
      await state.api.setManagerPin(pin.text.trim());
      if (!mounted) return;
      setState(() => _pinSet = true);
      showMessage(
        context,
        'PIN saved — cashiers can now ask you to approve at the till',
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _clearPin(AppState state) async {
    if (!await confirm(
      context,
      title: 'Remove your PIN?',
      message:
          'The till will stop offering PIN approval until a PIN is set again.',
      okLabel: 'Remove',
    )) {
      return;
    }
    try {
      await state.api.clearManagerPin();
      if (!mounted) return;
      setState(() => _pinSet = false);
      showMessage(context, 'PIN removed');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _saveScale(AppState state) async {
    try {
      await state.api.saveScaleSettings({
        'scale_barcode_prefix': _scalePrefix.text.trim(),
        'scale_barcode_mode': _scaleMode,
        'loyalty_point_value': parseAmount(_pointValue.text.trim()) ?? 0,
      });
      await state.refreshCatalogue(silent: true);
      if (!mounted) return;
      showMessage(context, 'Scale and loyalty settings saved');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Directory get _backupDir {
    final docs =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return Directory('$docs${Platform.pathSeparator}SupermartPOS Backups');
  }

  Future<void> _openBackupFolder() async {
    final dir = _backupDir;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = dir.path;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Backups are in: $path');
    }
  }

  /// Writes the whole shop to dated CSV files - the free plan has no auto-backups.
  Future<void> _backup(AppState state) async {
    setState(() => _backupBusy = true);
    try {
      final data = await state.api.backupBundle();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .substring(0, 16)
          .replaceAll('T', '_');
      final dir = Directory(
        '${_backupDir.path}${Platform.pathSeparator}$stamp',
      );
      dir.createSync(recursive: true);

      var written = 0;
      for (final entry in data.entries) {
        if (entry.value is! List) continue;
        final rows = (entry.value as List).whereType<Map>().toList();
        if (rows.isEmpty) continue;
        final file = File(
          '${dir.path}${Platform.pathSeparator}${entry.key}.csv',
        );
        file.writeAsStringSync(_toCsv(rows.cast<Map>()));
        written++;
      }
      await AppConfig.markBackupDone();
      if (!mounted) return;
      showMessage(context, 'Backup saved: $written file(s) in ${dir.path}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  static String _toCsv(List<Map> rows) {
    final keys = <String>{};
    for (final r in rows) {
      keys.addAll(r.keys.map((k) => k.toString()));
    }
    final cols = keys.toList()..sort();
    String cell(Object? v) {
      final text = v == null
          ? ''
          : (v is Map || v is List)
          ? jsonEncode(v)
          : v.toString();
      // numbers stay numbers; text is quoted and formula-safe (see csvCell)
      return v is num ? csvCell(v) : csvCell(text);
    }

    final buffer = StringBuffer()..writeln(cols.map(csvCell).join(','));
    for (final r in rows) {
      buffer.writeln(cols.map((c) => cell(r[c])).join(','));
    }
    return buffer.toString();
  }

  /// The server writes every store column from what it is sent, so a save must
  /// carry all of them. Start from the current store values and change only the
  /// fields on this screen; otherwise the other fields are cleared.
  Map<String, dynamic> _storePayload(AppState state, Map<String, dynamic> changes) => {
        ...?state.store?.raw,
        ...changes,
      };

  /// Fills the non-toggle store settings from the server value. The zero-stock
  /// switch is kept in the user's current local state so a toggle can be saved
  /// without being overwritten by an older store snapshot on every rebuild.
  void _fill(StoreSettings? store) {
    if (store == null) return;

    _expiryDays.text = store.expiryAlertDays.toString();
    _invoiceNote.text = store.invoiceNote.isEmpty
        ? 'Goods once sold are returnable only with a receipt.'
        : store.invoiceNote;
    _terms.text = store.termsAndConditions;
    _blockExpired = store.blockExpiredSales;
    _requireExpiry = store.requireExpiry;
    _enableBatches = store.enableBatches;
    _enableTiers = store.enableTiers;
    
  }

  Future<void> _openCategoryEditor(
    AppState state, {
    Map<String, dynamic>? category,
    String? parentCategoryId,
  }) async {
    final nameController = TextEditingController(
      text: category?['name']?.toString() ?? '',
    );
    String? selectedParentId = category == null
        ? parentCategoryId
        : ((category['parent_id'] ?? '') as String?)?.trim().isNotEmpty == true
        ? category['parent_id']?.toString()
        : null;

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(category == null ? 'Add category' : 'Edit category'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (category == null ||
                    category['parent_id'] == null ||
                    (category['parent_id'] as String).trim().isEmpty)
                  DropdownButtonFormField<String?>(
                    initialValue: selectedParentId,
                    decoration: const InputDecoration(
                      labelText: 'Parent category',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Top-level category'),
                      ),
                      for (final cat in state.categories)
                        DropdownMenuItem<String?>(
                          value: cat['id'] as String,
                          child: Text(cat['name'] as String),
                        ),
                    ],
                    onChanged: (v) => setLocal(() => selectedParentId = v),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(category == null ? 'Save category' : 'Update'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || !mounted) return;

    final name = nameController.text.trim();
    if (name.isEmpty) {
      showMessage(context, 'Category name is required', error: true);
      return;
    }

    try {
      final payload = <String, dynamic>{
        'name': name,
        'description': category?['description'] ?? '',
        'parent_id': selectedParentId?.trim().isNotEmpty == true
            ? selectedParentId
            : null,
      };
      if (category != null && category['id'] != null) {
        payload['id'] = category['id'];
      }
      await state.api.saveCategory(payload);
      await state.refreshReference();
      if (mounted) {
        showMessage(
          context,
          category == null ? 'Category saved' : 'Category updated',
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteCategory(
    AppState state,
    Map<String, dynamic> category,
  ) async {
    final categoryName = category['name']?.toString() ?? 'this category';
    final ok = await confirm(
      context,
      title: 'Delete category?',
      message:
          'Delete "$categoryName"? Products assigned to it will lose their category, and any subcategories below it will become orphaned.',
      okLabel: 'Delete',
    );
    if (!ok || !mounted) return;

    final id = category['id']?.toString();
    if (id == null || id.trim().isEmpty) {
      showMessage(context, 'Category does not have an ID', error: true);
      return;
    }

    try {
      await state.api.deleteCategory(id);
      await state.refreshReference();
      if (mounted) showMessage(context, 'Category deleted');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Owner only. Removes every product, but only after the owner types their
  /// password again. The server checks the role; the password is checked by
  /// signing in again.
  Future<void> _deleteAllProducts(AppState state) async {
    final password = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete all products permanently?'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This permanently deletes every product with its stock, prices and batches, '
                'all invoices and returns, all purchases, suppliers, categories, discounts, '
                'expenses and shifts. It cannot be undone.\n\n'
                'Kept: the customer list (their balances and loyalty points go to zero), '
                'staff logins, store settings and tills.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Your password'),
                onSubmitted: (_) => Navigator.pop(c, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete all products'),
          ),
        ],
      ),
    );
    // Read the value, then release the controller.
    final typed = password.text;
    password.dispose();
    if (ok != true || !mounted) return;
    if (typed.isEmpty) {
      showMessage(context, 'Type your password to continue', error: true);
      return;
    }

    try {
      await state.api.confirmPassword(typed);
      final result = await state.api.deleteAllProducts(device: AppConfig.deviceName);
      await state.resetAfterPurge();
      if (mounted) {
        showMessage(
          context,
          'Store cleared: ${result['products'] ?? 0} product(s), '
          '${result['sales'] ?? 0} invoice(s), ${result['purchase_orders'] ?? 0} purchase(s) deleted. '
          'Customer balances reset to zero.',
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'This PC (the till)',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _device,
                      decoration: const InputDecoration(
                        labelText: 'Till name',
                        helperText: 'Shown on every invoice this PC prints',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 140,
                    // read-only value: no controller is needed, so none is made per rebuild
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Terminal #'),
                      child: Text(AppConfig.terminalNo.toString()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () async {
                      await AppConfig.saveDevice(
                        _device.text,
                        AppConfig.terminalNo,
                      );
                      if (context.mounted) {
                        showMessage(
                          context,
                          'Saved. Restart the app to re-register.',
                        );
                      }
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Each of the 4 PCs has its own till name, so the reports show which counter sold what.',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        SectionCard(
          title: 'Receipt printing',
          child: Column(
            children: [
              Row(
                children: [
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 80, label: Text('80mm roll')),
                      ButtonSegment(value: 58, label: Text('58mm roll')),
                    ],
                    selected: {AppConfig.paperMm},
                    onSelectionChanged: (s) async {
                      await AppConfig.setPaperMm(s.first);
                      setState(() {});
                    },
                  ),
                  const SizedBox(width: 16),
                  Switch(
                    value: AppConfig.autoPrint,
                    onChanged: (v) async {
                      await AppConfig.setAutoPrint(v);
                      setState(() {});
                    },
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Print the receipt automatically after every sale',
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: () =>
                        ReceiptPrinter.printTest(context, state.store),
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Test print'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: AppConfig.thermalPrinter,
                decoration: const InputDecoration(
                  labelText: 'Thermal printer name',
                  hintText: 'Leave blank to use the Windows default printer',
                  helperText:
                      'Type the name exactly as it appears in Windows Settings > Printers. '
                      'Receipts go straight to this printer, so long baskets print in full.',
                  isDense: true,
                ),
                onChanged: (v) => AppConfig.setThermalPrinter(v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        SectionCard(
          title: 'The 4 counters',
          actions: [
            IconButton(
              onPressed: () async {
                await state.refreshReference();
              },
              icon: const Icon(Icons.refresh),
            ),
          ],
          child: state.devices.isEmpty
              ? const Text('No other till has checked in yet.')
              : Column(
                  children: [
                    for (final d in state.devices.map(DeviceRow.new))
                      ListTile(
                        dense: true,
                        leading: Icon(
                          d.isRecent
                              ? Icons.desktop_windows
                              : Icons.desktop_access_disabled,
                          color: d.isRecent ? AppColors.good : AppColors.warn,
                        ),
                        title: Text('${d.name}   (terminal ${d.terminalNo})'),
                        subtitle: Text(
                          'last seen ${agoLabel(d.lastSeen)}  •  v${d.appVersion}',
                        ),
                        trailing: StatusPill(
                          text: d.isRecent ? 'online' : 'idle',
                          color: d.isRecent ? AppColors.good : AppColors.warn,
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),

        SectionCard(
          title: 'Sales waiting to be sent  (offline queue)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.pendingOffline == 0
                    ? 'Nothing is waiting — every sale has reached the server.'
                    : '${state.pendingOffline} sale(s) made while the internet was down are stored on this PC '
                          'and will be sent automatically.',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => showSyncDialog(context),
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Open sales waiting to send'),
                  ),
                ],
              ),
            ],
          ),
        ),

        if (state.isAdmin) ...[
          const SizedBox(height: 16),
          SectionCard(
            title: 'Big-shop rules — expiry, offers, vouchers',
            child: Builder(
              builder: (context) {
                // fill from the server once, not on every rebuild: a rebuild after a
                // switch was flipped would otherwise put the old value straight back
                if (!_shopRulesFilled && state.store != null) {
                  _fill(state.store);
                  _shopRulesFilled = true;
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 260,
                          child: TextField(
                            controller: _expiryDays,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Warn me this many days before expiry',
                              helperText: 'Used by the Expiry & batches screen',
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: Text(
                            'Products that expire are tracked either way — this only decides how '
                            'early the shop starts shouting about them.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      value: _blockExpired,
                      onChanged: (v) => setState(() => _blockExpired = v),
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Refuse to sell stock that is past its expiry date',
                      ),
                      subtitle: const Text(
                        'Strongly recommended for dairy, bakery, medicine and baby food. '
                        'The till then asks the staff to write the stock off instead.',
                      ),
                    ),
                    SwitchListTile(
                      value: _requireExpiry,
                      onChanged: (v) => setState(() => _requireExpiry = v),
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Demand an expiry date when booking in a delivery',
                      ),
                      subtitle: const Text(
                        'For shops where every line has to carry a date by law.',
                      ),
                    ),
                    const Divider(height: 24),
                    const SectionLabel('Modules you have bought / switched on'),
                    Wrap(
                      spacing: 18,
                      children: [
                        _switch(
                          'Batch & expiry tracking',
                          _enableBatches,
                          (v) => setState(() => _enableBatches = v),
                        ),
                        _switch(
                          'Quantity price tiers',
                          _enableTiers,
                          (v) => setState(() => _enableTiers = v),
                        ),
                        
                      ],
                    ),
                    const Divider(height: 24),
                    const SectionLabel('Printed on a proper A4 invoice'),
                    TextField(
                      controller: _invoiceNote,
                      decoration: const InputDecoration(
                        labelText: 'Note printed on the invoice',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _terms,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Terms & conditions (multi-line)',
                        hintText:
                            'Payment within 15 days.\nGoods once sold are not returnable.\n'
                            'Cheques in favour of ...',
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () async {
                        try {
                          await state.api.saveStoreSettings(_storePayload(state, {
                            'expiry_alert_days':
                                int.tryParse(_expiryDays.text) ?? 30,
                            'block_expired_sales': _blockExpired,
                            'require_expiry': _requireExpiry,
                            'enable_batches': _enableBatches,
                            'enable_tiers': _enableTiers,
                            'invoice_note': _invoiceNote.text.trim(),
                            'terms_and_conditions': _terms.text.trim(),
                          }));
                          await state.bootstrap();
                          if (context.mounted) {
                            showMessage(context, 'Shop rules saved');
                          }
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save shop rules'),
                    ),
                  ],
                );
              },
            ),
          ),
        ],

        if (state.isSuperAdmin) ...[
          const SizedBox(height: 16),
          SectionCard(
            title: 'Delete all products (Super Admin)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Permanently empties the store for a fresh start: products, invoices, '
                  'purchases, suppliers, categories, discounts, expenses and shifts. The customer '
                  'list is kept, with balances reset to zero. Your password is asked first. '
                  'This cannot be undone: back up the database before you use it.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                  onPressed: () => _deleteAllProducts(state),
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Delete all products permanently...'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Store details (Super Admin)',
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Store name',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _phone,
                        decoration: const InputDecoration(labelText: 'Phone'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Address'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ntn,
                        decoration: const InputDecoration(
                          labelText: 'NTN / tax number',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _tax,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Tax %',
                          helperText: '0 hides the tax line on receipts',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _taxLabel,
                        decoration: const InputDecoration(
                          labelText: 'Tax label',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _cashierDiscount,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Default cashier discount %',
                          helperText: 'New staff inherit this',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _allowZeroStock,
                  onChanged: (v) => setState(() => _allowZeroStock = v),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sell stock even when stock is zero'),
                  subtitle: const Text(
                    'When off, any item with zero stock cannot be sold. When on, zero-stock items sell normally.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _header,
                  decoration: const InputDecoration(
                    labelText: 'Receipt heading (optional)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _footer,
                  decoration: const InputDecoration(
                    labelText: 'Receipt footer',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () async {
                        try {
                          // an invalid tax or discount limit is refused, not saved as 0
                          // (0 tax hides the tax line on every receipt)
                          final tax = parseAmount(_tax.text);
                          final cashierLimit = parseAmount(_cashierDiscount.text);
                          if (tax == null || tax < 0 || tax > 100) {
                            showMessage(context, 'Tax must be a number from 0 to 100', error: true);
                            return;
                          }
                          if (cashierLimit == null || cashierLimit < 0 || cashierLimit > 100) {
                            showMessage(context, 'Cashier discount limit must be from 0 to 100', error: true);
                            return;
                          }
                          final saved = await state.api.saveStoreSettings(_storePayload(state, {
                            'name': _name.text.trim(),
                            'address': _address.text.trim(),
                            'phone': _phone.text.trim(),
                            'ntn': _ntn.text.trim(),
                            'tax_percent': tax,
                            'tax_label': _taxLabel.text.trim(),
                            'receipt_header': _header.text.trim(),
                            'receipt_footer': _footer.text.trim(),
                            'max_cashier_discount_percent': cashierLimit,
                            'allow_negative_stock': _allowZeroStock,
                          }));
                          final raw = Map<String, dynamic>.from(
                            state.store?.raw ?? <String, dynamic>{},
                          );
                          raw['allow_negative_stock'] = _allowZeroStock;
                          if (saved['id'] != null) raw['id'] = saved['id'];
                          state.replaceStore(StoreSettings(raw));
                          await state.bootstrap();
                          if (context.mounted) {
                            showMessage(context, 'Store settings saved');
                          }
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save store settings'),
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                      ),
                      onPressed: () async {
                        final controller = TextEditingController();
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text(
                              'Delete ALL sales and start fresh?',
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'This removes every invoice, shift, refund and expense. '
                                  'Products and staff stay. Type DELETE-ALL-SALES to confirm.',
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: controller,
                                  decoration: const InputDecoration(
                                    labelText: 'Type to confirm',
                                  ),
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.danger,
                                ),
                                onPressed: () => Navigator.pop(
                                  c,
                                  controller.text.trim() == 'DELETE-ALL-SALES',
                                ),
                                child: const Text('Delete everything'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          try {
                            await state.api.resetDemoData('DELETE-ALL-SALES');
                            await state.refreshCatalogue();
                            if (context.mounted) {
                              showMessage(context, 'Trading history cleared');
                            }
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        }
                      },
                      icon: const Icon(Icons.warning_amber),
                      label: const Text('Reset trading data'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),

        SectionCard(
          title: 'Categories & subcategories',
          actions: [
            IconButton(
              onPressed: () async => state.refreshReference(),
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh categories',
            ),
            FilledButton.icon(
              onPressed: () => _openCategoryEditor(state),
              icon: const Icon(Icons.add),
              label: const Text('Add category'),
            ),
          ],
          child: state.categories.isEmpty && state.subcategories.isEmpty
              ? const Text(
                  'No categories yet. Add a category, then add subcategories under it.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final cat in state.categories)
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    cat['name']?.toString() ?? 'Unnamed',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () =>
                                      _openCategoryEditor(state, category: cat),
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('Edit'),
                                ),
                                TextButton.icon(
                                  onPressed: () => _deleteCategory(state, cat),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                  label: const Text('Delete'),
                                ),
                                TextButton.icon(
                                  onPressed: () => _openCategoryEditor(
                                    state,
                                    parentCategoryId: cat['id']?.toString(),
                                  ),
                                  icon: const Icon(Icons.add, size: 18),
                                  label: const Text('Add subcategory'),
                                ),
                              ],
                            ),
                            if (state.subcategories.any(
                              (sub) => sub['parent_id'] == cat['id'],
                            ))
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final sub in state.subcategories.where(
                                    (item) => item['parent_id'] == cat['id'],
                                  ))
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Theme.of(context).colorScheme.outlineVariant,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            sub['name']?.toString() ??
                                                'Unnamed',
                                          ),
                                          const SizedBox(width: 8),
                                          GestureDetector(
                                            onTap: () => _openCategoryEditor(
                                              state,
                                              category: sub,
                                            ),
                                            child: const Icon(
                                              Icons.edit_outlined,
                                              size: 16,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          GestureDetector(
                                            onTap: () =>
                                                _deleteCategory(state, sub),
                                            child: const Icon(
                                              Icons.delete_outline,
                                              size: 16,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              )
                            else
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  'No subcategories yet.',
                                  style: TextStyle(fontSize: 12.5),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (state.subcategories.any(
                      (sub) =>
                          sub['parent_id'] == null ||
                          (sub['parent_id'] as String).trim().isEmpty,
                    ))
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Orphaned subcategories',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final sub in state.subcategories.where(
                                  (item) =>
                                      item['parent_id'] == null ||
                                      (item['parent_id'] as String)
                                          .trim()
                                          .isEmpty,
                                ))
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Theme.of(context).colorScheme.outlineVariant,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          sub['name']?.toString() ?? 'Unnamed',
                                        ),
                                        const SizedBox(width: 8),
                                        GestureDetector(
                                          onTap: () => _openCategoryEditor(
                                            state,
                                            category: sub,
                                          ),
                                          child: const Icon(
                                            Icons.edit_outlined,
                                            size: 16,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        GestureDetector(
                                          onTap: () =>
                                              _deleteCategory(state, sub),
                                          child: const Icon(
                                            Icons.delete_outline,
                                            size: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),

        SectionCard(
          title: 'Manager PIN (approve at the till)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'A 4 to 8 digit PIN lets a manager approve a discount, refund or cancellation '
                'at the counter without signing in and losing the bill. Only the server '
                'checks the PIN, and every use is written to the Activity log.',
                style: TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _setPin(state),
                    icon: const Icon(Icons.password),
                    label: Text(_pinSet ? 'Change my PIN' : 'Set my PIN'),
                  ),
                  const SizedBox(width: 12),
                  if (_pinSet)
                    OutlinedButton.icon(
                      onPressed: () => _clearPin(state),
                      icon: const Icon(Icons.lock_open),
                      label: const Text('Remove my PIN'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Weighing scale & loyalty',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'If your scale printer puts its own barcode on loose items (atta, sugar, '
                'fruit), tell the till the leading digits it prints. Then scanning one of '
                'those labels bills the exact weight with no typing.',
                style: TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: TextField(
                      controller: _scalePrefix,
                      decoration: const InputDecoration(
                        labelText: 'Scale prefix (e.g. 22)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
                    value: _scaleMode,
                    items: const [
                      DropdownMenuItem(
                        value: 'weight',
                        child: Text('Label carries the weight'),
                      ),
                      DropdownMenuItem(
                        value: 'price',
                        child: Text('Label carries the price'),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _scaleMode = v ?? 'weight'),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 190,
                    child: TextField(
                      controller: _pointValue,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Loyalty: Rs per point',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    onPressed: () => _saveScale(state),
                    child: const Text('Save'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Points are already awarded automatically when a customer is attached '
                'to a sale (currently ${num2(state.store?.loyaltyPointsPer100 ?? 0)} per Rs 100).',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Backup',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KeyValue(
                k: 'Last backup on this PC',
                v: AppConfig.lastBackupAt == null
                    ? 'never'
                    : agoLabel(AppConfig.lastBackupAt),
                color: AppConfig.lastBackupAt == null ? AppColors.danger : null,
              ),
              const Text(
                'The free Supabase plan has no automatic backups, so this is your safety '
                'net: it writes a dated folder of CSV files (products, customers, sales, '
                'stock history, purchases, expenses) that opens in Excel.',
                style: TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _backupBusy ? null : () => _backup(state),
                    icon: _backupBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                    label: Text(_backupBusy ? 'Saving…' : 'Back up now'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => _openBackupFolder(),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open backup folder'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => const BulkImportDialog(),
                    ),
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Import products'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Server & support',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KeyValue(k: 'Connected to', v: AppConfig.url),
              KeyValue(
                k: 'This PC',
                v: '${AppConfig.deviceName} • terminal ${AppConfig.terminalNo}',
              ),
              KeyValue(
                k: 'Catalogue synced',
                v: agoLabel(state.catalogueSyncedAt),
              ),
              KeyValue(
                k: 'Signed in as',
                v: state.identity == null
                ? 'Not signed in'
                : '${state.identity!.fullName} (${state.identity!.roleLabel})',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      await state.refreshCatalogue();
                      if (context.mounted) {
                        showMessage(context, 'Stock figures refreshed');
                      }
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh stock now'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => context.read<AppState>().signOut(),
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) =>
      SizedBox(
        width: 290,
        child: SwitchListTile(
          value: value,
          onChanged: onChanged,
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(label, style: const TextStyle(fontSize: 13.5)),
          subtitle: Text(
            value ? 'switched on' : 'switched off',
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
      );
}
