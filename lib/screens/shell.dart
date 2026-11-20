import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/app_config.dart';
import '../core/format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/command_palette.dart';
import '../widgets/common.dart';
import '../widgets/sync_dialog.dart';
import 'customers_screen.dart';
import 'discounts_screen.dart';
import 'employees_screen.dart';
import 'invoices_screen.dart';
import 'pos_screen.dart';
import 'products_screen.dart';
import 'reports_screen.dart';
import 'expiry_screen.dart';
import 'insights_screen.dart';
import 'purchase_returns_screen.dart';
import 'settings_screen.dart';
import 'stock_screen.dart';
import 'expenses_screen.dart';
import 'activity_screen.dart';
import 'suppliers_screen.dart';
import 'stock_take_screen.dart';

Future<void> openShiftDialog(BuildContext context, AppState state) async {
  if (!state.hasOpenShift) {
    final controller = TextEditingController(text: '0');
    final started = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Open shift'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('How much cash is in the drawer to start with?'),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Opening cash float (Rs)'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Start shift'),
          ),
        ],
      ),
    );
    if (started != true) return;
    try {
      await state.openShift(parseAmount(controller.text) ?? 0);
      if (context.mounted) showMessage(context, 'Shift opened — happy selling!');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
    return;
  }

  final report = await context.read<AppState>().api.shiftSummary(state.shift!.id);
  final counted = TextEditingController();
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Cash up — ${state.shift!.shiftNo}'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          KeyValue(k: 'Invoices', v: num2(report['invoice_count'])),
          KeyValue(k: 'Total sales', v: money(report['gross_sales'])),
          KeyValue(k: 'Cash sales', v: money(report['cash_sales'])),
          KeyValue(k: 'Card / wallet', v: money(report['card_sales'])),
          KeyValue(k: 'Credit (udhaar)', v: money(report['credit_sales'])),
          KeyValue(k: 'Refunds', v: money(report['refunds'])),
          const Divider(height: 16),
          KeyValue(k: 'Expected in drawer', v: money(report['expected_cash']), bold: true),
          const SizedBox(height: 12),
          TextField(
            controller: counted,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Cash counted in drawer (Rs)'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            Navigator.pop(c);
            try {
              final res = await context.read<AppState>().closeShift(parseAmount(counted.text) ?? 0, null);
              final diff = toD(res['difference']);
              if (context.mounted) {
                showMessage(
                  context,
                  diff == 0
                      ? 'Shift closed — the drawer balances exactly.'
                      : 'Shift closed. Difference: ${money(diff)} ${diff < 0 ? "(short)" : "(over)"}',
                  error: diff.abs() > 0.01,
                );
              }
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          child: const Text('Close shift'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- the frame

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    final pages = <_Dest>[
      _Dest('Billing', 'Sell', Icons.point_of_sale, const PosScreen(), keywords: 'sale bill till charge cart'),
      _Dest('Invoices', 'Sell', Icons.receipt_long, const InvoicesScreen(), keywords: 'reprint refund cancel bills'),
      _Dest('Customers', 'Sell', Icons.people_outline, const CustomersScreen(), keywords: 'udhaar credit khata ledger'),
      _Dest('Products', 'Stock', Icons.inventory_2_outlined, const ProductsScreen(),
          visible: state.canAdjustStock, keywords: 'items prices barcode add'),
      _Dest('Stock & purchases', 'Stock', Icons.warehouse_outlined, const StockScreen(),
          visible: state.canAdjustStock, keywords: 'receive delivery purchase order reorder'),
      _Dest('Stock take', 'Stock', Icons.fact_check_outlined, const StockTakeScreen(),
          visible: state.canAdjustStock, keywords: 'count audit variance'),
      _Dest('Expiry & batches', 'Stock', Icons.event_busy_outlined, const ExpiryScreen(),
          visible: state.canAdjustStock, keywords: 'expired batch write off'),
      _Dest('Returns to supplier', 'Stock', Icons.keyboard_return, const PurchaseReturnsScreen(),
          visible: state.canAdjustStock, keywords: 'damaged send back'),
      _Dest('Suppliers', 'Stock', Icons.local_shipping_outlined, const SuppliersScreen(),
          visible: state.canAdjustStock, keywords: 'payable pay supplier'),
      _Dest('Expenses', 'Stock', Icons.account_balance_wallet_outlined, const ExpensesScreen(),
          visible: state.canAdjustStock, keywords: 'spend bill rent electricity'),
      _Dest('Reports', 'Insight', Icons.insights, const ReportsScreen(),
          visible: state.canAdjustStock, keywords: 'sales profit day close'),
      _Dest('Owner reports', 'Insight', Icons.insights_outlined, const InsightsScreen(),
          visible: state.canAdjustStock, keywords: 'margin dead stock performance'),
      _Dest('Discounts', 'Insight', Icons.percent, const DiscountsScreen(),
          visible: state.canApproveDiscount, keywords: 'codes offers coupons'),
      _Dest('Activity log', 'Insight', Icons.history, const ActivityScreen(),
          visible: state.canApproveDiscount, keywords: 'audit who did what'),
      _Dest('Employees', 'Team', Icons.badge_outlined, const EmployeesScreen(),
          visible: state.canManageStaff, keywords: 'staff role pin cashier'),
      _Dest('Settings', 'Team', Icons.settings_outlined, const SettingsScreen(),
          visible: state.canOpenSettings || !state.signedIn, keywords: 'printer tax receipt store scale'),
    ].where((d) => d.visible).toList();

    if (pages.isEmpty) {
      return const Scaffold(body: EmptyState(icon: Icons.lock_outline, title: 'Nothing is open for this login'));
    }

    // Clamp instead of resetting state during build (that throws in Flutter).
    final index = state.navIndex.clamp(0, pages.length - 1);
    if (index != state.navIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) => state.setNavIndex(index));
    }
    final current = pages[index];

    final width = MediaQuery.sizeOf(context).width;
    final expanded = width >= 1240;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showCommandPalette(context, _paletteItems(context, state, pages)),
      },
      child: Scaffold(
        body: Row(
          children: [
            _NavRail(
              pages: pages,
              index: index,
              expanded: expanded,
              onSelect: (i) => state.setNavIndex(i),
            ),
            Expanded(
              child: Column(
                children: [
                  _TopBar(
                    title: current.label,
                    group: current.group,
                    onSearch: () => showCommandPalette(context, _paletteItems(context, state, pages)),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      // The default switcher stack centres a shorter page vertically,
                      // which pushed every short screen down. Pages fill the area and
                      // start at the top, as they are designed to.
                      layoutBuilder: (current, previous) => Stack(
                        fit: StackFit.expand,
                        alignment: Alignment.topLeft,
                        children: [...previous, ?current],
                      ),
                      duration: const Duration(milliseconds: 240),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween(begin: const Offset(0.015, 0), end: Offset.zero).animate(anim),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(key: ValueKey(current.label), child: current.page),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<PaletteItem> _paletteItems(BuildContext context, AppState state, List<_Dest> pages) {
    return [
      for (var i = 0; i < pages.length; i++)
        PaletteItem(
          title: pages[i].label,
          subtitle: pages[i].group,
          icon: pages[i].icon,
          keywords: pages[i].keywords,
          group: 'Go to',
          onRun: () => state.setNavIndex(i),
        ),
      PaletteItem(
        title: state.hasOpenShift ? 'Cash up and close shift' : 'Open a shift',
        subtitle: state.hasOpenShift ? 'Count the drawer and close' : 'Start the day with a cash float',
        icon: state.hasOpenShift ? Icons.lock_outline : Icons.lock_open_outlined,
        keywords: 'shift drawer cash float open close',
        group: 'Actions',
        onRun: () => openShiftDialog(context, state),
      ),
      PaletteItem(
        title: 'Refresh stock now',
        subtitle: 'Pull the latest catalogue from the server',
        icon: Icons.sync,
        keywords: 'reload update catalogue',
        group: 'Actions',
        onRun: () async {
          await state.refreshCatalogue();
          if (context.mounted) showMessage(context, 'Catalogue refreshed from the server');
        },
      ),
      PaletteItem(
        title: 'Sync waiting sales',
        subtitle: state.pendingOffline > 0 ? '${state.pendingOffline} waiting' : 'Nothing is waiting',
        icon: Icons.cloud_upload_outlined,
        keywords: 'offline queue send',
        group: 'Actions',
        onRun: () => showSyncDialog(context),
      ),
      PaletteItem(
        title: 'Sign out',
        subtitle: 'Leave this till for the next person',
        icon: Icons.logout,
        keywords: 'logout exit switch user',
        group: 'Actions',
        onRun: () => _signOut(context, state),
      ),
    ];
  }

  Future<void> _signOut(BuildContext context, AppState state) async {
    final pending = state.pendingOffline;
    final sure = await confirm(
      context,
      title: 'Sign out of this till?',
      message: pending > 0
          ? '$pending sale${pending == 1 ? ' is' : 's are'} still waiting to send. They stay on this PC, but sync only after the next sign-in.'
          : 'The next cashier signs in with their own login.',
      okLabel: 'Sign out',
    );
    if (sure && context.mounted) await state.signOut();
  }
}

class _Dest {
  _Dest(this.label, this.group, this.icon, this.page, {this.visible = true, this.keywords = ''});
  final String label;
  final String group;
  final IconData icon;
  final Widget page;
  final bool visible;
  final String keywords;
}

class _NavRail extends StatelessWidget {
  const _NavRail({required this.pages, required this.index, required this.expanded, required this.onSelect});
  final List<_Dest> pages;
  final int index;
  final bool expanded;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final id = state.identity;
    final width = expanded ? ShellStyle.railExpanded : ShellStyle.railCollapsed;

    // sections in the order they first appear, with their items
    final sections = <String, List<int>>{};
    for (var i = 0; i < pages.length; i++) {
      (sections[pages[i].group] ??= []).add(i);
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: width,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ShellStyle.inkTop, ShellStyle.inkBottom],
        ),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Brand(expanded: expanded, name: state.store?.name ?? 'Supermart'),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                children: [
                  for (final entry in sections.entries) ...[
                    if (expanded)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                        child: Text(
                          entry.key.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10.5,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.w700,
                            color: ShellStyle.mist.withValues(alpha: 0.5),
                          ),
                        ),
                      )
                    else
                      const SizedBox(height: 16),
                    for (final i in entry.value)
                      _NavItem(
                        dest: pages[i],
                        selected: i == index,
                        expanded: expanded,
                        onTap: () => onSelect(i),
                      ),
                  ],
                ],
              ),
            ),
            _Profile(expanded: expanded, name: id?.fullName ?? '', role: id?.roleLabel ?? '', online: state.online),
          ],
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.expanded, required this.name});
  final bool expanded;
  final String name;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(colors: [ShellStyle.emerald, ShellStyle.emeraldDeep]),
        boxShadow: [
          BoxShadow(color: ShellStyle.emerald.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 6)),
        ],
      ),
      child: const Icon(Icons.storefront, color: Colors.white, size: 22),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(expanded ? 18 : 0, 18, expanded ? 18 : 0, 8),
      child: expanded
          ? Row(children: [
              mark,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                    Text('POS', style: TextStyle(color: ShellStyle.mist.withValues(alpha: 0.7), fontSize: 11.5, letterSpacing: 1.2)),
                  ],
                ),
              ),
            ])
          : Center(child: mark),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.dest, required this.selected, required this.expanded, required this.onTap});
  final _Dest dest;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final fg = selected ? Colors.white : ShellStyle.mist.withValues(alpha: _hover ? 0.95 : 0.78);

    final content = Row(
      mainAxisAlignment: widget.expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
      children: [
        Icon(widget.dest.icon, size: 21, color: fg),
        if (widget.expanded) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.dest.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: _withTooltip(widget.expanded ? null : widget.dest.label, AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: selected
                  ? const LinearGradient(colors: [ShellStyle.emerald, ShellStyle.emeraldDeep])
                  : null,
              color: !selected && _hover ? Colors.white.withValues(alpha: 0.07) : null,
              boxShadow: selected
                  ? [BoxShadow(color: ShellStyle.emerald.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6))]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: widget.onTap,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: widget.expanded ? 12 : 0, vertical: 11),
                  child: content,
                ),
              ),
            ),
          ), // AnimatedContainer
        ), // _withTooltip
      ),
    );
  }

  /// The label appears as a tooltip only when the rail is collapsed to icons.
  Widget _withTooltip(String? message, Widget child) => message == null
      ? child
      : Tooltip(message: message, waitDuration: const Duration(milliseconds: 300), child: child);
}

