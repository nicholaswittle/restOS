import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';

/// Swaps between [signedOut] and [signedIn] from the auth stream.
///
/// Demo mode has no session by design — bypass straight to [signedIn] so the
/// seeded walkthrough keeps working without a fake login.
///
/// Elevated access (super admin) is not decided here: [ApexShell] reads
/// `profiles.is_super_admin` after the session exists and mounts the Admin
/// console above all OsTier gates.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.signedIn,
    required this.signedOut,
  });

  final Widget signedIn;
  final Widget signedOut;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late bool _signedIn;
  StreamSubscription<AuthState>? _sub;

  @override
  void initState() {
    super.initState();
    // Read currentSession synchronously so a returning user never flashes login.
    _signedIn = Supabase.instance.client.auth.currentSession != null;
    if (!DemoMode.enabled) {
      _sub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        final next = data.session != null;
        if (next == _signedIn || !mounted) return;
        setState(() => _signedIn = next);
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (DemoMode.enabled) return widget.signedIn;
    return _signedIn ? widget.signedIn : widget.signedOut;
  }
}
