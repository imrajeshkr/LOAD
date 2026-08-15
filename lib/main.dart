import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme/app_theme.dart';
import 'services/app_state.dart';
import 'screens/v2/root_gate.dart';
import 'screens/v2/splash_v2.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    publishableKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  // Native Google Sign-In. serverClientId (the Web OAuth client) is what
  // Supabase's Google provider checks the id token's audience against; the
  // platform clientId is only needed on iOS to drive the native sheet.
  final webClientId = dotenv.env['GOOGLE_WEB_CLIENT_ID'];
  final iosClientId = dotenv.env['GOOGLE_IOS_CLIENT_ID'];
  if (webClientId != null && webClientId.isNotEmpty) {
    await GoogleSignIn.instance.initialize(
      clientId: (!kIsWeb && Platform.isIOS) ? iosClientId : null,
      serverClientId: webClientId,
    );
  }

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
        theme: AppTheme.theme,
        home: const _Launch(),
      ),
    );
  }
}

/// Plays the 1a splash once on cold start, then hands off to the app's front
/// door. The splash is a brand moment, independent of auth state.
class _Launch extends StatefulWidget {
  const _Launch();
  @override
  State<_Launch> createState() => _LaunchState();
}

class _LaunchState extends State<_Launch> {
  bool _done = false;
  @override
  Widget build(BuildContext context) {
    if (_done) return const RootGate();
    return SplashV2(onDone: () => setState(() => _done = true));
  }
}
