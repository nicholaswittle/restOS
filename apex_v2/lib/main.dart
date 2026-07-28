import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/demo_backend.dart';

/// Entry point.
///
/// Config comes from --dart-define so no key is ever committed:
///   flutter run \
///     --dart-define=SUPABASE_URL=... \
///     --dart-define=SUPABASE_ANON_KEY=...
///
/// (`employee_dashboard.dart` still carries its own `main()` from when it was
/// built standalone. This is the real entry point now; that one is vestigial
/// and can be removed in a later cleanup.)
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Demo build: the real screens run against seeded data over a fake HTTP
  // client, so no project, no keys and no database are involved.
  if (DemoMode.enabled) {
    await Supabase.initialize(
      url: 'https://demo.invalid',
      anonKey: 'demo', // ignore: deprecated_member_use — supabase_flutter 2.x
      httpClient: DemoHttpClient(),
      postgrestOptions: const PostgrestClientOptions(schema: 'public'),
      realtimeClientOptions:
          const RealtimeClientOptions(logLevel: RealtimeLogLevel.error),
    );
    runApp(const ApexApp());
    return;
  }

  const url = String.fromEnvironment('SUPABASE_URL');
  const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  if (url.isEmpty || anonKey.isEmpty) {
    runApp(const _MisconfiguredApp());
    return;
  }

  await Supabase.initialize(
    url: url,
    anonKey: anonKey, // ignore: deprecated_member_use — supabase_flutter 2.x
    postgrestOptions: const PostgrestClientOptions(schema: 'public'),
  );

  runApp(const ApexApp());
}

/// Shown when the app is launched without Supabase config, instead of crashing
/// on a null client several screens later.
class _MisconfiguredApp extends StatelessWidget {
  const _MisconfiguredApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF8C42),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF12100E),
      ),
      home: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'Apex is missing its Supabase configuration.\n\n'
              'Run with --dart-define=SUPABASE_URL=... '
              'and --dart-define=SUPABASE_ANON_KEY=...',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
