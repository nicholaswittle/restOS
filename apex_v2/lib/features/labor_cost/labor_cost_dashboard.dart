import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/shift_time.dart';

/// One-number labor view: cost %, scheduled vs actual, per-staff drill-down.
///
/// Projected sales stays in local state only — order revenue lives in D1 until
/// a later OS phase, so inventing a sales figure here would be a lie.
class LaborCostDashboard extends StatefulWidget {
  const LaborCostDashboard({
    super.key,
    required this.organizationId,
    this.onBack,
  });

  final String organizationId;
  final VoidCallback? onBack;

  @override
  State<LaborCostDashboard> createState() => _LaborCostDashboardState();
}

class _LaborCostDashboardState extends State<LaborCostDashboard> {
  final _client = Supabase.instance.client;
  final _salesController = TextEditingController();

  bool _loading = true;
  String? _error;
  bool _reloading = false;

  _Period _period = _Period.week;
  _ProfileData? _viewer;
  _LaborTotals _totals = const _LaborTotals();
  List<_StaffRow> _staff = const [];
  List<String> _openPunchNames = const [];
  double? _projectedSales;

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
    _salesController.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    for (final table in ['profiles', 'shifts', 'time_entries']) {
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
      var schedH = 0.0;
      var actH = 0.0;
      var schedCost = 0.0;
      var actCost = 0.0;

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
        rows.add(
          _StaffRow(
            name: name,
            scheduledHours: sH,
            actualHours: aH,
            rate: rate,
            scheduledCost: sC,
            actualCost: aC,
          ),
        );
      }

      rows.sort((a, b) => b.actualCost.compareTo(a.actualCost));

      setState(() {
        _viewer = viewer;
        _totals = _LaborTotals(
          scheduledHours: schedH,
          actualHours: actH,
          scheduledCost: schedCost,
          actualCost: actCost,
        );
        _staff = rows;
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
        _error = 'Could not load labor costs. Pull to retry.';
      });
    }
  }

  void _applySales() {
    final raw = _salesController.text.trim().replaceAll(r'$', '').replaceAll(',', '');
    if (raw.isEmpty) {
      setState(() => _projectedSales = null);
      _snack('Sales figure cleared — showing dollars and hours only.');
      return;
    }
    final value = double.tryParse(raw);
    if (value == null || value <= 0) {
      _snack('Enter a valid projected sales amount.');
      return;
    }
    setState(() => _projectedSales = value);
    _snack('Using \$${value.toStringAsFixed(0)} projected sales for this period.');
  }

  void _setPeriod(_Period period) {
    if (period == _period) return;
    setState(() => _period = period);
    _load();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  double? get _laborPercent {
    final sales = _projectedSales;
    if (sales == null || sales <= 0) return null;
    return (_totals.actualCost / sales) * 100;
  }

  Future<void> _exportCsv() async {
    if (_staff.isEmpty) {
      _snack('Nothing to export for this period.');
      return;
    }
    final range = _rangeFor(_period);
    final buf = StringBuffer(
      'Staff,Scheduled Hours,Actual Hours,Hourly Rate,Scheduled Pay,Actual Pay\n',
    );
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
      '${_totals.scheduledHours.toStringAsFixed(2)},'
      '${_totals.actualHours.toStringAsFixed(2)},'
      ','
      '${_totals.scheduledCost.toStringAsFixed(2)},'
      '${_totals.actualCost.toStringAsFixed(2)}',
    );
    final csv = buf.toString();
    final label =
        'labor_${dateKeyOf(range.start)}_${dateKeyOf(range.end)}.csv';

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Labor export'),
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
      return Scaffold(
        body: _ForbiddenView(onBack: widget.onBack),
      );
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
                            'Labor Cost',
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
                  actualCost: _totals.actualCost,
                  actualHours: _totals.actualHours,
                ),
                const SizedBox(height: 12),
                _SalesInputCard(
                  controller: _salesController,
                  projectedSales: _projectedSales,
                  onApply: _applySales,
                ),
                const SizedBox(height: 12),
                _CompareCard(totals: _totals),
                if (_openPunchNames.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _OpenPunchBanner(names: _openPunchNames),
                ],
                const SizedBox(height: 20),
                Text(
                  'By staff',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (_staff.isEmpty)
                  const _EmptyCard(
                    icon: Icons.groups_outlined,
                    title: 'No labor this period',
                    subtitle:
                        'Scheduled shifts and completed clock-ins will show up here.',
                  )
                else
                  for (var i = 0; i < _staff.length; i++) ...[
                    _StaffTile(row: _staff[i]),
                    if (i != _staff.length - 1) const SizedBox(height: 12),
                  ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  String _periodLabel(DateTime start, DateTime end) {
    if (_period == _Period.day) return formatDayLabel(dateKeyOf(start));
    if (start.year == end.year && start.month == end.month && start.day == end.day) {
      return formatDayLabel(dateKeyOf(start));
    }
    return '${formatDayLabel(dateKeyOf(start))} – ${formatDayLabel(dateKeyOf(end))}';
  }
}

// ─── Models ──────────────────────────────────────────────────────────────────

enum _Period { day, week, month }

class _ProfileData {
  const _ProfileData({required this.name, required this.role});

  final String name;
  final String role;

  factory _ProfileData.fromMap(Map<String, dynamic> m) => _ProfileData(
        name: m['name'] as String? ?? 'there',
        role: m['role'] as String? ?? 'Staff',
      );
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
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? 'Teammate',
        hourlyRate: (m['hourly_rate'] as num?)?.toDouble() ?? 0,
      );
}

