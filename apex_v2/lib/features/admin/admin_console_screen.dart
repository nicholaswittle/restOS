import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';
import '../../core/entitlements.dart';

/// Cross-org fleet console — only for profiles.is_super_admin.
class AdminConsoleScreen extends StatefulWidget {
  const AdminConsoleScreen({super.key});

  @override
  State<AdminConsoleScreen> createState() => _AdminConsoleScreenState();
}

class _AdminConsoleScreenState extends State<AdminConsoleScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  List<_OrgRow> _orgs = const [];
  _OrgRow? _selected;
  List<_UserRow> _users = const [];
  bool _detailBusy = false;
  String? _inviteCode;

  // Demo mutations live here so the walkthrough can change tier without SQL.
  static final Map<String, Map<String, dynamic>> _demoOrgState = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (DemoMode.enabled) {
        _seedDemoOrgsIfNeeded();
        final rows = _demoOrgState.values.map(_OrgRow.fromMap).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        if (!mounted) return;
        setState(() {
          _orgs = rows;
          _loading = false;
          if (_selected != null) {
            _selected = rows.cast<_OrgRow?>().firstWhere(
                  (o) => o?.id == _selected!.id,
                  orElse: () => null,
                );
          }
        });
        if (_selected != null) await _loadUsers(_selected!.id);
        return;
      }

      final raw = await _client.rpc('admin_list_orgs');
      final list = (raw as List)
          .cast<Map<String, dynamic>>()
          .map(_OrgRow.fromMap)
          .toList();
      if (!mounted) return;
      setState(() {
        _orgs = list;
        _loading = false;
        if (_selected != null) {
          _selected = list.cast<_OrgRow?>().firstWhere(
                (o) => o?.id == _selected!.id,
                orElse: () => null,
              );
        }
      });
      if (_selected != null) await _loadUsers(_selected!.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load venues. Pull to retry.';
      });
    }
  }

  void _seedDemoOrgsIfNeeded() {
    if (_demoOrgState.isNotEmpty) return;
    final alder = Map<String, dynamic>.from(DemoSeed.organization);
    alder['staff_count'] = DemoSeed.staff.length;
    alder['shift_count_week'] = DemoSeed.shifts.length;
    alder['last_active'] = DateTime.now().toUtc().toIso8601String();
    _demoOrgState[alder['id'] as String] = alder;

    _demoOrgState['demo-org-jigsy'] = {
      'id': 'demo-org-jigsy',
      'name': "Jigsy's Brewpub",
      'tier': 'free',
      'enabled_modules': <String>[],
      'disabled_modules': <String>[],
      'staff_count': 2,
      'shift_count_week': 8,
      'last_active': DateTime.now()
          .subtract(const Duration(days: 1))
          .toUtc()
          .toIso8601String(),
    };
  }

  Future<void> _loadUsers(String orgId) async {
    try {
      if (DemoMode.enabled) {
        final list = orgId == DemoMode.organizationId
            ? DemoSeed.staff
                .map((m) => _UserRow(
                      id: m['id'] as String? ?? '',
                      name: m['name'] as String? ?? '',
                      email: '${(m['name'] as String? ?? 'staff').split(' ').first.toLowerCase()}@demo.apex',
                      role: m['role'] as String? ?? 'Staff',
                      lastSignIn: DateTime.now().subtract(const Duration(hours: 3)),
                    ))
                .toList()
            : [
                const _UserRow(
                  id: 'demo-jigsy-owner',
                  name: 'Emily Jigsy',
                  email: 'emily@jigsys.demo',
                  role: 'Owner',
                  lastSignIn: null,
                ),
              ];
        if (!mounted) return;
        setState(() => _users = list);
        return;
      }

      final raw = await _client.rpc(
        'admin_list_users',
        params: {'p_org_id': orgId},
      );
      if (!mounted) return;
      setState(() {
        _users = (raw as List)
            .cast<Map<String, dynamic>>()
            .map(_UserRow.fromMap)
            .toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _users = const []);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _selectOrg(_OrgRow org) async {
    setState(() {
      _selected = org;
      _inviteCode = null;
      _users = const [];
    });
    await _loadUsers(org.id);
  }

  Future<void> _setTier(OsTier tier) async {
    final org = _selected;
    if (org == null || _detailBusy) return;
    setState(() => _detailBusy = true);
    try {
      if (DemoMode.enabled) {
        final row = _demoOrgState[org.id];
        if (row != null) row['tier'] = tier.name;
      } else {
        await _client.rpc(
          'admin_set_tier',
          params: {'p_org_id': org.id, 'new_tier': tier.name},
        );
      }
      await _load();
      _snack('${org.name} → ${tier.label}');
    } catch (_) {
      _snack('Could not update tier.');
    } finally {
      if (mounted) setState(() => _detailBusy = false);
    }
  }

  Future<void> _toggleModule(OsModule module, bool enabled) async {
    final org = _selected;
    if (org == null || _detailBusy) return;
    setState(() => _detailBusy = true);
    try {
      if (DemoMode.enabled) {
        final row = _demoOrgState[org.id];
        if (row != null) {
          final enabledList =
              List<String>.from((row['enabled_modules'] as List?) ?? const []);
          final disabledList =
              List<String>.from((row['disabled_modules'] as List?) ?? const []);
          enabledList.remove(module.name);
          disabledList.remove(module.name);
          if (enabled) {
            enabledList.add(module.name);
          } else {
            disabledList.add(module.name);
          }
          row['enabled_modules'] = enabledList;
          row['disabled_modules'] = disabledList;
        }
      } else {
        await _client.rpc(
          'admin_toggle_module',
          params: {
            'p_org_id': org.id,
            'module_name': module.name,
            'enabled': enabled,
          },
        );
      }
      await _load();
    } catch (_) {
      _snack('Could not toggle module.');
    } finally {
      if (mounted) setState(() => _detailBusy = false);
    }
  }

  Future<void> _generateInvite() async {
    final org = _selected;
    if (org == null || _detailBusy) return;
    setState(() => _detailBusy = true);
    try {
      String code;
      if (DemoMode.enabled) {
        const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        final rng = Random();
        code = List.generate(6, (_) => alphabet[rng.nextInt(alphabet.length)])
            .join();
      } else {
        final raw = await _client.rpc(
          'admin_generate_invite',
          params: {'p_org_id': org.id},
        );
        code = (raw as String?)?.trim() ?? '';
      }
      if (!mounted) return;
      if (code.isEmpty) {
        _snack('Could not create invite.');
        return;
      }
      await Clipboard.setData(ClipboardData(text: code));
      setState(() => _inviteCode = code);
      _snack('Invite $code copied.');
    } catch (_) {
      _snack('Could not create invite.');
    } finally {
      if (mounted) setState(() => _detailBusy = false);
    }
  }

  Future<void> _createOrg() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create venue'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Restaurant name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;

    setState(() => _detailBusy = true);
    try {
      if (DemoMode.enabled) {
        final id = 'demo-org-${Random().nextInt(99999)}';
        _demoOrgState[id] = {
          'id': id,
          'name': name,
          'tier': 'free',
          'enabled_modules': <String>[],
          'disabled_modules': <String>[],
          'staff_count': 0,
          'shift_count_week': 0,
          'last_active': DateTime.now().toUtc().toIso8601String(),
        };
      } else {
        await _client.rpc('admin_create_org', params: {'p_name': name});
      }
      await _load();
      _snack('Created $name');
    } catch (_) {
      _snack('Could not create venue.');
    } finally {
      if (mounted) setState(() => _detailBusy = false);
    }
  }

  int get _projectedCents {
    var total = 0;
    for (final o in _orgs) {
      total += o.tier.priceCents;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading && _orgs.isEmpty) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        color: cs.primary,
        backgroundColor: cs.surfaceContainer,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Admin',
                              style: Theme.of(context).textTheme.displaySmall),
                          Text(
                            'Fleet command console',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color:
                                      cs.onSurface.withValues(alpha: 0.55),
                                ),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Create venue',
                      onPressed: _detailBusy ? null : _createOrg,
                      icon: const Icon(Icons.add_business_rounded),
                    ),
                  ]),
                ),
              ),
            ),
            if (_error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(_error!, textAlign: TextAlign.center),
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                sliver: SliverToBoxAdapter(
                  child: _RevenueCard(
                    orgs: _orgs,
                    projectedCents: _projectedCents,
                  ),
                ),
              ),
              if (_selected == null)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                  sliver: SliverList.list(children: [
                    Text('Venues',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    for (final org in _orgs) ...[
                      _OrgCard(org: org, onTap: () => _selectOrg(org)),
                      const SizedBox(height: 10),
                    ],
                  ]),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                  sliver: SliverList.list(children: [
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _selected = null;
                        _inviteCode = null;
                        _users = const [];
                      }),
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: const Text('All venues'),
                    ),
                    const SizedBox(height: 8),
                    Text(_selected!.name,
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    Text('Tier',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    SegmentedButton<OsTier>(
                      segments: [
                        for (final t in OsTier.values)
                          ButtonSegment(value: t, label: Text(t.label.split(' ').first)),
                      ],
                      selected: {_selected!.tier},
                      onSelectionChanged: _detailBusy
                          ? null
                          : (s) {
                              if (s.isNotEmpty) _setTier(s.first);
                            },
                    ),
                    const SizedBox(height: 24),
                    Text('Modules',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final m in OsModule.values)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_moduleLabel(m)),
                        subtitle: Text(m.name,
                            style: Theme.of(context).textTheme.bodySmall),
                        value: _moduleEnabled(_selected!, m),
                        onChanged: _detailBusy
                            ? null
                            : (v) => _toggleModule(m, v),
                      ),
                    const SizedBox(height: 16),
                    FilledButton.tonalIcon(
                      onPressed: _detailBusy ? null : _generateInvite,
                      icon: const Icon(Icons.vpn_key_rounded),
                      label: const Text('Generate invite'),
                    ),
                    if (_inviteCode != null) ...[
                      const SizedBox(height: 12),
                      Card(
                        color: cs.primaryContainer.withValues(alpha: 0.35),
                        child: ListTile(
                          title: Text(_inviteCode!,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w700,
                                letterSpacing: 2,
                              )),
                          subtitle: const Text('Share with the first owner'),
                          trailing: IconButton(
                            icon: const Icon(Icons.copy_rounded),
                            onPressed: () {
                              Clipboard.setData(
                                  ClipboardData(text: _inviteCode!));
                              _snack('Copied $_inviteCode');
                            },
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Text('Staff',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_users.isEmpty)
                      Text(
                        'No staff yet.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                      )
                    else
                      for (final u in _users) ...[
                        Card(
                          child: ListTile(
                            title: Text(u.name),
                            subtitle: Text(
                              [
                                u.role,
                                if (u.email.isNotEmpty) u.email,
                                if (u.lastSignIn != null)
                                  'Last in ${DateFormat.MMMd().add_jm().format(u.lastSignIn!.toLocal())}',
                              ].join(' · '),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                  ]),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static bool _moduleEnabled(_OrgRow org, OsModule m) {
    final ent = Entitlements(
      tier: org.tier,
      extraModules: {
        for (final n in org.enabledModules)
          if (OsModule.values.any((e) => e.name == n))
            OsModule.values.firstWhere((e) => e.name == n),
      },
      blockedModules: {
        for (final n in org.disabledModules)
          if (OsModule.values.any((e) => e.name == n))
            OsModule.values.firstWhere((e) => e.name == n),
      },
    );
    return ent.has(m);
  }

  static String _moduleLabel(OsModule m) => switch (m) {
        OsModule.scheduling => 'Scheduling',
        OsModule.shiftSwaps => 'Shift swaps',
        OsModule.timeClock => 'Time clock',
        OsModule.pushNotifications => 'Push notifications',
        OsModule.managerLogBook => 'Manager log book',
        OsModule.tipManagement => 'Tip management',
        OsModule.laborCost => 'Labor cost',
        OsModule.offlineMode => 'Offline mode',
        OsModule.teamChat => 'Team chat',
        OsModule.onlineOrdering => 'Online ordering',
        OsModule.smartCapacity => 'Smart capacity',
        OsModule.noShowEngine => 'No-show engine',
        OsModule.laborVsRevenue => 'Labor vs revenue',
        OsModule.multiLocation => 'Multi-location',
      };
}

class _OrgRow {
  const _OrgRow({
    required this.id,
    required this.name,
    required this.tier,
    required this.staffCount,
    required this.shiftCountWeek,
    required this.lastActive,
    required this.enabledModules,
    required this.disabledModules,
  });

  final String id;
  final String name;
  final OsTier tier;
  final int staffCount;
  final int shiftCountWeek;
  final DateTime? lastActive;
  final List<String> enabledModules;
  final List<String> disabledModules;

  factory _OrgRow.fromMap(Map<String, dynamic> m) => _OrgRow(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? 'Venue',
        tier: OsTier.parse(m['tier'] as String?),
        staffCount: (m['staff_count'] as num?)?.toInt() ?? 0,
        shiftCountWeek: (m['shift_count_week'] as num?)?.toInt() ?? 0,
        lastActive: m['last_active'] != null
            ? DateTime.tryParse(m['last_active'].toString())
            : null,
        enabledModules: (m['enabled_modules'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        disabledModules: (m['disabled_modules'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
      );
}

class _UserRow {
  const _UserRow({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.lastSignIn,
  });

  final String id;
  final String name;
  final String email;
  final String role;
  final DateTime? lastSignIn;

  factory _UserRow.fromMap(Map<String, dynamic> m) => _UserRow(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        email: m['email'] as String? ?? '',
        role: m['role'] as String? ?? 'Staff',
        lastSignIn: m['last_sign_in_at'] != null
            ? DateTime.tryParse(m['last_sign_in_at'].toString())
            : null,
      );
}

class _RevenueCard extends StatelessWidget {
  const _RevenueCard({required this.orgs, required this.projectedCents});

  final List<_OrgRow> orgs;
  final int projectedCents;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final money = NumberFormat.simpleCurrency();
    final counts = <OsTier, int>{
      for (final t in OsTier.values) t: 0,
    };
    for (final o in orgs) {
      counts[o.tier] = (counts[o.tier] ?? 0) + 1;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Projected MRR',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              money.format(projectedCents / 100),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: cs.secondary,
                  ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in OsTier.values)
                  if ((counts[t] ?? 0) > 0)
                    Chip(
                      label: Text(
                        '${t.label}: ${counts[t]} × ${money.format(t.priceCents / 100)}',
                      ),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OrgCard extends StatelessWidget {
  const _OrgCard({required this.org, required this.onTap});

  final _OrgRow org;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tierColor = switch (org.tier) {
      OsTier.free => cs.onSurface.withValues(alpha: 0.55),
      OsTier.pro => cs.primary,
      OsTier.os => cs.secondary,
      OsTier.multi => cs.tertiary,
    };
    final last = org.lastActive == null
        ? 'Never'
        : DateFormat.MMMd().add_jm().format(org.lastActive!.toLocal());

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(org.name,
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: tierColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    org.tier.label,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: tierColor,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Text(
                '${org.staffCount} staff · ${org.shiftCountWeek} shifts this week · last active $last',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.65),
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