class _Profile extends StatelessWidget {
  const _Profile({required this.expanded, required this.name, required this.role, required this.online});
  final bool expanded;
  final String name;
  final String role;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    final avatar = Stack(children: [
      CircleAvatar(
        radius: 17,
        backgroundColor: ShellStyle.emerald,
        child: Text(initial, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      ),
      Positioned(
        right: 0,
        bottom: 0,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: online ? const Color(0xFF34D399) : AppColors.danger,
            shape: BoxShape.circle,
            border: Border.all(color: ShellStyle.inkBottom, width: 2),
          ),
        ),
      ),
    ]);
    return Container(
      margin: EdgeInsets.fromLTRB(10, 6, 10, 12),
      padding: EdgeInsets.all(expanded ? 10 : 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
      ),
      child: expanded
          ? Row(children: [
              avatar,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5)),
                    Text(role,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: ShellStyle.mist.withValues(alpha: 0.7), fontSize: 11.5)),
                  ],
                ),
              ),
            ])
          : Center(child: avatar),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.group, required this.onSearch});
  final String title;
  final String group;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 1240;

    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
      ),
      child: Row(children: [
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(group.toUpperCase(),
                style: TextStyle(fontSize: 10.5, letterSpacing: 1.3, fontWeight: FontWeight.w700, color: scheme.outline)),
            Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
        const Spacer(),
        // the palette: one search for screens, actions and shortcuts
        Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onSearch,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                if (!compact)
                  Text('Search or jump to…', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5)),
                if (!compact) const SizedBox(width: 24),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Text('Ctrl K', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
                ),
              ]),
            ),
          ),
        ),
        SizedBox(width: 16),
        if (!compact) ...[
          if (state.online)
            StatusPill(text: 'Live', color: AppColors.good, icon: Icons.cloud_done_outlined)
          else
            StatusPill(text: 'Offline', color: AppColors.danger, icon: Icons.cloud_off_outlined),
          const SizedBox(width: 8),
        ],
        if (state.pendingOffline > 0 || state.refusedSales.isNotEmpty)
          GestureDetector(
            onTap: () => showSyncDialog(context),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (state.pendingOffline > 0)
                StatusPill(
                  text: '${state.pendingOffline} to send',
                  color: AppColors.warn,
                  icon: Icons.upload_outlined,
                ),
              if (state.refusedSales.isNotEmpty) ...[
                const SizedBox(width: 8),
                StatusPill(
                  text: '${state.refusedSales.length} refused',
                  color: AppColors.danger,
                  icon: Icons.error_outline,
                ),
              ],
            ]),
          ),
        const SizedBox(width: 8),
        if (state.hasOpenShift)
          StatusPill(
            text: compact ? 'Shift open' : 'Shift ${state.shift?.shiftNo ?? ''} open',
            color: AppColors.good,
            icon: Icons.lock_open_outlined,
          )
        else
          StatusPill(text: compact ? 'No shift' : 'No shift open', color: AppColors.warn, icon: Icons.lock_outline),
        const SizedBox(width: 8),
        const _AppearanceButton(),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: state.hasOpenShift ? 'Close shift / cash up' : 'Open shift with a cash float',
          icon: Icon(state.hasOpenShift ? Icons.lock_outline : Icons.lock_open_outlined),
          onPressed: () => openShiftDialog(context, state),
        ),
        const SizedBox(width: 8),
        _ProfileMenu(),
      ]),
    );
  }
}

