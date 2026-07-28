import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';
import '../../core/entitlements.dart';
import '../../core/shift_time.dart';

/// Manager roster + invite codes + owner role promotion.
class TeamScreen extends StatefulWidget {
  const TeamScreen({
    super.key,
    required this.organizationId,
    this.role,
  });

  final String organizationId;
  final StaffRole? role;

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  bool _busy = false;
  String? _latestCode;

  List<_Member> _members = const [];
  List<_Invite> _invites = const [];

  final _subs = <StreamSubscription<dynamic>>[];

  bool get _canManage => widget.role?.canManage ?? false;
  bool get _isOwner => widget.role == StaffRole.owner;

  String get _selfId => DemoMode.enabled
      ? DemoMode.userId
      : (_client.auth.currentUser?.id ?? '');

  @override
  void initState() {
    super.initState();
    _load().then((_) => _subscribeRealtime());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _subscribeRealtime() {
    _subs.add(
      _client
          .from('profiles')
          .stream(primaryKey: ['id'])
          .eq('organization_id', widget.organizationId)
          .listen((_) => _load(quiet: true)),
    );
  }

  Future<void> _load({bool quiet = false}) async {
    if (!mounted) return;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<dynamic>([
        _client
            .from('profiles')
            .select('id, name, role, hourly_rate')
            .eq('organization_id', widget.organizationId)
            .order('name'),
        if (_canManage)
          _client
              .from('organization_invites')
              .select('code, role, expires_at, used_at, created_at')
              .eq('organization_id', widget.organizationId)
              .order('created_at', ascending: false)
              .limit(10)
        else
          Future.value(const <dynamic>[]),
      ]);

      if (!mounted) return;
      setState(() {
        _members = (results[0] as List)
            .cast<Map<String, dynamic>>()
            .map(_Member.fromMap)
            .toList();
        _invites = (results[1] as List)
            .cast<Map<String, dynamic>>()
            .map(_Invite.fromMap)
            .toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load team. Pull to retry.';
      });
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _generateInvite() async {
    if (!_canManage || _busy) return;
    setState(() => _busy = true);
    try {
      String code;
      if (DemoMode.enabled) {
        code = _demoInviteCode();
      } else {
        final raw = await _client.rpc('apex_generate_invite');
        code = (raw as String?)?.trim() ?? '';
      }
      if (!mounted) return;
      if (code.isEmpty) {
        setState(() => _busy = false);
        _snack('Could not create invite.');
        return;
      }
      await Clipboard.setData(ClipboardData(text: code));
      setState(() {
        _busy = false;
        _latestCode = code;
      });
      _snack('Invite $code copied — share it with your staff.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not create invite.');
    }
  }

  static String _demoInviteCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random();
    return List.generate(6, (_) => alphabet[rng.nextInt(alphabet.length)])
        .join();
  }

  void _copy(String code) {
    Clipboard.setData(ClipboardData(text: code));
    _snack('Copied $code');
  }

  Future<void> _openRoleSheet(_Member member) async {
    if (!_isOwner) return;
    if (member.id == _selfId) {
      _snack('You cannot change your own role here.');
      return;
    }

    const roles = ['Staff', 'Server', 'Kitchen', 'Manager', 'Owner'];
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Set role for ${member.name}',
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Only owners can change roles.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                ),
                const SizedBox(height: 12),
                for (final r in roles)
                  ListTile(
                    title: Text(r),
                    trailing: member.role.toLowerCase() == r.toLowerCase()
                        ? Icon(Icons.check_rounded, color: cs.primary)
                        : null,
                    onTap: () => Navigator.pop(ctx, r),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (picked == null || !mounted) return;
    if (picked.toLowerCase() == member.role.toLowerCase()) return;

    setState(() => _busy = true);
    try {
      if (DemoMode.enabled) {
        for (final row in DemoSeed.staff) {
          if (row['id'] == member.id) {
            row['role'] = picked;
            break;
          }
        }
      } else {
        await _client.rpc(
          'apex_set_role',
          params: {
            'target_user_id': member.id,
            'new_role': picked,
          },
        );
      }
      if (!mounted) return;
      _snack('${member.name} is now $picked.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      if (msg.contains('cannot_demote_last_owner')) {
        _snack('Keep at least one Owner on the team.');
      } else {
        _snack('Could not update role.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _members.isEmpty) {
      return const Scaffold(body: _LoadingView());
    }
    if (_error != null && _members.isEmpty) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      floatingActionButton: _canManage
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _generateInvite,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(_busy ? 'Creating…' : 'Invite'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () => _load(),
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
                          Text('Team',
                              style: Theme.of(context).textTheme.displaySmall),
                          Text(
                            _canManage
                                ? 'Roster · invite codes expire in 7 days'
                                : 'Your crew',
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
                  ]),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
              sliver: SliverList.list(children: [
                if (_latestCode != null) ...[
                  _InviteBanner(
                    code: _latestCode!,
                    onCopy: () => _copy(_latestCode!),
                  ),
                  const SizedBox(height: 16),
                ],
                Text('People', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                if (_members.isEmpty)
                  const _EmptyCard(
                    title: 'No one yet',
                    subtitle: 'Generate an invite and have staff join.',
                  )
                else
                  for (var i = 0; i < _members.length; i++) ...[
                    _MemberTile(
                      member: _members[i],
                      onTap: _isOwner && _members[i].id != _selfId
                          ? () => _openRoleSheet(_members[i])
                          : null,
                    ),
                    if (i != _members.length - 1) const SizedBox(height: 10),
                  ],
                if (_canManage) ...[
                  const SizedBox(height: 24),
                  Text('Recent invites',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  if (_invites.isEmpty)
                    Text(
                      'No invites yet. Tap Invite to create one.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                    )
                  else
                    for (final inv in _invites) ...[
                      _InviteTile(
                        invite: inv,
                        onCopy: inv.used ? null : () => _copy(inv.code),
                      ),
                      const SizedBox(height: 8),
                    ],
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Member {
  const _Member({
    required this.id,
    required this.name,
    required this.role,
    required this.hourlyRate,
  });

  final String id;
  final String name;
  final String role;
  final double hourlyRate;

  factory _Member.fromMap(Map<String, dynamic> m) => _Member(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? 'Teammate',
        role: m['role'] as String? ?? 'Staff',
        hourlyRate: (m['hourly_rate'] as num?)?.toDouble() ?? 0,
      );
}

class _Invite {
  const _Invite({
    required this.code,
    required this.role,
    required this.used,
    this.expiresAt,
  });

  final String code;
  final String role;
  final bool used;
  final String? expiresAt;

  factory _Invite.fromMap(Map<String, dynamic> m) => _Invite(
        code: m['code'] as String? ?? '',
        role: m['role'] as String? ?? 'Staff',
        used: m['used_at'] != null,
        expiresAt: m['expires_at'] as String?,
      );
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member, this.onTap});

  final _Member member;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rate = member.hourlyRate > 0
        ? ' · \$${member.hourlyRate.toStringAsFixed(2)}/hr'
        : '';
    return Card(
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: cs.primary.withValues(alpha: 0.2),
          child: Text(
            member.name.isNotEmpty ? member.name[0].toUpperCase() : '?',
            style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700),
          ),
        ),
        title: Text(member.name),
        subtitle: Text('${member.role}$rate'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RoleBadge(role: member.role),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.edit_outlined,
                  size: 18, color: cs.onSurface.withValues(alpha: 0.45)),
            ],
          ],
        ),
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (role.toLowerCase()) {
      'owner' => cs.tertiary,
      'manager' => cs.primary,
      'kitchen' => cs.secondary,
      _ => cs.onSurface.withValues(alpha: 0.55),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        role,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _InviteTile extends StatelessWidget {
  const _InviteTile({required this.invite, this.onCopy});

  final _Invite invite;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final exp = invite.expiresAt != null
        ? ' · expires ${formatDayLabel(invite.expiresAt!.substring(0, 10))}'
        : '';
    return Card(
      child: ListTile(
        title: Text(invite.code,
            style: const TextStyle(
                fontFamily: 'monospace', fontWeight: FontWeight.w700)),
        subtitle: Text(
          invite.used ? 'Used' : 'Active · ${invite.role}$exp',
          style: TextStyle(
            color: invite.used
                ? cs.onSurface.withValues(alpha: 0.45)
                : cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
        trailing: onCopy == null
            ? null
            : IconButton(
                tooltip: 'Copy',
                onPressed: onCopy,
                icon: const Icon(Icons.copy_rounded),
              ),
      ),
    );
  }
}

class _InviteBanner extends StatelessWidget {
  const _InviteBanner({required this.code, required this.onCopy});

  final String code;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Share this code with your staff',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(code,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontFamily: 'monospace',
                          letterSpacing: 2,
                        )),
              ],
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy'),
          ),
        ]),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.55),
                  )),
        ]),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          height: 220,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
            onPressed: onRetry,
          ),
        ]),
      ),
    );
  }
}
