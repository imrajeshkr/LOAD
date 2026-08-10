import 'package:flutter/material.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_colors.dart';

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

  Future<void> _submit() async {
    setState(() => _error = null);
    if (_isSignup && _passwordCtrl.text != _confirmCtrl.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    if (_emailCtrl.text.trim().isEmpty || _passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    setState(() => _loading = true);
    try {
      if (_isSignup) {
        await SupabaseService.instance.signUpWithEmail(_emailCtrl.text.trim(), _passwordCtrl.text);
      } else {
        await SupabaseService.instance.signInWithEmail(_emailCtrl.text.trim(), _passwordCtrl.text);
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
    return 'Something went wrong — try again.';
  }

  Future<void> _google() async {
    setState(() => _error = null);
    try {
      await SupabaseService.instance.signInWithGoogle();
    } catch (e) {
      setState(() => _error = 'Google sign-in isn\'t set up yet — enable Google as an auth provider in Supabase first.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: const TextSpan(
                          style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                          children: [
                            TextSpan(text: 'LOAD'),
                            TextSpan(text: '.', style: TextStyle(color: AppColors.accent)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "Your coach — trained on your history, not a generic plan.",
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5),
                      ),
                      const SizedBox(height: 40),
                      OutlinedButton.icon(
                        onPressed: _google,
                        icon: const Icon(Icons.g_mobiledata, size: 22),
                        label: const Text('Continue with Google'),
                      ),
                      const SizedBox(height: 18),
                      Row(children: const [
                        Expanded(child: Divider()),
                        Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('OR', style: TextStyle(color: AppColors.textTertiary, fontSize: 11))),
                        Expanded(child: Divider()),
                      ]),
                      const SizedBox(height: 18),
                      TextField(controller: _emailCtrl, decoration: const InputDecoration(hintText: 'Email'), keyboardType: TextInputType.emailAddress),
                      const SizedBox(height: 12),
                      TextField(controller: _passwordCtrl, decoration: const InputDecoration(hintText: 'Password'), obscureText: true),
                      if (_isSignup) ...[
                        const SizedBox(height: 12),
                        TextField(controller: _confirmCtrl, decoration: const InputDecoration(hintText: 'Confirm password'), obscureText: true),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                      const SizedBox(height: 18),
                      ElevatedButton(
                        onPressed: _loading ? null : _submit,
                        child: _loading
                            ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentOn))
                            : Text(_isSignup ? 'Create account' : 'Sign in'),
                      ),
                    ],
                  ),
                ),
              ),
              Center(
                child: TextButton(
                  onPressed: () => setState(() => _isSignup = !_isSignup),
                  child: Text(
                    _isSignup ? 'Already have an account? Sign in' : "New here? Create an account",
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
