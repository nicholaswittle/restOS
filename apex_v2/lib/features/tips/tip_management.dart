import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tip pool entry + per-employee week view.
///
/// Owner / manager: pick date → enter totals → Split → Confirm.
/// Everyone: see their tip allocations for the current week.
class TipManagement extends StatefulWidget {
  const TipManagement({
    super.key,
    required this.organizationId,
    this.canManage,
  });

  final String organizationId;

  /// When null, derived from the signed-in profile role.
  final bool? canManage;

  @override
  State<TipManagement> createState() => _TipManagementState();
}

class _TipManagementState extends State<TipManagement> {
  final _client = Supabase.instance.client;
  final _cashController = TextEditingController();
  final _cardController = TextEditingController();

  bool _loading = true;
  String? _error;
  bool _splitting = false;
  bool _confirming = false;

  _ProfileData? _profile;
  DateTime _poolDate = DateTime.now();
  _TipFlow _flow = _TipFlow.enter;
  List<_DraftShare> _draft = const [];
  int _draftTotalCents = 0;
  _WeekSummary _myWeek = const _WeekSummary(hours: 0, tips: 0, count: 0);
  List<_MyTipRow> _myTips = const [];
  _ExistingPool? _existingPool;

  final _subs = <StreamSubscription<dynamic>>[];

  String get _userId => _client.auth.currentUser?.id ?? '';

  bool get _canManage {
    if (widget.canManage != null) return widget.canManage!;
    return _profile?.canManageTips ?? false;
  }

