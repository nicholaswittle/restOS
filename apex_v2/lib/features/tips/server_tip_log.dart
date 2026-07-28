import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';

/// Server tip log — servers enter what they made each day.
/// Owners/managers see everyone's declared tips vs pool splits.
class ServerTipLog extends StatefulWidget {
  const ServerTipLog({
    super.key,
    required this.organizationId,
    this.canManage,
    this.onBack,
  });

  final String organizationId;
  final bool? canManage;
  final VoidCallback? onBack;

  @override
  State<ServerTipLog> createState() => _ServerTipLogState();
}

class _ServerTipLogState extends State<ServerTipLog> {
  final _client = Supabase.instance.client;
  final _cashCtrl = TextEditingController();
  final _cardCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  bool _loading = true;
  String? _error;
  bool _saving = false;

  String _myName = '';
  bool _canManage = false;
  DateTime _entryDate = DateTime.now();

  List<_ServerTipRow> _myTips = const [];
  List<_AuditRow> _auditRows = const [];
  _WeekTotal _myWeek = const _WeekTotal(cash: 0, card: 0, total: 0, days: 0);

  final _subs = <StreamSubscription<dynamic>>[];

  String get _userId => DemoMode.enabled
      ? DemoMode.userId
      : (_client.auth.currentUser?.id ?? '');

