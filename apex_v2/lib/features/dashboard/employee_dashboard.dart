import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/calendar_export.dart';
import '../../core/demo_backend.dart';
import '../../core/offline_sync.dart';
import '../../core/shift_time.dart';
import '../notifications/notification_bell.dart';
import '../schedule/calendar_export_sheet.dart';
import '../time_clock/qr_scan_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL'),
    anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'), // ignore: deprecated_member_use — supabase_flutter 2.x
    postgrestOptions: const PostgrestClientOptions(schema: 'public'),
  );
  runApp(const ApexApp());
}

class ApexApp extends StatelessWidget {
  const ApexApp({super.key});

  @override
  Widget build(BuildContext context) {
    const surface = Color(0xFF1A1A24);
    const background = Color(0xFF0A0C10);
    const surfaceHigh = Color(0xFF22222E);
    return MaterialApp(
      title: 'Apex',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          surface: surface,
          primary: Color(0xFF8B5CF6),
          onPrimary: Color(0xFFF5F5F7),
          secondary: Color(0xFF14B8A6),
          onSecondary: Color(0xFFF5F5F7),
          onSurface: Color(0xFFF5F5F7),
          tertiary: Color(0xFF00BFFF),
          surfaceContainer: surface,
          surfaceContainerHigh: surfaceHigh,
        ),
        scaffoldBackgroundColor: background,
        cardTheme: CardThemeData(
          elevation: 0,
          color: surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          margin: EdgeInsets.zero,
        ),
        textTheme: const TextTheme(
          displaySmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
          headlineSmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3),
          titleLarge: TextStyle(fontWeight: FontWeight.w600),
          titleMedium: TextStyle(fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(height: 1.4),
        ),
      ),
      home: const EmployeeDashboard(organizationId: String.fromEnvironment('ORG_ID')),
    );
  }
}

class EmployeeDashboard extends StatefulWidget {
  const EmployeeDashboard({
    super.key,
    required this.organizationId,
    this.onSwapShift,
    this.onRequestTimeOff,
    this.onOpenChat,
    this.onSignOut,
  });

  final String organizationId;
  final VoidCallback? onSwapShift;
  final VoidCallback? onRequestTimeOff;
  final VoidCallback? onOpenChat;
  final VoidCallback? onSignOut;

  @override
  State<EmployeeDashboard> createState() => _EmployeeDashboardState();
}

