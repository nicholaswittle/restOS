import 'package:apex_v2/core/demo_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:supabase/supabase.dart';

/// Exercises every query the shipped screens make against [DemoHttpClient].
///
/// The demo has now broken twice in ways that only showed up as a caught
/// "could not load" in the UI, with the real exception swallowed. These tests
/// run the same queries where the failure is visible.
void main() {
  late SupabaseClient client;

  setUp(() {
    client = SupabaseClient(
      'https://demo.invalid',
      'demo',
      httpClient: DemoHttpClient(),
    );
  });

  final now = DateTime.now();
  final todayKey = DateFormat('yyyy-MM-dd').format(now);
  final weekStart = now.subtract(Duration(days: now.weekday - 1));
  final weekStartKey = DateFormat('yyyy-MM-dd').format(weekStart);
  final weekEndKey =
      DateFormat('yyyy-MM-dd').format(weekStart.add(const Duration(days: 6)));
  const org = DemoMode.organizationId;

  /// What the screens *actually* send. Every one reads identity as
  /// `auth.currentUser?.id ?? ''`, and demo mode has no session — so the empty
  /// string is the real condition. An earlier version of this file passed
  /// [DemoMode.userId] here and passed while the app was broken, because it was
  /// testing a state the app never reaches.
  const uid = '';

  test('shell resolves the venue and its entitlements', () async {
    final row = await client
        .from('organizations')
        .select('tier, enabled_modules, disabled_modules')
        .maybeSingle();
    expect(row, isNotNull);
    expect(row!['tier'], 'os');
  });

  test('dashboard: profile resolves via single()', () async {
    final row = await client
        .from('profiles')
        .select('name, hourly_rate, organization_id')
        .eq('id', uid)
        .eq('organization_id', org)
        .single();
    expect(row['name'], isNotEmpty);
  });

  test('dashboard: every parallel query succeeds', () async {
    const staffName = 'Alex Rivera';
    final results = await Future.wait<dynamic>([
      client
          .from('shifts')
          .select()
          .eq('organization_id', org)
          .eq('shift_date', todayKey)
          .eq('staff', staffName)
          .maybeSingle(),
      client
          .from('shifts')
          .select()
          .eq('organization_id', org)
          .gt('shift_date', todayKey)
          .eq('staff', staffName)
          .order('shift_date')
          .limit(1)
          .maybeSingle(),
      client
          .from('time_entries')
          .select('id')
          .eq('organization_id', org)
          .eq('user_id', uid)
          .isFilter('clock_out', null)
          .maybeSingle(),
      client
          .from('shifts')
          .select('start_time, end_time')
          .eq('organization_id', org)
          .eq('staff', staffName)
          .gte('shift_date', weekStartKey)
          .lte('shift_date', weekEndKey),
      client
          .from('tip_allocations')
          .select('amount_cents, tip_pools!inner(shift_date, organization_id)')
          .eq('tip_pools.organization_id', org)
          .eq('user_id', uid)
          .gte('tip_pools.shift_date', weekStartKey)
          .lte('tip_pools.shift_date', weekEndKey),
      client
          .from('shift_notes')
          .select('note, shift_date, created_at, profiles(name)')
          .eq('organization_id', org)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle(),
      client
          .from('messages')
          .select('text, created_at, profiles(name)')
          .eq('organization_id', org)
          .order('created_at', ascending: false)
          .limit(2),
    ]);

    // Today's shift must be *this* user's, not whichever row came first.
    expect(results[0], isNotNull);
    expect((results[0] as Map)['staff'], staffName);
    expect((results[0] as Map)['shift_date'], todayKey);

    // Next shift is strictly after today, and is the soonest one.
    final nextDate = (results[1] as Map?)?['shift_date'] as String?;
    expect(nextDate, isNotNull);
    expect(nextDate!.compareTo(todayKey), greaterThan(0));

    // Alex has no open punch — the open one belongs to Sam Chen.
    expect(results[2], isNull);

    expect(results[3], isA<List>());
    expect(results[4], isA<List>());
    expect(results[6], isA<List>());
  });

  test('empty user id resolves to the demo user, not to nothing', () async {
    // Regression: with real filtering, `id=eq.` matched zero rows and every
    // screen's opening single() threw. Demo mode has no session, so this is the
    // only identity the app ever sends.
    final row = await client
        .from('profiles')
        .select('id, name')
        .eq('id', '')
        .single();
    expect(row['id'], DemoMode.userId);
    expect(row['name'], 'Alex Rivera');

    final mine = await client
        .from('tip_allocations')
        .select('user_id, amount_cents')
        .eq('user_id', '') as List;
    expect(mine, isNotEmpty);
    expect(mine.every((r) => r['user_id'] == DemoMode.userId), isTrue);
  });

  test('filters actually narrow: shifts by staff and date', () async {
    final all = await client.from('shifts').select().eq('organization_id', org);
    final mine = await client
        .from('shifts')
        .select()
        .eq('organization_id', org)
        .eq('staff', 'Alex Rivera');
    expect((all as List).length, greaterThan((mine as List).length));
    expect(mine.every((r) => r['staff'] == 'Alex Rivera'), isTrue);
  });

  test('is.null selects only the open punch', () async {
    final open = await client
        .from('time_entries')
        .select()
        .eq('organization_id', org)
        .isFilter('clock_out', null) as List;
    expect(open, hasLength(1));
    expect(open.single['user_id'], 'demo-user-0002');
  });

  test('order + limit returns the newest note', () async {
    final row = await client
        .from('shift_notes')
        .select('note, created_at, profiles(name)')
        .eq('organization_id', org)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    expect(row, isNotNull);
    expect((row!['profiles'] as Map)['name'], 'Jordan Blake');
  });

  test('log book, tips and labor cost queries all resolve', () async {
    await client
        .from('shift_notes')
        .select('id, note, shift_date, created_at, profiles(name)')
        .eq('organization_id', org)
        .order('created_at', ascending: false);
    await client
        .from('tip_pools')
        .select()
        .eq('organization_id', org)
        .eq('shift_date', todayKey)
        .maybeSingle();
    await client
        .from('profiles')
        .select('id, name, hourly_rate')
        .eq('organization_id', org);
    await client
        .from('time_entries')
        .select('user_id, clock_in, clock_out')
        .eq('organization_id', org);
  });

  test('schedule: week-range filter returns only in-range shifts', () async {
    final week = await client
        .from('shifts')
        .select()
        .eq('organization_id', org)
        .gte('shift_date', weekStartKey)
        .lte('shift_date', weekEndKey)
        .order('shift_date')
        .order('start_time') as List;

    expect(week, isNotEmpty);
    for (final row in week) {
      final d = row['shift_date'] as String;
      expect(d.compareTo(weekStartKey), greaterThanOrEqualTo(0));
      expect(d.compareTo(weekEndKey), lessThanOrEqualTo(0));
    }

    final all = await client.from('shifts').select().eq('organization_id', org);
    // Seed spans days outside a single Mon–Sun window depending on "today",
    // but the week filter must never return *more* rows than the unfiltered set.
    expect(week.length, lessThanOrEqualTo((all as List).length));
  });

  test('schedule: day filter is narrower than the week', () async {
    final week = await client
        .from('shifts')
        .select()
        .eq('organization_id', org)
        .gte('shift_date', weekStartKey)
        .lte('shift_date', weekEndKey) as List;
    final day = await client
        .from('shifts')
        .select()
        .eq('organization_id', org)
        .eq('shift_date', todayKey) as List;

    expect(day, isNotEmpty);
    expect(day.every((r) => r['shift_date'] == todayKey), isTrue);
    expect(day.length, lessThan(week.length));
  });

  test('schedule: profile for highlight resolves', () async {
    final row = await client
        .from('profiles')
        .select('name')
        .eq('id', uid)
        .eq('organization_id', org)
        .maybeSingle();
    expect(row, isNotNull);
    expect(row!['name'], 'Alex Rivera');
  });

  test('chat: messages are org-scoped and ordered', () async {
    final rows = await client
        .from('messages')
        .select('text, created_at, profiles(name)')
        .eq('organization_id', org)
        .order('created_at', ascending: true)
        .limit(100) as List;
    expect(rows.length, greaterThanOrEqualTo(2));
    for (var i = 1; i < rows.length; i++) {
      final prev = rows[i - 1]['created_at'] as String;
      final cur = rows[i]['created_at'] as String;
      expect(cur.compareTo(prev), greaterThanOrEqualTo(0));
    }
  });

  test('swaps: available filter is narrower than all', () async {
    final all =
        await client.from('swaps').select().eq('organization_id', org) as List;
    final open = await client
        .from('swaps')
        .select()
        .eq('organization_id', org)
        .eq('status', 'Available') as List;
    expect(all, isNotEmpty);
    expect(open, isNotEmpty);
    expect(open.length, lessThan(all.length));
    expect(open.every((r) => r['status'] == 'Available'), isTrue);
  });

  test('time off: pending filter narrows', () async {
    final all = await client
        .from('time_off_requests')
        .select()
        .eq('organization_id', org) as List;
    final pending = await client
        .from('time_off_requests')
        .select()
        .eq('organization_id', org)
        .eq('status', 'Pending') as List;
    expect(all.length, greaterThan(pending.length));
    expect(pending.every((r) => r['status'] == 'Pending'), isTrue);
  });

  test('empty id equals the seeded demo user', () async {
    final blank = await client
        .from('profiles')
        .select('id, name')
        .eq('id', '')
        .eq('organization_id', org)
        .single();
    expect(blank['id'], DemoMode.userId);
  });

  test('sidework: day filter returns only that date', () async {
    final today = DateTime.now();
    final key =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final rows = await client
        .from('sidework')
        .select('task, assigned_to, task_date')
        .eq('organization_id', org)
        .eq('task_date', key) as List;
    expect(rows, isNotEmpty);
    expect(rows.every((r) => r['task_date'] == key), isTrue);
  });

  test('organization_invites: unused codes exist for managers', () async {
    final rows = await client
        .from('organization_invites')
        .select('code, used_at')
        .eq('organization_id', org) as List;
    expect(rows, isNotEmpty);
    expect(rows.any((r) => r['used_at'] == null), isTrue);
  });

  test('notifications: unread filter narrows', () async {
    final all = await client
        .from('notifications')
        .select()
        .eq('user_id', DemoMode.userId) as List;
    final unread = await client
        .from('notifications')
        .select()
        .eq('user_id', DemoMode.userId)
        .isFilter('read_at', null) as List;
    expect(all, isNotEmpty);
    expect(unread, isNotEmpty);
    expect(unread.length, lessThanOrEqualTo(all.length));
    expect(unread.every((r) => r['read_at'] == null), isTrue);
  });
}
