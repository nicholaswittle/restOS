import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/shift_time.dart';

/// The OS feature: real labor cost vs real order revenue from the same Supabase.
/// Shows the one number that matters — labor cost % — with drill-down.
class LaborVsRevenueDashboard extends StatefulWidget {
  const LaborVsRevenueDashboard({
    super.key,
    required this.organizationId,
    this.onBack,
  });

  final String organizationId;
  final VoidCallback? onBack;

  @override
  State<LaborVsRevenueDashboard> createState() =>
      _LaborVsRevenueDashboardState();
}

class _LaborVsRevenueDashboardState extends State<LaborVsRevenueDashboard> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  bool _reloading = false;

  _Period _period = _Period.week;
  _ProfileData? _viewer;
  _Summary _summary = const _Summary();
  List<_StaffRow> _staff = const [];
  List<_OrderRow> _orders = const [];
  List<String> _openPunchNames = const [];

  final _subs = <StreamSubscription<dynamic>>[];

  String get _userId => _client.auth.currentUser?.id ?? '';

  bool get _canView {
    final role = _viewer?.role.toLowerCase() ?? '';
    return role == 'owner' || role == 'manager';
  }

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
    for (final table in ['profiles', 'shifts', 'time_entries', 'online_orders']) {
      _subs.add(
        _client
            .from(table)
            .stream(primaryKey: ['id'])
            .eq('organization_id', widget.organizationId)
            .listen((_) => _load(quiet: true)),
      );
    }
  }

  ({DateTime start, DateTime end}) _rangeFor(_Period period) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (period) {
      case _Period.day:
        return (start: today, end: today);
      case _Period.week:
        final monday = today.subtract(Duration(days: today.weekday - 1));
        return (start: monday, end: monday.add(const Duration(days: 6)));
      case _Period.month:
        final start = DateTime(today.year, today.month, 1);
        final end = DateTime(today.year, today.month + 1, 0);
        return (start: start, end: end);
    }
  }

  Future<void> _load({bool quiet = false}) async {
    if (!mounted) return;
    if (_reloading) return;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() => _reloading = true);
    }

    try {
      final range = _rangeFor(_period);
      final startKey = dateKeyOf(range.start);
      final endKey = dateKeyOf(range.end);
      final startBound = localDayBoundsUtc(range.start);
      final endBound = localDayBoundsUtc(range.end);

      final results = await Future.wait<dynamic>([
        _client
            .from('profiles')
            .select('id, name, role, hourly_rate, organization_id')
            .eq('id', _userId)
            .eq('organization_id', widget.organizationId)
            .single(),
        _client
            .from('profiles')
            .select('id, name, hourly_rate, role')
            .eq('organization_id', widget.organizationId),
        _client
            .from('shifts')
            .select('staff, start_time, end_time, shift_date')
            .eq('organization_id', widget.organizationId)
            .gte('shift_date', startKey)
            .lte('shift_date', endKey),
        _client
            .from('time_entries')
            .select('user_id, clock_in, clock_out, profiles(name)')
            .eq('organization_id', widget.organizationId)
            .gte('clock_in', startBound.startUtc)
            .lt('clock_in', endBound.endUtc),
        _client
            .from('online_orders')
            .select('id, public_token, status, total_cents, submitted_at, completed_at')
            .eq('organization_id', widget.organizationId)
            .gte('submitted_at', startBound.startUtc)
            .lt('submitted_at', endBound.endUtc)
            .order('submitted_at', ascending: false),
      ]);

      if (!mounted) return;

      final viewer = _ProfileData.fromMap(results[0] as Map<String, dynamic>);
      final profiles = (results[1] as List)
          .cast<Map<String, dynamic>>()
          .map(_StaffProfile.fromMap)
          .toList();

      final byId = {for (final p in profiles) p.id: p};
      final byName = <String, _StaffProfile>{};
      for (final p in profiles) {
        byName[p.name.trim().toLowerCase()] = p;
      }

      final scheduledHours = <String, double>{};
      for (final row
          in (results[2] as List).cast<Map<String, dynamic>>()) {
        final name = (row['staff'] as String?)?.trim() ?? '';
        if (name.isEmpty || name.toLowerCase() == 'open') continue;
        final profile = byName[name.toLowerCase()];
        final key = profile?.id ?? 'name:${name.toLowerCase()}';
        scheduledHours[key] = (scheduledHours[key] ?? 0) +
            hoursBetween(
              row['start_time'] as String?,
              row['end_time'] as String?,
            );
        if (profile == null) {
          byId.putIfAbsent(
            key,
            () => _StaffProfile(id: key, name: name, hourlyRate: 0),
          );
        }
      }

      final actualHours = <String, double>{};
      final openNames = <String>{};
      for (final row
          in (results[3] as List).cast<Map<String, dynamic>>()) {
        final uid = row['user_id'] as String?;
        if (uid == null) continue;
        final clockOut = row['clock_out'] as String?;
        final name = (row['profiles'] as Map?)?['name'] as String? ??
            byId[uid]?.name ??
            'Teammate';
        if (clockOut == null) {
          openNames.add(name);
          continue;
        }
        actualHours[uid] = (actualHours[uid] ?? 0) +
            hoursBetweenTimestamps(row['clock_in'] as String?, clockOut);
        byId.putIfAbsent(
          uid,
          () => _StaffProfile(id: uid, name: name, hourlyRate: 0),
        );
      }

      final keys = {...scheduledHours.keys, ...actualHours.keys};
      final rows = <_StaffRow>[];
      var schedH = 0.0, actH = 0.0, schedCost = 0.0, actCost = 0.0;

      for (final key in keys) {
        final profile = byId[key];
        final name = profile?.name ?? 'Unknown';
        final rate = profile?.hourlyRate ?? 0;
        final sH = scheduledHours[key] ?? 0;
        final aH = actualHours[key] ?? 0;
        final sC = sH * rate;
        final aC = aH * rate;
        schedH += sH;
        actH += aH;
        schedCost += sC;
        actCost += aC;
        rows.add(_StaffRow(
          name: name,
          scheduledHours: sH,
          actualHours: aH,
          rate: rate,
          scheduledCost: sC,
          actualCost: aC,
        ));
      }
      rows.sort((a, b) => b.actualCost.compareTo(a.actualCost));

      final orderRows = (results[4] as List)
          .cast<Map<String, dynamic>>()
          .map(_OrderRow.fromMap)
          .toList();
      final revenueCents = orderRows
          .where((o) => o.status != 'rejected')
          .fold(0, (sum, o) => sum + o.totalCents);

      setState(() {
        _viewer = viewer;
        _summary = _Summary(
          scheduledHours: schedH,
          actualHours: actH,
          scheduledCost: schedCost,
          actualCost: actCost,
          revenueCents: revenueCents,
          orderCount: orderRows.length,
        );
        _staff = rows;
        _orders = orderRows;
        _openPunchNames = openNames.toList()..sort();
        _loading = false;
        _reloading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _reloading = false;
        _error = 'Could not load dashboard. Pull to retry.';
      });
    }
  }

  void _setPeriod(_Period period) {
    if (period == _period) return;
    setState(() => _period = period);
    _load();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  double? get _laborPercent {
    final revenue = _summary.revenueDollars;
    if (revenue <= 0) return null;
    return (_summary.actualCost / revenue) * 100;
  }

  String _periodLabel(DateTime start, DateTime end) {
    if (start == end) return _fmtDate(start);
    return '${_fmtDate(start)} – ${_fmtDate(end)}';
  }

  String _fmtDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }

  Future<void> _exportCsv() async {
    if (_staff.isEmpty && _orders.isEmpty) {
      _snack('Nothing to export for this period.');
      return;
    }
    final range = _rangeFor(_period);
    final buf = StringBuffer();

    buf.writeln('STAFF,Scheduled Hours,Actual Hours,Hourly Rate,Scheduled Pay,Actual Pay');
    for (final r in _staff) {
      buf.writeln(
        '"${r.name}",'
        '${r.scheduledHours.toStringAsFixed(2)},'
        '${r.actualHours.toStringAsFixed(2)},'
        '${r.rate.toStringAsFixed(2)},'
        '${r.scheduledCost.toStringAsFixed(2)},'
        '${r.actualCost.toStringAsFixed(2)}',
      );
    }
    buf.writeln(
      '"TOTAL",'
      '${_summary.scheduledHours.toStringAsFixed(2)},'
      '${_summary.actualHours.toStringAsFixed(2)},'
      ','
      '${_summary.scheduledCost.toStringAsFixed(2)},'
      '${_summary.actualCost.toStringAsFixed(2)}',
    );
    buf.writeln();
    buf.writeln('ORDERS,Token,Status,Total,Submitted');
    for (final o in _orders) {
      buf.writeln(
        '"${o.publicToken}",'
        '${o.status},'
        '${(o.totalCents / 100).toStringAsFixed(2)},'
        '${o.submittedAt.toIso8601String()}',
      );
    }
    buf.writeln();
    buf.writeln('SUMMARY');
    buf.writeln('Revenue,${_summary.revenueDollars.toStringAsFixed(2)}');
    buf.writeln('Labor Cost,${_summary.actualCost.toStringAsFixed(2)}');
    final pct = _laborPercent;
    buf.writeln('Labor %,${pct != null ? pct.toStringAsFixed(1) : "N/A"}');

    final csv = buf.toString();
    final label = 'labor_vs_revenue_${dateKeyOf(range.start)}_${dateKeyOf(range.end)}.csv';

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              csv,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy CSV'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: csv));
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              _snack('Copied $label');
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }
    if (!_canView) {
      return Scaffold(body: _ForbiddenView(onBack: widget.onBack));
    }

    final cs = Theme.of(context).colorScheme;
    final pct = _laborPercent;
    final range = _rangeFor(_period);

    return Scaffold(
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
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        if (widget.onBack != null)
                          IconButton(
                            onPressed: widget.onBack,
                            icon: const Icon(Icons.arrow_back_rounded),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                          ),
                        if (widget.onBack != null) const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Labor vs Revenue',
                            style: Theme.of(context).textTheme.displaySmall,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Export CSV',
                          onPressed: _exportCsv,
                          icon: const Icon(Icons.table_chart_rounded),
                        ),
                        if (_reloading)
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: cs.primary.withValues(alpha: 0.7),
                            ),
                          ),
                      ]),
                      const SizedBox(height: 8),
                      Text(
                        _periodLabel(range.start, range.end),
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
                SegmentedButton<_Period>(
                  segments: const [
                    ButtonSegment(value: _Period.day, label: Text('Day')),
                    ButtonSegment(value: _Period.week, label: Text('Week')),
                    ButtonSegment(value: _Period.month, label: Text('Month')),
                  ],
                  selected: {_period},
                  onSelectionChanged: (s) => _setPeriod(s.first),
                ),
                const SizedBox(height: 12),
                _HeadlineCard(
                  percent: pct,
                  revenue: _summary.revenueDollars,
                  laborCost: _summary.actualCost,
                  hours: _summary.actualHours,
                  orderCount: _summary.orderCount,
                ),
                const SizedBox(height: 12),
                if (_openPunchNames.isNotEmpty) ...[
                  _OpenPunchBanner(names: _openPunchNames),
                  const SizedBox(height: 12),
                ],
                Text('Revenue breakdown',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _RevenueBreakdownCard(summary: _summary, orders: _orders),
                const SizedBox(height: 12),
                Text('Staff labor',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final r in _staff) ...[
                  _StaffCard(row: r),
                  if (r != _staff.last) const SizedBox(height: 8),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Models ──────────────────────────────────────────────────────────────────

enum _Period { day, week, month }

class _ProfileData {
  const _ProfileData({required this.role});

  final String role;

  factory _ProfileData.fromMap(Map<String, dynamic> m) =>
      _ProfileData(role: m['role'] as String? ?? '');
}

class _StaffProfile {
  const _StaffProfile({
    required this.id,
    required this.name,
    required this.hourlyRate,
  });

  final String id;
  final String name;
  final double hourlyRate;

  factory _StaffProfile.fromMap(Map<String, dynamic> m) => _StaffProfile(
        id: m['id'] as String,
        name: m['name'] as String? ?? 'Staff',
        hourlyRate: (m['hourly_rate'] as num?)?.toDouble() ?? 0,
      );
}

class _StaffRow {
  const _StaffRow({
    required this.name,
    required this.scheduledHours,
    required this.actualHours,
    required this.rate,
    required this.scheduledCost,
    required this.actualCost,
  });

  final String name;
  final double scheduledHours;
  final double actualHours;
  final double rate;
  final double scheduledCost;
  final double actualCost;
}

class _OrderRow {
  const _OrderRow({
    required this.publicToken,
    required this.status,
    required this.totalCents,
    required this.submittedAt,
  });

  final String publicToken;
  final String status;
  final int totalCents;
  final DateTime submittedAt;

  factory _OrderRow.fromMap(Map<String, dynamic> m) => _OrderRow(
        publicToken: m['public_token'] as String? ?? '',
        status: m['status'] as String? ?? 'waiting',
        totalCents: (m['total_cents'] as num?)?.toInt() ?? 0,
        submittedAt:
            DateTime.tryParse(m['submitted_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

class _Summary {
  const _Summary({
    this.scheduledHours = 0,
    this.actualHours = 0,
    this.scheduledCost = 0,
    this.actualCost = 0,
    this.revenueCents = 0,
    this.orderCount = 0,
  });

  final double scheduledHours;
  final double actualHours;
  final double scheduledCost;
  final double actualCost;
  final int revenueCents;
  final int orderCount;

  double get revenueDollars => revenueCents / 100.0;
}

// ─── UI pieces ───────────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SizedBox(
        width: 32,
        height: 32,
        child: CircularProgressIndicator(strokeWidth: 3, color: cs.primary),
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
              size: 48, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: cs.onSurface.withValues(alpha: 0.8))),
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

class _ForbiddenView extends StatelessWidget {
  const _ForbiddenView({this.onBack});

  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline_rounded,
              size: 48, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text('Owner or manager only',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 20),
          if (onBack != null)
            FilledButton.tonal(
              onPressed: onBack,
              child: const Text('Back'),
            ),
        ]),
      ),
    );
  }
}

