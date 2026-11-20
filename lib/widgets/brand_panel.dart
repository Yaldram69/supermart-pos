import 'package:flutter/material.dart';

import '../theme.dart';

/// The left-hand brand panel used on the sign-in and setup screens: the store
/// mark, a one-line promise and a few reasons the till is trustworthy.
class BrandPanel extends StatelessWidget {
  const BrandPanel({
    super.key,
    required this.headline,
    required this.lines,
    this.footer,
  });

  final String headline;
  final String? footer;
  final List<BrandLine> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ShellStyle.inkTop, ShellStyle.inkBottom, Color(0xFF0E5A4A)],
        ),
      ),
      child: Stack(children: [
        // soft glow behind the mark, for depth without an image asset
        Positioned(
          top: -120,
          right: -80,
          child: Container(
            width: 360,
            height: 360,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                ShellStyle.emerald.withValues(alpha: 0.35),
                ShellStyle.emerald.withValues(alpha: 0),
              ]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(56),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(colors: [ShellStyle.emerald, ShellStyle.emeraldDeep]),
                  boxShadow: [
                    BoxShadow(color: ShellStyle.emerald.withValues(alpha: 0.5), blurRadius: 26, offset: const Offset(0, 10)),
                  ],
                ),
                child: const Icon(Icons.storefront, color: Colors.white, size: 34),
              ),
              const SizedBox(height: 28),
              Text(
                'Supermart POS',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                headline,
                style: TextStyle(color: ShellStyle.mist.withValues(alpha: 0.9), fontSize: 17, height: 1.4),
              ),
              const SizedBox(height: 36),
              for (final line in lines) ...[
                _Feature(line: line),
                const SizedBox(height: 20),
              ],
              if (footer != null) ...[
                const Spacer(),
                Text(footer!, style: TextStyle(color: ShellStyle.mist.withValues(alpha: 0.6), fontSize: 12.5)),
              ],
            ],
          ),
        ),
      ]),
    );
  }
}

class BrandLine {
  const BrandLine(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}

class _Feature extends StatelessWidget {
  const _Feature({required this.line});
  final BrandLine line;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(line.icon, color: ShellStyle.emerald, size: 21),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 3),
            Text(line.body, style: TextStyle(color: ShellStyle.mist.withValues(alpha: 0.75), fontSize: 13.5, height: 1.4)),
          ],
        ),
      ),
    ]);
  }
}
