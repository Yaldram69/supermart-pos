import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/reporting.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Every change anyone made, in plain english: who sold, who cancelled,
/// who gave a discount, who approved one with a PIN, who adjusted stock.
/// This is the screen that tells you if something odd is going on.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  List<ActivityRow> _rows = [];
  int _days = 7;
  String? _action;
  bool _busy = false;
  bool _capped = false;
  static const _rowCap = 5000;

  static const _filters = <String, String>{
    'All actions': '',
    'Sales': 'sale.',
    'Cancellations': 'sale.void',
    'Refunds': 'refund',
    'PIN approvals': 'override.pin',
    'Stock changes': 'stock.',
    'Products': 'product.',
    'Suppliers & purchases': 'purchase',
    'Expenses': 'expense.',
    'Staff & settings': 'staff',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final rows = await state.api.activity(
        limit: _rowCap,
        from: DateTime.now().subtract(Duration(days: _days)),
        to: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _rows = rows.map(ActivityRow.new).toList();
        _capped = rows.length >= _rowCap;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<ActivityRow> get _visible {
    final f = _action ?? '';
    if (f.isEmpty) return _rows;
    if (f == 'staff') {
      // staff changes and settings changes both belong under this filter
      return _rows.where((r) =>
          r.action.startsWith('staff') ||
          r.action.startsWith('settings') ||
          r.action.startsWith('employee')).toList();
    }
    return _rows.where((r) => r.action.startsWith(f)).toList();
  }

  Color _colorFor(String action) {
    if (action.startsWith('sale.void')) return AppColors.danger;
    if (action == 'override.pin') return AppColors.warn;
    if (action.startsWith('return')) return AppColors.info;
    if (action.startsWith('stock') || action.startsWith('stocktake')) return AppColors.info;
    if (action.startsWith('expense')) return AppColors.warn;
    if (action.startsWith('staff') || action.startsWith('settings')) return AppColors.danger;
    return AppColors.good;
  }

  Widget _stat(String label, String value, IconData icon, Color color) => SizedBox(
        width: 180,
        child: StatCard(label: label, value: value, icon: icon, color: color, sub: 'audit trail'),
      );

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final auditSummary = buildAuditSummary(rows.map((row) => {'action': row.action}).toList());

    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_capped)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warn.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Showing the newest $_rowCap entries for this period. '
                'Choose a shorter period to see older activity.',
              ),
            ),
          Row(children: [
            Text('Activity log', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(width: 12),
            Tooltip(
              message: 'Nothing here can be edited or deleted - it is the permanent record.',
              child: Icon(Icons.info_outline, size: 18, color: Theme.of(context).hintColor),
            ),
            const Spacer(),
            DropdownButton<String>(
              value: _action ?? '',
              items: _filters.entries
                  .map((e) => DropdownMenuItem(value: e.value, child: Text(e.key)))
                  .toList(),
              onChanged: (v) => setState(() => _action = v ?? ''),
            ),
            const SizedBox(width: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Today')),
                ButtonSegment(value: 7, label: Text('7 days')),
                ButtonSegment(value: 30, label: Text('30 days')),
              ],
              selected: {_days},
              onSelectionChanged: (s) {
                setState(() => _days = s.first);
                _load();
              },
            ),
          ]),
          const SizedBox(height: 8),
          Text('${rows.length} entries',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Compliance overview',
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              _stat('Entries', auditSummary.totalEntries.toString(), Icons.history, AppColors.info),
              _stat('PIN approvals', auditSummary.pinApprovals.toString(), Icons.verified_user_outlined, AppColors.warn),
              _stat('Stock adjustments', auditSummary.stockAdjustments.toString(), Icons.inventory_2_outlined, AppColors.info),
              _stat('Voids', auditSummary.cancellations.toString(), Icons.cancel_outlined, AppColors.danger),
              _stat('Refunds', auditSummary.refunds.toString(), Icons.assignment_return, AppColors.info),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Audit alerts',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final alert in auditSummary.complianceAlerts)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Icon(Icons.check_circle_outline, size: 17, color: AppColors.good),
                      const SizedBox(width: 8),
                      Expanded(child: Text(alert)),
                    ]),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Who did what',
            actions: [
              if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            ],
            child: rows.isEmpty
                ? const EmptyState(
                    icon: Icons.history,
                    title: 'Nothing recorded yet',
                    message: 'Sales, refunds, stock changes and approvals appear here as '
                        'they happen.',
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final r = rows[i];
                      final summary = r.summary;
                      return ListTile(
                        dense: true,
                        leading: Container(
                          width: 4,
                          height: 34,
                          decoration: BoxDecoration(
                            color: _colorFor(r.action),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        title: Text(
                          '${r.label}${summary.isEmpty ? '' : '  •  $summary'}',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                        ),
                        subtitle: Text(
                          '${r.actorName} (${r.actorRole})'
                          '${r.deviceName.isEmpty ? '' : '  on ${r.deviceName}'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Text(agoLabel(r.at),
                            style: Theme.of(context).textTheme.bodySmall),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
