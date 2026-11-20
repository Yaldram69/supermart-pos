import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_config.dart';
import '../main.dart';
import '../services/api.dart';
import '../theme.dart';
import '../widgets/brand_panel.dart';

/// Shown only on the very first run on a PC. The two values come from your
/// Supabase project: Settings > API.
class SetupGate extends StatefulWidget {
  const SetupGate({super.key});

  @override
  State<SetupGate> createState() => _SetupGateState();
}

class _SetupGateState extends State<SetupGate> {
  final _url = TextEditingController(text: AppConfig.url);
  final _key = TextEditingController(text: AppConfig.anonKey);
  final _device = TextEditingController(text: AppConfig.deviceName.isEmpty ? 'Counter-1' : AppConfig.deviceName);
  final _terminal = TextEditingController(text: AppConfig.terminalNo.toString());
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  bool _showKey = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _device.dispose();
    _terminal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MaterialApp(
      title: 'Supermart POS setup',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: Scaffold(
        body: Row(children: [
          Expanded(
            flex: 5,
            child: BrandPanel(
              headline: 'Set this till up once. It takes about two minutes.',
              lines: const [
                BrandLine(Icons.key_outlined, 'Two values from Supabase',
                    'The project address and the public anon key, from Settings > API.'),
                BrandLine(Icons.fact_check_outlined, 'Checked before it is saved',
                    'We contact your project first, so a typo is caught here, not at the counter.'),
                BrandLine(Icons.computer_outlined, 'Same on every counter',
                    'Only the till name and terminal number change between PCs.'),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: Container(
              color: scheme.surface,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(40),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Set up this till',
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          Text('Do this once on each PC.',
                              style: TextStyle(color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 28),
                          TextFormField(
                            controller: _url,
                            keyboardType: TextInputType.url,
                            decoration: const InputDecoration(
                              labelText: 'Supabase project URL',
                              hintText: 'https://xxxxxxxxxxxx.supabase.co',
                              prefixIcon: Icon(Icons.link),
                            ),
                            validator: (v) {
                              final url = AppConfig.normalizeUrl(v ?? '');
                              if (url.isEmpty || !url.startsWith('https://')) {
                                return 'Paste the https:// URL from Supabase';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _key,
                            obscureText: !_showKey,
                            maxLines: _showKey ? 2 : 1,
                            decoration: InputDecoration(
                              labelText: 'Supabase anon public key',
                              hintText: 'eyJhbGciOi…',
                              prefixIcon: const Icon(Icons.vpn_key_outlined),
                              suffixIcon: IconButton(
                                tooltip: _showKey ? 'Hide key' : 'Show key',
                                icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                                onPressed: () => setState(() => _showKey = !_showKey),
                              ),
                            ),
                            validator: (v) => (v == null || v.trim().length < 40) ? 'Paste the anon key' : null,
                          ),
                          const SizedBox(height: 24),
                          Row(children: [
                            Expanded(
                              child: TextFormField(
                                controller: _device,
                                decoration: const InputDecoration(
                                  labelText: 'Name of this PC',
                                  hintText: 'Counter-1',
                                  prefixIcon: Icon(Icons.desktop_windows_outlined),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Give the till a name' : null,
                              ),
                            ),
                            const SizedBox(width: 16),
                            SizedBox(
                              width: 120,
                              child: TextFormField(
                                controller: _terminal,
                                decoration: const InputDecoration(labelText: 'Terminal #'),
                                keyboardType: TextInputType.number,
                              ),
                            ),
                          ]),
                          AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            child: _error == null
                                ? const SizedBox(width: double.infinity)
                                : Padding(
                                    padding: const EdgeInsets.only(top: 16),
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: AppColors.danger.withValues(alpha: 0.08),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: AppColors.danger.withValues(alpha: 0.25)),
                                      ),
                                      child: Text(_error!,
                                          style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600)),
                                    ),
                                  ),
                          ),
                          const SizedBox(height: 26),
                          FilledButton.icon(
                            onPressed: _busy ? null : _save,
                            icon: _busy
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary))
                                : const Icon(Icons.play_arrow_rounded),
                            label: Text(_busy ? 'Checking the server…' : 'Save and start'),
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Test the two values against the real server first: this catches the
      // common mistake of pasting .../rest/v1 on the end of the URL, which
      // makes every later request fail with a 404.
      final problem = await Api.checkServer(_url.text, _key.text);
      if (!mounted) return;
      if (problem != null) {
        setState(() {
          _busy = false;
          _error = problem;
        });
        return;
      }
      await AppConfig.saveConnection(_url.text, _key.text);
      await AppConfig.saveDevice(
        _device.text,
        int.tryParse(_terminal.text.trim()) ?? 1,
      );
      // same start-up as a normal launch, including the encrypted session store
      await Api.initializeClient();
      if (!mounted) return;
      runApp(SupermartApp(api: Api(Supabase.instance.client)));
    } catch (e) {
      // the detail goes to the console for support; the cashier sees a plain sentence
      debugPrint('Setup could not finish: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not connect. Check the internet connection and the two values, then try again.';
      });
    }
  }
}
