import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_config.dart';
import 'screens/login_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/shell.dart';
import 'services/api.dart';
import 'state/app_state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();

  // 1. Keep the window hidden while we connect. If the window is already on
  //    screen but Flutter has not drawn its first frame yet, every click on it
  //    throws "Cannot hit test a render box that has never been laid out" and
  //    the app looks frozen. Staying hidden until we have something to show
  //    avoids that completely.
  await _prepareWindow();

  // 2. Connect, then hand the app to Flutter.
  if (AppConfig.isConfigured) {
    // the signed-in session is kept encrypted with this Windows account
    await Api.initializeClient();
    runApp(SupermartApp(api: Api(Supabase.instance.client)));
  } else {
    // first run on this PC: ask for the Supabase URL + anon key
    runApp(const SetupGate());
  }

  // 3. Only now put the window on screen - the first frame is already drawn,
  //    so the very first click lands on a real, laid-out widget.
  WidgetsBinding.instance.addPostFrameCallback((_) => _revealWindow());
}

bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Sizes the window and hides it until the first frame is ready.
Future<void> _prepareWindow() async {
  if (!_isDesktop) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.hide();
    await windowManager.setSize(const Size(1440, 900));
    await windowManager.setMinimumSize(const Size(1100, 700));
    await windowManager.center();
    await windowManager.setTitle('Supermart POS');
  } catch (_) {
    // running somewhere window_manager does not support - ignore
  }
}

/// Shows the window once there is a painted frame behind it.
Future<void> _revealWindow() async {
  if (!_isDesktop) return;
  try {
    await windowManager.show();
    await windowManager.focus();
  } catch (_) {
    // ignore: the window is visible anyway on platforms without window_manager
  }
}

class SupermartApp extends StatelessWidget {
  const SupermartApp({super.key, required this.api});
  final Api api;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>(
      create: (_) => AppState(api),
      child: Consumer<AppState>(
        builder: (context, state, _) {
          final mode = state.themeMode;
          final systemDark =
              WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
          // the semantic colours (good, warn, danger...) follow the look in use
          AppColors.dark = mode == ThemeMode.dark || (mode == ThemeMode.system && systemDark);
          return MaterialApp(
            title: 'Supermart POS',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            darkTheme: buildTheme(dark: true),
            themeMode: mode,
            home: const RootGate(),
          );
        },
      ),
    );
  }
}

/// Decides what the PC shows: sign in, wait for data, or the till.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    if (state.signedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (state.identity == null || state.catalogue.isEmpty) {
          await state.bootstrap();
        } else {
          await state.refreshCatalogue(forceReload: true);
          await state.refreshReference();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // a saved sign-in is still being restored: wait for it rather than ask for the password
    if (!state.signedIn && state.sessionPending) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3)),
              SizedBox(height: 20),
              Text('Checking sign-in…', style: TextStyle(fontSize: 16)),
            ],
          ),
        ),
      );
    }

    if (!state.signedIn) return const LoginScreen();

    if (state.booting) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3)),
              SizedBox(height: 20),
              Text('Loading catalogue…', style: TextStyle(fontSize: 16)),
            ],
          ),
        ),
      );
    }

    if (state.bootError != null) {
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.error_outline, color: AppColors.danger, size: 28),
                      const SizedBox(width: 12),
                      Text('Cannot start selling yet',
                          style: Theme.of(context).textTheme.titleLarge),
                    ]),
                    const SizedBox(height: 12),
                    Text(state.bootError!),
                    const SizedBox(height: 20),
                    Row(children: [
                      FilledButton.icon(
                        onPressed: () => state.bootstrap(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () async {
                          await state.signOut();
                        },
                        child: const Text('Sign out'),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return const Shell();
  }
}
