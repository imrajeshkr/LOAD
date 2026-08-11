import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import 'auth/auth_screen.dart';
import 'onboarding/onboarding_flow.dart';
import 'app_shell.dart';

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
