import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/entitlements.dart';
import 'menu_screen.dart';
import 'ordering_models.dart';

/// Kitchen / staff console — accept, reject, complete, pause ordering.
class StaffConsoleScreen extends StatefulWidget {
  const StaffConsoleScreen({
    super.key,
    required this.organizationId,
    this.role = StaffRole.server,
  });

  final String organizationId;
  final StaffRole role;

  @override
  State<StaffConsoleScreen> createState() => _StaffConsoleScreenState();
}

class _StaffConsoleScreenState extends State<StaffConsoleScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  bool _busy = false;
  String _restaurantId = '';
  String _restaurantName = '';
  RestaurantSettingsData? _settings;
  List<_OrderData> _orders = const [];
  String? _expandedId;

  final _subs = <StreamSubscription<dynamic>>[];

  bool get _canManage => widget.role.canManage;

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
          .from('online_orders')
          .stream(primaryKey: ['id'])
          .eq('organization_id', widget.organizationId)
          .listen((_) => _load(quiet: true)),
    );
    _subs.add(
      _client
          .from('restaurant_settings')
          .stream(primaryKey: ['restaurant_id'])
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
      final restaurant = await _client
          .from('restaurants')
          .select('id, name')
          .eq('organization_id', widget.organizationId)
          .maybeSingle();

      if (restaurant == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error =
              'No restaurant linked to this venue yet. Apply the ordering migration.';
        });
        return;
      }

      final restId = restaurant['id'] as String;

      final results = await Future.wait<dynamic>([
        _client
            .from('restaurant_settings')
            .select()
            .eq('restaurant_id', restId)
            .eq('organization_id', widget.organizationId)
            .maybeSingle(),
        _client
            .from('online_orders')
            .select(
              'id, public_token, status, submitted_at, accepted_at, rejected_at, '
              'completed_at, reject_reason, pickup_minutes, customer_json, notes, '
              'subtotal_cents, fee_cents, tax_cents, total_cents, '
              'order_items(id, name, price_cents, quantity, notes, '
              'order_item_modifiers(name, price_delta_cents))',
            )
            .eq('organization_id', widget.organizationId)
            .order('submitted_at', ascending: false)
            .limit(50),
      ]);

      final settingsRow = results[0] as Map<String, dynamic>?;
      final orderRows = (results[1] as List).cast<Map<String, dynamic>>();

      if (!mounted) return;
      setState(() {
        _restaurantId = restId;
        _restaurantName = restaurant['name'] as String? ?? 'Orders';
        _settings = settingsRow == null
            ? null
            : RestaurantSettingsData.fromMap(settingsRow);
        _orders = orderRows.map(_OrderData.fromMap).toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load orders. Pull to retry.';
      });
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _setStatus(_OrderData order, String status,
      {String? reason}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final patch = <String, dynamic>{'status': status};
      final now = DateTime.now().toUtc().toIso8601String();
      switch (status) {
        case 'accepted':
          patch['accepted_at'] = now;
        case 'rejected':
          patch['rejected_at'] = now;
          patch['reject_reason'] = reason ?? '';
        case 'completed':
          patch['completed_at'] = now;
      }
      await _client
          .from('online_orders')
          .update(patch)
          .eq('id', order.id)
          .eq('organization_id', widget.organizationId);
      if (!mounted) return;
      _snack('Order ${order.publicToken} → $status');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      _snack('Could not update order.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject(_OrderData order) async {
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject order?'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Reason',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (reason == null) return;
    await _setStatus(order, 'rejected', reason: reason);
  }

  Future<void> _togglePause() async {
    if (!_canManage || _busy || _settings == null) return;
    setState(() => _busy = true);
    try {
      final next = !_settings!.paused;
      await _client.from('restaurant_settings').update({'paused': next}).eq(
          'restaurant_id', _restaurantId);
      if (!mounted) return;
      _snack(next ? 'Ordering paused' : 'Ordering reopened');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      _snack('Could not update pause state.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openMenu() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MenuScreen(organizationId: widget.organizationId),
      ),
    );
  }

  List<_OrderData> get _active => _orders
      .where((o) => o.status == 'waiting' || o.status == 'accepted')
      .toList();

  List<_OrderData> get _history => _orders
      .where((o) => o.status == 'completed' || o.status == 'rejected')
      .toList();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final paused = _settings?.paused == true;

    return Scaffold(
      appBar: AppBar(
        title: Text(_restaurantName),
        actions: [
          IconButton(
            tooltip: 'Preview menu',
            onPressed: _openMenu,
            icon: const Icon(Icons.restaurant_menu_rounded),
          ),
          if (_canManage)
            IconButton(
              tooltip: paused ? 'Reopen ordering' : 'Pause ordering',
              onPressed: _busy ? null : _togglePause,
              icon: Icon(paused
                  ? Icons.play_circle_outline_rounded
                  : Icons.pause_circle_outline_rounded),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (paused)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Material(
                  color: cs.errorContainer.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(16),
                  child: const ListTile(
                    leading: Icon(Icons.pause_circle_filled_rounded),
                    title: Text('Online ordering is paused'),
                    subtitle: Text('Customers see “temporarily unavailable”.'),
                  ),
                ),
              ),
            Text('Active', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_active.isEmpty)
              const _EmptyCard(
                icon: Icons.receipt_long_outlined,
                title: 'No active orders',
                subtitle: 'New tickets will appear here in real time.',
              )
            else
              for (final o in _active)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _OrderCard(
                    order: o,
                    expanded: _expandedId == o.id,
                    busy: _busy,
                    onToggle: () => setState(() {
                      _expandedId = _expandedId == o.id ? null : o.id;
                    }),
                    onAccept: o.status == 'waiting'
                        ? () => _setStatus(o, 'accepted')
                        : null,
                    onReject:
                        o.status == 'waiting' ? () => _reject(o) : null,
                    onComplete: o.status == 'accepted'
                        ? () => _setStatus(o, 'completed')
                        : null,
                  ),
                ),
            const SizedBox(height: 20),
            Text('Recent', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_history.isEmpty)
              Text(
                'Completed and rejected orders show up here.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
              )
            else
              for (final o in _history.take(20))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _OrderCard(
                    order: o,
                    expanded: _expandedId == o.id,
                    busy: _busy,
                    onToggle: () => setState(() {
                      _expandedId = _expandedId == o.id ? null : o.id;
                    }),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _OrderData {
  const _OrderData({
    required this.id,
    required this.publicToken,
    required this.status,
    required this.submittedAt,
    required this.acceptedAt,
    required this.rejectedAt,
    required this.completedAt,
    required this.rejectReason,
    required this.pickupMinutes,
    required this.customerName,
    required this.customerPhone,
    required this.notes,
    required this.totalCents,
    required this.items,
  });

  final String id;
  final String publicToken;
  final String status;
  final DateTime submittedAt;
  final DateTime? acceptedAt;
  final DateTime? rejectedAt;
  final DateTime? completedAt;
  final String rejectReason;
  final int pickupMinutes;
  final String customerName;
  final String customerPhone;
  final String notes;
  final int totalCents;
  final List<_OrderLine> items;

  factory _OrderData.fromMap(Map<String, dynamic> m) {
    final customer = m['customer_json'];
    String name = '';
    String phone = '';
    if (customer is Map) {
      name = '${customer['name'] ?? ''}';
      phone = '${customer['phone'] ?? ''}';
    }
    final rawItems = m['order_items'];
    final items = <_OrderLine>[];
    if (rawItems is List) {
      for (final row in rawItems) {
        if (row is Map<String, dynamic>) {
          items.add(_OrderLine.fromMap(row));
        }
      }
    }
    return _OrderData(
      id: m['id'] as String,
      publicToken: m['public_token'] as String? ?? '',
      status: m['status'] as String? ?? 'waiting',
      submittedAt: DateTime.tryParse(m['submitted_at'] as String? ?? '') ??
          DateTime.now(),
      acceptedAt: DateTime.tryParse(m['accepted_at'] as String? ?? ''),
      rejectedAt: DateTime.tryParse(m['rejected_at'] as String? ?? ''),
      completedAt: DateTime.tryParse(m['completed_at'] as String? ?? ''),
      rejectReason: m['reject_reason'] as String? ?? '',
      pickupMinutes: (m['pickup_minutes'] as num?)?.toInt() ?? 30,
      customerName: name,
      customerPhone: phone,
      notes: m['notes'] as String? ?? '',
      totalCents: (m['total_cents'] as num?)?.toInt() ?? 0,
      items: items,
    );
  }

  Duration? get pickupCountdown {
    final start = acceptedAt;
    if (start == null || status != 'accepted') return null;
    final ready = start.add(Duration(minutes: pickupMinutes));
    return ready.difference(DateTime.now());
  }
}

class _OrderLine {
  const _OrderLine({
    required this.name,
    required this.priceCents,
    required this.quantity,
    required this.notes,
    required this.modifiers,
  });

  final String name;
  final int priceCents;
  final int quantity;
  final String notes;
  final List<String> modifiers;

  factory _OrderLine.fromMap(Map<String, dynamic> m) {
    final mods = <String>[];
    final raw = m['order_item_modifiers'];
    if (raw is List) {
      for (final r in raw) {
        if (r is Map && r['name'] != null) mods.add('${r['name']}');
      }
    }
    return _OrderLine(
      name: m['name'] as String? ?? '',
      priceCents: (m['price_cents'] as num?)?.toInt() ?? 0,
      quantity: (m['quantity'] as num?)?.toInt() ?? 1,
      notes: m['notes'] as String? ?? '',
      modifiers: mods,
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({
    required this.order,
    required this.expanded,
    required this.busy,
    required this.onToggle,
    this.onAccept,
    this.onReject,
    this.onComplete,
  });

  final _OrderData order;
  final bool expanded;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final VoidCallback? onComplete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final time = DateFormat.jm().format(order.submittedAt.toLocal());
    final countdown = order.pickupCountdown;
    String? countdownLabel;
    if (countdown != null) {
      if (countdown.isNegative) {
        countdownLabel = 'Pickup overdue';
      } else {
        final m = countdown.inMinutes;
        final s = countdown.inSeconds % 60;
        countdownLabel = 'Pickup in ${m}m ${s.toString().padLeft(2, '0')}s';
      }
    }

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
                      '#${order.publicToken} · $time',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  _StatusChip(status: order.status),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${order.customerName} · ${order.customerPhone}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                formatCents(order.totalCents),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: cs.primary),
              ),
              if (countdownLabel != null) ...[
                const SizedBox(height: 6),
                Text(
                  countdownLabel,
                  style: TextStyle(
                    color: countdown!.isNegative ? cs.error : cs.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (expanded) ...[
                const SizedBox(height: 12),
                for (final line in order.items) ...[
                  Text(
                    '${line.quantity}× ${line.name}',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  if (line.modifiers.isNotEmpty)
                    Text(
                      line.modifiers.join(' · '),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                    ),
                  const SizedBox(height: 6),
                ],
                if (order.notes.isNotEmpty)
                  Text('Notes: ${order.notes}',
                      style: Theme.of(context).textTheme.bodyMedium),
                if (order.rejectReason.isNotEmpty)
                  Text('Rejected: ${order.rejectReason}',
                      style: TextStyle(color: cs.error)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (onAccept != null)
                      FilledButton(
                        onPressed: busy ? null : onAccept,
                        child: const Text('Accept'),
                      ),
                    if (onReject != null)
                      OutlinedButton(
                        onPressed: busy ? null : onReject,
                        child: const Text('Reject'),
                      ),
                    if (onComplete != null)
                      FilledButton.tonal(
                        onPressed: busy ? null : onComplete,
                        child: const Text('Complete'),
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
      'waiting' => ('Waiting', cs.tertiary),
      'accepted' => ('Accepted', cs.primary),
      'rejected' => ('Rejected', cs.error),
      'completed' => ('Done', cs.onSurface.withValues(alpha: 0.5)),
      _ => (status, cs.onSurface),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w600, fontSize: 12)),
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
            height: 88,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 88,
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