class _EmployeeDashboardState extends State<EmployeeDashboard> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  bool _clocking = false;
  int _pendingPunches = 0;
  bool _localOnClock = false;

  _ProfileData? _profile;
  _ShiftData? _todayShift;
  _ShiftData? _nextShift;
  String? _activeEntryId;
  _WeekSummary _week = const _WeekSummary(hours: 0, pay: 0, tips: 0);
  _ShiftNoteData? _latestNote;
  List<_ChatPreview> _chatPreview = const [];

  final _subs = <StreamSubscription<dynamic>>[];

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
    for (final table in ['shifts', 'time_entries', 'messages', 'shift_notes']) {
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
      // Kitchen Wi‑Fi often drops mid-shift — push queued punches first.
      await OfflinePunchQueue.flush(_client);
      final pending = await OfflinePunchQueue.pendingCount();
      final localOpen = await OfflinePunchQueue.hasOpenLocalPunch();

      final now = DateTime.now();
      final todayKey = DateFormat('yyyy-MM-dd').format(now);
      final weekStart = now.subtract(Duration(days: now.weekday - 1));
      final weekStartKey = DateFormat('yyyy-MM-dd').format(weekStart);
      final weekEndKey =
          DateFormat('yyyy-MM-dd').format(weekStart.add(const Duration(days: 6)));

      final profileRow = await _client
          .from('profiles')
          .select('name, hourly_rate, organization_id')
          .eq('id', _userId)
          .eq('organization_id', widget.organizationId)
          .single();
      final profile = _ProfileData.fromMap(profileRow);
      final staffName = profile.name;

      final results = await Future.wait<dynamic>([
        _client
            .from('shifts')
            .select()
            .eq('organization_id', widget.organizationId)
            .eq('shift_date', todayKey)
            .eq('staff', staffName)
            .maybeSingle(),
        _client
            .from('shifts')
            .select()
            .eq('organization_id', widget.organizationId)
            .gt('shift_date', todayKey)
            .eq('staff', staffName)
            .order('shift_date')
            .limit(1)
            .maybeSingle(),
        _client
            .from('time_entries')
            .select('id')
            .eq('organization_id', widget.organizationId)
            .eq('user_id', _userId)
            .isFilter('clock_out', null)
            .maybeSingle(),
        _client
            .from('shifts')
            .select('start_time, end_time')
            .eq('organization_id', widget.organizationId)
            .eq('staff', staffName)
            .gte('shift_date', weekStartKey)
            .lte('shift_date', weekEndKey),
        _client
            .from('tip_allocations')
            .select('amount_cents, tip_pools!inner(shift_date, organization_id)')
            .eq('tip_pools.organization_id', widget.organizationId)
            .eq('user_id', _userId)
            .gte('tip_pools.shift_date', weekStartKey)
            .lte('tip_pools.shift_date', weekEndKey),
        _client
            .from('shift_notes')
            .select('note, shift_date, created_at, profiles(name)')
            .eq('organization_id', widget.organizationId)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle(),
        _client
            .from('messages')
            .select('text, created_at, profiles(name)')
            .eq('organization_id', widget.organizationId)
            .order('created_at', ascending: false)
            .limit(2),
      ]);

      if (!mounted) return;

      double weekHours = 0;
      for (final s in (results[3] as List).cast<Map<String, dynamic>>()) {
        weekHours += _hoursBetween(
            s['start_time'] as String?, s['end_time'] as String?);
      }
      final tipsCents = (results[4] as List)
          .cast<Map<String, dynamic>>()
          .fold(0, (sum, r) => sum + (r['amount_cents'] as num? ?? 0).toInt());

      setState(() {
        _profile = profile;
        _todayShift = results[0] == null
            ? null
            : _ShiftData.fromMap(results[0] as Map<String, dynamic>);
        _nextShift = results[1] == null
            ? null
            : _ShiftData.fromMap(results[1] as Map<String, dynamic>);
        _activeEntryId = (results[2] as Map<String, dynamic>?)?['id'] as String?;
        _pendingPunches = pending;
        _localOnClock = localOpen;
        _week = _WeekSummary(
          hours: weekHours,
          pay: weekHours * profile.hourlyRate,
          tips: tipsCents / 100.0,
        );
        _latestNote = results[5] == null
            ? null
            : _ShiftNoteData.fromMap(results[5] as Map<String, dynamic>);
        _chatPreview = (results[6] as List)
            .cast<Map<String, dynamic>>()
            .map(_ChatPreview.fromMap)
            .toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load your dashboard. Pull to retry.';
        });
      }
    }
  }

  Future<void> _clockIn() async {
    if (_clocking || _activeEntryId != null || _localOnClock) return;
    final shift = _todayShift;
    if (shift == null) return;

    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => QrScanScreen(
          organizationId: widget.organizationId,
        ),
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _clocking = true);
    final name = _profile?.name ?? 'Staff';
    final at = DateTime.now().toUtc().toIso8601String();
    try {
      final inserted = await _client.from('time_entries').insert({
        'organization_id': widget.organizationId,
        'user_id': _userId,
        'user_name': name,
        'shift_id': shift.id,
        'clock_in': at,
      }).select('id').single();

      if (!mounted) return;
      setState(() {
        _activeEntryId = inserted['id'] as String;
        _localOnClock = false;
        _clocking = false;
      });
      _snack("You're clocked in. Have a great shift!");
    } catch (e) {
      await OfflinePunchQueue.enqueueClockIn(
        organizationId: widget.organizationId,
        userId: _userId,
        userName: name,
        shiftId: shift.id,
      );
      if (!mounted) return;
      final pending = await OfflinePunchQueue.pendingCount();
      setState(() {
        _localOnClock = true;
        _pendingPunches = pending;
        _clocking = false;
      });
      _snack('Saved offline — will sync when Wi‑Fi is back.');
    }
  }

  Future<void> _clockOut() async {
    if (_clocking) return;
    if (_activeEntryId == null && !_localOnClock) return;

    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => QrScanScreen(
          organizationId: widget.organizationId,
          clockingOut: true,
        ),
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _clocking = true);
    final entryId = _activeEntryId;
    try {
      if (entryId != null) {
        await _client.from('time_entries').update({
          'clock_out': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', entryId);
      } else {
        // Local-only open punch — close it in the queue.
        await OfflinePunchQueue.enqueueClockOut();
      }

      if (!mounted) return;
      setState(() {
        _activeEntryId = null;
        _localOnClock = false;
        _clocking = false;
      });
      _snack('Clocked out. Nice work today.');
      await _load();
    } catch (e) {
      await OfflinePunchQueue.enqueueClockOut(entryId: entryId);
      if (!mounted) return;
      final pending = await OfflinePunchQueue.pendingCount();
      setState(() {
        _activeEntryId = null;
        _localOnClock = false;
        _pendingPunches = pending;
        _clocking = false;
      });
      _snack('Clock-out saved offline — will sync when Wi‑Fi is back.');
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

  Future<void> _exportMyCalendar() async {
    final name = _profile?.name;
    if (name == null || name.isEmpty) {
      _snack('Could not load your name.');
      return;
    }
    try {
      final start = dateKeyOf(DateTime.now());
      final end = dateKeyOf(DateTime.now().add(const Duration(days: 21)));
      final rows = await _client
          .from('shifts')
          .select('staff, shift_date, start_time, end_time')
          .eq('organization_id', widget.organizationId)
          .eq('staff', name)
          .gte('shift_date', start)
          .lte('shift_date', end)
          .order('shift_date');
      final shifts = (rows as List)
          .cast<Map<String, dynamic>>()
          .map(CalendarShift.fromMap)
          .toList();
      if (!mounted) return;
      await showCalendarExportSheet(
        context,
        title: 'My shifts',
        shifts: shifts,
      );
    } catch (_) {
      if (!mounted) return;
      _snack('Could not load shifts for calendar.');
    }
  }

  // ─── Status ──────────────────────────────────────────────────────────────

  _WorkStatus get _status {
    if (_activeEntryId != null || _localOnClock) return _WorkStatus.onTheClock;
    final today = _todayShift;
    if (today == null) return _WorkStatus.offToday;
    final start = _combineDateAndTime(today.shiftDate, today.startTime);
    if (start == null) return _WorkStatus.offToday;
    final now = DateTime.now();
    if (now.isAfter(start)) {
      final end = _combineDateAndTime(today.shiftDate, today.endTime);
      if (end != null && now.isAfter(end)) return _WorkStatus.offToday;
      return _WorkStatus.shiftStarted;
    }
    return _WorkStatus.upcoming;
  }

  String get _statusLine {
    switch (_status) {
      case _WorkStatus.onTheClock:
        return "You're on the clock";
      case _WorkStatus.offToday:
        return "You're off today";
      case _WorkStatus.shiftStarted:
        return 'Your shift started — clock in';
      case _WorkStatus.upcoming:
        final start =
            _combineDateAndTime(_todayShift!.shiftDate, _todayShift!.startTime);
        if (start == null) return 'You have a shift today';
        final diff = start.difference(DateTime.now());
        if (diff.inMinutes < 60) {
          final m = diff.inMinutes.clamp(1, 59);
          return 'You work in $m ${m == 1 ? 'minute' : 'minutes'}';
        }
        final h = diff.inHours;
        final rem = diff.inMinutes % 60;
        if (rem == 0) return 'You work in $h ${h == 1 ? 'hour' : 'hours'}';
        return 'You work in $h hr $rem min';
    }
  }

  bool get _canClockIn {
    if (_activeEntryId != null || _localOnClock) return false;
    final today = _todayShift;
    if (today == null) return false;
    final start = _combineDateAndTime(today.shiftDate, today.startTime);
    if (start == null) return false;
    final now = DateTime.now();
    final end = _combineDateAndTime(today.shiftDate, today.endTime);
    final stillInShift = end == null || now.isBefore(end);
    return now.isAfter(start.subtract(const Duration(minutes: 30))) && stillInShift;
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));

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
                      Row(children: [
                        Expanded(
                          child: Text(
                            'Hey ${_firstName(_profile?.name ?? '')}',
                            style: Theme.of(context).textTheme.displaySmall,
                          ),
                        ),
                        NotificationBell(
                          organizationId: widget.organizationId,
                        ),
                        IconButton(
                          tooltip: 'Add my shifts to calendar',
                          onPressed: _exportMyCalendar,
                          icon: Icon(
                            Icons.event_rounded,
                            color: cs.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                        if (widget.onSignOut != null)
                          IconButton(
                            tooltip: 'Sign out',
                            onPressed: widget.onSignOut,
                            icon: Icon(
                              Icons.logout_rounded,
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Icon(
                          _statusIcon,
                          size: 16,
                          color: _statusColor(cs),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _statusLine,
                          style: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.copyWith(color: cs.onSurface.withValues(alpha: 0.75)),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              sliver: SliverList.list(children: [
                _TodayShiftCard(
                  shift: _todayShift,
                  canClockIn: _canClockIn,
                  isOnClock: _activeEntryId != null || _localOnClock,
                  clocking: _clocking,
                  onClockIn: _clockIn,
                  onClockOut: _clockOut,
                ),
                if (_pendingPunches > 0) ...[
                  const SizedBox(height: 12),
                  _OfflineBanner(pending: _pendingPunches),
                ],
                const SizedBox(height: 12),
                _WeekSummaryCard(summary: _week),
                const SizedBox(height: 12),
                if (_todayShift == null && _nextShift != null)
                  _NextShiftCard(shift: _nextShift!),
                if (_todayShift == null && _nextShift != null)
                  const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.swap_horiz_rounded,
                      label: 'Swap Shift',
                      onTap: widget.onSwapShift ??
                          () => Navigator.pushNamed(context, '/swaps'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.event_busy_rounded,
                      label: 'Request Off',
                      onTap: widget.onRequestTimeOff ??
                          () => Navigator.pushNamed(context, '/time-off'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                if (_latestNote != null)
                  _ShiftNoteCard(note: _latestNote!)
                else
                  const _EmptyCard(
                    icon: Icons.sticky_note_2_outlined,
                    title: 'No shift notes yet',
                    subtitle: 'Handoff notes from the previous crew will appear here.',
                  ),
                const SizedBox(height: 12),
                _ChatCard(messages: _chatPreview, onOpen: widget.onOpenChat),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  IconData get _statusIcon {
    switch (_status) {
      case _WorkStatus.onTheClock:
        return Icons.timer_outlined;
      case _WorkStatus.shiftStarted:
        return Icons.play_circle_outline;
      case _WorkStatus.upcoming:
        return Icons.schedule;
      case _WorkStatus.offToday:
        return Icons.coffee_outlined;
    }
  }

  Color _statusColor(ColorScheme cs) {
    switch (_status) {
      case _WorkStatus.onTheClock:
        return const Color(0xFF4ADE80);
      case _WorkStatus.shiftStarted:
        return cs.primary;
      case _WorkStatus.upcoming:
        return cs.primary;
      case _WorkStatus.offToday:
        return cs.onSurface.withValues(alpha: 0.4);
    }
  }
}

// ─── Pure helpers ────────────────────────────────────────────────────────────

enum _WorkStatus { onTheClock, upcoming, shiftStarted, offToday }

String _firstName(String full) {
  final trimmed = full.trim();
  if (trimmed.isEmpty) return 'there';
  return trimmed.split(RegExp(r'\s+')).first;
}

DateTime? _combineDateAndTime(String dateKey, String? timeRaw) {
  if (timeRaw == null) return null;
  final date = DateTime.tryParse(dateKey);
  if (date == null) return null;
  final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(timeRaw);
  if (m == null) return null;
  return DateTime(date.year, date.month, date.day,
      int.parse(m.group(1)!), int.parse(m.group(2)!));
}

double _hoursBetween(String? start, String? end) {
  final s = _combineDateAndTime('2000-01-01', start);
  var e = _combineDateAndTime('2000-01-01', end);
  if (s == null || e == null) return 0;
  if (!e.isAfter(s)) e = e.add(const Duration(days: 1)); // overnight
  return e.difference(s).inMinutes / 60.0;
}

String _formatTime(String? raw) {
  final dt = _combineDateAndTime('2000-01-01', raw);
  if (dt == null) return raw ?? '';
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:${dt.minute.toString().padLeft(2, '0')} $ampm';
}

String _formatDayLabel(String dateKey) {
  final d = DateTime.tryParse(dateKey);
  if (d == null) return dateKey;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(d.year, d.month, d.day);
  final diff = target.difference(today).inDays;
  if (diff == 1) return 'Tomorrow';
  return DateFormat('EEE, MMM d').format(d);
}

String _relativeTime(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return DateFormat('MMM d').format(t);
}

// ─── Typed models ────────────────────────────────────────────────────────────

class _ProfileData {
  const _ProfileData({
    required this.name,
    required this.hourlyRate,
    required this.organizationId,
  });

  final String name;
  final double hourlyRate;
  final String organizationId;

  factory _ProfileData.fromMap(Map<String, dynamic> m) => _ProfileData(
        name: m['name'] as String? ?? 'there',
        hourlyRate: (m['hourly_rate'] as num?)?.toDouble() ?? 0,
        organizationId: m['organization_id'] as String? ?? '',
      );
}

class _ShiftData {
  const _ShiftData({
    required this.id,
    required this.shiftDate,
    required this.startTime,
    required this.endTime,
    required this.role,
    required this.zone,
  });

  final String id;
  final String shiftDate;
  final String startTime;
  final String endTime;
  final String role;
  final String zone;

  String get timeRange => '${_formatTime(startTime)} – ${_formatTime(endTime)}';

  factory _ShiftData.fromMap(Map<String, dynamic> m) => _ShiftData(
        id: m['id'] as String? ?? '',
        shiftDate: m['shift_date'] as String? ?? '',
        startTime: (m['start_time'] as String?) ?? '00:00',
        endTime: (m['end_time'] as String?) ?? '00:00',
        role: (m['role'] as String?) ?? 'Staff',
        zone: (m['zone'] as String?) ?? '',
      );
}

class _WeekSummary {
  const _WeekSummary({required this.hours, required this.pay, required this.tips});

  final double hours;
  final double pay;
  final double tips;
}

class _ShiftNoteData {
  const _ShiftNoteData({required this.note, required this.shiftDate, required this.author});

  final String note;
  final String shiftDate;
  final String author;

  factory _ShiftNoteData.fromMap(Map<String, dynamic> m) => _ShiftNoteData(
        note: m['note'] as String? ?? '',
        shiftDate: m['shift_date'] as String? ?? '',
        author: (m['profiles'] as Map?)?['name'] as String? ?? 'last shift',
      );
}

class _ChatPreview {
  const _ChatPreview({required this.text, required this.senderName, required this.createdAt});

  final String text;
  final String senderName;
  final DateTime createdAt;

  factory _ChatPreview.fromMap(Map<String, dynamic> m) => _ChatPreview(
        text: m['text'] as String? ?? '',
        senderName: (m['profiles'] as Map?)?['name'] as String? ?? 'Team',
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
      );
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
          _SkeletonBox(width: 160, height: 34, color: cs.surfaceContainerHigh),
          const SizedBox(height: 8),
          _SkeletonBox(width: 220, height: 18, color: cs.surfaceContainerHigh),
          const SizedBox(height: 24),
          _SkeletonBox(width: double.infinity, height: 140, color: cs.surfaceContainerHigh),
          const SizedBox(height: 12),
          _SkeletonBox(width: double.infinity, height: 88, color: cs.surfaceContainerHigh),
        ]),
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({required this.width, required this.height, required this.color});

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
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
          Icon(Icons.wifi_off_rounded, size: 48, color: cs.onSurface.withValues(alpha: 0.5)),
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

class _TodayShiftCard extends StatelessWidget {
  const _TodayShiftCard({
    required this.shift,
    required this.canClockIn,
    required this.isOnClock,
    required this.clocking,
    required this.onClockIn,
    required this.onClockOut,
  });

  final _ShiftData? shift;
  final bool canClockIn;
  final bool isOnClock;
  final bool clocking;
  final VoidCallback onClockIn;
  final VoidCallback onClockOut;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (shift == null) {
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
              child: Icon(Icons.beach_access_rounded, color: cs.primary, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Off today', style: Theme.of(context).textTheme.titleMedium),
                Text('Enjoy the day',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
              ]),
            ),
          ]),
        ),
      );
    }

    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(shift!.timeRange,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(color: cs.onPrimaryContainer)),
            ),
            if (isOnClock)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF4ADE80).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'ON CLOCK',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: Color(0xFF4ADE80),
                  ),
                ),
              ),
            if (!isOnClock && shift!.zone.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: cs.onPrimaryContainer.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(shift!.zone,
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: cs.onPrimaryContainer)),
              ),
          ]),
          if (shift!.role.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(shift!.role,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: cs.onPrimaryContainer.withValues(alpha: 0.75))),
          ],
          if (canClockIn || isOnClock) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  backgroundColor: isOnClock ? cs.onSurface : cs.primary,
                ),
                onPressed: clocking ? null : (isOnClock ? onClockOut : onClockIn),
                icon: clocking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : Icon(isOnClock
                        ? Icons.qr_code_scanner_rounded
                        : Icons.qr_code_scanner_rounded),
                label: Text(
                  isOnClock ? 'Scan to Clock Out' : 'Scan to Clock In',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.pending});

  final int pending;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFBBF24).withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const Icon(Icons.cloud_off_rounded, color: Color(0xFFFBBF24), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              pending == 1
                  ? 'Offline — 1 punch waiting to sync'
                  : 'Offline — $pending punches waiting to sync',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
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
            label: 'Hours',
            value: summary.hours.toStringAsFixed(
                summary.hours == summary.hours.roundToDouble() ? 0 : 1),
          ),
          _VertDivider(color: cs.outlineVariant),
          _WeekMetric(label: 'Est. pay', value: '\$${summary.pay.toStringAsFixed(0)}'),
          _VertDivider(color: cs.outlineVariant),
          _WeekMetric(label: 'Tips', value: '\$${summary.tips.toStringAsFixed(0)}'),
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
        Text(label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurface.withValues(alpha: 0.55))),
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