class _HeadlineCard extends StatelessWidget {
  const _HeadlineCard({
    required this.percent,
    required this.revenue,
    required this.laborCost,
    required this.hours,
    required this.orderCount,
  });

  final double? percent;
  final double revenue;
  final double laborCost;
  final double hours;
  final int orderCount;

  Color _pctColor(ColorScheme cs) {
    if (percent == null) return cs.onSurface.withValues(alpha: 0.4);
    if (percent! < 25) return const Color(0xFF4ADE80);
    if (percent! <= 30) return const Color(0xFFFBBF24);
    return const Color(0xFFF87171);
  }

  String get _pctLabel {
    if (percent == null) return '—';
    return '${percent!.toStringAsFixed(1)}%';
  }

  String get _verdict {
    if (percent == null) return 'No revenue data yet';
    if (percent! < 25) return 'Healthy — under 25%';
    if (percent! <= 30) return 'On target — under 30%';
    return 'Over 30% — labor is eating sales';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _pctColor(cs);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Labor Cost',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_pctLabel,
                    style: TextStyle(
                      fontSize: 56,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.5,
                      color: color,
                    )),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_verdict,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: color,
                        )),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(children: [
              _Metric(
                label: 'Revenue',
                value: '\$${revenue.toStringAsFixed(0)}',
                sublabel: '$orderCount orders',
              ),
              _VertDivider(color: cs.outlineVariant),
              _Metric(
                label: 'Labor',
                value: '\$${laborCost.toStringAsFixed(0)}',
                sublabel: '${hours.toStringAsFixed(1)}h',
              ),
              _VertDivider(color: cs.outlineVariant),
              _Metric(
                label: 'Margin',
                value: '\$${(revenue - laborCost).toStringAsFixed(0)}',
                sublabel: revenue > 0
                    ? '${((1 - laborCost / revenue) * 100).toStringAsFixed(0)}%'
                    : '—',
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.sublabel});

  final String label;
  final String value;
  final String? sublabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(children: [
        Text(value, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.55))),
        if (sublabel != null) ...[
          const SizedBox(height: 2),
          Text(sublabel!,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.onSurface.withValues(alpha: 0.4))),
        ],
      ]),
    );
  }
}

