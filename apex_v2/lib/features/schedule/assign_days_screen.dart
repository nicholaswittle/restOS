import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/conflict_detector.dart';
import '../../core/labor_guardrails.dart';
import '../../core/notification_service.dart';
import '../../core/shift_time.dart';

/// Manager publish flow: pick a person, pick hours, tap days on a month grid,
/// submit. No role/zone — just who works when.
class AssignDaysScreen extends StatefulWidget {
  const AssignDaysScreen({
    super.key,
    required this.organizationId,
  });

  final String organizationId;

  @override
  State<AssignDaysScreen> createState() => _AssignDaysScreenState();
}

class _AssignDaysScreenState extends State<AssignDaysScreen> {
  final _client = Supabase.instance.client;
  final _startCtrl = TextEditingController(text: '16:00');
  final _endCtrl = TextEditingController(text: '22:00');

  bool _loading = true;
  String? _error;
  bool _busy = false;

  List<String> _staffNames = const [];
  String? _staff;
  late DateTime _month; // first of month
  final Set<String> _selected = {};
  /// Days this person already has a shift in the visible month.
  final Set<String> _alreadyScheduled = {};

  static const _presets = <(String, String, String)>[
    ('Lunch', '11:00', '15:00'),
    ('Mid', '12:00', '20:00'),
    ('Dinner', '16:00', '22:00'),
    ('Close', '17:00', '23:00'),
  ];