class _LaborTotals {
  const _LaborTotals({
    this.scheduledHours = 0,
    this.actualHours = 0,
    this.scheduledCost = 0,
    this.actualCost = 0,
  });

  final double scheduledHours;
  final double actualHours;
  final double scheduledCost;
  final double actualCost;

  double get hoursVariance => actualHours - scheduledHours;
  double get costVariance => actualCost - scheduledCost;
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

  double get hoursVariance => actualHours - scheduledHours;
  double get costVariance => actualCost - scheduledCost;

  /// Actual more than 15% over scheduled — overstaff burn or overtime risk.
  bool get overScheduled =>
      scheduledHours > 0 && actualHours > scheduledHours * 1.15;
}

enum _LaborBand { green, yellow, red, unknown }

_LaborBand _bandFor(double? percent) {
  if (percent == null) return _LaborBand.unknown;
  if (percent < 25) return _LaborBand.green;
  if (percent <= 30) return _LaborBand.yellow;
  return _LaborBand.red;
}

Color _bandColor(_LaborBand band, ColorScheme cs) {
  switch (band) {
    case _LaborBand.green:
      return const Color(0xFF4ADE80);
    case _LaborBand.yellow:
      return const Color(0xFFFBBF24);
    case _LaborBand.red:
      return const Color(0xFFF87171);
    case _LaborBand.unknown:
      return cs.onSurface.withValues(alpha: 0.55);
  }
}

String _dollars(double v) => formatCents((v * 100).round());

String _signedHours(double h) {
  final sign = h > 0 ? '+' : '';
  return '$sign${formatHours(h)}h';
}

String _signedDollars(double v) {
  final sign = v > 0 ? '+' : (v < 0 ? '−' : '');
  return '$sign${formatCents((v.abs() * 100).round())}';
}

// ─── UI ──────────────────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _SkeletonBox(width: 180, height: 34, color: cs.surfaceContainerHigh),
          const SizedBox(height: 8),
          _SkeletonBox(width: 200, height: 18, color: cs.surfaceContainerHigh),
          const SizedBox(height: 24),
          _SkeletonBox(
              width: double.infinity, height: 160, color: cs.surfaceContainerHigh),
          const SizedBox(height: 12),
          _SkeletonBox(
              width: double.infinity, height: 100, color: cs.surfaceContainerHigh),
          const SizedBox(height: 12),
          _SkeletonBox(
              width: double.infinity, height: 88, color: cs.surfaceContainerHigh),
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