/// Light, dark or follow Windows. The icon shows the look currently in use.
class _AppearanceButton extends StatelessWidget {
  const _AppearanceButton();

  static const _options = [
    (ThemeMode.light, 'Light', Icons.light_mode_outlined),
    (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
    (ThemeMode.system, 'Match Windows', Icons.brightness_auto_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final mode = state.themeMode;
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<ThemeMode>(
      tooltip: 'Appearance: light or dark',
      initialValue: mode,
      offset: const Offset(0, 46),
      onSelected: state.setThemeMode,
      icon: Icon(AppColors.dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
      itemBuilder: (c) => [
        for (final (value, label, icon) in _options)
          PopupMenuItem<ThemeMode>(
            value: value,
            child: Row(children: [
              Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (value == mode) Icon(Icons.check_rounded, size: 18, color: scheme.primary),
            ]),
          ),
      ],
    );
  }
}

class _ProfileMenu extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final id = state.identity;
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: 'Account and till',
      offset: const Offset(0, 46),
      onSelected: (v) async {
        if (v == 'signout') {
          final pending = state.pendingOffline;
          final sure = await confirm(
            context,
            title: 'Sign out of this till?',
            message: pending > 0
                ? '$pending sale${pending == 1 ? ' is' : 's are'} still waiting to send.'
                : 'The next cashier signs in with their own login.',
            okLabel: 'Sign out',
          );
          if (sure && context.mounted) await state.signOut();
        } else if (v == 'refresh') {
          await state.refreshCatalogue();
          if (context.mounted) showMessage(context, 'Catalogue refreshed from the server');
        } else if (v == 'layout') {
          final sure = await confirm(
            context,
            title: 'Change this till\'s server settings?',
            message: 'The till forgets its Supabase address and key. You will enter them again on the next start.',
            okLabel: 'Change settings',
          );
          if (!sure) return;
          await AppConfig.clearConnection();
          if (context.mounted) {
            showMessage(context, 'Server settings cleared — restart the app to change them');
          }
        }
      },
      itemBuilder: (c) => [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(id?.fullName ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(id?.roleLabel ?? '', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'refresh', child: ListTile(leading: Icon(Icons.sync), title: Text('Refresh stock now'), dense: true, contentPadding: EdgeInsets.zero)),
        const PopupMenuItem(value: 'layout', child: ListTile(leading: Icon(Icons.dns_outlined), title: Text('Change server / till settings'), dense: true, contentPadding: EdgeInsets.zero)),
        const PopupMenuItem(value: 'signout', child: ListTile(leading: Icon(Icons.logout), title: Text('Sign out'), dense: true, contentPadding: EdgeInsets.zero)),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: scheme.primaryContainer.withValues(alpha: 0.6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: scheme.primary,
            child: Text(
              (id?.fullName ?? '?').characters.first.toUpperCase(),
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Text(id?.fullName ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
          const Icon(Icons.arrow_drop_down),
        ]),
      ),
    );
  }
}
