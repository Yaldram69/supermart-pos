import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_config.dart';
import '../core/format.dart';
import '../services/api.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'pin_pad.dart';

/// A small helper so every screen reports errors (and successes) the same way.
void showMessage(BuildContext context, String text, {bool error = false}) {
  final messenger = ScaffoldMessenger.of(context);
  // The newest message replaces the old one instead of queueing behind it.
  messenger.clearSnackBars();
  messenger.showSnackBar(SnackBar(
    content: Text(text),
    backgroundColor: error ? AppColors.danger : null,
    duration: Duration(seconds: error ? 6 : 3),
  ));
}

void showError(BuildContext context, Object e) =>
    showMessage(context, e is AppError ? e.message : e.toString(), error: true);

Future<bool> confirm(BuildContext context,
    {required String title, required String message, String okLabel = 'Yes, continue'}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      title: Text(title),
      content: Text(message),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(okLabel)),
      ],
    ),
  );
  return res ?? false;
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.actions = const [],
    this.headerContent,
    this.padding = const EdgeInsets.all(16),
    this.expand = false,
  });

  final Widget child;
  final String? title;
  final List<Widget> actions;
  final Widget? headerContent;
  final EdgeInsets padding;
  /// Set when the card sits in a bounded column and its child uses [Spacer] or
  /// [Expanded] to pin content to the bottom. Without it, a Column gives its
  /// children unbounded height and the layout throws.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null || headerContent != null || actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (title != null)
                      Text(
                        title!,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    if (headerContent != null) ...[
                      const SizedBox(width: 12),
                      // callers may pass an Expanded already; a second one inside it breaks layout
                      headerContent is Expanded ? headerContent! : Expanded(child: headerContent!),
                    ],
                    if (actions.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      ...actions,
                    ],
                  ],
                ),
              ),
            expand ? Expanded(child: child) : child,
          ],
        ),
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.icon,
    this.color,
  });

  final String label;
  final String value;
  final String? sub;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // No Expanded here: a card can sit in a Row (where its width is not
            // bounded), and an Expanded inside would throw. The label ellipsises
            // within the width the card is given.
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: c),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12.5),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700, color: c, fontSize: 22),
              overflow: TextOverflow.ellipsis,
            ),
            if (sub != null) ...[
              const SizedBox(height: 3),
              Text(
                sub!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message});

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 54, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(message!, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      );
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, required this.color, this.icon});

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 5)],
          Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      );
}

class KeyValue extends StatelessWidget {
  const KeyValue({super.key, required this.k, required this.v, this.bold = false, this.color});

  final String k;
  final String v;
  final bool bold;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(k, style: Theme.of(context).textTheme.bodyMedium)),
            Text(v,
                style: TextStyle(
                  fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          ],
        ),
      );
}

/// Quantity spinner used in the cart and purchase screens.
class QtyStepper extends StatelessWidget {
  const QtyStepper({
    super.key,
    required this.qty,
    required this.onChanged,
    this.step = 1,
    this.decimals = 3,
  });

  final double qty;
  final ValueChanged<double> onChanged;
  /// 1 for pieces; use a smaller step for weighed goods.
  final double step;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    // Minus stops at the smallest step. Removing a line is a deliberate
    // action (the bin icon), never an accidental side effect of "-".
    final canDecrease = qty - step > 0.0001;
    const touch = BoxConstraints.tightFor(width: 44, height: 44);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'Less',
        constraints: touch,
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: canDecrease ? () => onChanged(qty - step) : null,
      ),
      SizedBox(
        width: 52,
        child: Text(qtyStr(qty), textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ),
      IconButton(
        tooltip: 'More',
        constraints: touch,
        icon: const Icon(Icons.add_circle_outline),
        onPressed: () => onChanged(qty + step),
      ),
    ]);
  }
}