class _VertDivider extends StatelessWidget {
  const _VertDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 44, color: color.withValues(alpha: 0.3));
  }
}

class _OpenPunchBanner extends StatelessWidget {
  const _OpenPunchBanner({required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFBBF24).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFBBF24).withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        const Icon(Icons.cloud_off_rounded,
            color: Color(0xFFFBBF24), size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            names.length == 1
                ? '${names.first} is still on the clock — hours not counted'
                : '${names.join(', ')} still on the clock — hours not counted',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.8),
                ),
          ),
        ),
      ]),
    );
  }
}

class _RevenueBreakdownCard extends StatelessWidget {
  const _RevenueBreakdownCard({required this.summary, required this.orders});

  final _Summary summary;
  final List<_OrderRow> orders;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (orders.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Icon(Icons.receipt_long_outlined,
                size: 32, color: cs.onSurface.withValues(alpha: 0.3)),
            const SizedBox(height: 8),
            Text('No orders this period',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    )),
          ]),
        ),
      );
    }

    final completed =
        orders.where((o) => o.status == 'completed').toList();
    final accepted =
        orders.where((o) => o.status == 'accepted' || o.status == 'waiting').toList();
    final rejected = orders.where((o) => o.status == 'rejected').toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.receipt_long_rounded, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Text('${summary.orderCount} orders',
                style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            Text('\$${summary.revenueDollars.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.titleMedium),
          ]),
          const SizedBox(height: 12),
          if (completed.isNotEmpty)
            _StatusRow(label: 'Completed', count: completed.length, color: const Color(0xFF4ADE80)),
          if (accepted.isNotEmpty)
            _StatusRow(label: 'In progress', count: accepted.length, color: cs.primary),
          if (rejected.isNotEmpty)
            _StatusRow(label: 'Rejected', count: rejected.length, color: const Color(0xFFF87171)),
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 8),
          Text('Recent orders',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.5),
                  )),
          const SizedBox(height: 8),
          for (final o in orders.take(8)) ...[
            Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: o.status == 'completed'
                      ? const Color(0xFF4ADE80)
                      : o.status == 'rejected'
                          ? const Color(0xFFF87171)
                          : cs.primary,
                ),
              ),
              const SizedBox(width: 10),
              Text(o.publicToken,
                  style: Theme.of(context).textTheme.bodyMedium),
              const Spacer(),
              Text('\$${(o.totalCents / 100).toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.bodyMedium),
            ]),
            if (o != orders.take(8).last) const SizedBox(height: 8),
          ],
        ]),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.count, required this.color});

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 10),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const Spacer(),
        Text('$count',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.7))),
      ]),
    );
  }
}

class _StaffCard extends StatelessWidget {
  const _StaffCard({required this.row});

  final _StaffRow row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: cs.surfaceContainerHigh,
            child: Text(
              row.name.isNotEmpty ? row.name[0].toUpperCase() : '?',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(row.name, style: Theme.of(context).textTheme.titleSmall),
              Text(
                '${row.actualHours.toStringAsFixed(1)}h actual · ${row.scheduledHours.toStringAsFixed(1)}h scheduled',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
              ),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('\$${row.actualCost.toStringAsFixed(0)}',
                style: Theme.of(context).textTheme.titleMedium),
            Text('\$${row.rate.toStringAsFixed(0)}/hr',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.4),
                    )),
          ]),
        ]),
      ),
    );
  }
}