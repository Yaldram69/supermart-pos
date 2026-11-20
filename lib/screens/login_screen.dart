import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_config.dart';
import '../core/format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/brand_panel.dart';
import '../widgets/common.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController(text: AppConfig.lastUser);
  final _password = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 5,
            child: BrandPanel(
              headline: 'One shop, four counters, one live stock count.',
              lines: const [
                BrandLine(Icons.sync, 'Live across every till',
                    'A sale on one counter updates the shelf count on all of them.'),
                BrandLine(Icons.wifi_off, 'Keeps selling when the internet drops',
                    'Sales are held on the till and sent as soon as the link returns.'),
                BrandLine(Icons.verified_user_outlined, 'Every approval is on record',
                    'Discounts, voids and refunds name the person who approved them.'),
              ],
              footer: 'This till: ${AppConfig.deviceName}  •  Terminal ${AppConfig.terminalNo}',
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
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Welcome back',
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text('Sign in with the staff login the owner gave you.',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                        const SizedBox(height: 30),
                        TextField(
                          controller: _email,
                          autofocus: true,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.alternate_email),
                          ),
                          onSubmitted: (_) => _signIn(state),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _password,
                          obscureText: !_show,
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              tooltip: _show ? 'Hide password' : 'Show password',
                              icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                              onPressed: () => setState(() => _show = !_show),
                            ),
                          ),
                          onSubmitted: (_) => _signIn(state),
                        ),
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
                                    child: Row(children: [
                                      Icon(Icons.error_outline, color: AppColors.danger),
                                      SizedBox(width: 12),
                                      Expanded(
                                        child: Text(_error!,
                                            style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600)),
                                      ),
                                    ]),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _signIn(state),
                          icon: _busy
                              ? SizedBox(
                                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary))
                              : const Icon(Icons.login),
                          label: Text(_busy ? 'Signing in…' : 'Sign in'),
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: TextButton.icon(
                            onPressed: () => _changeServer(context),
                            icon: const Icon(Icons.dns_outlined, size: 18),
                            label: const Text('Change server settings for this PC'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text('Version ${AppConfig.appVersion}',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changeServer(BuildContext context) async {
    final sure = await confirm(
      context,
      title: 'Change the server for this till?',
      message: 'The saved Supabase address and key are forgotten. You will enter them again on the next start.',
      okLabel: 'Change settings',
    );
    if (!sure || !context.mounted) return;
    await AppConfig.clearConnection();
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Server details cleared'),
        content: const Text('Restart the app to enter a different Supabase project on this PC.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _signIn(AppState state) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.signIn(_email.text, _password.text);
    } catch (e) {
      // AppError carries a plain-language message; anything else gets a generic line
      // rather than a raw exception with internal detail.
      setState(() => _error = e is AppError
          ? e.message
          : 'Could not sign in. Check the internet connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
