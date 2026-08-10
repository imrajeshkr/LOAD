import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme/app_theme.dart';
import 'services/app_state.dart';
import 'services/supabase_service.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/onboarding/onboarding_flow.dart';
import 'screens/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    publishableKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );
  runApp(const LoadApp());
}

class LoadApp extends StatelessWidget {
  const LoadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        title: 'LOAD',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const AuthGate(),
      ),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: SupabaseService.instance.authStateChanges,
      builder: (context, snapshot) {
        final session = SupabaseService.instance.currentUser;
        if (session == null) {
          return const AuthScreen();
        }
        return const _PostAuthLoader();
      },
    );
  }
}

/// Loads the profile once signed in, then routes to onboarding or the app shell.
class _PostAuthLoader extends StatefulWidget {
  const _PostAuthLoader();

  @override
  State<_PostAuthLoader> createState() => _PostAuthLoaderState();
}

class _PostAuthLoaderState extends State<_PostAuthLoader> {
  bool _started = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!_started) {
      _started = true;
      Future.microtask(() => state.loadInitial());
    }
    if (state.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!state.profile.isComplete) {
      return const OnboardingFlow();
    }
    return const AppShell();
  }
}