  String get _start => _startCtrl.text.trim();
  String get _end => _endCtrl.text.trim();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month, 1);
    _load();
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final monthEnd = DateTime(_month.year, _month.month + 1, 0);
      final nameRows = await _client
          .from('profiles')
          .select('name')
          .eq('organization_id', widget.organizationId)
          .order('name');

      if (!mounted) return;
      final names = (nameRows as List)
          .cast<Map<String, dynamic>>()
          .map((r) => r['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
      final staff = _staff ?? (names.isNotEmpty ? names.first : null);

      final existing = <String>{};
      if (staff != null) {
        final shiftRows = await _client
            .from('shifts')
            .select('shift_date')
            .eq('organization_id', widget.organizationId)
            .eq('staff', staff)
            .gte('shift_date', dateKeyOf(_month))
            .lte('shift_date', dateKeyOf(monthEnd));
        for (final r in (shiftRows as List).cast<Map<String, dynamic>>()) {
          final d = r['shift_date'] as String?;
          if (d != null) existing.add(d);
        }
      }

      if (!mounted) return;
      setState(() {
        _staffNames = names;
        _staff = staff;
        _alreadyScheduled
          ..clear()
          ..addAll(existing);
        _selected.removeWhere((d) => existing.contains(d));
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load staff. Pull to retry.';
      });
    }
  }

  Future<void> _onStaffChanged(String? name) async {
    if (name == null || name == _staff) return;
    setState(() {
      _staff = name;
      _selected.clear();
    });
    await _load();
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta, 1);
      _selected.clear();
    });
    _load();
  }

  void _toggleDay(DateTime day) {
    final key = dateKeyOf(day);
    if (_alreadyScheduled.contains(key)) return;
    setState(() {
      if (_selected.contains(key)) {
        _selected.remove(key);
      } else {
        _selected.add(key);
      }
    });
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _submit() async {
    if (_busy) return;
    final staff = _staff;
    if (staff == null || staff.isEmpty) {
      _snack('Pick someone first.');
      return;
    }
    if (_selected.isEmpty) {
      _snack('Tap the days they work.');
      return;
    }
    if (hoursBetween(_start, _end) <= 0) {
      _snack('Check the shift times.');
      return;
    }

    setState(() => _busy = true);
    try {
      final days = _selected.toList()..sort();
      final conflicts = await ConflictDetector(_client).findPublishConflicts(
        organizationId: widget.organizationId,
        targetDates: days,
        staff: staff,
      );
      if (!mounted) return;
      if (conflicts.isNotEmpty) {
        setState(() => _busy = false);
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Conflicts found'),
            content: SingleChildScrollView(
              child: Text(conflicts.join('\n')),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Publish anyway'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
        if (!mounted) return;
        setState(() => _busy = true);
      }

      final guardrails = await LaborGuardrails(_client).checkProposedShifts(
        organizationId: widget.organizationId,
        staff: staff,
        shiftDates: days,
        startTime: _start,
        endTime: _end,
      );
      if (!mounted) return;
      if (guardrails.isNotEmpty) {
        setState(() => _busy = false);
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Labor checks'),
            content: SingleChildScrollView(
              child: Text(guardrails.join('\n\n')),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
        if (!mounted) return;
        setState(() => _busy = true);
      }

      final rows = [
        for (final day in days)
          {
            'organization_id': widget.organizationId,
            'shift_date': day,
            'staff': staff,
            'start_time': _start,
            'end_time': _end,
            'title': 'Shift',
            'day_num': DateTime.parse(day).day,
          },
      ];
      await _client.from('shifts').insert(rows);
      // Best-effort: alert the staff member the schedule landed.
      try {
        final profile = await _client
            .from('profiles')
            .select('id')
            .eq('organization_id', widget.organizationId)
            .eq('name', staff)
            .maybeSingle();
        final uid = profile?['id'] as String?;
        if (uid != null) {
          await NotificationService.notifyUser(
            targetUserId: uid,
            title: 'Schedule updated',
            body:
                '${rows.length} day${rows.length == 1 ? '' : 's'} published for you.',
          );
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _busy = false;
        _selected.clear();
      });
      _snack(
        '${rows.length} ${rows.length == 1 ? 'day' : 'days'} scheduled for $staff.',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not save. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _staffNames.isEmpty) {
      return const Scaffold(body: _LoadingView());
    }
    if (_error != null && _staffNames.isEmpty) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final cs = Theme.of(context).colorScheme;
    final monthLabel = _monthLabel(_month);

    return Scaffold(
      body: Column(children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
            child: Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Expanded(
                child: Text('Assign days',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
            ]),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Text('Who', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_staffNames.isEmpty)
                Text(
                  'No staff in this venue yet.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                )
              else
                DropdownButtonFormField<String>(
                  key: ValueKey(_staff),
                  initialValue: _staff,
                  items: [
                    for (final n in _staffNames)
                      DropdownMenuItem(value: n, child: Text(n)),
                  ],
                  onChanged: _busy ? null : _onStaffChanged,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: cs.surfaceContainer,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Text('Shift', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in _presets)
                    ChoiceChip(
                      label: Text('${p.$1} · ${formatTime(p.$2)}–${formatTime(p.$3)}'),
                      selected: _start == p.$2 && _end == p.$3,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() {
                                _startCtrl.text = p.$2;
                                _endCtrl.text = p.$3;
                              }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    enabled: !_busy,
                    controller: _startCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Start',
                      hintText: '16:00',
                      filled: true,
                      fillColor: cs.surfaceContainer,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    enabled: !_busy,
                    controller: _endCtrl,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'End',
                      hintText: '22:00',
                      filled: true,
                      fillColor: cs.surfaceContainer,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 20),
              Row(children: [
                IconButton(
                  tooltip: 'Previous month',
                  onPressed: _busy ? null : () => _shiftMonth(-1),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Text(
                    monthLabel,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Next month',
                  onPressed: _busy ? null : () => _shiftMonth(1),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ]),
              const SizedBox(height: 4),
              Text(
                _selected.isEmpty
                    ? 'Tap the days they work'
                    : '${_selected.length} day${_selected.length == 1 ? '' : 's'} selected',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
              ),
              const SizedBox(height: 12),
              _MonthGrid(
                month: _month,
                selected: _selected,
                alreadyScheduled: _alreadyScheduled,
                onToggle: _busy ? null : _toggleDay,
              ),
              const SizedBox(height: 12),
              Row(children: [
                _LegendDot(color: cs.primary, label: 'Selected'),
                const SizedBox(width: 16),
                _LegendDot(
                  color: cs.onSurface.withValues(alpha: 0.25),
                  label: 'Already on',
                ),
              ]),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _busy || _selected.isEmpty ? null : _submit,
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : Text(
                          _selected.isEmpty
                              ? 'Submit'
                              : 'Submit · ${_selected.length} day${_selected.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  static String _monthLabel(DateTime m) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${months[m.month - 1]} ${m.year}';
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.alreadyScheduled,
    required this.onToggle,
  });

  final DateTime month;
  final Set<String> selected;
  final Set<String> alreadyScheduled;
  final void Function(DateTime day)? onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // DateTime.weekday: Mon=1 … Sun=7. Grid starts Monday.
    final lead = DateTime(month.year, month.month, 1).weekday - 1;
    final cells = lead + daysInMonth;
    final rows = ((cells + 6) ~/ 7);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
        child: Column(children: [
          Row(
            children: [
              for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                Expanded(
                  child: Text(
                    d,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.45),
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (var r = 0; r < rows; r++) ...[
            Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Expanded(child: _dayCell(context, r * 7 + c, lead, daysInMonth)),
              ],
            ),
            if (r != rows - 1) const SizedBox(height: 6),
          ],
        ]),
      ),
    );
  }

  Widget _dayCell(BuildContext context, int index, int lead, int daysInMonth) {
    final cs = Theme.of(context).colorScheme;
    final dayNum = index - lead + 1;
    if (dayNum < 1 || dayNum > daysInMonth) {
      return const SizedBox(height: 44);
    }
    final day = DateTime(month.year, month.month, dayNum);
    final key = dateKeyOf(day);
    final isSelected = selected.contains(key);
    final isExisting = alreadyScheduled.contains(key);
    final isToday = key == dateKeyOf(DateTime.now());

    Color bg;
    Color fg;
    if (isSelected) {
      bg = cs.primary;
      fg = cs.onPrimary;
    } else if (isExisting) {
      bg = cs.onSurface.withValues(alpha: 0.18);
      fg = cs.onSurface.withValues(alpha: 0.55);
    } else {
      bg = cs.surfaceContainerHigh;
      fg = cs.onSurface;
    }

    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isExisting || onToggle == null ? null : () => onToggle!(day),
          child: SizedBox(
            height: 44,
            child: Stack(children: [
              Center(
                child: Text(
                  '$dayNum',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              if (isToday)
                Positioned(
                  top: 5,
                  right: 5,
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: isSelected ? cs.onPrimary : cs.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
      ),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ]);
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
          height: 280,
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
