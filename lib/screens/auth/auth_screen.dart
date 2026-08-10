import 'package:flutter/material.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isSignup = false;
  bool _loading = false;
  String? _error;

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    final email = _emailCtrl.text.trim();

    if (email.isEmpty || _passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    if (_isSignup && _passwordCtrl.text != _confirmCtrl.text) {
      setState(() => _error = "Those passwords don't match.");
      return;
    }
    if (_isSignup && _passwordCtrl.text.length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
      return;
    }

    setState(() => _loading = true);
    try {
      if (_isSignup) {
        await SupabaseService.instance.signUpWithEmail(email, _passwordCtrl.text);
      } else {
        await SupabaseService.instance.signInWithEmail(email, _passwordCtrl.text);
      }
    } catch (e) {
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('Invalid login credentials')) return 'Incorrect email or password.';
    if (s.contains('already registered')) return 'An account already exists for this email.';
    if (s.contains('rate limit')) return 'Too many attempts — give it a minute.';
    return 'Something went wrong — try again.';
  }

  Future<void> _google() async {
    setState(() => _error = null);
    try {
      await SupabaseService.instance.signInWithGoogle();
    } catch (_) {
      setState(() => _error =
          "Google sign-in isn't enabled yet — turn it on in your Supabase auth providers.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 54,
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.fitness_center_rounded,
                    color: AppColors.onAccent, size: 27),
              ),
            ),
            const SizedBox(height: 22),
            Text('LOAD', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            const Text(
              'Your coach — trained on your history, not a generic plan.',
              style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 34),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _loading ? null : _google,
                icon: const Icon(Icons.g_mobiledata_rounded, size: 26),
                label: const Text('Continue with Google'),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(child: Divider(color: AppColors.track)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'or',
                    style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w600,
                      fontSize: 11.5,
                      color: AppColors.textFaint,
                    ),
                  ),
                ),
                const Expanded(child: Divider(color: AppColors.track)),
              ],
            ),
            const SizedBox(height: 18),

            TextField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              style: _inputStyle,
              decoration: const InputDecoration(
                hintText: 'Email',
                fillColor: AppColors.surface,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              style: _inputStyle,
              decoration: const InputDecoration(
                hintText: 'Password',
                fillColor: AppColors.surface,
              ),
            ),
            if (_isSignup) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _confirmCtrl,
                obscureText: true,
                style: _inputStyle,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  hintText: 'Confirm password',
                  fillColor: AppColors.surface,
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline_rounded,
                      size: 15, color: AppColors.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        height: 1.4,
                        color: AppColors.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.onAccent,
                        ),
                      )
                    : Text(_isSignup ? 'Create account' : 'Sign in'),
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: TextButton(
                onPressed: () => setState(() {
                  _isSignup = !_isSignup;
                  _error = null;
                }),
                child: Text(
                  _isSignup
                      ? 'Already have an account? Sign in'
                      : 'New here? Create an account',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _inputStyle = TextStyle(
    fontFamily: AppTheme.fontFamily,
    fontWeight: FontWeight.w600,
    fontSize: 13.5,
    color: AppColors.textBody,
  );
}
