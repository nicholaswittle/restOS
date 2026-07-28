import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Email + password sign-in, plus join-with-invite (Apex v1 auth pattern).
///
/// Creating a brand-new venue still needs owner setup elsewhere. Staff join
/// with a manager invite via [apex_redeem_invite] after sign-up.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _client = Supabase.instance.client;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _invite = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _busy = false;
  bool _obscured = true;
  bool _joining = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    _invite.dispose();
    super.dispose();
  }

  /// Supabase error codes are stable; its messages are not.
  static String _readableError(Object error) {
    if (error is AuthException) {
      switch (error.code) {
        case 'invalid_credentials':
          return 'Incorrect email or password.';
        case 'email_not_confirmed':
          return 'Confirm your email first — check your inbox.';
        case 'over_request_rate_limit':
          return 'Too many attempts. Wait a minute and try again.';
        case 'user_banned':
          return 'This account is disabled. Ask your manager.';
        case 'user_already_exists':
          return 'That email already has an account. Sign in instead.';
      }
      return error.message;
    }
    final msg = error.toString().toLowerCase();
    if (msg.contains('invite') && msg.contains('invalid')) {
      return 'That invite code is invalid. Ask your manager for a new one.';
    }
    if (msg.contains('invite') && msg.contains('used')) {
      return 'That invite was already used. Try signing in.';
    }
    if (msg.contains('invite') && msg.contains('expired')) {
      return 'That invite expired. Ask your manager for a new one.';
    }
    return 'Could not continue. Check your connection and try again.';
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_joining) {
        await _joinWithInvite();
      } else {
        await _client.auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
      // AuthGate swaps this screen out on the auth stream.
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _readableError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinWithInvite() async {
    final email = _email.text.trim();
    final name = _name.text.trim();
    final invite = _invite.text.trim().toUpperCase();

    final response = await _client.auth.signUp(
      email: email,
      password: _password.text,
      data: {'name': name, 'full_name': name},
    );

    // Session may be null when email confirmation is required.
    if (response.session == null) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error =
            'Account created. Confirm your email, then sign in and ask your manager if the invite still needs redeeming.';
      });
      return;
    }

    await _client.rpc(
      'apex_redeem_invite',
      params: {'invite_code': invite},
    );

    // Best-effort name on profile after redeem creates/links the row.
    try {
      final uid = response.user?.id;
      if (uid != null && name.isNotEmpty) {
        await _client.from('profiles').update({'name': name}).eq('id', uid);
      }
    } catch (_) {}
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email first, then tap reset.');
      return;
    }
    try {
      await _client.auth.resetPasswordForEmail(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Password reset sent to $email.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _readableError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.calendar_month_rounded,
                        size: 40, color: cs.primary),
                    const SizedBox(height: 16),
                    Text('Apex',
                        textAlign: TextAlign.center,
                        style: text.displaySmall),
                    const SizedBox(height: 6),
                    Text(
                      _joining
                          ? 'Join your venue with an invite'
                          : 'Sign in to see your shifts',
                      textAlign: TextAlign.center,
                      style: text.bodyLarge?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.7)),
                    ),
                    const SizedBox(height: 32),
                    if (_joining) ...[
                      TextFormField(
                        controller: _name,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Your name',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        validator: (v) => (v ?? '').trim().isEmpty
                            ? 'Enter your name.'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _invite,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.characters,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Invite code',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.vpn_key_outlined),
                        ),
                        validator: (v) => (v ?? '').trim().isEmpty
                            ? 'Enter the invite from your manager.'
                            : null,
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextFormField(
                      controller: _email,
                      enabled: !_busy,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.alternate_email_rounded),
                      ),
                      validator: (v) {
                        final s = v?.trim() ?? '';
                        if (s.isEmpty) return 'Enter your email.';
                        if (!s.contains('@') || !s.contains('.')) {
                          return 'That does not look like an email.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: _obscured,
                      autofillHints: _joining
                          ? const [AutofillHints.newPassword]
                          : const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: _joining ? 'Create password' : 'Password',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setState(() => _obscured = !_obscured),
                          icon: Icon(_obscured
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded),
                          tooltip:
                              _obscured ? 'Show password' : 'Hide password',
                        ),
                      ),
                      validator: (v) {
                        if ((v ?? '').isEmpty) return 'Enter your password.';
                        if (_joining && (v ?? '').length < 6) {
                          return 'Use at least 6 characters.';
                        }
                        return null;
                      },
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.errorContainer.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(children: [
                          Icon(Icons.error_outline_rounded,
                              size: 18, color: cs.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_error!,
                                style: text.bodyMedium
                                    ?.copyWith(color: cs.onSurface)),
                          ),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_joining ? 'Join venue' : 'Sign in'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _joining = !_joining;
                                _error = null;
                              }),
                      child: Text(_joining
                          ? 'Already have an account? Sign in'
                          : 'Have an invite? Join your venue'),
                    ),
                    if (!_joining)
                      TextButton(
                        onPressed: _busy ? null : _resetPassword,
                        child: const Text('Forgot password?'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
