import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/capacity_engine.dart';

/// Manager view: live kitchen capacity — staff on shift, order volume,
/// auto-pause status. Toggle auto-pause and adjust thresholds.
class CapacityScreen extends StatefulWidget {
  const CapacityScreen({
    super.key,
    required this.organizationId,
    this.onBack,
  });

  final String organizationId;
  final VoidCallback? onBack;

  @override
  State<CapacityScreen> createState() => _CapacityScreenState();
}

class _CapacityScreenState extends State<CapacityScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  bool _busy = false;

  String _restaurantId = '';
  CapacityStatus _status = const CapacityStatus(
    staffOnShift: 0,
    ordersLastHour: 0,
    maxCapacity: 0,
    state: CapacityState.unknown,
  );
  bool _autoPauseEnabled = true;
  int _autoPauseThreshold = 1;
  int _maxOrdersPerHour = 15;
  List<_CapacityEventRow> _events = const [];

  final _subs = <StreamSubscription<dynamic>>[];

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
    for (final table in ['time_entries', 'online_orders', 'restaurant_settings']) {
      _subs.add(
        _client
            .from(table)
            .stream(primaryKey: ['id'])
            .eq('organization_id', widget.organizationId)
            .listen((_) => _load(quiet: true)),
      );
    }
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
      final restaurantRow = await _client
          .from('restaurants')
          .select('id')
          .eq('organization_id', widget.organizationId)
          .maybeSingle();
      if (restaurantRow == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No restaurant found for this organization.';
        });
        return;
      }
      final restId = restaurantRow['id'] as String;

      final engine = CapacityEngine(_client);
      final status = await engine.check(
        organizationId: widget.organizationId,
        restaurantId: restId,
      );

      final settingsRow = await _client
          .from('restaurant_settings')
          .select()
          .eq('restaurant_id', restId)
          .maybeSingle();

      final eventRows = await _client
          .from('capacity_events')
          .select('event, staff_on_shift, orders_last_hour, max_capacity, detail, created_at')
          .eq('restaurant_id', restId)
          .order('created_at', ascending: false)
          .limit(10);

      if (!mounted) return;
      setState(() {
        _restaurantId = restId;
        _status = status;
        _autoPauseEnabled = settingsRow?['auto_pause_enabled'] as bool? ?? true;
        _autoPauseThreshold =
            (settingsRow?['auto_pause_threshold'] as num?)?.toInt() ?? 1;
        _maxOrdersPerHour =
            (settingsRow?['max_orders_per_hour'] as num?)?.toInt() ?? 15;
        _events = (eventRows as List)
            .cast<Map<String, dynamic>>()
            .map(_CapacityEventRow.fromMap)
            .toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load capacity status.';
      });
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _toggleAutoPause() async {
    if (_busy || _restaurantId.isEmpty) return;
    setState(() => _busy = true);
    try {
      final next = !_autoPauseEnabled;
      await _client
          .from('restaurant_settings')
          .update({'auto_pause_enabled': next})
          .eq('restaurant_id', _restaurantId);
      if (!mounted) return;
      setState(() {
        _autoPauseEnabled = next;
        _busy = false;
      });
      _snack(next ? 'Auto-pause enabled' : 'Auto-pause disabled');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not update setting.');
    }
  }

  Future<void> _adjustThreshold(int delta) async {
    final next = (_autoPauseThreshold + delta).clamp(0, 10);
    if (next == _autoPauseThreshold || _busy) return;
    setState(() => _busy = true);
    try {
      await _client
          .from('restaurant_settings')
          .update({'auto_pause_threshold': next})
          .eq('restaurant_id', _restaurantId);
      if (!mounted) return;
      setState(() {
        _autoPauseThreshold = next;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not update threshold.');
    }
  }

  Future<void> _adjustMaxOrders(int delta) async {
    final next = (_maxOrdersPerHour + delta).clamp(1, 50);
    if (next == _maxOrdersPerHour || _busy) return;
    setState(() => _busy = true);
    try {
      await _client
          .from('restaurant_settings')
          .update({'max_orders_per_hour': next})
          .eq('restaurant_id', _restaurantId);
      if (!mounted) return;
      setState(() {
        _maxOrdersPerHour = next;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not update max orders.');
    }
  }

  Future<void> _manualPauseResume() async {
    if (_busy || _restaurantId.isEmpty) return;
    setState(() => _busy = true);
    try {
      final isPaused = _status.paused;
      final next = !isPaused;
      await _client
          .from('restaurant_settings')
          .update({'paused': next})
          .eq('restaurant_id', _restaurantId);
      await _client.from('capacity_events').insert({
        'organization_id': widget.organizationId,
        'restaurant_id': _restaurantId,
        'event': next ? 'manual_pause' : 'manual_resume',
        'staff_on_shift': _status.staffOnShift,
        'orders_last_hour': _status.ordersLastHour,
        'max_capacity': _status.maxCapacity,
      });
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(next ? 'Ordering paused' : 'Ordering reopened');
      _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not toggle ordering.');
    }
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
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(children: [
                    if (widget.onBack != null)
                      IconButton(
                        onPressed: widget.onBack,
                        icon: const Icon(Icons.arrow_back_rounded),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      ),
                    if (widget.onBack != null) const SizedBox(width: 4),
                    Expanded(
                      child: Text('Smart Capacity',
                          style: Theme.of(context).textTheme.displaySmall),
                    ),
                  ]),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              sliver: SliverList.list(children: [
                _StatusCard(status: _status),
                const SizedBox(height: 12),
                _ControlsCard(
                  autoPauseEnabled: _autoPauseEnabled,
                  autoPauseThreshold: _autoPauseThreshold,
                  maxOrdersPerHour: _maxOrdersPerHour,
                  isPaused: _status.paused,
                  busy: _busy,
                  onToggleAutoPause: _toggleAutoPause,
                  onAdjustThreshold: _adjustThreshold,
                  onAdjustMaxOrders: _adjustMaxOrders,
                  onManualPauseResume: _manualPauseResume,
                ),
                const SizedBox(height: 12),
                if (_events.isNotEmpty) ...[
                  Text('Recent events',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final e in _events) ...[
                    _EventCard(event: e),
                    if (e != _events.last) const SizedBox(height: 8),
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

// ─── Models ──────────────────────────────────────────────────────────────────

class _CapacityEventRow {
  const _CapacityEventRow({
    required this.event,
    required this.staffOnShift,
    required this.ordersLastHour,
    required this.maxCapacity,
    required this.detail,
    required this.createdAt,
  });

  final String event;
  final int staffOnShift;
  final int ordersLastHour;
  final int maxCapacity;
  final String? detail;
  final DateTime createdAt;

  factory _CapacityEventRow.fromMap(Map<String, dynamic> m) => _CapacityEventRow(
        event: m['event'] as String? ?? '',
        staffOnShift: (m['staff_on_shift'] as num?)?.toInt() ?? 0,
        ordersLastHour: (m['orders_last_hour'] as num?)?.toInt() ?? 0,
        maxCapacity: (m['max_capacity'] as num?)?.toInt() ?? 0,
        detail: m['detail'] as String?,
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
      );
}

// ─── UI ──────────────────────────────────────────────────────────────────────

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

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final CapacityStatus status;

  Color _stateColor(ColorScheme cs) {
    switch (status.state) {
      case CapacityState.open:
        return const Color(0xFF4ADE80);
      case CapacityState.nearCapacity:
        return const Color(0xFFFBBF24);
      case CapacityState.atCapacity:
        return const Color(0xFFF87171);
      case CapacityState.autoPaused:
        return const Color(0xFFF87171);
      case CapacityState.manuallyPaused:
        return cs.onSurface.withValues(alpha: 0.4);
      case CapacityState.unknown:
        return cs.onSurface.withValues(alpha: 0.4);
    }
  }

  String get _stateLabel {
    switch (status.state) {
      case CapacityState.open:
        return 'Open';
      case CapacityState.nearCapacity:
        return 'Near capacity';
      case CapacityState.atCapacity:
        return 'At capacity';
      case CapacityState.autoPaused:
        return 'Auto-paused';
      case CapacityState.manuallyPaused:
        return 'Paused';
      case CapacityState.unknown:
        return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _stateColor(cs);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 10),
            Text(_stateLabel,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: color,
                )),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            _Metric(label: 'Staff on shift', value: '${status.staffOnShift}'),
            _VertDivider(color: cs.outlineVariant),
            _Metric(
                label: 'Orders (1h)',
                value: '${status.ordersLastHour}',
                sublabel: '/ ${status.maxCapacity} max'),
            _VertDivider(color: cs.outlineVariant),
            _Metric(
                label: 'Capacity',
                value: status.maxCapacity > 0
                    ? '${((status.ordersLastHour / status.maxCapacity) * 100).round()}%'
                    : '—'),
          ]),
          if (status.customerMessage.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                status.customerMessage,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.8),
                    ),
              ),
            ),
          ],
        ]),
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

class _ControlsCard extends StatelessWidget {
  const _ControlsCard({
    required this.autoPauseEnabled,
    required this.autoPauseThreshold,
    required this.maxOrdersPerHour,
    required this.isPaused,
    required this.busy,
    required this.onToggleAutoPause,
    required this.onAdjustThreshold,
    required this.onAdjustMaxOrders,
    required this.onManualPauseResume,
  });

  final bool autoPauseEnabled;
  final int autoPauseThreshold;
  final int maxOrdersPerHour;
  final bool isPaused;
  final bool busy;
  final VoidCallback onToggleAutoPause;
  final void Function(int) onAdjustThreshold;
  final void Function(int) onAdjustMaxOrders;
  final VoidCallback onManualPauseResume;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Settings', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 16),
          // Auto-pause toggle
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Auto-pause when short-staffed',
                    style: Theme.of(context).textTheme.bodyMedium),
                Text('Pauses ordering if staff drop below threshold',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.5),
                        )),
              ]),
            ),
            Switch(
              value: autoPauseEnabled,
              onChanged: busy ? null : (_) => onToggleAutoPause(),
            ),
          ]),
          const Divider(height: 24),
          // Min staff threshold
          Row(children: [
            Expanded(
              child: Text('Minimum staff to stay open',
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
            _Stepper(
              value: autoPauseThreshold,
              onMinus: busy ? null : () => onAdjustThreshold(-1),
              onPlus: busy ? null : () => onAdjustThreshold(1),
            ),
          ]),
          const SizedBox(height: 12),
          // Max orders per hour per staff
          Row(children: [
            Expanded(
              child: Text('Max orders/hour per staff',
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
            _Stepper(
              value: maxOrdersPerHour,
              onMinus: busy ? null : () => onAdjustMaxOrders(-1),
              onPlus: busy ? null : () => onAdjustMaxOrders(1),
            ),
          ]),
          const Divider(height: 24),
          // Manual pause/resume
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : onManualPauseResume,
              icon: Icon(isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded),
              label: Text(isPaused ? 'Reopen ordering' : 'Pause ordering'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.value,
    this.onMinus,
    this.onPlus,
  });

  final int value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        onPressed: onMinus,
        icon: const Icon(Icons.remove_rounded),
        iconSize: 20,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
      SizedBox(
        width: 32,
        child: Text('$value',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
      ),
      IconButton(
        onPressed: onPlus,
        icon: const Icon(Icons.add_rounded),
        iconSize: 20,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
    ]);
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});

  final _CapacityEventRow event;

  Color _eventColor(ColorScheme cs) {
    switch (event.event) {
      case 'auto_pause':
      case 'manual_pause':
        return const Color(0xFFF87171);
      case 'auto_resume':
      case 'manual_resume':
        return const Color(0xFF4ADE80);
      case 'capacity_warning':
        return const Color(0xFFFBBF24);
      default:
        return cs.onSurface.withValues(alpha: 0.4);
    }
  }

  String get _eventLabel {
    switch (event.event) {
      case 'auto_pause':
        return 'Auto-paused';
      case 'auto_resume':
        return 'Auto-resumed';
      case 'manual_pause':
        return 'Manually paused';
      case 'manual_resume':
        return 'Manually reopened';
      case 'capacity_warning':
        return 'Capacity warning';
      default:
        return event.event;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _eventColor(cs);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_eventLabel, style: Theme.of(context).textTheme.bodyMedium),
              if (event.detail != null)
                Text(event.detail!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.5),
                        )),
            ]),
          ),
          Text(
            '${event.staffOnShift} staff · ${event.ordersLastHour}/${event.maxCapacity}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.4),
                ),
          ),
        ]),
      ),
    );
  }
}