  String get _dateKey => DateFormat('yyyy-MM-dd').format(_entryDate);

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
    _cashCtrl.dispose();
    _cardCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    _subs.add(
      _client
          .from('server_tips')
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
      final now = DateTime.now();
      final weekStart = now.subtract(Duration(days: now.weekday - 1));
      final weekStartKey = DateFormat('yyyy-MM-dd').format(weekStart);
      final weekEndKey =
          DateFormat('yyyy-MM-dd').format(weekStart.add(const Duration(days: 6)));

      final profile = await _client
          .from('profiles')
          .select('name, role')
          .eq('id', _userId)
          .eq('organization_id', widget.organizationId)
          .maybeSingle();

      final name = profile?['name'] as String? ?? 'Staff';
      final role = (profile?['role'] as String?)?.toLowerCase() ?? '';
      final canManage = widget.canManage ??
          (role == 'owner' || role == 'manager' || role == 'Owner' || role == 'Manager');

      // tip_allocations must not order on embedded tip_pools.shift_date —
      // PostgREST returns 400 and the whole screen fails to load.
      final results = await Future.wait<dynamic>([
        _client
            .from('server_tips')
            .select()
            .eq('organization_id', widget.organizationId)
            .eq('user_id', _userId)
            .order('shift_date', ascending: false)
            .limit(30),
        _client
            .from('server_tips')
            .select()
            .eq('organization_id', widget.organizationId)
            .eq('user_id', _userId)
            .gte('shift_date', weekStartKey)
            .lte('shift_date', weekEndKey),
        _client
            .from('server_tips')
            .select(
                'id, staff_name, shift_date, cash_tips_cents, card_tips_cents, total_cents')
            .eq('organization_id', widget.organizationId)
            .order('shift_date', ascending: false)
            .limit(30),
        _client
            .from('tip_allocations')
            .select(
              'amount_cents, hours_worked, tip_pools!inner(shift_date, organization_id, total_cents)',
            )
            .eq('tip_pools.organization_id', widget.organizationId)
            .limit(100),
      ]);

      if (!mounted) return;

      final myTips = (results[0] as List)
          .cast<Map<String, dynamic>>()
          .map(_ServerTipRow.fromMap)
          .toList();

      final weekRows = (results[1] as List)
          .cast<Map<String, dynamic>>()
          .map(_ServerTipRow.fromMap)
          .toList();
      var weekCash = 0, weekCard = 0;
      for (final r in weekRows) {
        weekCash += r.cashCents;
        weekCard += r.cardCents;
      }

      final allServerTips = (results[2] as List)
          .cast<Map<String, dynamic>>()
          .map(_ServerTipRow.fromMap)
          .toList();

      final poolAllocs = (results[3] as List)
          .cast<Map<String, dynamic>>()
          .toList();

      // Build audit rows: match server-declared totals to pool split totals by date
      final audit = <_AuditRow>[];
      final byDateServer = <String, int>{};
      for (final r in allServerTips) {
        byDateServer[r.shiftDate] = (byDateServer[r.shiftDate] ?? 0) + r.totalCents;
      }
      final byDatePool = <String, int>{};
      for (final r in poolAllocs) {
        final pool = r['tip_pools'] as Map<String, dynamic>?;
        final date = pool?['shift_date'] as String?;
        final amt = (r['amount_cents'] as num?)?.toInt() ?? 0;
        if (date != null) {
          byDatePool[date] = (byDatePool[date] ?? 0) + amt;
        }
      }

      final allDates = {...byDateServer.keys, ...byDatePool.keys}
          .toList()
        ..sort((a, b) => b.compareTo(a));
      for (final date in allDates.take(14)) {
        final declared = byDateServer[date] ?? 0;
        final split = byDatePool[date] ?? 0;
        audit.add(_AuditRow(
          date: date,
          declaredCents: declared,
          splitCents: split,
          diffCents: declared - split,
        ));
      }

      // Check if today already has an entry
      final existing = myTips.where((t) => t.shiftDate == _dateKey).firstOrNull;
      if (existing != null) {
        _cashCtrl.text = (existing.cashCents / 100).toStringAsFixed(2);
        _cardCtrl.text = (existing.cardCents / 100).toStringAsFixed(2);
        _noteCtrl.text = existing.note ?? '';
      } else {
        _cashCtrl.clear();
        _cardCtrl.clear();
        _noteCtrl.clear();
      }

      setState(() {
        _myName = name;
        _canManage = canManage;
        _myTips = myTips;
        _auditRows = audit;
        _myWeek = _WeekTotal(
          cash: weekCash,
          card: weekCard,
          total: weekCash + weekCard,
          days: weekRows.length,
        );
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load tips. Pull to retry.';
      });
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final cash = _parseDollars(_cashCtrl.text);
    final card = _parseDollars(_cardCtrl.text);
    if (cash <= 0 && card <= 0) {
      _snack('Enter cash and/or card tips.');
      return;
    }

    setState(() => _saving = true);
    try {
      await _client.from('server_tips').upsert(
        {
          'organization_id': widget.organizationId,
          'user_id': _userId,
          'staff_name': _myName,
          'shift_date': _dateKey,
          'cash_tips_cents': (cash * 100).round(),
          'card_tips_cents': (card * 100).round(),
          'note': _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'organization_id,user_id,shift_date',
      );

      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Tips saved for ${DateFormat('MMM d').format(_entryDate)}.');
      _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Could not save. Try again.');
    }
  }

  Future<void> _delete(_ServerTipRow row) async {
    try {
      await _client.from('server_tips').delete().eq('id', row.id);
      if (!mounted) return;
      _snack('Deleted ${DateFormat('MMM d').format(DateTime.parse(row.shiftDate))}.');
      _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      _snack('Could not delete.');
    }
  }

  double _parseDollars(String s) {
    final cleaned = s.trim().replaceAll(r'$', '').replaceAll(',', '');
    return double.tryParse(cleaned) ?? 0;
  }

  void _changeDate(int delta) {
    setState(() {
      _entryDate = _entryDate.add(Duration(days: delta));
    });
    _load(quiet: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
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
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                      ),
                    if (widget.onBack != null) const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'My Tips',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              sliver: SliverList.list(children: [
                // Week summary
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('This week', style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.6),
                      )),
                      const SizedBox(height: 12),
                      Row(children: [
                        _Stat(label: 'Cash', value: '\$${(_myWeek.cash / 100).toStringAsFixed(0)}'),
                        _Divider(color: cs.outlineVariant),
                        _Stat(label: 'Card', value: '\$${(_myWeek.card / 100).toStringAsFixed(0)}'),
                        _Divider(color: cs.outlineVariant),
                        _Stat(label: 'Total', value: '\$${(_myWeek.total / 100).toStringAsFixed(0)}',
                          highlight: true),
                        _Divider(color: cs.outlineVariant),
                        _Stat(label: 'Days', value: '${_myWeek.days}'),
                      ]),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),

                // Entry form
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // Date picker
                      Row(children: [
                        IconButton(
                          onPressed: () => _changeDate(-1),
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        Expanded(
                          child: Text(
                            DateFormat('EEEE, MMM d').format(_entryDate),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          onPressed: () => _changeDate(1),
                          icon: const Icon(Icons.chevron_right_rounded),
                        ),
                      ]),
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(
                          child: _MoneyField(
                            label: 'Cash tips',
                            controller: _cashCtrl,
                            icon: Icons.payments_outlined,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _MoneyField(
                            label: 'Card tips',
                            controller: _cardCtrl,
                            icon: Icons.credit_card_outlined,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _noteCtrl,
                        decoration: InputDecoration(
                          labelText: 'Note (optional)',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          isDense: true,
                        ),
                        maxLines: 1,
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2.4),
                                )
                              : const Text('Save tips'),
                        ),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),

                // My recent entries
                Text('Recent entries', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_myTips.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text('No tips logged yet. Enter what you made today above.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  )
                else
                  for (final t in _myTips.take(10)) ...[
                    _TipEntryCard(
                      row: t,
                      onDelete: () => _delete(t),
                    ),
                    if (t != _myTips.take(10).last) const SizedBox(height: 8),
                  ],

                // Audit comparison (manager/owner only)
                if (_canManage && _auditRows.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('Audit: declared vs split', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('Compare what servers say vs tip pool payouts',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final a in _auditRows) ...[
                    _AuditCard(row: a),
                    if (a != _auditRows.last) const SizedBox(height: 8),
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

class _ServerTipRow {
  const _ServerTipRow({
    required this.id,
    required this.shiftDate,
    required this.cashCents,
    required this.cardCents,
    required this.totalCents,
    this.note,
  });

  final String id;
  final String shiftDate;
  final int cashCents;
  final int cardCents;
  final int totalCents;
  final String? note;

  factory _ServerTipRow.fromMap(Map<String, dynamic> m) => _ServerTipRow(
        id: m['id'] as String? ?? '',
        shiftDate: m['shift_date'] as String? ?? '',
        cashCents: (m['cash_tips_cents'] as num?)?.toInt() ?? 0,
        cardCents: (m['card_tips_cents'] as num?)?.toInt() ?? 0,
        totalCents: (m['total_cents'] as num?)?.toInt() ?? 0,
        note: m['note'] as String?,
      );
}

class _AuditRow {
  const _AuditRow({
    required this.date,
    required this.declaredCents,
    required this.splitCents,
    required this.diffCents,
  });

  final String date;
  final int declaredCents;
  final int splitCents;
  final int diffCents;
}

class _WeekTotal {
  const _WeekTotal({
    required this.cash,
    required this.card,
    required this.total,
    required this.days,
  });

  final int cash;
  final int card;
  final int total;
  final int days;
}

// ─── UI ──────────────────────────────────────────────────────────────────────

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.highlight});

  final String label;
  final String value;
  final bool? highlight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(children: [
        Text(value,
          style: TextStyle(
            fontSize: highlight == true ? 22 : 18,
            fontWeight: FontWeight.w700,
            color: highlight == true ? cs.primary : cs.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ]),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 36, color: color.withValues(alpha: 0.3));
  }
}

class _MoneyField extends StatelessWidget {
  const _MoneyField({required this.label, required this.controller, required this.icon});

  final String label;
  final TextEditingController controller;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
      ],
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        prefixText: '\$',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
      ),
    );
  }
}

class _TipEntryCard extends StatelessWidget {
  const _TipEntryCard({required this.row, required this.onDelete});

