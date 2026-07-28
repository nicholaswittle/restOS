import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/demo_backend.dart';
import 'core/entitlements.dart';
import 'features/auth/auth_gate.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/callout/call_out_screen.dart';
import 'features/capacity/capacity_screen.dart';
import 'features/chat/team_chat_screen.dart';
import 'features/dashboard/employee_dashboard.dart';
import 'features/labor_cost/labor_cost_dashboard.dart';
import 'features/labor_vs_revenue/labor_vs_revenue_dashboard.dart';
import 'features/log_book/manager_log_book.dart';
import 'features/ordering/menu_screen.dart';
import 'features/ordering/staff_console_screen.dart';
import 'features/schedule/schedule_screen.dart';
import 'features/sidework/sidework_screen.dart';
import 'features/swaps/swaps_screen.dart';
import 'features/team/team_screen.dart';
import 'features/time_clock/qr_wall_screen.dart';
import 'features/time_off/time_off_screen.dart';
import 'features/tips/tip_management.dart';

/// The Apex shell.
///
/// Loads who the user is and what their venue has bought, then mounts only the
/// modules that apply. Adding a piece of the OS is a single entry in
/// [_moduleRoutes] — that is the whole plug-in contract.
class ApexApp extends StatelessWidget {
  const ApexApp({super.key});

  @override
  Widget build(BuildContext context) {
    const surface = Color(0xFF1A1A24);
    const background = Color(0xFF0A0C10);
    const surfaceHigh = Color(0xFF22222E);
    return MaterialApp(
      title: 'Apex',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          surface: surface,
          primary: Color(0xFF8B5CF6),
          onPrimary: Color(0xFFF5F5F7),
          secondary: Color(0xFF14B8A6),
          onSecondary: Color(0xFFF5F5F7),
          onSurface: Color(0xFFF5F5F7),
          tertiary: Color(0xFF00BFFF),
          surfaceContainer: surface,
          surfaceContainerHigh: surfaceHigh,
        ),
        scaffoldBackgroundColor: background,
        cardTheme: CardThemeData(
          elevation: 0,
          color: surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          margin: EdgeInsets.zero,
        ),
        textTheme: const TextTheme(
          displaySmall:
              TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
          headlineSmall:
              TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3),
          titleLarge: TextStyle(fontWeight: FontWeight.w600),
          titleMedium: TextStyle(fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(height: 1.4),
        ),
      ),
      home: const AuthGate(
        signedIn: ApexShell(),
        signedOut: SignInScreen(),
      ),
    );
  }
}

/// A mountable piece of the OS.
class OsFeature {
  const OsFeature({
    required this.module,
    required this.route,
    required this.label,
    required this.icon,
    required this.builder,
    this.managerOnly = false,
  });

  final OsModule module;
  final String route;
  final String label;
  final IconData icon;
  final Widget Function(BuildContext, String orgId, StaffRole role) builder;

  /// Hidden from servers and kitchen staff.
  final bool managerOnly;
}