  String get _dateKey => DateFormat('yyyy-MM-dd').format(_poolDate);

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
    _cashController.dispose();
    _cardController.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    // tip_allocations has no organization_id — reload when pools/entries change
    for (final table in ['tip_pools', 'time_entries']) {
      _subs.add(
        _client
            .from(table)
            .stream(primaryKey: ['id'])
            .eq('organization_id', widget.organizationId)
            .listen((_) => _load()),
      );
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final now = DateTime.now();
      final weekStart = now.subtract(Duration(days: now.weekday - 1));
      final weekStartKey = DateFormat('yyyy-MM-dd').format(weekStart);
      final weekEndKey =
          DateFormat('yyyy-MM-dd').format(weekStart.add(const Duration(days: 6)));

      final results = await Future.wait<dynamic>([
        _client
            .from('profiles')
            .select('name, role, organization_id')
            .eq('id', _userId)
            .eq('organization_id', widget.organizationId)
            .single(),
        _client
            .from('tip_allocations')
            .select(
              'amount_cents, hours_worked, tip_pools!inner(shift_date, organization_id, total_cents)',
            )
            .eq('tip_pools.organization_id', widget.organizationId)
            .eq('user_id', _userId)
            .gte('tip_pools.shift_date', weekStartKey)
            .lte('tip_pools.shift_date', weekEndKey),
        _client
            .from('tip_pools')
            .select('id, total_cents, split_method, shift_date')
            .eq('organization_id', widget.organizationId)
            .eq('shift_date', _dateKey)
            .maybeSingle(),
      ]);

      if (!mounted) return;

      final tipRows =
          (results[1] as List).cast<Map<String, dynamic>>();
      var tipsCents = 0;
      var hours = 0.0;
      final myTips = <_MyTipRow>[];
      for (final r in tipRows) {
        final cents = (r['amount_cents'] as num?)?.toInt() ?? 0;
        final h = (r['hours_worked'] as num?)?.toDouble() ?? 0;
        tipsCents += cents;
        hours += h;
        final pool = r['tip_pools'] as Map?;
        myTips.add(
          _MyTipRow(
            shiftDate: pool?['shift_date'] as String? ?? '',
            amountCents: cents,
            hoursWorked: h,
            poolTotalCents: (pool?['total_cents'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      myTips.sort((a, b) => b.shiftDate.compareTo(a.shiftDate));

      final existing = results[2] as Map<String, dynamic>?;

      setState(() {
        _profile = _ProfileData.fromMap(results[0] as Map<String, dynamic>);
        _myTips = myTips;
        _myWeek = _WeekSummary(
          hours: hours,
          tips: tipsCents / 100.0,
          count: myTips.length,
        );
        _existingPool = existing == null
            ? null
            : _ExistingPool(
                id: existing['id'] as String,
                totalCents: (existing['total_cents'] as num?)?.toInt() ?? 0,
                splitMethod: existing['split_method'] as String? ?? 'hours',
              );
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load tips. Pull to retry.';
        });
      }
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _poolDate,
      firstDate: DateTime.now().subtract(const Duration(days: 60)),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _poolDate = picked;
      _flow = _TipFlow.enter;
      _draft = const [];
      _draftTotalCents = 0;
    });
    await _load();
  }

  Future<void> _split() async {
    if (_splitting) return;
    if (_existingPool != null) {
      _snack('Tips already split for this date.');
      return;
    }

    final cash = _parseDollars(_cashController.text);
    final card = _parseDollars(_cardController.text);
    final totalCents = ((cash + card) * 100).round();
    if (totalCents <= 0) {
      _snack('Enter cash and/or card tip totals.');
      return;
    }

    setState(() => _splitting = true);
    try {
      final nextDay = _poolDate.add(const Duration(days: 1));
      final nextKey = DateFormat('yyyy-MM-dd').format(nextDay);

      final results = await Future.wait<dynamic>([
        _client
            .from('time_entries')
            .select('user_id, clock_in, clock_out, profiles(name)')
            .eq('organization_id', widget.organizationId)
            .gte('clock_in', '${_dateKey}T00:00:00')
            .lt('clock_in', '${nextKey}T00:00:00')
            .not('clock_out', 'is', null),
        _client
            .from('tip_pools')
            .select('id')
            .eq('organization_id', widget.organizationId)
            .eq('shift_date', _dateKey)
            .maybeSingle(),
      ]);

      if (!mounted) return;

      if (results[1] != null) {
        setState(() => _splitting = false);
        _snack('Tips already split for this date.');
        await _load();
        return;
      }

      final hoursByUser = <String, double>{};
      final namesByUser = <String, String>{};
      for (final row
          in (results[0] as List).cast<Map<String, dynamic>>()) {
        final uid = row['user_id'] as String?;
        if (uid == null) continue;
        final hours = _hoursBetweenTimestamps(
          row['clock_in'] as String?,
          row['clock_out'] as String?,
        );
        if (hours <= 0) continue;
        hoursByUser[uid] = (hoursByUser[uid] ?? 0) + hours;
        namesByUser[uid] =
            (row['profiles'] as Map?)?['name'] as String? ?? 'Teammate';
      }

      if (hoursByUser.isEmpty) {
        setState(() => _splitting = false);
        _snack('No completed clock-ins for this date.');
        return;
      }

      final draft = _splitByHours(totalCents, hoursByUser, namesByUser);
      setState(() {
        _draft = draft;
        _draftTotalCents = totalCents;
        _flow = _TipFlow.review;
        _splitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _splitting = false);
      _snack('Could not calculate split. Try again.');
    }
  }

  Future<void> _confirm() async {
    if (_confirming || _draft.isEmpty) return;

    setState(() => _confirming = true);
    try {
      final existing = await _client
          .from('tip_pools')
          .select('id')
          .eq('organization_id', widget.organizationId)
          .eq('shift_date', _dateKey)
          .maybeSingle();
      if (existing != null) {
        if (!mounted) return;
        setState(() => _confirming = false);
        _snack('Tips already split for this date.');
        return;
      }

      final pool = await _client
          .from('tip_pools')
          .insert({
            'organization_id': widget.organizationId,
            'shift_date': _dateKey,
            'total_cents': _draftTotalCents,
            'split_method': 'hours',
          })
          .select('id')
          .single();

      final poolId = pool['id'] as String;
      final shareCount = _draft.length;
      await _client.from('tip_allocations').insert([
        for (final s in _draft)
          {
            'tip_pool_id': poolId,
            'user_id': s.userId,
            'hours_worked': double.parse(s.hours.toStringAsFixed(2)),
            'amount_cents': s.amountCents,
          },
      ]);

      if (!mounted) return;
      _cashController.clear();
      _cardController.clear();
      setState(() {
        _confirming = false;
        _flow = _TipFlow.enter;
        _draft = const [];
        _draftTotalCents = 0;
      });
      _snack('Tip pool confirmed — $shareCount people paid out.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirming = false);
      _snack('Could not confirm tip split. Try again.');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final cs = Theme.of(context).colorScheme;

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
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tips',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _canManage
                            ? 'Split tonight\'s tips by hours worked'
                            : 'Your tip share this week',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.75),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              sliver: SliverList.list(children: [
                _WeekSummaryCard(summary: _myWeek),
                const SizedBox(height: 12),
                if (_myTips.isEmpty)
                  const _EmptyCard(
                    icon: Icons.payments_outlined,
                    title: 'No tips this week yet',
                    subtitle:
                        'When the owner splits a tip pool, your share shows up here.',
                  )
                else
                  for (var i = 0; i < _myTips.length; i++) ...[
                    _MyTipCard(row: _myTips[i]),
                    if (i != _myTips.length - 1) const SizedBox(height: 12),
                  ],
                if (_canManage) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Split tips',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  if (_existingPool != null)
                    _ExistingPoolCard(
                      dateKey: _dateKey,
                      pool: _existingPool!,
                      onPickDate: _pickDate,
                    )
                  else if (_flow == _TipFlow.enter)
                    _EnterTotalsCard(
                      dateKey: _dateKey,
                      cashController: _cashController,
                      cardController: _cardController,
                      splitting: _splitting,
                      onPickDate: _pickDate,
                      onSplit: _split,
                    )
                  else
                    _ReviewSplitCard(
                      dateKey: _dateKey,
                      totalCents: _draftTotalCents,
                      shares: _draft,
                      confirming: _confirming,
                      onBack: () => setState(() {
                        _flow = _TipFlow.enter;
                        _draft = const [];
                      }),
                      onConfirm: _confirm,
                    ),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Pure helpers ────────────────────────────────────────────────────────────

enum _TipFlow { enter, review }

DateTime? _combineDateAndTime(String dateKey, String? timeRaw) {
  if (timeRaw == null) return null;
  final date = DateTime.tryParse(dateKey);
  if (date == null) return null;
  final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(timeRaw);
  if (m == null) return null;
  return DateTime(date.year, date.month, date.day, int.parse(m.group(1)!),
      int.parse(m.group(2)!));
}

/// Copied from employee_dashboard — used when falling back to shift wall-clock times.
double _hoursBetween(String? start, String? end) {
  final s = _combineDateAndTime('2000-01-01', start);
  var e = _combineDateAndTime('2000-01-01', end);
  if (s == null || e == null) return 0;
  if (!e.isAfter(s)) e = e.add(const Duration(days: 1)); // overnight
  return e.difference(s).inMinutes / 60.0;
}

double _hoursBetweenTimestamps(String? clockIn, String? clockOut) {
  if (clockIn == null || clockOut == null) return 0;
  final s = DateTime.tryParse(clockIn);
  final e = DateTime.tryParse(clockOut);
  if (s == null || e == null) {
    return _hoursBetween(clockIn, clockOut);
  }
  if (!e.isAfter(s)) return 0;
  return e.difference(s).inMinutes / 60.0;
}

double _parseDollars(String raw) {
  final cleaned = raw.trim().replaceAll(r'$', '').replaceAll(',', '');
  if (cleaned.isEmpty) return 0;
  return double.tryParse(cleaned) ?? 0;
}

String _formatDayLabel(String dateKey) {
  final d = DateTime.tryParse(dateKey);
  if (d == null) return dateKey;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(d.year, d.month, d.day);
  final diff = target.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == -1) return 'Yesterday';
  return DateFormat('EEE, MMM d').format(d);
}

String _moneyCents(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

/// Largest-remainder so allocated cents always equal the pool total.
List<_DraftShare> _splitByHours(
  int totalCents,
  Map<String, double> hoursByUser,
  Map<String, String> namesByUser,
) {
  final totalHours = hoursByUser.values.fold<double>(0, (a, b) => a + b);
  if (totalHours <= 0) return const [];

  final rows = hoursByUser.entries.map((e) {
    final exact = e.value / totalHours * totalCents;
    return (
      userId: e.key,
      hours: e.value,
      floor: exact.floor(),
      frac: exact - exact.floor(),
    );
  }).toList();

  var allocated = rows.fold<int>(0, (s, r) => s + r.floor);
  var rem = totalCents - allocated;
  rows.sort((a, b) => b.frac.compareTo(a.frac));

  final amounts = <String, int>{for (final r in rows) r.userId: r.floor};
  for (var i = 0; i < rem; i++) {
    final id = rows[i % rows.length].userId;
    amounts[id] = amounts[id]! + 1;
  }

  final shares = [
    for (final e in hoursByUser.entries)
      _DraftShare(
        userId: e.key,
        name: namesByUser[e.key] ?? 'Teammate',
        hours: e.value,
        amountCents: amounts[e.key] ?? 0,
      ),
  ]..sort((a, b) => b.amountCents.compareTo(a.amountCents));

  return shares;
}

// ─── Typed models ────────────────────────────────────────────────────────────

class _ProfileData {
  const _ProfileData({
    required this.name,
    required this.role,
    required this.organizationId,
  });

  final String name;
  final String role;
  final String organizationId;

  bool get canManageTips {
    final r = role.toLowerCase();
    return r == 'owner' || r == 'manager';
  }

  factory _ProfileData.fromMap(Map<String, dynamic> m) => _ProfileData(
        name: m['name'] as String? ?? 'there',
        role: m['role'] as String? ?? 'Staff',
        organizationId: m['organization_id'] as String? ?? '',
      );
}

class _WeekSummary {
  const _WeekSummary({
    required this.hours,
    required this.tips,
    required this.count,
  });

  final double hours;
  final double tips;
  final int count;
}

class _MyTipRow {
  const _MyTipRow({
    required this.shiftDate,
    required this.amountCents,
    required this.hoursWorked,
    required this.poolTotalCents,
  });

  final String shiftDate;
  final int amountCents;
  final double hoursWorked;
  final int poolTotalCents;
}

class _DraftShare {
  const _DraftShare({
    required this.userId,
    required this.name,
    required this.hours,
    required this.amountCents,
  });

  final String userId;
  final String name;
  final double hours;
  final int amountCents;
}

class _ExistingPool {
  const _ExistingPool({
    required this.id,
    required this.totalCents,
    required this.splitMethod,
  });

  final String id;
  final int totalCents;
  final String splitMethod;
}

// ─── UI pieces ───────────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _SkeletonBox(width: 120, height: 34, color: cs.surfaceContainerHigh),
          const SizedBox(height: 8),
          _SkeletonBox(width: 240, height: 18, color: cs.surfaceContainerHigh),
          const SizedBox(height: 24),
          _SkeletonBox(
              width: double.infinity, height: 88, color: cs.surfaceContainerHigh),
          const SizedBox(height: 12),
          _SkeletonBox(
              width: double.infinity,
              height: 160,
              color: cs.surfaceContainerHigh),
        ]),
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    required this.color,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
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
              size: 48, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.8)),
          ),
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

class _WeekSummaryCard extends StatelessWidget {
  const _WeekSummaryCard({required this.summary});

  final _WeekSummary summary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(children: [
          _WeekMetric(
            label: 'Hours tipped',
            value: summary.hours.toStringAsFixed(
              summary.hours == summary.hours.roundToDouble() ? 0 : 1,
            ),
          ),
          _VertDivider(color: cs.outlineVariant),
          _WeekMetric(
            label: 'Your tips',
            value: '\$${summary.tips.toStringAsFixed(0)}',
          ),
          _VertDivider(color: cs.outlineVariant),
          _WeekMetric(label: 'Pools', value: '${summary.count}'),
        ]),
      ),
    );
  }
}

