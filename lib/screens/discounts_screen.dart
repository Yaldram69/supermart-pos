import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Super Admin / Admin surface: the rules that allow money off, and the limits
/// a cashier is held to.
class DiscountsScreen extends StatefulWidget {
  const DiscountsScreen({super.key});

  @override
  State<DiscountsScreen> createState() => _DiscountsScreenState();
}

class _DiscountsScreenState extends State<DiscountsScreen> {
  List<DiscountRule> _rules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final raw = await context.read<AppState>().api.discounts(all: true);
      setState(() => _rules = raw.map(DiscountRule.new).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(children: [
          SectionCard(
            child: Row(children: [
              const Icon(Icons.percent, size: 20),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'A code is typed at the till. A rule with “automatic” ticks on by itself when the bill '
                  'qualifies. “Needs manager” codes cannot be used by a cashier alone — the server refuses.',
                ),
              ),
              FilledButton.icon(
                onPressed: () => _edit(null),
                icon: const Icon(Icons.add),
                label: const Text('New discount'),
              ),
              const SizedBox(width: 8),
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            ]),
          ),
          const SizedBox(height: 12),
          _rules.isEmpty
              ? const EmptyState(icon: Icons.percent, title: 'No discount rules yet')
              : SectionCard(
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    child: DataTable(
                      showCheckboxColumn: false,
                      columns: const [
                        DataColumn(label: Text('Name')),
                        DataColumn(label: Text('Code')),
                        DataColumn(label: Text('Gives')),
                        DataColumn(label: Text('Min bill'), numeric: true),
                        DataColumn(label: Text('Cap'), numeric: true),
                        DataColumn(label: Text('Manager?')),
                        DataColumn(label: Text('Automatic?')),
                        DataColumn(label: Text('Used')),
                        DataColumn(label: Text('Live?')),
                        DataColumn(label: Text('')),
                      ],
                      rows: [
                        for (final r in _rules)
                          DataRow(
                            onSelectChanged: (_) => _edit(r),
                            cells: [
                              DataCell(Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                              DataCell(Text(r.code.isEmpty ? '—' : r.code)),
                              DataCell(Text(r.label)),
                              DataCell(Text(r.minSubtotal > 0 ? num2(r.minSubtotal) : '—')),
                              DataCell(Text(r.maxDiscount == null ? '—' : num2(r.maxDiscount))),
                              DataCell(Text(r.requiresManager ? 'yes' : 'no')),
                              DataCell(Text(r.auto ? 'yes' : 'no')),
                              DataCell(Text('${r.usedCount}${r.maxUses == null ? '' : ' / ${r.maxUses}'}')),
                              DataCell(StatusPill(
                                text: r.isActive ? 'active' : 'paused',
                                color: r.isActive ? AppColors.good : AppColors.warn,
                              )),
                              DataCell(
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                  onPressed: () async {
                                    final api = context.read<AppState>().api;
                                    if (!context.mounted) return;
                                    if (await confirm(context,
                                        title: 'Delete ${r.name}?',
                                        message: 'Existing invoices keep the discount they were given.',
                                        okLabel: 'Delete')) {
                                      try {
                                        await api.deleteDiscount(r.id);
                                        await _load();
                                      } catch (e) {
                                        if (context.mounted) showError(context, e);
                                      }
                                    }
                                  },
                                ),
                              ),
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

  Future<void> _edit(DiscountRule? existing) async {
    final state = context.read<AppState>();
    final name = TextEditingController(text: existing?.name ?? '');
    final code = TextEditingController(text: existing?.code ?? '');
    final value = TextEditingController(text: existing == null ? '' : num2(existing.value));
    final minSub = TextEditingController(text: existing == null ? '0' : num2(existing.minSubtotal));
    final cap = TextEditingController(text: existing?.maxDiscount == null ? '' : num2(existing!.maxDiscount!));
    final maxUses = TextEditingController(text: existing?.maxUses?.toString() ?? '');
    String kind = existing?.kind ?? 'percent';
    bool requiresManager = existing?.requiresManager ?? false;
    bool auto = existing?.auto ?? false;
    bool active = existing?.isActive ?? true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(existing == null ? 'New discount rule' : 'Edit ${existing.name}'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: name,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Name (shown to staff) *'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: code,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Code (optional)',
                        hintText: 'EID10',
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'percent', label: Text('% off')),
                        ButtonSegment(value: 'amount', label: Text('Rs off')),
                      ],
                      selected: {kind},
                      onSelectionChanged: (s) => setLocal(() => kind = s.first),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: value,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: kind == 'percent' ? 'Percent' : 'Rupees'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: minSub,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Minimum bill',
                        helperText: '0 = any bill',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: cap,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Maximum discount',
                        helperText: 'blank = no cap',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: maxUses,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Times it can be used',
                        helperText: 'blank = unlimited',
                      ),
                    ),
                  ),
                ]),
                SwitchListTile(
                  value: requiresManager,
                  onChanged: (v) => setLocal(() => requiresManager = v),
                  title: const Text('Only a manager can apply it'),
                  subtitle: const Text('Stops cashiers giving this away on their own'),
                ),
                SwitchListTile(
                  value: auto,
                  onChanged: (v) => setLocal(() => auto = v),
                  title: const Text('Applies automatically'),
                  subtitle: const Text('The till adds it as soon as the bill qualifies'),
                ),
                SwitchListTile(
                  value: active,
                  onChanged: (v) => setLocal(() => active = v),
                  title: const Text('Active'),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty) return;
                try {
                  await state.api.saveDiscount({
                    if (existing != null) 'id': existing.id,
                    'name': name.text.trim(),
                    'code': code.text.trim().isEmpty ? null : code.text.trim().toUpperCase(),
                    'kind': kind,
                    'value': parseAmount(value.text) ?? 0,
                    'scope': 'all',
                    'min_subtotal': parseAmount(minSub.text) ?? 0,
                    'max_discount': cap.text.trim().isEmpty ? null : parseAmount(cap.text),
                    'max_uses': maxUses.text.trim().isEmpty ? null : int.tryParse(maxUses.text),
                    'requires_manager': requiresManager,
                    'applies_automatically': auto,
                    'is_active': active,
                  });
                  await state.refreshReference();
                  if (c.mounted) Navigator.pop(c, true);
                } catch (e) {
                  if (c.mounted) showError(c, e);
                }
              },
              child: const Text('Save rule'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) await _load();
  }
}
