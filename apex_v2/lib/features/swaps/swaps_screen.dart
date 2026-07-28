import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';
import '../../core/entitlements.dart';
import '../../core/shift_time.dart';

/// Post, claim, and approve shift swaps.
class SwapsScreen extends StatefulWidget {
  const SwapsScreen({
    super.key,
    required this.organizationId,
    this.role,
  });

  final String organizationId;
  final StaffRole? role;

  @override
  State<SwapsScreen> createState() => _SwapsScreenState();
}

class _SwapsScreenState extends State<SwapsScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  bool _busy = false;

  String? _myName;
  List<_SwapRow> _swaps = const [];
  List<_MyShift> _myShifts = const [];

  final _subs = <StreamSubscription<dynamic>>[];

  String get _userId => DemoMode.enabled
      ? DemoMode.userId
      : (_client.auth.currentUser?.id ?? '');

  bool get _canManage => widget.role?.canManage ?? false;

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
          .from('swaps')
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
      final todayKey = dateKeyOf(DateTime.now());
      final results = await Future.wait<dynamic>([
        _client
            .from('profiles')
            .select('name')
            .eq('id', _userId)
            .eq('organization_id', widget.organizationId)
            .maybeSingle(),
        _client
            .from('swaps')
            .select()
            .eq('organization_id', widget.organizationId)
            .order('created_at', ascending: false)
            .limit(40),
        _client
            .from('shifts')
            .select('id, shift_date, staff, start_time, end_time, role, zone')
            .eq('organization_id', widget.organizationId)
            .gte('shift_date', todayKey)
            .order('shift_date')
            .order('start_time'),
      ]);

      if (!mounted) return;
      final profile = results[0] as Map<String, dynamic>?;
      final myName = profile?['name'] as String? ?? '';
      final swaps = (results[1] as List)
          .cast<Map<String, dynamic>>()
          .map(_SwapRow.fromMap)
          .toList();
      final myShifts = (results[2] as List)
          .cast<Map<String, dynamic>>()
          .where((r) =>
              (r['staff'] as String?)?.trim().toLowerCase() ==
              myName.trim().toLowerCase())
          .map(_MyShift.fromMap)
          .toList();

      setState(() {
        _myName = myName;
        _swaps = swaps;
        _myShifts = myShifts;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load swaps. Pull to retry.';
      });
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _postSwap(_MyShift shift) async {
    if (_busy || _myName == null) return;
    setState(() => _busy = true);
    try {
      final d = DateTime.tryParse(shift.shiftDate) ?? DateTime.now();
      await _client.from('swaps').insert({
        'organization_id': widget.organizationId,
        'shift_title':
            '${formatTime(shift.startTime)} – ${formatTime(shift.endTime)}'
            '${shift.role.isNotEmpty ? ' · ${shift.role}' : ''}',
        'original_staff': _myName,
        'shift_date': shift.shiftDate,
        'day_num': d.day,
        'status': 'Available',
      });
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Swap posted — waiting for a claim.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not post swap. Try again.');
    }
  }

  Future<void> _claim(_SwapRow swap) async {
    if (_busy || _myName == null) return;
    setState(() => _busy = true);
    try {
      await _client.from('swaps').update({
        'status': 'Pending Approval',
        'claimed_by': _userId,
        'claimed_by_name': _myName,
      }).eq('id', swap.id);
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Claimed — waiting on manager approval.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not claim. Try again.');
    }
  }

  Future<void> _decide(_SwapRow swap, {required bool approve}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (approve) {
        final claimer = swap.claimedByName;
        if (claimer == null || claimer.isEmpty) {
          throw StateError('No claimer');
        }
        final matches = await _client
            .from('shifts')
            .select('id')
            .eq('organization_id', widget.organizationId)
            .eq('shift_date', swap.shiftDate)
            .eq('staff', swap.originalStaff);
        if ((matches as List).isNotEmpty) {
          await _client
              .from('shifts')
              .update({'staff': claimer})
              .eq('id', matches.first['id']);
        }
        await _client
            .from('swaps')
            .update({'status': 'Swapped'})
            .eq('id', swap.id);
      } else {
        await _client.from('swaps').update({
          'status': 'Available',
          'claimed_by': null,
          'claimed_by_name': null,
        }).eq('id', swap.id);
      }
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(approve ? 'Swap approved.' : 'Claim sent back to the board.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not update swap. Try again.');
    }
  }

  Future<void> _openPostSheet() async {
    if (_myShifts.isEmpty) {
      _snack('You have no upcoming shifts to post.');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text('Post a swap', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Pick one of your upcoming shifts.',
                style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
              ),
              const SizedBox(height: 12),
              for (final s in _myShifts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${formatDayLabel(s.shiftDate)} · ${formatTime(s.startTime)} – ${formatTime(s.endTime)}',
                  ),
                  subtitle: Text(
                    [if (s.role.isNotEmpty) s.role, if (s.zone.isNotEmpty) s.zone]
                        .join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.pop(ctx);
                    _postSwap(s);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final cs = Theme.of(context).colorScheme;
    final open = _swaps.where((s) => s.status == 'Available').toList();
    final pending =
        _swaps.where((s) => s.status == 'Pending Approval').toList();
    final done = _swaps
        .where((s) => s.status != 'Available' && s.status != 'Pending Approval')
        .toList();

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _openPostSheet,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Post swap'),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        color: cs.primary,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                  child: Row(children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: Text('Shift swaps',
                          style: Theme.of(context).textTheme.headlineSmall),
                    ),
                  ]),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
              sliver: SliverList.list(children: [
                if (open.isEmpty && pending.isEmpty && done.isEmpty)
                  const _EmptyCard(
                    icon: Icons.swap_horiz_rounded,
                    title: 'No swaps yet',
                    subtitle: 'Post one of your shifts when you need cover.',
                  )
                else ...[
                  if (pending.isNotEmpty) ...[
                    Text('Needs approval',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final s in pending) ...[
                      _SwapCard(
                        swap: s,
                        myName: _myName,
                        canManage: _canManage,
                        busy: _busy,
                        onClaim: null,
                        onApprove: () => _decide(s, approve: true),
                        onDeny: () => _decide(s, approve: false),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 8),
                  ],
                  if (open.isNotEmpty) ...[
                    Text('Available',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final s in open) ...[
                      _SwapCard(
                        swap: s,
                        myName: _myName,
                        canManage: _canManage,
                        busy: _busy,
                        onClaim: s.originalStaff.trim().toLowerCase() ==
                                (_myName ?? '').trim().toLowerCase()
                            ? null
                            : () => _claim(s),
                        onApprove: null,
                        onDeny: null,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                  if (done.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Recent',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final s in done.take(8)) ...[
                      _SwapCard(
                        swap: s,
                        myName: _myName,
                        canManage: _canManage,
                        busy: _busy,
                        onClaim: null,
                        onApprove: null,
                        onDeny: null,
                      ),
                      const SizedBox(height: 10),
                    ],
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

class _SwapRow {
  const _SwapRow({
    required this.id,
    required this.shiftTitle,
    required this.originalStaff,
    required this.shiftDate,
    required this.status,
    this.claimedByName,
  });

  final String id;
  final String shiftTitle;
  final String originalStaff;
  final String shiftDate;
  final String status;
  final String? claimedByName;

  factory _SwapRow.fromMap(Map<String, dynamic> m) => _SwapRow(
        id: m['id'] as String? ?? '',
        shiftTitle: m['shift_title'] as String? ?? 'Shift',
        originalStaff: m['original_staff'] as String? ?? '',
        shiftDate: m['shift_date'] as String? ?? '',
        status: m['status'] as String? ?? 'Available',
        claimedByName: m['claimed_by_name'] as String?,
      );
}

class _MyShift {
  const _MyShift({
    required this.id,
    required this.shiftDate,
    required this.startTime,
    required this.endTime,
    required this.role,
    required this.zone,
  });

  final String id;
  final String shiftDate;
  final String startTime;
  final String endTime;
  final String role;
  final String zone;

  factory _MyShift.fromMap(Map<String, dynamic> m) => _MyShift(
        id: m['id'] as String? ?? '',
        shiftDate: m['shift_date'] as String? ?? '',
        startTime: m['start_time'] as String? ?? '00:00',
        endTime: m['end_time'] as String? ?? '00:00',
        role: m['role'] as String? ?? '',
        zone: m['zone'] as String? ?? '',
      );
}

class _SwapCard extends StatelessWidget {
  const _SwapCard({
    required this.swap,
    required this.myName,
    required this.canManage,
    required this.busy,
    required this.onClaim,
    required this.onApprove,
    required this.onDeny,
  });

  final _SwapRow swap;
  final String? myName;
  final bool canManage;
  final bool busy;
  final VoidCallback? onClaim;
  final VoidCallback? onApprove;
  final VoidCallback? onDeny;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(swap.shiftTitle,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(swap.status,
                  style: Theme.of(context).textTheme.labelSmall),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            '${swap.originalStaff} · ${formatDayLabel(swap.shiftDate)}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
          ),
          if (swap.claimedByName != null) ...[
            const SizedBox(height: 4),
            Text(
              'Claimed by ${swap.claimedByName}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.primary,
                  ),
            ),
          ],
          if (onClaim != null || onApprove != null) ...[
            const SizedBox(height: 12),
            Row(children: [
              if (onClaim != null)
                FilledButton(
                  onPressed: busy ? null : onClaim,
                  child: const Text('I can cover'),
                ),
              if (onApprove != null) ...[
                FilledButton(
                  onPressed: busy ? null : onApprove,
                  child: const Text('Approve'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : onDeny,
                  child: const Text('Deny'),
                ),
              ],
            ]),
          ],
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
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 160,
            height: 34,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            height: 100,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ]),
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

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(children: [
          Icon(icon, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.5),
                      )),
            ]),
          ),
        ]),
      ),
    );
  }
}
