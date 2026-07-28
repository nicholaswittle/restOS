import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Email/password auth with three entry paths: sign in, join invite, create venue.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

enum _AuthMode { signIn, join, createRestaurant }

class _SignInScreenState extends State<SignInScreen> {
  final _client = Supabase.instance.client;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _invite = TextEditingController();
  final _restaurant = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _busy = false;
  bool _obscured = true;
  _AuthMode _mode = _AuthMode.signIn;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    _invite.dispose();
    _restaurant.dispose();
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
      _info = null;
    });
    try {
      switch (_mode) {
        case _AuthMode.signIn:
          await _client.auth.signInWithPassword(
            email: _email.text.trim(),
            password: _password.text,
          );
        case _AuthMode.join:
          await _joinWithInvite();
        case _AuthMode.createRestaurant:
          await _createRestaurant();
      }
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
      data: {
        'name': name,
        'full_name': name,
        'invite_code': invite,
      },
    );

    if (response.session == null) {
      if (!mounted) return;
      setState(() {
        _mode = _AuthMode.signIn;
        _info =
            'Account created. Confirm your email, then sign in — your invite links you automatically.';
      });
      return;
    }

    // Idempotent if the signup trigger already redeemed the code.
    await _client.rpc(
      'apex_redeem_invite',
      params: {'invite_code': invite},
    );

    try {
      final uid = response.user?.id;
      if (uid != null && name.isNotEmpty) {
        await _client.from('profiles').update({'name': name}).eq('id', uid);
      }
    } catch (_) {}
  }

  Future<void> _createRestaurant() async {
    final email = _email.text.trim();
    final restaurant = _restaurant.text.trim();
    final name = _name.text.trim().isEmpty
        ? restaurant
        : _name.text.trim();

    final response = await _client.auth.signUp(
      email: email,
      password: _password.text,
      data: {
        'name': name,
        'full_name': name,
        'org_name': restaurant,
      },
    );

    if (response.session == null) {
      if (!mounted) return;
      setState(() {
        _mode = _AuthMode.signIn;
        _info = 'Account created. Confirm your email, then sign in.';
      });
    }
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

  void _setMode(_AuthMode next) {
    setState(() {
      _mode = next;
      _error = null;
      _info = null;
    });
  }

  String get _subtitle => switch (_mode) {
        _AuthMode.signIn => 'Sign in to see your shifts',
        _AuthMode.join => 'Join your venue with an invite',
        _AuthMode.createRestaurant => 'Create a new restaurant',
      };

  String get _submitLabel => switch (_mode) {
        _AuthMode.signIn => 'Sign in',
        _AuthMode.join => 'Join venue',
        _AuthMode.createRestaurant => 'Create restaurant',
      };

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
                      _subtitle,
                      textAlign: TextAlign.center,
                      style: text.bodyLarge?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.7)),
                    ),
                    const SizedBox(height: 24),
                    SegmentedButton<_AuthMode>(
                      segments: const [
                        ButtonSegment(
                          value: _AuthMode.signIn,
                          label: Text('Sign in'),
                          icon: Icon(Icons.login_rounded, size: 16),
                        ),
                        ButtonSegment(
                          value: _AuthMode.join,
                          label: Text('Join'),
                          icon: Icon(Icons.group_add_rounded, size: 16),
                        ),
                        ButtonSegment(
                          value: _AuthMode.createRestaurant,
                          label: Text('Create'),
                          icon: Icon(Icons.storefront_rounded, size: 16),
                        ),
                      ],
                      selected: {_mode},
                      onSelectionChanged: _busy
                          ? null
                          : (s) {
                              if (s.isNotEmpty) _setMode(s.first);
                            },
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        textStyle: WidgetStatePropertyAll(
                          text.labelMedium,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_mode == _AuthMode.join) ...[
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
                    if (_mode == _AuthMode.createRestaurant) ...[
                      TextFormField(
                        controller: _restaurant,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Restaurant name',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.storefront_outlined),
                        ),
                        validator: (v) => (v ?? '').trim().isEmpty
                            ? 'Enter your restaurant name.'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _name,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Your name (optional)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
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
                      autofillHints: _mode == _AuthMode.signIn
                          ? const [AutofillHints.password]
                          : const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: _mode == _AuthMode.signIn
                            ? 'Password'
                            : 'Create password',
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
                        if (_mode != _AuthMode.signIn &&
                            (v ?? '').length < 6) {
                          return 'Use at least 6 characters.';
                        }
                        return null;
                      },
                    ),
                    if (_info != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.secondaryContainer.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(children: [
                          Icon(Icons.check_circle_outline_rounded,
                              size: 18, color: cs.secondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_info!,
                                style: text.bodyMedium
                                    ?.copyWith(color: cs.onSurface)),
                          ),
                        ]),
                      ),
                    ],
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
                          : Text(_submitLabel),
                    ),
                    if (_mode == _AuthMode.signIn)
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
