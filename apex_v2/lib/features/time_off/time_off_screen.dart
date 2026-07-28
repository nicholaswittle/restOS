import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';
import '../../core/entitlements.dart';
import '../../core/shift_time.dart';

/// Request time off and (for managers) approve or deny.
class TimeOffScreen extends StatefulWidget {
  const TimeOffScreen({
    super.key,
    required this.organizationId,
    this.role,
  });

  final String organizationId;
  final StaffRole? role;

  @override
  State<TimeOffScreen> createState() => _TimeOffScreenState();
}

class _TimeOffScreenState extends State<TimeOffScreen> {
  final _client = Supabase.instance.client;
  final _reason = TextEditingController();

  bool _loading = true;
  String? _error;
  bool _busy = false;
  bool _composing = false;

  String? _myName;
  DateTime _start = DateTime.now().add(const Duration(days: 1));
  DateTime _end = DateTime.now().add(const Duration(days: 1));
  List<_TimeOffRow> _rows = const [];

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
    _reason.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    _subs.add(
      _client
          .from('time_off_requests')
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
            .select('name')
            .eq('id', _userId)
            .eq('organization_id', widget.organizationId)
            .maybeSingle(),
        _client
            .from('time_off_requests')
            .select()
            .eq('organization_id', widget.organizationId)
            .order('start_date', ascending: true)
            .limit(50),
      ]);

      if (!mounted) return;
      final profile = results[0] as Map<String, dynamic>?;
      var rows = (results[1] as List)
          .cast<Map<String, dynamic>>()
          .map(_TimeOffRow.fromMap)
          .toList();
      if (!_canManage) {
        rows = rows.where((r) => r.userId == _userId).toList();
      }

      setState(() {
        _myName = profile?['name'] as String?;
        _rows = rows;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load time off. Pull to retry.';
      });
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _pickStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() {
        _start = picked;
        if (_end.isBefore(_start)) _end = _start;
      });
    }
  }

  Future<void> _pickEnd() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _end,
      firstDate: _start,
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() => _end = picked);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final reason = _reason.text.trim();
    if (reason.isEmpty) {
      _snack('Add a short reason.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _client.from('time_off_requests').insert({
        'organization_id': widget.organizationId,
        'user_id': _userId,
        'user_name': _myName ?? 'Team Member',
        'start_date': dateKeyOf(_start),
        'end_date': dateKeyOf(_end),
        'reason': reason,
        'status': 'Pending',
        'notified': false,
      });
      if (!mounted) return;
      _reason.clear();
      setState(() {
        _busy = false;
        _composing = false;
      });
      _snack('Request sent.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not submit. Try again.');
    }
  }

  Future<void> _setStatus(_TimeOffRow row, String status) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _client.from('time_off_requests').update({
        'status': status,
        'notified': false,
      }).eq('id', row.id);
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Marked $status.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not update. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final cs = Theme.of(context).colorScheme;
    final pending = _rows.where((r) => r.status == 'Pending').toList();
    final rest = _rows.where((r) => r.status != 'Pending').toList();

    return Scaffold(
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
                      child: Text('Time off',
                          style: Theme.of(context).textTheme.headlineSmall),
                    ),
                  ]),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              sliver: SliverList.list(children: [
                if (!_composing)
                  _ActionButton(
                    icon: Icons.event_busy_rounded,
                    label: 'Request time off',
                    onTap: () => setState(() => _composing = true),
                  )
                else
                  _ComposeCard(
                    start: _start,
                    end: _end,
                    reason: _reason,
                    busy: _busy,
                    onPickStart: _pickStart,
                    onPickEnd: _pickEnd,
                    onCancel: () => setState(() => _composing = false),
                    onSubmit: _submit,
                  ),
                const SizedBox(height: 16),
                if (_rows.isEmpty)
                  const _EmptyCard(
                    icon: Icons.beach_access_outlined,
                    title: 'No requests yet',
                    subtitle: 'Request days off in three taps.',
                  )
                else ...[
                  if (pending.isNotEmpty) ...[
                    Text(
                      _canManage ? 'Pending approval' : 'Pending',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final r in pending) ...[
                      _RequestCard(
                        row: r,
                        canManage: _canManage,
                        busy: _busy,
                        onApprove: () => _setStatus(r, 'Approved'),
                        onDeny: () => _setStatus(r, 'Denied'),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                  if (rest.isNotEmpty) ...[
                    Text('History',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final r in rest) ...[
                      _RequestCard(
                        row: r,
                        canManage: false,
                        busy: _busy,
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

class _TimeOffRow {
  const _TimeOffRow({
    required this.id,
    required this.userId,
    required this.userName,
    required this.startDate,
    required this.endDate,
    required this.reason,
    required this.status,
  });

  final String id;
  final String userId;
  final String userName;
  final String startDate;
  final String endDate;
  final String reason;
  final String status;

  factory _TimeOffRow.fromMap(Map<String, dynamic> m) => _TimeOffRow(
        id: m['id'] as String? ?? '',
        userId: m['user_id'] as String? ?? '',
        userName: m['user_name'] as String? ?? 'Teammate',
        startDate: m['start_date'] as String? ?? '',
        endDate: m['end_date'] as String? ?? '',
        reason: m['reason'] as String? ?? '',
        status: m['status'] as String? ?? 'Pending',
      );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
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
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(children: [
            Icon(icon, color: cs.primary, size: 26),
            const SizedBox(height: 6),
            Text(label, style: Theme.of(context).textTheme.labelLarge),
          ]),
        ),
      ),
    );
  }
}

class _ComposeCard extends StatelessWidget {
  const _ComposeCard({
    required this.start,
    required this.end,
    required this.reason,
    required this.busy,
    required this.onPickStart,
    required this.onPickEnd,
    required this.onCancel,
    required this.onSubmit,
  });

  final DateTime start;
  final DateTime end;
  final TextEditingController reason;
  final bool busy;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('New request',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: cs.onPrimaryContainer)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _DateChip(
                label: 'From',
                value: formatDayLabel(dateKeyOf(start)),
                onTap: onPickStart,
                color: cs.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _DateChip(
                label: 'To',
                value: formatDayLabel(dateKeyOf(end)),
                onTap: onPickEnd,
                color: cs.onPrimaryContainer,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: reason,
            maxLines: 3,
            style: TextStyle(color: cs.onPrimaryContainer),
            decoration: InputDecoration(
              hintText: 'Reason (short)',
              hintStyle: TextStyle(
                color: cs.onPrimaryContainer.withValues(alpha: 0.45),
              ),
              filled: true,
              fillColor: cs.onPrimaryContainer.withValues(alpha: 0.08),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            TextButton(
              onPressed: busy ? null : onCancel,
              child: Text('Cancel',
                  style: TextStyle(
                      color: cs.onPrimaryContainer.withValues(alpha: 0.7))),
            ),
            const Spacer(),
            FilledButton(
              onPressed: busy ? null : onSubmit,
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Submit'),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  const _DateChip({
    required this.label,
    required this.value,
    required this.onTap,
    required this.color,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: color.withValues(alpha: 0.7))),
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: color)),
          ]),
        ),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.row,
    required this.canManage,
    required this.busy,
    required this.onApprove,
    required this.onDeny,
  });

  final _TimeOffRow row;
  final bool canManage;
  final bool busy;
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
              child: Text(row.userName,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Text(row.status,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: row.status == 'Approved'
                          ? const Color(0xFF4ADE80)
                          : row.status == 'Denied'
                              ? const Color(0xFFF87171)
                              : cs.primary,
                    )),
          ]),
          const SizedBox(height: 4),
          Text(
            row.startDate == row.endDate
                ? formatDayLabel(row.startDate)
                : '${formatDayLabel(row.startDate)} → ${formatDayLabel(row.endDate)}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(row.reason,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6),
                  )),
          if (canManage && onApprove != null) ...[
            const SizedBox(height: 12),
            Row(children: [
              FilledButton(
                onPressed: busy ? null : onApprove,
                child: const Text('Approve'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy ? null : onDeny,
                child: const Text('Deny'),
              ),
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
        child: Container(
          height: 120,
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
