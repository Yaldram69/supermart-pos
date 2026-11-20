// The sales this till has not yet sent to the server, and the ones the server
// refused. Opened from the status bar, the Invoices screen and Settings.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_config.dart';
import '../core/format.dart';
import '../state/app_state.dart';
import '../theme.dart';

Future<void> showSyncDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const SyncDialog());

class SyncDialog extends StatefulWidget {
  const SyncDialog({super.key});

  @override
  State<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<SyncDialog> {
  bool _busy = false;

  Future<void> _sendNow(AppState state) async {
    setState(() => _busy = true);
    try {
      await state.flushOfflineQueue(manual: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry(AppState state, Map<String, dynamic> entry) async {
    setState(() => _busy = true);
    try {
      await state.retryRefused(AppConfig.saleUuid(entry));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discard(AppState state, Map<String, dynamic> entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Throw this sale away?'),
        content: const Text(
          'The sale will NOT be entered in the books. Do this only if the goods '
          'were never handed over or were already entered by hand. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Throw away'),
          ),
        ],
      ),
    );
    if (ok == true) await state.discardRefused(AppConfig.saleUuid(entry));
  }

  static String _when(Object? iso) {
    final t = parseDate(iso);
    return t == null ? '' : dateTimeFmt.format(t);
  }

  static int _itemCount(Map<String, dynamic> entry) {
    final sale = entry['sale'];
    final items = sale is Map ? sale['items'] : null;
    return items is List ? items.length : 0;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sym = state.store?.currencySymbol ?? 'Rs';
    final queued = state.queuedSales;
    final refused = state.refusedSales;
    final me = state.identity?.id ?? '';
    final changes = AppConfig.opEntries;
    final pendingChanges = changes.where((o) => o['refused'] != true).toList();
    final refusedChanges = changes.where((o) => o['refused'] == true).toList();

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            state.online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            color: state.online ? AppColors.good : AppColors.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(state.online
                ? 'Sales waiting to be sent'
                : 'Offline: sales are kept on this PC'),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.syncNotice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(state.syncNotice!),
              ),
            Expanded(
              child: ListView(
                children: [
                  _heading('Waiting to be sent (${queued.length})'),
                  if (queued.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text('Nothing is waiting. Every sale has reached the server.'),
                    ),
                  for (final e in queued)
                    _row(
                      icon: Icons.schedule,
                      color: AppColors.warn,
                      title: _customer(e),
                      subtitle: [
                        _when(e['queued_at']),
                        '${_itemCount(e)} item(s)',
                        if ((e['queued_by'] ?? '').toString().isNotEmpty &&
                            e['queued_by'] != me)
                          'waits for ${e['queued_by_name'] ?? 'its cashier'} to sign in',
                      ].where((s) => s.isNotEmpty).join('  ·  '),
                      trailing: money(e['total'], symbol: sym),
                    ),
                  if (pendingChanges.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _heading('Customer and product changes waiting (${pendingChanges.length})'),
                    for (final o in pendingChanges)
                      _row(
                        icon: Icons.schedule,
                        color: AppColors.warn,
                        title: _changeLabel(o),
                        subtitle: [
                          _when(o['queued_at']),
                          if ((o['queued_by'] ?? '').toString().isNotEmpty && o['queued_by'] != me)
                            'waits for ${o['queued_by_name'] ?? 'its cashier'} to sign in',
                        ].where((s) => s.isNotEmpty).join('  ·  '),
                      ),
                  ],
                  if (refusedChanges.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _heading('Customer and product changes refused (${refusedChanges.length})'),
                    for (final o in refusedChanges)
                      _row(
                        icon: Icons.error_outline,
                        color: AppColors.danger,
                        title: _changeLabel(o),
                        subtitle: 'Refused: ${o['refused_reason'] ?? 'unknown reason'}',
                        actions: [
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => state.retryRefusedChange(o['id'].toString()),
                            child: const Text('Try again'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _discardChange(state, o['id'].toString()),
                            child: const Text('Throw away'),
                          ),
                        ],
                      ),
                  ],
                  const SizedBox(height: 16),
                  _heading('Refused by the server (${refused.length})'),
                  if (refused.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text('None.'),
                    ),
                  for (final e in refused)
                    _row(
                      icon: Icons.error_outline,
                      color: AppColors.danger,
                      title: '${_customer(e)}  ·  ${money(e['total'], symbol: sym)}',
                      subtitle: 'Refused: ${e['refused_reason'] ?? 'unknown reason'}'
                          '${_when(e['refused_at']).isEmpty ? '' : '  ·  ${_when(e['refused_at'])}'}',
                      actions: [
                        TextButton(
                          onPressed: _busy ? null : () => _retry(state, e),
                          child: const Text('Try again'),
                        ),
                        TextButton(
                          onPressed: _busy ? null : () => _discard(state, e),
                          child: const Text('Throw away'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _busy || queued.isEmpty ? null : () => _sendNow(state),
          icon: const Icon(Icons.cloud_upload_outlined),
          label: Text(_busy ? 'Sending…' : 'Send now'),
        ),
      ],
    );
  }

  Future<void> _discardChange(AppState state, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Throw this change away?'),
        content: const Text('The change will NOT be saved on the server. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Throw away'),
          ),
        ],
      ),
    );
    if (ok == true) await state.discardRefusedChange(id);
  }

  /// What a customer or product change does, in words for the cashier.
  static String _changeLabel(Map<String, dynamic> op) {
    final p = op['p'] is Map ? op['p'] as Map : const {};
    final name = (p['name'] ?? '').toString().trim();
    final shown = name.isEmpty ? '(no name)' : name;
    return switch (op['op']) {
      'save_customer' => 'Customer: $shown',
      'save_product' => 'Product: $shown',
      'delete_product' => 'Remove a product',
      'adjust_stock' => 'Stock count set to ${p['new_qty']}',
      _ => 'Change',
    };
  }

  static String _customer(Map<String, dynamic> entry) {
    final sale = entry['sale'];
    final name = sale is Map ? (sale['customer_name'] ?? '').toString().trim() : '';
    return name.isEmpty ? 'Walk-in sale' : name;
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
      );

  Widget _row({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    String? trailing,
    List<Widget> actions = const [],
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(subtitle, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(trailing, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ...actions,
        ],
      ),
    );
  }
}