class _NextShiftCard extends StatelessWidget {
  const _NextShiftCard({required this.shift});

  final _ShiftData shift;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final date = DateTime.tryParse(shift.shiftDate);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(children: [
              if (date != null)
                Text(DateFormat('EEE').format(date).toUpperCase(),
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
              if (date != null)
                Text('${date.day}', style: Theme.of(context).textTheme.titleMedium),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Next shift · ${_formatDayLabel(shift.shiftDate)}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurface.withValues(alpha: 0.55))),
              Text(shift.timeRange, style: Theme.of(context).textTheme.titleMedium),
              if (shift.role.isNotEmpty)
                Text('${shift.role}${shift.zone.isNotEmpty ? ' · ${shift.zone}' : ''}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurface.withValues(alpha: 0.45))),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.onTap});

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

class _ShiftNoteCard extends StatelessWidget {
  const _ShiftNoteCard({required this.note});

  final _ShiftNoteData note;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.sticky_note_2_rounded, color: cs.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('From ${note.author} · ${_formatDayLabel(note.shiftDate)}',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: cs.onSurface.withValues(alpha: 0.55))),
              const SizedBox(height: 4),
              Text(note.note, style: Theme.of(context).textTheme.bodyLarge),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ChatCard extends StatelessWidget {
  const _ChatCard({required this.messages, this.onOpen});

  final List<_ChatPreview> messages;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (messages.isEmpty) {
      return const _EmptyCard(
        icon: Icons.chat_bubble_outline_rounded,
        title: 'No messages yet',
        subtitle: 'Team chat will appear here.',
      );
    }
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.chat_bubble_outline_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text('Team chat', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              if (onOpen != null)
                Icon(Icons.chevron_right, size: 18, color: cs.onSurface.withValues(alpha: 0.4)),
            ]),
            const SizedBox(height: 12),
            for (final m in messages) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: cs.surfaceContainerHigh,
                  child: Text(
                    m.senderName.isNotEmpty
                        ? m.senderName[0].toUpperCase()
                        : '?',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(m.senderName,
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(color: cs.primary.withValues(alpha: 0.9))),
                      const SizedBox(width: 8),
                      Text(_relativeTime(m.createdAt),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onSurface.withValues(alpha: 0.45))),
                    ]),
                    Text(m.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium),
                  ]),
                ),
              ]),
              if (m != messages.last) const SizedBox(height: 12),
            ],
          ]),
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.icon, required this.title, required this.subtitle});

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
            child: Icon(icon, color: cs.onSurface.withValues(alpha: 0.5), size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(subtitle,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurface.withValues(alpha: 0.5))),
            ]),
          ),
        ]),
      ),
    );
  }
}