/// The registry. One entry per pluggable module.
///
/// To add a feature: import it, add a line here, done — the shell handles
/// entitlement gating, navigation, and routing.
const _moduleRoutes = <OsFeature>[
  OsFeature(
    module: OsModule.scheduling,
    route: '/schedule',
    label: 'Schedule',
    icon: Icons.calendar_month_rounded,
    builder: _buildSchedule,
  ),
  OsFeature(
    module: OsModule.scheduling,
    route: '/team',
    label: 'Team',
    icon: Icons.groups_rounded,
    managerOnly: true,
    builder: _buildTeam,
  ),
  OsFeature(
    module: OsModule.scheduling,
    route: '/sidework',
    label: 'Sidework',
    icon: Icons.checklist_rounded,
    builder: _buildSidework,
  ),
  OsFeature(
    module: OsModule.timeClock,
    route: '/qr-wall',
    label: 'QR Wall',
    icon: Icons.qr_code_2_rounded,
    managerOnly: true,
    builder: _buildQrWall,
  ),
  OsFeature(
    module: OsModule.shiftSwaps,
    route: '/swaps',
    label: 'Swaps',
    icon: Icons.swap_horiz_rounded,
    builder: _buildSwaps,
  ),
  OsFeature(
    module: OsModule.managerLogBook,
    route: '/log-book',
    label: 'Log Book',
    icon: Icons.sticky_note_2_rounded,
    builder: _buildLogBook,
  ),
  OsFeature(
    module: OsModule.tipManagement,
    route: '/tips',
    label: 'Tips',
    icon: Icons.payments_rounded,
    builder: _buildTips,
  ),
  OsFeature(
    module: OsModule.teamChat,
    route: '/chat',
    label: 'Chat',
    icon: Icons.chat_bubble_outline_rounded,
    builder: _buildChat,
  ),
  OsFeature(
    module: OsModule.laborCost,
    route: '/labor-cost',
    label: 'Labor Cost',
    icon: Icons.query_stats_rounded,
    managerOnly: true,
    builder: _buildLaborCost,
  ),
  OsFeature(
    module: OsModule.laborVsRevenue,
    route: '/labor-vs-revenue',
    label: 'Labor vs Revenue',
    icon: Icons.balance_rounded,
    managerOnly: true,
    builder: _buildLaborVsRevenue,
  ),
  OsFeature(
    module: OsModule.noShowEngine,
    route: '/call-outs',
    label: 'Call-Outs',
    icon: Icons.phone_in_talk_rounded,
    builder: _buildCallOuts,
  ),
  OsFeature(
    module: OsModule.smartCapacity,
    route: '/capacity',
    label: 'Capacity',
    icon: Icons.speed_rounded,
    managerOnly: true,
    builder: _buildCapacity,
  ),
  OsFeature(
    module: OsModule.onlineOrdering,
    route: '/orders',
    label: 'Orders',
    icon: Icons.receipt_long_rounded,
    builder: _buildOrders,
  ),
  OsFeature(
    module: OsModule.onlineOrdering,
    route: '/menu',
    label: 'Menu',
    icon: Icons.restaurant_menu_rounded,
    builder: _buildMenu,
  ),
];

Widget _buildSchedule(BuildContext context, String orgId, StaffRole role) =>
    ScheduleScreen(organizationId: orgId, role: role);

Widget _buildTeam(BuildContext context, String orgId, StaffRole role) =>
    TeamScreen(organizationId: orgId, role: role);

Widget _buildSidework(BuildContext context, String orgId, StaffRole role) =>
    SideworkScreen(organizationId: orgId, role: role);

Widget _buildQrWall(BuildContext context, String orgId, StaffRole role) =>
    QrWallScreen(organizationId: orgId);

Widget _buildSwaps(BuildContext context, String orgId, StaffRole role) =>
    SwapsScreen(organizationId: orgId, role: role);

Widget _buildLogBook(BuildContext context, String orgId, StaffRole role) =>
    ManagerLogBook(organizationId: orgId);

Widget _buildTips(BuildContext context, String orgId, StaffRole role) =>
    TipManagement(organizationId: orgId);

Widget _buildChat(BuildContext context, String orgId, StaffRole role) =>
    TeamChatScreen(organizationId: orgId);

Widget _buildLaborCost(BuildContext context, String orgId, StaffRole role) =>
    LaborCostDashboard(organizationId: orgId);

Widget _buildLaborVsRevenue(BuildContext context, String orgId, StaffRole role) =>
    LaborVsRevenueDashboard(organizationId: orgId);

Widget _buildCallOuts(BuildContext context, String orgId, StaffRole role) =>
    CallOutScreen(organizationId: orgId, role: role);

Widget _buildCapacity(BuildContext context, String orgId, StaffRole role) =>
    CapacityScreen(organizationId: orgId);

Widget _buildOrders(BuildContext context, String orgId, StaffRole role) =>
    StaffConsoleScreen(organizationId: orgId, role: role);

Widget _buildMenu(BuildContext context, String orgId, StaffRole role) =>
    MenuScreen(organizationId: orgId);

/// Resolves session + entitlements, then renders the dashboard with only the
/// modules this venue and this role can use.
class ApexShell extends StatefulWidget {
  const ApexShell({super.key});

