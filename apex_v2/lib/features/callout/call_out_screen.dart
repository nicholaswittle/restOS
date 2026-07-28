import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';
import '../../core/entitlements.dart';
import '../../core/shift_time.dart';
import 'call_out_models.dart';

/// No-show call-out engine — report you cannot work, or claim an open shift.
class CallOutScreen extends StatefulWidget {
  const CallOutScreen({
    super.key,
    required this.organizationId,
    this.role = StaffRole.server,
  });

  final String organizationId;
  final StaffRole role;

  @override
  State<CallOutScreen> createState() => _CallOutScreenState();
}

class _CallOutScreenState extends State<CallOutScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  bool _busy = false;

  String _myName = '';
  String? _myRoleLabel;
  List<CallOutData> _callOuts = const [];
  List<ShiftOption> _myShifts = const [];
  Map<String, List<CallOutNotificationData>> _notifsByCallOut = const {};
  List<_StaffPick> _staffRoster = const [];
  String? _expandedId;

  final _subs = <StreamSubscription<dynamic>>[];

  bool get _canManage => widget.role.canManage;

  String get _userId => DemoMode.enabled
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
          .from('call_outs')
          .stream(primaryKey: ['id'])
          .eq('organization_id', widget.organizationId)
          .listen((_) => _load(quiet: true)),
    );
    _subs.add(
      _client
          .from('call_out_notifications')
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
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final weekEnd = DateFormat('yyyy-MM-dd')
          .format(DateTime.now().add(const Duration(days: 7)));

      final results = await Future.wait<dynamic>([
        _client
            .from('profiles')
            .select('id, name, role')
            .eq('id', _userId)
            .maybeSingle(),
        _client
            .from('call_outs')
            .select()
            .eq('organization_id', widget.organizationId)
            .order('created_at', ascending: false)
            .limit(80),
        _client
            .from('call_out_notifications')
            .select()
            .eq('organization_id', widget.organizationId)
            .order('notified_at', ascending: false)
            .limit(200),
        _client
            .from('profiles')
            .select('id, name, role')
            .eq('organization_id', widget.organizationId)
            .order('name'),
      ]);

      final profile = results[0] as Map<String, dynamic>?;
      final myName = profile?['name'] as String? ?? '';
      final myRole = profile?['role'] as String?;

      final callOutRows =
          (results[1] as List).cast<Map<String, dynamic>>();
      final notifRows =
          (results[2] as List).cast<Map<String, dynamic>>();
      final staffRows =
          (results[3] as List).cast<Map<String, dynamic>>();

      // Expire past opens locally so the list stays honest without a cron.
      final now = DateTime.now();
      for (final row in callOutRows) {
        if (row['status'] != 'open') continue;
        final exp = DateTime.tryParse(row['expires_at'] as String? ?? '');
        if (exp != null && exp.isBefore(now)) {
          try {
            await _client
                .from('call_outs')
                .update({'status': 'expired'})
                .eq('id', row['id'])
                .eq('organization_id', widget.organizationId)
                .eq('status', 'open');
            row['status'] = 'expired';
          } catch (_) {}
        }
      }

      List<ShiftOption> myShifts = const [];
      if (myName.isNotEmpty) {
        final shiftRows = await _client
            .from('shifts')
            .select('id, shift_date, start_time, end_time, role, staff')
            .eq('organization_id', widget.organizationId)
            .eq('staff', myName)
            .gte('shift_date', today)
            .lte('shift_date', weekEnd)
            .order('shift_date');
        myShifts = (shiftRows as List)
            .cast<Map<String, dynamic>>()
            .map(ShiftOption.fromMap)
            .toList();
      }

      final notifsBy = <String, List<CallOutNotificationData>>{};
      for (final n in notifRows) {
        final data = CallOutNotificationData.fromMap(n);
        notifsBy.putIfAbsent(data.callOutId, () => []).add(data);
      }

      if (!mounted) return;
      setState(() {
        _myName = myName;
        _myRoleLabel = myRole;
        _callOuts = callOutRows.map(CallOutData.fromMap).toList();
        _myShifts = myShifts;
        _notifsByCallOut = notifsBy;
        _staffRoster = staffRows
            .map((r) => _StaffPick(
                  id: r['id'] as String,
                  name: r['name'] as String? ?? '',
                  role: r['role'] as String?,
                ))
            .where((s) => s.name.isNotEmpty)
            .toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load call-outs. Pull to retry.';
      });
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _submitCallOut() async {
    if (_busy) return;
    if (_myShifts.isEmpty) {
      _snack('You have no upcoming shifts to call out from.');
      return;
    }

    ShiftOption? picked = _myShifts.first;
    final reasonCtrl = TextEditingController();

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('I can\'t make it',
                      style: Theme.of(ctx).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ShiftOption>(
                    initialValue: picked,
                    items: [
                      for (final s in _myShifts)
                        DropdownMenuItem(value: s, child: Text(s.label)),
                    ],
                    onChanged: (v) => setLocal(() => picked = v),
                    decoration: const InputDecoration(
                      labelText: 'Shift',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: reasonCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Reason (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Notify the team'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    final shift = picked;
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (ok != true || shift == null) return;

    setState(() => _busy = true);
    try {
      DateTime? expires;
      final start = combineDateAndTime(shift.shiftDate, shift.startTime);
      expires = start;

      final row = await _client
          .from('call_outs')
          .insert({
            'organization_id': widget.organizationId,
            'shift_id': shift.id,
            'shift_date': shift.shiftDate,
            'start_time': shift.startTime,
            'end_time': shift.endTime,
            'staff_name': _myName,
            'staff_user_id': _userId,
            'staff_role': shift.role ?? _myRoleLabel,
            'reason': reason.isEmpty ? null : reason,
            'status': 'open',
            'expires_at': expires?.toUtc().toIso8601String(),
          })
          .select('id')
          .single();

      final callOutId = row['id'] as String;
      // Best-effort fan-out — in-app list works even if SMS / edge is down.
      if (!DemoMode.enabled) {
        try {
          await _client.functions.invoke(
            'route-callout',
            body: {'call_out_id': callOutId},
          );
        } catch (e, st) {
          debugPrint('route-callout skipped: $e');
          debugPrint('$st');
        }
      }

      if (!mounted) return;
      _snack('Call-out sent. Waiting for cover.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      _snack('Could not create call-out. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim(CallOutData callOut) async {
    if (_busy || !callOut.isOpen) return;
    if (callOut.staffUserId == _userId || callOut.staffName == _myName) {
      _snack('You cannot claim your own call-out.');
      return;
    }

    setState(() => _busy = true);
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final updated = await _client
          .from('call_outs')
          .update({
            'status': 'filled',
            'filled_by': _myName,
            'filled_by_user_id': _userId,
            'filled_at': now,
          })
          .eq('id', callOut.id)
          .eq('organization_id', widget.organizationId)
          .eq('status', 'open')
          .select('id');

      if ((updated as List).isEmpty) {
        if (!mounted) return;
        _snack('Someone else claimed it first.');
        await _load(quiet: true);
        return;
      }

      if (callOut.shiftId != null) {
        await _client.from('shifts').update({
          'staff': _myName,
        }).eq('id', callOut.shiftId!).eq(
            'organization_id', widget.organizationId);
      }

      await _client
          .from('call_out_notifications')
          .update({
            'response': 'accepted',
            'responded_at': now,
          })
          .eq('call_out_id', callOut.id)
          .eq('user_id', _userId)
          .eq('organization_id', widget.organizationId);

      if (!mounted) return;
      _snack('Shift claimed! See you there.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      _snack('Could not claim shift. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(CallOutData callOut) async {
    if (_busy || !callOut.isOpen) return;
    setState(() => _busy = true);
    try {
      await _client
          .from('call_outs')
          .update({'status': 'cancelled'})
          .eq('id', callOut.id)
          .eq('organization_id', widget.organizationId);
      if (!mounted) return;
      _snack('Call-out cancelled.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      _snack('Could not cancel.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manualAssign(CallOutData callOut) async {
    if (_busy || !callOut.isOpen || _staffRoster.isEmpty) return;
    final picks = _staffRoster
        .where((s) => s.name != callOut.staffName)
        .toList();
    if (picks.isEmpty) {
      _snack('No other staff to assign.');
      return;
    }

    final chosen = await showDialog<_StaffPick>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Assign cover'),
        children: [
          for (final s in picks)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Text(s.name),
            ),
        ],
      ),
    );
    if (chosen == null) return;

    setState(() => _busy = true);
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final updated = await _client
          .from('call_outs')
          .update({
            'status': 'filled',
            'filled_by': chosen.name,
            'filled_by_user_id': chosen.id,
            'filled_at': now,
          })
          .eq('id', callOut.id)
          .eq('organization_id', widget.organizationId)
          .eq('status', 'open')
          .select('id');

      if ((updated as List).isEmpty) {
        if (!mounted) return;
        _snack('Call-out is no longer open.');
        await _load(quiet: true);
        return;
      }

      if (callOut.shiftId != null) {
        await _client.from('shifts').update({
          'staff': chosen.name,
        }).eq('id', callOut.shiftId!).eq(
            'organization_id', widget.organizationId);
      }

      if (!mounted) return;
      _snack('Assigned to ${chosen.name}.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      _snack('Could not assign.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<CallOutData> get _openForClaim {
    return _callOuts.where((c) {
      if (!c.isOpen) return false;
      if (c.staffUserId == _userId || c.staffName == _myName) return false;
      // Soft role filter — managers see all; staff see matching role when set.
      if (_canManage) return true;
      final need = c.staffRole?.trim().toLowerCase();
      if (need == null || need.isEmpty) return true;
      final mine = (_myRoleLabel ?? '').trim().toLowerCase();
      if (mine.isEmpty) return true;
      return mine == need ||
          mine.contains(need) ||
          need.contains(mine) ||
          // Owner/manager profiles often cover any role.
          mine == 'owner' ||
          mine == 'manager';
    }).toList();
  }

  List<CallOutData> get _mineOpen => _callOuts
      .where((c) =>
          c.isOpen &&
          (c.staffUserId == _userId || c.staffName == _myName))
      .toList();

  List<CallOutData> get _allOpen =>
      _callOuts.where((c) => c.isOpen).toList();

  List<CallOutData> get _history => _callOuts
      .where((c) => c.status != 'open')
      .take(30)
      .toList();

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Call-Outs')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _busy ? null : _submitCallOut,
                icon: const Icon(Icons.phone_disabled_rounded),
                label: const Text('I can\'t make it'),
              ),
            ),
            const SizedBox(height: 20),
            if (_mineOpen.isNotEmpty) ...[
              Text('Your open call-outs',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              for (final c in _mineOpen)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _CallOutCard(
                    callOut: c,
                    notifs: _notifsByCallOut[c.id] ?? const [],
                    expanded: _expandedId == c.id,
                    busy: _busy,
                    canManage: _canManage,
                    isMine: true,
                    onToggle: () => setState(() {
                      _expandedId = _expandedId == c.id ? null : c.id;
                    }),
                    onCancel: () => _cancel(c),
                    onAssign: _canManage ? () => _manualAssign(c) : null,
                  ),
                ),
              const SizedBox(height: 12),
            ],
            Text(
              _canManage ? 'Open call-outs' : 'Shifts needing cover',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if ((_canManage ? _allOpen : _openForClaim).isEmpty)
              const _EmptyCard(
                icon: Icons.check_circle_outline_rounded,
                title: 'No open call-outs',
                subtitle: 'When someone cannot work, it shows up here.',
              )
            else
              for (final c in (_canManage ? _allOpen : _openForClaim))
                if (!_mineOpen.any((m) => m.id == c.id))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _CallOutCard(
                      callOut: c,
                      notifs: _notifsByCallOut[c.id] ?? const [],
                      expanded: _expandedId == c.id,
                      busy: _busy,
                      canManage: _canManage,
                      isMine: false,
                      onToggle: () => setState(() {
                        _expandedId = _expandedId == c.id ? null : c.id;
                      }),
                      onClaim: () => _claim(c),
                      onCancel: _canManage ? () => _cancel(c) : null,
                      onAssign: _canManage ? () => _manualAssign(c) : null,
                    ),
                  ),
            if (_canManage) ...[
              const SizedBox(height: 20),
              Text('Recent history',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              if (_history.isEmpty)
                Text(
                  'Filled, cancelled, and expired call-outs land here.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.55),
                      ),
                )
              else
                for (final c in _history)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _CallOutCard(
                      callOut: c,
                      notifs: _notifsByCallOut[c.id] ?? const [],
                      expanded: _expandedId == c.id,
                      busy: _busy,
                      canManage: true,
                      isMine: false,
                      onToggle: () => setState(() {
                        _expandedId = _expandedId == c.id ? null : c.id;
                      }),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StaffPick {
  const _StaffPick({
    required this.id,
    required this.name,
    required this.role,
  });

  final String id;
  final String name;
  final String? role;
}

class _CallOutCard extends StatelessWidget {
  const _CallOutCard({
    required this.callOut,
    required this.notifs,
    required this.expanded,
    required this.busy,
    required this.canManage,
    required this.isMine,
    required this.onToggle,
    this.onClaim,
    this.onCancel,
    this.onAssign,
  });

  final CallOutData callOut;
  final List<CallOutNotificationData> notifs;
  final bool expanded;
  final bool busy;
  final bool canManage;
  final bool isMine;
  final VoidCallback onToggle;
  final VoidCallback? onClaim;
  final VoidCallback? onCancel;
  final VoidCallback? onAssign;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${callOut.staffName} · ${callOut.dayLabel}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  _StatusChip(status: callOut.status),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                callOut.hoursLabel,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.65),
                    ),
              ),
              if (callOut.staffRole != null &&
                  callOut.staffRole!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  callOut.staffRole!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.primary,
                      ),
                ),
              ],
              if (callOut.filledBy != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Covered by ${callOut.filledBy}',
                  style: TextStyle(
                    color: cs.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (expanded) ...[
                if (callOut.reason != null && callOut.reason!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('Reason: ${callOut.reason}'),
                ],
                if (canManage && notifs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Notified',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  for (final n in notifs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${n.staffName} — ${n.response ?? 'no response yet'}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.7),
                            ),
                      ),
                    ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (onClaim != null && !isMine)
                      FilledButton(
                        onPressed: busy ? null : onClaim,
                        child: const Text('I\'ll take it'),
                      ),
                    if (onAssign != null)
                      FilledButton.tonal(
                        onPressed: busy ? null : onAssign,
                        child: const Text('Assign'),
                      ),
                    if (onCancel != null)
                      OutlinedButton(
                        onPressed: busy ? null : onCancel,
                        child: const Text('Cancel'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      'open' => ('Open', cs.tertiary),
      'filled' => ('Filled', cs.secondary),
      'cancelled' => ('Cancelled', cs.onSurface.withValues(alpha: 0.45)),
      'expired' => ('Expired', cs.error),
      _ => (status, cs.onSurface),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
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
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Icon(icon, size: 36, color: cs.onSurface.withValues(alpha: 0.4)),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
          ),
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            height: 96,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ],
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
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.wifi_off_rounded,
              size: 44, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ]),
      ),
    );
  }
}
