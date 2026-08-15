import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../auth/auth_screen.dart';
import 'nav_shell.dart';
import 'onboarding_v2.dart';

/// The app's front door. Reacts to auth changes and routes:
///   • no session            → sign in / create account
///   • signed in, no program → the v2 intake
///   • signed in, has program→ the app
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  String? _uid;
  Future<bool>? _programFuture;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: SupabaseService.instance.authStateChanges,
      builder: (context, _) {
        final user = SupabaseService.instance.currentUser;
        if (user == null) {
          _uid = null;
          _programFuture = null;
          return const AuthScreen();
        }
        // Memoize the program check per signed-in user.
        if (_uid != user.id) {
          _uid = user.id;
          _programFuture = SupabaseService.instance.hasActiveProgram();
        }
        return FutureBuilder<bool>(
          future: _programFuture,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Scaffold(
                backgroundColor: AppColors.page,
                body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
              );
            }
            if (snap.data == true) return const NavShell();
            return OnboardingV2(
              onFinished: () => setState(() {
                _programFuture = SupabaseService.instance.hasActiveProgram();
              }),
            );
          },
        );
      },
    );
  }
}
