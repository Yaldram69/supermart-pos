import 'package:flutter/material.dart';

import '../core/format.dart';
import '../theme.dart';

/// A number that glides to its new value instead of jumping. Used wherever
/// money changes while someone is watching: the amount due, dashboard tiles.
class CountUp extends StatelessWidget {
  const CountUp({
    super.key,
    required this.value,
    required this.format,
    this.style,
    this.duration = const Duration(milliseconds: 520),
  });

  final double value;
  final String Function(double) format;
  final TextStyle? style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Text(
        format(v),
        style: style?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]) ??
            const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
    );
  }
}

/// The amount due on the till: a gradient panel with the total as the hero
/// figure, so the one number that matters is the first thing a cashier sees.
class AmountDueCard extends StatelessWidget {
  const AmountDueCard({
    super.key,
    required this.total,
    required this.symbol,
    required this.items,
    required this.units,
    this.discount,
  });

  final double total;
  final String symbol;
  final int items;
  final double units;
  /// Optional line under the figure, e.g. "You saved Rs 40".
  final String? discount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ShellStyle.inkTop, ShellStyle.inkBottom, Color(0xFF0E5A4A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(
              'AMOUNT DUE',
              style: TextStyle(
                color: ShellStyle.mist.withValues(alpha: 0.75),
                fontSize: 11.5,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            Text(
              '$items ${items == 1 ? 'item' : 'items'} · ${qtyStr(units)} units',
              style: TextStyle(color: ShellStyle.mist.withValues(alpha: 0.7), fontSize: 12),
            ),
          ]),
          const SizedBox(height: 8),
          CountUp(
            value: total,
            format: (v) => money(v, symbol: symbol),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 40,
              height: 1.05,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          if (discount != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF34D399).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                discount!,
                style: const TextStyle(color: Color(0xFF6EE7B7), fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A dashboard tile with a count-up figure and a quiet accent bar.
class PremiumStat extends StatelessWidget {
  const PremiumStat({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.sub,
    this.format,
  });

  final String label;
  final double value;
  final IconData icon;
  final Color color;
  final String? sub;
  final String Function(double)? format;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: scheme.outline, fontSize: 12.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              CountUp(
                value: value,
                format: format ?? (v) => v.round().toString(),
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: scheme.onSurface),
              ),
              if (sub != null)
                Text(sub!, style: TextStyle(color: scheme.outline, fontSize: 11.5)),
            ],
          ),
        ),
      ]),
    );
  }
}