class _WeekMetric extends StatelessWidget {
  const _WeekMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(children: [
        Text(value, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.onSurface.withValues(alpha: 0.55)),
        ),
      ]),
    );
  }
}

class _VertDivider extends StatelessWidget {
  const _VertDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 36, color: color.withValues(alpha: 0.4));
  }
}

class _MyTipCard extends StatelessWidget {
  const _MyTipCard({required this.row});

  final _MyTipRow row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.payments_rounded, color: cs.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                _formatDayLabel(row.shiftDate),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '${row.hoursWorked.toStringAsFixed(1)}h of pool ${_moneyCents(row.poolTotalCents)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
              ),
            ]),
          ),
          Text(
            _moneyCents(row.amountCents),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: const Color(0xFF4ADE80)),
          ),
        ]),
      ),
    );
  }
}

class _EnterTotalsCard extends StatelessWidget {
  const _EnterTotalsCard({
    required this.dateKey,
    required this.cashController,
    required this.cardController,
    required this.splitting,
    required this.onPickDate,
    required this.onSplit,
  });

  final String dateKey;
  final TextEditingController cashController;
  final TextEditingController cardController;
  final bool splitting;
  final VoidCallback onPickDate;
  final VoidCallback onSplit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Material(
            color: cs.onPrimaryContainer.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onPickDate,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Icon(Icons.calendar_today_rounded,
                      size: 18, color: cs.onPrimaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _formatDayLabel(dateKey),
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: cs.onPrimaryContainer),
                    ),
                  ),
                  Icon(Icons.expand_more_rounded,
                      color: cs.onPrimaryContainer.withValues(alpha: 0.6)),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: _MoneyField(
                controller: cashController,
                label: 'Cash',
                onPrimaryContainer: cs.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MoneyField(
                controller: cardController,
                label: 'Card',
                onPrimaryContainer: cs.onPrimaryContainer,
              ),
            ),
          ]),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                backgroundColor: cs.primary,
              ),
              onPressed: splitting ? null : onSplit,
              icon: splitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Icon(Icons.call_split_rounded),
              label: const Text(
                'Split',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _MoneyField extends StatelessWidget {
  const _MoneyField({
    required this.controller,
    required this.label,
    required this.onPrimaryContainer,
  });

  final TextEditingController controller;
  final String label;
  final Color onPrimaryContainer;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
      ],
      style: TextStyle(color: onPrimaryContainer),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: onPrimaryContainer.withValues(alpha: 0.7),
        ),
        prefixText: '\$ ',
        prefixStyle: TextStyle(color: onPrimaryContainer),
        filled: true,
        fillColor: onPrimaryContainer.withValues(alpha: 0.08),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _ReviewSplitCard extends StatelessWidget {
  const _ReviewSplitCard({
    required this.dateKey,
    required this.totalCents,
    required this.shares,
    required this.confirming,
    required this.onBack,
    required this.onConfirm,
  });

  final String dateKey;
  final int totalCents;
  final List<_DraftShare> shares;
  final bool confirming;
  final VoidCallback onBack;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalHours =
        shares.fold<double>(0, (s, r) => s + r.hours);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Review · ${_formatDayLabel(dateKey)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '${_moneyCents(totalCents)} across ${shares.length} people · ${totalHours.toStringAsFixed(1)}h',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
          ),
          const SizedBox(height: 16),
          for (final s in shares) ...[
            Row(children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: cs.surfaceContainerHigh,
                child: Text(
                  s.name.isNotEmpty ? s.name[0].toUpperCase() : '?',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, style: Theme.of(context).textTheme.titleSmall),
                    Text(
                      '${s.hours.toStringAsFixed(1)}h',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.5),
                          ),
                    ),
                  ],
                ),
              ),
              Text(
                _moneyCents(s.amountCents),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ]),
            if (s != shares.last) const SizedBox(height: 12),
          ],
          const SizedBox(height: 20),
          Row(children: [
            TextButton(
              onPressed: confirming ? null : onBack,
              child: const Text('Back'),
            ),
            const Spacer(),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: confirming ? null : onConfirm,
              icon: confirming
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Icon(Icons.check_rounded),
              label: const Text(
                'Confirm',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _ExistingPoolCard extends StatelessWidget {
  const _ExistingPoolCard({
    required this.dateKey,
    required this.pool,
    required this.onPickDate,
  });

  final String dateKey;
  final _ExistingPool pool;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.check_circle_rounded,
                color: Color(0xFF4ADE80), size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'Already split · ${_formatDayLabel(dateKey)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '${_moneyCents(pool.totalCents)} by ${pool.splitMethod}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
              ),
            ]),
          ),
          IconButton(
            onPressed: onPickDate,
            icon: Icon(Icons.calendar_today_rounded, color: cs.primary),
            tooltip: 'Pick another date',
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
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon,
                color: cs.onSurface.withValues(alpha: 0.5), size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
