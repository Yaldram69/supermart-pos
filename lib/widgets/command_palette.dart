import 'package:flutter/material.dart';

/// One thing the palette can do: open a screen or run an action.
class PaletteItem {
  const PaletteItem({
    required this.title,
    required this.icon,
    required this.onRun,
    this.group = 'Go to',
    this.subtitle,
    this.keywords = '',
    this.shortcut,
  });

  final String title;
  final IconData icon;
  final VoidCallback onRun;
  final String group;
  final String? subtitle;
  /// Extra words that should match the search (e.g. "bill" for Billing).
  final String keywords;
  /// A key hint shown on the right, such as "F12".
  final String? shortcut;
}

/// Opens the command palette (Ctrl+K). Typing narrows the list; Enter runs the
/// top result; Escape closes. The palette scales in from the top of the window.
Future<void> showCommandPalette(BuildContext context, List<PaletteItem> items) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.32),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (c, _, _) => Align(
      alignment: const Alignment(0, -0.6),
      child: _CommandPalette(items: items, onDone: () => Navigator.pop(c)),
    ),
    transitionBuilder: (c, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(curved), child: child),
      );
    },
  );
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({required this.items, required this.onDone});
  final List<PaletteItem> items;
  final VoidCallback onDone;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _query = TextEditingController();
  String _text = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<PaletteItem> get _matches {
    final q = _text.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    final terms = q.split(RegExp(r'\s+'));
    return widget.items.where((i) {
      final hay = '${i.title} ${i.subtitle ?? ''} ${i.keywords} ${i.group}'.toLowerCase();
      return terms.every(hay.contains);
    }).toList();
  }

  void _run(PaletteItem item) {
    widget.onDone();
    // run after the palette has closed so the action sees the normal screen
    WidgetsBinding.instance.addPostFrameCallback((_) => item.onRun());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final matches = _matches;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 640,
        constraints: const BoxConstraints(maxHeight: 520),
        margin: const EdgeInsets.only(top: 40),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 40, offset: const Offset(0, 18)),
          ],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: TextField(
              controller: _query,
              autofocus: true,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: 'Jump to a screen or run an action…',
                prefixIcon: Icon(Icons.search, color: scheme.primary),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                suffixIcon: const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: _KeyChip('Esc'),
                ),
              ),
              onChanged: (v) => setState(() => _text = v),
              onSubmitted: (_) {
                if (matches.isNotEmpty) _run(matches.first);
              },
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          Flexible(
            child: matches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(40),
                    child: Text('Nothing matches "$_text"', style: TextStyle(color: scheme.outline)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                    shrinkWrap: true,
                    itemCount: matches.length,
                    itemBuilder: (c, i) {
                      final item = matches[i];
                      final showGroup = i == 0 || matches[i - 1].group != item.group;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (showGroup)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                              child: Text(
                                item.group.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 11,
                                  letterSpacing: 1.1,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.outline,
                                ),
                              ),
                            ),
                          _PaletteRow(item: item, highlighted: i == 0, onTap: () => _run(item)),
                        ],
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(22)),
            ),
            child: Row(children: [
              const _KeyChip('Enter'),
              const SizedBox(width: 8),
              Text('run the top result', style: TextStyle(fontSize: 12, color: scheme.outline)),
              const Spacer(),
              Text('${matches.length} result${matches.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({required this.item, required this.highlighted, required this.onTap});
  final PaletteItem item;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: highlighted ? scheme.primary.withValues(alpha: 0.08) : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: highlighted ? scheme.primary : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(item.icon, size: 19, color: highlighted ? scheme.onPrimary : scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  if (item.subtitle != null)
                    Text(item.subtitle!, style: TextStyle(fontSize: 12.5, color: scheme.outline)),
                ],
              ),
            ),
            if (item.shortcut != null) _KeyChip(item.shortcut!),
          ]),
        ),
      ),
    );
  }
}

/// A small keyboard-key look for hints like "Esc" or "F12".
class _KeyChip extends StatelessWidget {
  const _KeyChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
