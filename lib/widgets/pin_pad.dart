import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A touch-first numeric keypad for manager PINs.
///
/// The digits are shown as dots, never as numbers, so a bystander at the till
/// cannot read the PIN. It also takes the hardware keyboard: digits, Backspace
/// to delete, Enter to submit and Delete to clear.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.onSubmit,
    this.enabled = true,
    this.minDigits = 4,
    this.maxDigits = 8,
    this.submitLabel = 'Approve',
  });

  final ValueChanged<String> onSubmit;
  final bool enabled;
  final int minDigits;
  final int maxDigits;
  final String submitLabel;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  String _digits = '';
  final FocusNode _focus = FocusNode(debugLabel: 'pin-pad');

  /// Clears what has been typed (used after a wrong PIN).
  void clear() => setState(() => _digits = '');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _press(String digit) {
    if (!widget.enabled || _digits.length >= widget.maxDigits) return;
    setState(() => _digits += digit);
  }

  void _back() {
    if (!widget.enabled || _digits.isEmpty) return;
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  void _submit() {
    if (!widget.enabled || _digits.length < widget.minDigits) return;
    widget.onSubmit(_digits);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      _back();
    } else if (key == LogicalKeyboardKey.delete) {
      clear();
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _submit();
    } else {
      final ch = event.character;
      if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
        _press(ch);
      } else {
        return KeyEventResult.ignored;
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _digits.length < widget.minDigits ? widget.minDigits : _digits.length;
    final ready = _digits.length >= widget.minDigits;

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // dots, not digits
        Semantics(
          label: '${_digits.length} digits entered',
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < shown; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                width: i < _digits.length ? 16 : 12,
                height: i < _digits.length ? 16 : 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _digits.length ? scheme.primary : scheme.outlineVariant,
                ),
              ),
          ]),
        ),
        const SizedBox(height: AppSpacing.lg),
        GridView.count(
          shrinkWrap: true,
          crossAxisCount: 3,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.6,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (final d in const ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
              _Key(label: d, enabled: widget.enabled, onTap: () => _press(d)),
            _Key(
              label: 'Clear',
              small: true,
              enabled: widget.enabled,
              onTap: clear,
            ),
            _Key(label: '0', enabled: widget.enabled, onTap: () => _press('0')),
            _Key(
              icon: Icons.backspace_outlined,
              enabled: widget.enabled,
              onTap: _back,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: widget.enabled && ready ? _submit : null,
            icon: const Icon(Icons.verified_user_outlined),
            label: Text(widget.submitLabel),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          ),
        ),
      ]),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    this.label,
    this.icon,
    required this.enabled,
    required this.onTap,
    this.small = false,
  });

  final String? label;
  final IconData? icon;
  final bool enabled;
  final bool small;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: enabled ? scheme.surfaceContainerHighest : scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onTap : null,
        child: Center(
          child: icon != null
              ? Icon(icon, size: 26, color: scheme.onSurface)
              : Text(
                  label!,
                  style: TextStyle(
                    fontSize: small ? 15 : 26,
                    fontWeight: small ? FontWeight.w600 : FontWeight.w700,
                    color: enabled ? scheme.onSurface : scheme.outline,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
        ),
      ),
    );
  }
}