  @override
  State<ApexShell> createState() => _ApexShellState();
}

class _ApexShellState extends State<ApexShell> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  String _orgId = '';
  StaffRole _role = StaffRole.server;
  Entitlements _entitlements = Entitlements.none;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      // Demo builds have no session; the seeded venue stands in for one.
      if (DemoMode.enabled) {
        final org = await _client
            .from('organizations')
            .select('tier, enabled_modules, disabled_modules')
            .maybeSingle();
        if (!mounted) return;
        setState(() {
          _orgId = DemoMode.organizationId;
          _role = StaffRole.manager;
          _entitlements = Entitlements.fromMap(org);
          _loading = false;
          _error = null;
        });
        return;
      }

      final userId = _client.auth.currentUser?.id;
      if (userId == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Sign in to continue.';
        });
        return;
      }

      final profile = await _client
          .from('profiles')
          .select('role, organization_id')
          .eq('id', userId)
          .maybeSingle();

      final orgId = profile?['organization_id'] as String? ?? '';
      if (orgId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Your account is not linked to a venue yet.';
        });
        return;
      }

      final org = await _client
          .from('organizations')
          .select('tier, enabled_modules, disabled_modules')
          .eq('id', orgId)
          .maybeSingle();

      if (!mounted) return;
      setState(() {
        _orgId = orgId;
        _role = StaffRole.parse(profile?['role'] as String?);
        _entitlements = Entitlements.fromMap(org);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your workspace. Check your connection.';
      });
    }
  }

  /// Modules this venue bought, filtered by what this role may open.
  List<OsFeature> get _available => [
        for (final f in _moduleRoutes)
          if (_entitlements.has(f.module) && (!f.managerOnly || _role.canManage))
            f
      ];

  void _open(OsFeature f) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (ctx) => f.builder(ctx, _orgId, _role)),
    );
  }

  void _openRoute(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _signOut() async {
    await _client.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline_rounded,
                  size: 44, color: cs.onSurface.withValues(alpha: 0.5)),
              const SizedBox(height: 16),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ]),
          ),
        ),
      );
    }

    final extras = _available;
    // Four labels ("Labor Cost" especially) do not fit Expanded on a 375px
    // phone — switch to a horizontal scroll once we exceed three modules.
    final scrollModules = extras.length > 3;

    return Scaffold(
      body: EmployeeDashboard(
        organizationId: _orgId,
        onSwapShift: () => _openRoute(
          SwapsScreen(organizationId: _orgId, role: _role),
        ),
        onRequestTimeOff: () => _openRoute(
          TimeOffScreen(organizationId: _orgId, role: _role),
        ),
        onOpenChat: _entitlements.has(OsModule.teamChat)
            ? () => _openRoute(TeamChatScreen(organizationId: _orgId))
            : null,
        onSignOut: DemoMode.enabled ? null : _signOut,
      ),
      // Free tier still shows Schedule (scheduling is free). Pro+ adds more.
      bottomNavigationBar: extras.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: scrollModules
                    ? SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final f in extras) ...[
                              SizedBox(
                                width: 96,
                                child: _ModuleButton(
                                  icon: f.icon,
                                  label: f.label,
                                  onTap: () => _open(f),
                                ),
                              ),
                              if (f != extras.last) const SizedBox(width: 10),
                            ],
                          ],
                        ),
                      )
                    : Row(
                        children: [
                          for (final f in extras) ...[
                            Expanded(
                              child: _ModuleButton(
                                icon: f.icon,
                                label: f.label,
                                onTap: () => _open(f),
                              ),
                            ),
                            if (f != extras.last) const SizedBox(width: 10),
                          ],
                        ],
                      ),
              ),
            ),
    );
  }
}

class _ModuleButton extends StatelessWidget {
  const _ModuleButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          // Without MainAxisSize.min this Column takes every pixel the
          // bottom bar is offered, which is the whole screen — the dashboard
          // then renders at zero height and the app looks blank.
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22, color: cs.primary),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
      ),
    );
  }
}