  final _ServerTipRow row;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final date = DateTime.tryParse(row.shiftDate);
    final label = date != null ? DateFormat('EEE, MMM d').format(date) : row.shiftDate;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Row(children: [
                if (row.cashCents > 0)
                  Text('Cash \$${(row.cashCents / 100).toStringAsFixed(0)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                if (row.cashCents > 0 && row.cardCents > 0) const SizedBox(width: 12),
                if (row.cardCents > 0)
                  Text('Card \$${(row.cardCents / 100).toStringAsFixed(0)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
              ]),
              if (row.note != null && row.note!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(row.note!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.45),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ]),
          ),
          Text('\$${(row.totalCents / 100).toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: cs.primary,
            ),
          ),
          IconButton(
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline_rounded, size: 20,
              color: cs.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ]),
      ),
    );
  }
}

class _AuditCard extends StatelessWidget {
  const _AuditCard({required this.row});

  final _AuditRow row;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(row.date);
    final label = date != null ? DateFormat('EEE, MMM d').format(date) : row.date;
    final diff = row.diffCents;
    final diffColor = diff.abs() < 100
        ? const Color(0xFF4ADE80)
        : diff.abs() < 1000
            ? const Color(0xFFFBBF24)
            : const Color(0xFFF87171);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: _CompareStat(label: 'Servers said', value: '\$${(row.declaredCents / 100).toStringAsFixed(2)}'),
            ),
            const Icon(Icons.compare_arrows_rounded, size: 18, color: Colors.grey),
            Expanded(
              child: _CompareStat(label: 'Pool split', value: '\$${(row.splitCents / 100).toStringAsFixed(2)}'),
            ),
            Expanded(
              child: _CompareStat(
                label: 'Difference',
                value: '${diff >= 0 ? '+' : ''}\$${(diff / 100).toStringAsFixed(2)}',
                color: diffColor,
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _CompareStat extends StatelessWidget {
  const _CompareStat({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Text(value,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: color ?? cs.onSurface,
        ),
      ),
      const SizedBox(height: 2),
      Text(label,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSurface.withValues(alpha: 0.5),
        ),
      ),
    ]);
  }
}