class _ForbiddenView extends StatelessWidget {
  const _ForbiddenView({this.onBack});

  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline_rounded,
                size: 48, color: cs.onSurface.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              'Ask your manager',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Labor cost is only visible to managers and owners.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
            ),
            if (onBack != null) ...[
              const SizedBox(height: 24),
              FilledButton.tonal(
                onPressed: onBack,
                child: const Text('Go back'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeadlineCard extends StatelessWidget {
  const _HeadlineCard({
    required this.percent,
    required this.actualCost,
    required this.actualHours,
  });

  final double? percent;
  final double actualCost;
  final double actualHours;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final band = _bandFor(percent);
    final color = _bandColor(band, cs);

    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Text(
            percent == null ? '—' : '${percent!.toStringAsFixed(0)}%',
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: color,
                  fontSize: 56,
                  height: 1.05,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            percent == null
                ? 'Labor cost % needs a sales figure'
                : band == _LaborBand.green
                    ? 'Under target — keep it here'
                    : band == _LaborBand.yellow
                        ? 'Watch it — creeping toward 30%'
                        : 'Over 30% — labor is eating sales',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: cs.onPrimaryContainer.withValues(alpha: 0.85),
                ),
          ),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(
              '${_dollars(actualCost)} labor',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: cs.onPrimaryContainer.withValues(alpha: 0.8),
                  ),
            ),
            Text(
              '  ·  ',
              style: TextStyle(
                color: cs.onPrimaryContainer.withValues(alpha: 0.4),
              ),
            ),
            Text(
              '${formatHours(actualHours)}h actual',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: cs.onPrimaryContainer.withValues(alpha: 0.8),
                  ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _SalesInputCard extends StatelessWidget {
  const _SalesInputCard({
    required this.controller,
    required this.projectedSales,
    required this.onApply,
  });

  final TextEditingController controller;
  final double? projectedSales;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Projected sales',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            projectedSales == null
                ? 'Order sales are not in Supabase yet. Enter a figure to unlock the %.'
                : 'Using ${_dollars(projectedSales!)} for this period (local only — not saved).',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                ],
                decoration: InputDecoration(
                  prefixText: '\$ ',
                  hintText: '2400',
                  filled: true,
                  fillColor: cs.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: onApply,
              child: const Text('Apply'),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _CompareCard extends StatelessWidget {
  const _CompareCard({required this.totals});

  final _LaborTotals totals;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
        child: Column(children: [
          Row(children: [
            _Metric(
              label: 'Scheduled',
              hours: formatHours(totals.scheduledHours),
              money: _dollars(totals.scheduledCost),
            ),
            _VertDivider(color: cs.outlineVariant),
            _Metric(
              label: 'Actual',
              hours: formatHours(totals.actualHours),
              money: _dollars(totals.actualCost),
            ),
            _VertDivider(color: cs.outlineVariant),
            _Metric(
              label: 'Variance',
              hours: _signedHours(totals.hoursVariance),
              money: _signedDollars(totals.costVariance),
              accent: totals.costVariance > 0
                  ? const Color(0xFFF87171)
                  : const Color(0xFF4ADE80),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.hours,
    required this.money,
    this.accent,
  });

  final String label;
  final String hours;
  final String money;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(children: [
        Text(
          money,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: accent,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          '$hours hrs',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.65),
              ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
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
    return Container(width: 1, height: 48, color: color.withValues(alpha: 0.4));
  }
}

class _OpenPunchBanner extends StatelessWidget {
  const _OpenPunchBanner({required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: const Color(0xFFFBBF24).withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.timer_outlined, color: Color(0xFFFBBF24), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              names.length == 1
                  ? '${names.first} is still clocked in — their hours are not in actual yet.'
                  : '${names.join(', ')} are still clocked in — their hours are not in actual yet.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.85),
                  ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _StaffTile extends StatelessWidget {
  const _StaffTile({required this.row});

  final _StaffRow row;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.name, style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    '\$${row.rate.toStringAsFixed(2)}/hr',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                  ),
                ],
              ),
            ),
            Text(
              _dollars(row.actualCost),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            _StaffStat(
              label: 'Sched',
              value: '${formatHours(row.scheduledHours)}h',
            ),
            _StaffStat(
              label: 'Actual',
              value: '${formatHours(row.actualHours)}h',
            ),
            _StaffStat(
              label: 'Var',
              value: _signedHours(row.hoursVariance),
              warn: row.overScheduled,
            ),
          ]),
          if (row.overScheduled) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF87171).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Actual exceeds scheduled by more than 15%',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: const Color(0xFFF87171),
                    ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _StaffStat extends StatelessWidget {
  const _StaffStat({
    required this.label,
    required this.value,
    this.warn = false,
  });

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: warn ? const Color(0xFFF87171) : null,
              ),
        ),
      ]),
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
