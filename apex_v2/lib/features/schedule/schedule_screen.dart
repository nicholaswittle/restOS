import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/calendar_export.dart';
import '../../core/demo_backend.dart';
import '../../core/entitlements.dart';
import '../../core/shift_time.dart';
import 'assign_days_screen.dart';
import 'calendar_export_sheet.dart';
import 'photo_import_screen.dart';

/// Week calendar for the venue.
///
/// Everyone sees the full crew (you need to know who you are working with).
/// The signed-in user's rows are emphasized so an employee finds themselves
/// in under a second. Managers can add and remove shifts here.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({
    super.key,
    required this.organizationId,
    this.role,
  });

  final String organizationId;
  final StaffRole? role;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  bool _busy = false;

  late DateTime _weekStart;
  String? _myName;
  List<_ShiftRow> _shifts = const [];
  List<String> _staffNames = const [];

  final _subs = <StreamSubscription<dynamic>>[];

  /// Demo has no auth session; fall back to the seeded stand-in user.
  String get _userId => DemoMode.enabled
      ? DemoMode.userId
      : (_client.auth.currentUser?.id ?? '');

  bool get _canManage => widget.role?.canManage ?? false;

  DateTime get _weekEnd => _weekStart.add(const Duration(days: 6));

  @override
  void initState() {
    super.initState();
    _weekStart = _mondayOf(DateTime.now());
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
          .from('shifts')
          .stream(primaryKey: ['id'])
          .eq('organization_id', widget.organizationId)
          .listen((_) => _load(quiet: true)),
    );
  }

  static DateTime _mondayOf(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    return day.subtract(Duration(days: day.weekday - 1));
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
      final startKey = dateKeyOf(_weekStart);
      final endKey = dateKeyOf(_weekEnd);

      final results = await Future.wait<dynamic>([
        _client
            .from('profiles')
            .select('name')
            .eq('id', _userId)
            .eq('organization_id', widget.organizationId)
            .maybeSingle(),
        _client
            .from('shifts')
            .select(
              'id, organization_id, shift_date, staff, start_time, end_time, role, zone',
            )
            .eq('organization_id', widget.organizationId)
            .gte('shift_date', startKey)
            .lte('shift_date', endKey)
            .order('shift_date')
            .order('start_time'),
        _client
            .from('profiles')
            .select('name')
            .eq('organization_id', widget.organizationId)
            .order('name'),
      ]);

      if (!mounted) return;

      final profile = results[0] as Map<String, dynamic>?;
      final shifts = (results[1] as List)
          .cast<Map<String, dynamic>>()
          .map(_ShiftRow.fromMap)
          .toList();
      final staff = (results[2] as List)
          .cast<Map<String, dynamic>>()
          .map((r) => r['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();

      setState(() {
        _myName = profile?['name'] as String?;
        _shifts = shifts;
        _staffNames = staff;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the schedule. Pull to retry.';
      });
    }
  }

  void _shiftWeek(int delta) {
    setState(() {
      _weekStart = _weekStart.add(Duration(days: 7 * delta));
    });
    _load();
  }

  void _thisWeek() {
    final monday = _mondayOf(DateTime.now());
    if (monday == _weekStart) return;
    setState(() => _weekStart = monday);
    _load();
  }

  double get _weekHours => _shifts.fold<double>(
        0,
        (sum, s) => sum + hoursBetween(s.startTime, s.endTime),
      );

  Map<String, List<_ShiftRow>> get _byDay {
    final map = <String, List<_ShiftRow>>{};
    for (final s in _shifts) {
      map.putIfAbsent(s.shiftDate, () => []).add(s);
    }
    return map;
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _deleteShift(_ShiftRow shift) async {
    if (!_canManage || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove shift?'),
        content: Text('${shift.staff} · ${formatDayLabel(shift.shiftDate)}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await _client
          .from('shifts')
          .delete()
          .eq('id', shift.id)
          .eq('organization_id', widget.organizationId);
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Shift removed.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not remove shift.');
    }
  }

  Future<void> _exportWeekCalendar() async {
    final shifts = [
      for (final s in _shifts)
        CalendarShift(
          staff: s.staff,
          shiftDate: s.shiftDate,
          startTime: s.startTime,
          endTime: s.endTime,
        ),
    ];
    if (!mounted) return;
    await showCalendarExportSheet(
      context,
      title: 'Week schedule',
      shifts: shifts,
    );
  }

  Future<void> _openAssignDays() async {
    if (!_canManage) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AssignDaysScreen(
          organizationId: widget.organizationId,
        ),
      ),
    );
    if (!mounted) return;
    await _load(quiet: true);
  }

  Future<void> _openPhotoImport() async {
    if (!_canManage) return;
    final published = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PhotoImportScreen(
          organizationId: widget.organizationId,
        ),
      ),
    );
    if (!mounted) return;
    if (published == true) await _load(quiet: true);
  }

  Future<void> _openAddSheet({String? dateKey}) async {
    if (!_canManage) return;
    final staff = _staffNames.isEmpty
        ? <String>[_myName ?? 'Open']
        : _staffNames;
    var selectedStaff = staff.first;
    var selectedDate = dateKey != null
        ? (DateTime.tryParse(dateKey) ?? DateTime.now())
        : DateTime.now();
    final startCtrl = TextEditingController(text: '16:00');
    final endCtrl = TextEditingController(text: '22:00');
    final roleCtrl = TextEditingController(text: 'Server');
    final zoneCtrl = TextEditingController(text: 'Front');

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final cs = Theme.of(ctx).colorScheme;
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                bottom: MediaQuery.viewInsetsOf(ctx).bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Add shift',
                      style: Theme.of(ctx).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey(selectedStaff),
                    initialValue: selectedStaff,
                    items: [
                      for (final n in staff)
                        DropdownMenuItem(value: n, child: Text(n)),
                      const DropdownMenuItem(
                          value: 'Open', child: Text('Open')),
                    ],
                    onChanged: (v) =>
                        setLocal(() => selectedStaff = v ?? selectedStaff),
                    decoration: const InputDecoration(labelText: 'Staff'),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Date'),
                    subtitle: Text(formatDayLabel(dateKeyOf(selectedDate))),
                    trailing: const Icon(Icons.calendar_today_rounded),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: selectedDate,
                        firstDate: DateTime.now()
                            .subtract(const Duration(days: 7)),
                        lastDate:
                            DateTime.now().add(const Duration(days: 90)),
                      );
                      if (picked != null) {
                        setLocal(() => selectedDate = picked);
                      }
                    },
                  ),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: startCtrl,
                        decoration:
                            const InputDecoration(labelText: 'Start (HH:MM)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: endCtrl,
                        decoration:
                            const InputDecoration(labelText: 'End (HH:MM)'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  TextField(
                    controller: roleCtrl,
                    decoration: const InputDecoration(labelText: 'Role'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: zoneCtrl,
                    decoration: const InputDecoration(labelText: 'Zone'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            Navigator.pop(ctx);
                            await _createShift(
                              staff: selectedStaff,
                              date: selectedDate,
                              start: startCtrl.text.trim(),
                              end: endCtrl.text.trim(),
                              role: roleCtrl.text.trim(),
                              zone: zoneCtrl.text.trim(),
                            );
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Save shift'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    startCtrl.dispose();
    endCtrl.dispose();
    roleCtrl.dispose();
    zoneCtrl.dispose();
  }

  Future<void> _createShift({
    required String staff,
    required DateTime date,
    required String start,
    required String end,
    required String role,
    required String zone,
  }) async {
    if (_busy) return;
    if (hoursBetween(start, end) <= 0) {
      _snack('Check start and end times (use HH:MM).');
      return;
    }
    setState(() => _busy = true);
    try {
      await _client.from('shifts').insert({
        'organization_id': widget.organizationId,
        'shift_date': dateKeyOf(date),
        'staff': staff,
        'start_time': start,
        'end_time': end,
        'role': role,
        'zone': zone,
        'title': role.isEmpty ? 'Shift' : role,
        'day_num': date.day,
      });
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Shift added.');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not add shift.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final cs = Theme.of(context).colorScheme;
    final byDay = _byDay;
    final isThisWeek = _weekStart == _mondayOf(DateTime.now());

    return Scaffold(
      floatingActionButton: _canManage
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'import',
                  onPressed: _busy ? null : _openPhotoImport,
                  icon: const Icon(Icons.photo_camera_rounded),
                  label: const Text('Import photo'),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'assign',
                  onPressed: _busy ? null : _openAssignDays,
                  icon: const Icon(Icons.calendar_month_rounded),
                  label: const Text('Assign days'),
                ),
              ],
            )
          : null,
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
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        IconButton(
                          tooltip: 'Back',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Schedule',
                                style: Theme.of(context).textTheme.displaySmall,
                              ),
                              Text(
                                _canManage
                                    ? 'Full crew · Assign days to publish'
                                    : 'Your shifts are highlighted',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: cs.onSurface.withValues(alpha: 0.55),
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(children: [
                          IconButton(
                            tooltip: 'Previous week',
                            onPressed: () => _shiftWeek(-1),
                            icon: const Icon(Icons.chevron_left_rounded),
                          ),
                          Expanded(
                            child: Column(children: [
                              Text(
                                '${formatDayLabel(dateKeyOf(_weekStart))} – ${formatDayLabel(dateKeyOf(_weekEnd))}',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                '${formatHours(_weekHours)}h scheduled',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: cs.onSurface.withValues(alpha: 0.55),
                                    ),
                              ),
                            ]),
                          ),
                          IconButton(
                            tooltip: 'Next week',
                            onPressed: () => _shiftWeek(1),
                            icon: const Icon(Icons.chevron_right_rounded),
                          ),
                          IconButton(
                            tooltip: 'Add week to calendar',
                            onPressed: _shifts.isEmpty ? null : _exportWeekCalendar,
                            icon: const Icon(Icons.event_available_rounded),
                          ),
                        ]),
                      ),
                      if (!isThisWeek)
                        Center(
                          child: TextButton(
                            onPressed: _thisWeek,
                            child: const Text('This week'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
              sliver: SliverList.list(children: [
                for (var i = 0; i < 7; i++) ...[
                  _DaySection(
                    dateKey: dateKeyOf(_weekStart.add(Duration(days: i))),
                    shifts: byDay[dateKeyOf(_weekStart.add(Duration(days: i)))] ??
                        const [],
                    myName: _myName,
                    canManage: _canManage,
                    onAdd: _canManage
                        ? () => _openAddSheet(
                              dateKey: dateKeyOf(
                                  _weekStart.add(Duration(days: i))),
                            )
                        : null,
                    onDelete: _canManage ? _deleteShift : null,
                  ),
                  if (i != 6) const SizedBox(height: 12),
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

class _ShiftRow {
  const _ShiftRow({
    required this.id,
    required this.shiftDate,
    required this.staff,
    required this.startTime,
    required this.endTime,
    required this.role,
    required this.zone,
  });

  final String id;
  final String shiftDate;
  final String staff;
  final String startTime;
  final String endTime;
  final String role;
  final String zone;

  String get timeRange =>
      '${formatTime(startTime)} – ${formatTime(endTime)}';

  factory _ShiftRow.fromMap(Map<String, dynamic> m) => _ShiftRow(
        id: m['id'] as String? ?? '',
        shiftDate: m['shift_date'] as String? ?? '',
        staff: m['staff'] as String? ?? '',
        startTime: m['start_time'] as String? ?? '00:00',
        endTime: m['end_time'] as String? ?? '00:00',
        role: m['role'] as String? ?? '',
        zone: m['zone'] as String? ?? '',
      );
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
          _SkeletonBox(width: 160, height: 34, color: cs.surfaceContainerHigh),
          const SizedBox(height: 8),
          _SkeletonBox(width: 220, height: 18, color: cs.surfaceContainerHigh),
          const SizedBox(height: 24),
          _SkeletonBox(
              width: double.infinity, height: 100, color: cs.surfaceContainerHigh),
          const SizedBox(height: 12),
          _SkeletonBox(
              width: double.infinity, height: 100, color: cs.surfaceContainerHigh),
          const SizedBox(height: 12),
          _SkeletonBox(
              width: double.infinity, height: 100, color: cs.surfaceContainerHigh),
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

class _DaySection extends StatelessWidget {
  const _DaySection({
    required this.dateKey,
    required this.shifts,
    required this.myName,
    this.canManage = false,
    this.onAdd,
    this.onDelete,
  });

  final String dateKey;
  final List<_ShiftRow> shifts;
  final String? myName;
  final bool canManage;
  final VoidCallback? onAdd;
  final void Function(_ShiftRow shift)? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final todayKey = dateKeyOf(DateTime.now());
    final isToday = dateKey == todayKey;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(children: [
            Text(
              formatDayLabel(dateKey),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: isToday ? cs.primary : null,
                  ),
            ),
            if (isToday) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'TODAY',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                ),
              ),
            ],
            const Spacer(),
            if (onAdd != null)
              IconButton(
                tooltip: 'Add shift',
                onPressed: onAdd,
                icon: Icon(Icons.add_circle_outline, color: cs.primary, size: 22),
              ),
          ]),
        ),
        if (shifts.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Text(
                'No one scheduled',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.45),
                    ),
              ),
            ),
          )
        else
          for (var i = 0; i < shifts.length; i++) ...[
            _ShiftTile(
              shift: shifts[i],
              isMine: myName != null &&
                  shifts[i].staff.trim().toLowerCase() ==
                      myName!.trim().toLowerCase(),
              onDelete: canManage && onDelete != null
                  ? () => onDelete!(shifts[i])
                  : null,
            ),
            if (i != shifts.length - 1) const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _ShiftTile extends StatelessWidget {
  const _ShiftTile({
    required this.shift,
    required this.isMine,
    this.onDelete,
  });

  final _ShiftRow shift;
  final bool isMine;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: isMine ? cs.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Container(
            width: 4,
            height: 44,
            decoration: BoxDecoration(
              color: isMine
                  ? cs.primary
                  : cs.onSurface.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      shift.staff,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: isMine ? cs.onPrimaryContainer : null,
                          ),
                    ),
                  ),
                  if (isMine)
                    Text(
                      'YOU',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: cs.primary,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                    ),
                ]),
                const SizedBox(height: 2),
                Text(
                  shift.timeRange,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isMine
                            ? cs.onPrimaryContainer.withValues(alpha: 0.85)
                            : cs.onSurface.withValues(alpha: 0.8),
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (shift.role.isNotEmpty) shift.role,
                    if (shift.zone.isNotEmpty) shift.zone,
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isMine
                            ? cs.onPrimaryContainer.withValues(alpha: 0.6)
                            : cs.onSurface.withValues(alpha: 0.5),
                      ),
                ),
              ],
            ),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: 'Remove',
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline_rounded,
                  color: cs.onSurface.withValues(alpha: 0.45)),
            ),
        ]),
      ),
    );
  }
}