/// Asks for a manager PIN when the server refuses an action that a manager may
/// approve (a discount over the cashier's limit, cancelling a bill, a refund).
/// Returns the typed PIN, or null when the manager cancelled.
/// The PIN is only ever sent to the server together with the action, and the
/// server records who approved it in the activity log.
/// Asks a manager to approve an action with their PIN. The PIN is checked on the
/// server before this returns, so a wrong PIN never reaches the sale, and the
/// server counts wrong tries (five in 15 minutes locks the cashier out).
/// Returns the verified PIN, or null when cancelled.
Future<String?> askManagerPin(BuildContext context, String reason, {String title = 'Manager approval'}) {
  final api = Provider.of<AppState>(context, listen: false).api;
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ManagerApprovalDialog(api: api, reason: reason, title: title),
  );
}

class _ManagerApprovalDialog extends StatefulWidget {
  const _ManagerApprovalDialog({required this.api, required this.reason, required this.title});
  final Api api;
  final String reason;
  final String title;

  @override
  State<_ManagerApprovalDialog> createState() => _ManagerApprovalDialogState();
}

class _ManagerApprovalDialogState extends State<_ManagerApprovalDialog> {
  final _pad = GlobalKey<PinPadState>();
  bool _busy = false;
  String? _message;
  bool _locked = false;
  DateTime? _lockedUntil;
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    // refreshes the "wait N minutes" line while locked out
    _countdown = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && _locked) setState(() {});
    });
  }

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _verify(String pin) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final res = await widget.api.verifyManagerPin(pin, AppConfig.deviceName);
      if (!mounted) return;
      if (res['ok'] == true) {
        Navigator.pop(context, pin);
        return;
      }
      final locked = res['locked'] == true;
      final left = (res['attempts_left'] as num?)?.toInt();
      setState(() {
        _busy = false;
        _locked = locked;
        _lockedUntil = DateTime.tryParse(res['locked_until']?.toString() ?? '')?.toLocal();
        _message = locked
            ? 'Too many wrong PINs. Wait 15 minutes, or ask the manager to approve it themselves.'
            : 'That PIN is not right.${left == null ? '' : ' $left ${left == 1 ? 'try' : 'tries'} left before a 15-minute lock.'}';
      });
      _pad.currentState?.clear();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = e is AppError ? e.message : 'Could not check the PIN. Check the connection and try again.';
      });
      _pad.currentState?.clear();
    }
  }

  String _waitText() {
    final until = _lockedUntil;
    if (until == null) return 'a few minutes';
    final mins = until.difference(DateTime.now()).inMinutes + 1;
    if (mins <= 0) return 'a moment';
    return mins == 1 ? '1 minute' : '$mins minutes';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warn.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.lock_outline, color: AppColors.warn),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 12),
            Text(widget.reason, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            if (_locked)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(children: [
                  Icon(Icons.timer_outlined, color: AppColors.danger, size: 30),
                  SizedBox(height: 8),
                  Text('Locked for ${_waitText()}',
                      style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.danger)),
                ]),
              )
            else
              PinPad(
                key: _pad,
                enabled: !_busy,
                submitLabel: _busy ? 'Checking…' : 'Approve',
                onSubmit: _verify,
              ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _message == null
                  ? const SizedBox(height: 0, key: ValueKey('none'))
                  : Text(
                      _message!,
                      key: ValueKey(_message),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _locked ? AppColors.danger : scheme.error,
                      ),
                    ),
            ),
            const SizedBox(height: 4),
            Text(
              'Every approval is written to the Activity log with who gave it.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ]),
        ),
      ),
    );
  }
}

/// True when a refusal means "a manager can approve this" rather than
/// "this is simply not allowed".
bool needsManagerApproval(AppError e) =>
    e.code == 'DISCOUNT_LIMIT' ||
    e.code == 'NOT_ALLOWED' ||
    e.code == 'PIN_WRONG' ||
    e.code == 'CODE_NEEDS_MANAGER';

/// A small heading that separates blocks inside a long form.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11.5,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).hintColor,
          ),
        ),
      );
}
