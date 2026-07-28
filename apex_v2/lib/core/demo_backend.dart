import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

/// Demo mode — runs the real screens against seeded data, with no database.
///
/// Enabled with `--dart-define=DEMO=true`. Rather than adding demo branches to
/// every feature screen, this intercepts at the HTTP layer: the screens make
/// their normal PostgREST calls and [DemoHttpClient] answers them. Feature code
/// is untouched and behaves in demo exactly as it does in production, which is
/// what makes this worth showing to anyone.
class DemoMode {
  static const enabled = bool.fromEnvironment('DEMO');

  /// Stand-in signed-in user. Matches a seeded profile so "you" resolve.
  static const userId = 'demo-user-0001';
  static const organizationId = 'demo-org-0001';
}

String _key(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
String _iso(DateTime d) => d.toUtc().toIso8601String();

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);
DateTime _at(int daysFromToday, int hour, [int minute = 0]) =>
    _today.add(Duration(days: daysFromToday)).add(Duration(hours: hour, minutes: minute));

/// The seeded venue: a handful of staff, a week of shifts, punches, tips, notes.
class DemoSeed {
  static const orgName = 'The Alder House';

  static const staff = <Map<String, dynamic>>[
    {
      'id': DemoMode.userId,
      'name': 'Alex Rivera',
      'role': 'Owner',
      'hourly_rate': 21.0,
      'organization_id': DemoMode.organizationId,
      'phone': '+15555550101',
      'push_token': null,
      // Demo walkthrough opens the fleet console without a live session.
      'is_super_admin': true,
      'email': 'alex@alder.demo',
    },
    {
      'id': 'demo-user-0002',
      'name': 'Sam Chen',
      'role': 'Server',
      'hourly_rate': 16.5,
      'organization_id': DemoMode.organizationId,
      'is_super_admin': false,
      'email': 'sam@alder.demo',
    },
    {
      'id': 'demo-user-0003',
      'name': 'Jordan Blake',
      'role': 'Kitchen',
      'hourly_rate': 19.0,
      'organization_id': DemoMode.organizationId,
      'is_super_admin': false,
      'email': 'jordan@alder.demo',
    },
    {
      'id': 'demo-user-0004',
      'name': 'Priya Nair',
      'role': 'Server',
      'hourly_rate': 16.5,
      'organization_id': DemoMode.organizationId,
      'is_super_admin': false,
      'email': 'priya@alder.demo',
    },
  ];

  static final organization = <String, dynamic>{
    'id': DemoMode.organizationId,
    'name': orgName,
    // OS tier so every module is visible in the demo.
    'tier': 'os',
    'enabled_modules': <String>[],
    'disabled_modules': <String>[],
  };

  /// A shift today for the demo user, plus the rest of the crew across the week
  /// so the schedule screen is not mostly empty days.
  static final shifts = <Map<String, dynamic>>[
    {
      'id': 'demo-shift-today',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today),
      'staff': 'Alex Rivera',
      'start_time': '16:00',
      'end_time': '22:00',
      'role': 'Floor Manager',
      'zone': 'Front',
    },
    {
      'id': 'demo-shift-today-2',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today),
      'staff': 'Sam Chen',
      'start_time': '16:00',
      'end_time': '22:00',
      'role': 'Server',
      'zone': 'Patio',
    },
    {
      'id': 'demo-shift-today-3',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today),
      'staff': 'Jordan Blake',
      'start_time': '15:00',
      'end_time': '23:00',
      'role': 'Line Cook',
      'zone': 'Kitchen',
    },
    {
      'id': 'demo-shift-today-4',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today),
      'staff': 'Priya Nair',
      'start_time': '17:00',
      'end_time': '23:00',
      'role': 'Server',
      'zone': 'Bar',
    },
    {
      'id': 'demo-shift-y1',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.subtract(const Duration(days: 1))),
      'staff': 'Alex Rivera',
      'start_time': '16:00',
      'end_time': '22:00',
      'role': 'Floor Manager',
      'zone': 'Front',
    },
    {
      'id': 'demo-shift-y2',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.subtract(const Duration(days: 1))),
      'staff': 'Priya Nair',
      'start_time': '17:00',
      'end_time': '23:00',
      'role': 'Server',
      'zone': 'Bar',
    },
    {
      'id': 'demo-shift-y3',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.subtract(const Duration(days: 1))),
      'staff': 'Jordan Blake',
      'start_time': '14:00',
      'end_time': '22:00',
      'role': 'Line Cook',
      'zone': 'Kitchen',
    },
    {
      'id': 'demo-shift-t1',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 1))),
      'staff': 'Sam Chen',
      'start_time': '11:00',
      'end_time': '19:00',
      'role': 'Server',
      'zone': 'Patio',
    },
    {
      'id': 'demo-shift-t2',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 1))),
      'staff': 'Priya Nair',
      'start_time': '11:00',
      'end_time': '19:00',
      'role': 'Server',
      'zone': 'Front',
    },
    {
      'id': 'demo-shift-next',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 2))),
      'staff': 'Alex Rivera',
      'start_time': '11:00',
      'end_time': '19:00',
      'role': 'Floor Manager',
      'zone': 'Front',
    },
    {
      'id': 'demo-shift-d2b',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 2))),
      'staff': 'Jordan Blake',
      'start_time': '10:00',
      'end_time': '18:00',
      'role': 'Line Cook',
      'zone': 'Kitchen',
    },
    {
      'id': 'demo-shift-d3',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 3))),
      'staff': 'Alex Rivera',
      'start_time': '16:00',
      'end_time': '22:00',
      'role': 'Floor Manager',
      'zone': 'Front',
    },
    {
      'id': 'demo-shift-d3b',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 3))),
      'staff': 'Sam Chen',
      'start_time': '16:00',
      'end_time': '22:00',
      'role': 'Server',
      'zone': 'Patio',
    },
    {
      'id': 'demo-shift-d4',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 4))),
      'staff': 'Priya Nair',
      'start_time': '17:00',
      'end_time': '23:00',
      'role': 'Server',
      'zone': 'Bar',
    },
    {
      'id': 'demo-shift-d4b',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 4))),
      'staff': 'Jordan Blake',
      'start_time': '15:00',
      'end_time': '23:00',
      'role': 'Line Cook',
      'zone': 'Kitchen',
    },
    {
      'id': 'demo-shift-d5',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 5))),
      'staff': 'Alex Rivera',
      'start_time': '12:00',
      'end_time': '20:00',
      'role': 'Floor Manager',
      'zone': 'Front',
    },
    {
      'id': 'demo-shift-d5b',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 5))),
      'staff': 'Sam Chen',
      'start_time': '12:00',
      'end_time': '20:00',
      'role': 'Server',
      'zone': 'Patio',
    },
    {
      'id': 'demo-shift-d5c',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.add(const Duration(days: 5))),
      'staff': 'Priya Nair',
      'start_time': '12:00',
      'end_time': '20:00',
      'role': 'Server',
      'zone': 'Front',
    },
  ];

  /// Yesterday's completed punches (so tips have hours to split) plus one open
  /// punch today — which is exactly the case the tip screen warns about.
  static final timeEntries = <Map<String, dynamic>>[
    {
      'id': 'demo-te-1',
      'organization_id': DemoMode.organizationId,
      'user_id': DemoMode.userId,
      'shift_id': 'demo-shift-y1',
      'clock_in': _iso(_at(-1, 15, 58)),
      'clock_out': _iso(_at(-1, 22, 12)),
    },
    {
      'id': 'demo-te-2',
      'organization_id': DemoMode.organizationId,
      'user_id': 'demo-user-0004',
      'shift_id': 'demo-shift-y2',
      'clock_in': _iso(_at(-1, 17, 3)),
      'clock_out': _iso(_at(-1, 23, 20)),
    },
    {
      'id': 'demo-te-3',
      'organization_id': DemoMode.organizationId,
      'user_id': 'demo-user-0003',
      'shift_id': 'demo-shift-y2',
      'clock_in': _iso(_at(-1, 14, 55)),
      'clock_out': _iso(_at(-1, 23, 5)),
    },
    // Open punch — no clock_out. Drives the "still clocked in" notice.
    {
      'id': 'demo-te-open',
      'organization_id': DemoMode.organizationId,
      'user_id': 'demo-user-0002',
      'shift_id': 'demo-shift-today-2',
      'clock_in': _iso(_at(0, 16, 2)),
      'clock_out': null,
    },
  ];

  static final shiftNotes = <Map<String, dynamic>>[
    {
      'id': 'demo-note-1',
      'organization_id': DemoMode.organizationId,
      'author_id': 'demo-user-0003',
      'shift_date': _key(_today.subtract(const Duration(days: 1))),
      'note':
          'Walk-in is running warm — vendor is booked for Tuesday morning. Keep the '
              'backup cooler stocked and check temps every couple of hours.',
      'photo_url': null,
      'created_at': _iso(_at(-1, 23, 10)),
      'profiles': {'name': 'Jordan Blake'},
    },
    {
      'id': 'demo-note-2',
      'organization_id': DemoMode.organizationId,
      'author_id': DemoMode.userId,
      'shift_date': _key(_today.subtract(const Duration(days: 2))),
      'note':
          'Two large parties booked Friday at 7. Prep extra and pull an extra server '
              'if anyone wants hours.',
      'photo_url': null,
      'created_at': _iso(_at(-2, 22, 40)),
      'profiles': {'name': 'Alex Rivera'},
    },
  ];

  static final tipPools = <Map<String, dynamic>>[
    {
      'id': 'demo-pool-1',
      'organization_id': DemoMode.organizationId,
      'shift_date': _key(_today.subtract(const Duration(days: 1))),
      'total_cents': 48200,
      'split_method': 'hours',
      'created_at': _iso(_at(-1, 23, 30)),
    },
  ];

  static final tipAllocations = <Map<String, dynamic>>[
    {
      'id': 'demo-alloc-1',
      'tip_pool_id': 'demo-pool-1',
      'user_id': DemoMode.userId,
      'hours_worked': 6.23,
      'amount_cents': 14800,
      'profiles': {'name': 'Alex Rivera'},
      'tip_pools': {
        'shift_date': _key(_today.subtract(const Duration(days: 1))),
        'organization_id': DemoMode.organizationId,
        'total_cents': 48200,
      },
    },
    {
      'id': 'demo-alloc-2',
      'tip_pool_id': 'demo-pool-1',
      'user_id': 'demo-user-0004',
      'hours_worked': 6.28,
      'amount_cents': 14920,
      'profiles': {'name': 'Priya Nair'},
      'tip_pools': {
        'shift_date': _key(_today.subtract(const Duration(days: 1))),
        'organization_id': DemoMode.organizationId,
        'total_cents': 48200,
      },
    },
    {
      'id': 'demo-alloc-3',
      'tip_pool_id': 'demo-pool-1',
      'user_id': 'demo-user-0003',
      'hours_worked': 8.17,
      'amount_cents': 18480,
      'profiles': {'name': 'Jordan Blake'},
      'tip_pools': {
        'shift_date': _key(_today.subtract(const Duration(days: 1))),
        'organization_id': DemoMode.organizationId,
        'total_cents': 48200,
      },
    },
  ];

  static final messages = <Map<String, dynamic>>[
    {
      'id': 'demo-msg-1',
      'organization_id': DemoMode.organizationId,
      'user_id': 'demo-user-0004',
      'text': 'Running about 10 minutes late — traffic on the bridge.',
      'pinned': false,
      'system_generated': false,
      'created_at': _iso(_now.subtract(const Duration(minutes: 24))),
      'profiles': {'name': 'Priya Nair'},
    },
    {
      'id': 'demo-msg-2',
      'organization_id': DemoMode.organizationId,
      'user_id': 'demo-user-0003',
      'text': 'Fresh dough is proofed and in the walk-in for tonight.',
      'pinned': false,
      'system_generated': false,
      'created_at': _iso(_now.subtract(const Duration(hours: 3))),
      'profiles': {'name': 'Jordan Blake'},
    },
    {
      'id': 'demo-msg-pin',
      'organization_id': DemoMode.organizationId,
      'user_id': DemoMode.userId,
      'text': 'Saturday prep: 40 wings, 6 trays of dough. Pinning this.',
      'pinned': true,
      'system_generated': false,
      'created_at': _iso(_now.subtract(const Duration(hours: 5))),
      'profiles': {'name': 'Alex Rivera'},
    },
  ];

  static final swaps = <Map<String, dynamic>>[
    {
      'id': 'demo-swap-1',
      'organization_id': DemoMode.organizationId,
      'shift_title': '4:00 PM – 10:00 PM · Server',
      'original_staff': 'Sam Chen',
      'shift_date': _key(_today.add(const Duration(days: 1))),
      'day_num': _today.add(const Duration(days: 1)).day,
      'status': 'Available',
      'claimed_by': null,
      'claimed_by_name': null,
      'created_at': _iso(_now.subtract(const Duration(hours: 2))),
    },
    {
      'id': 'demo-swap-2',
      'organization_id': DemoMode.organizationId,
      'shift_title': '5:00 PM – 11:00 PM · Server',
      'original_staff': 'Priya Nair',
      'shift_date': _key(_today.add(const Duration(days: 3))),
      'day_num': _today.add(const Duration(days: 3)).day,
      'status': 'Pending Approval',
      'claimed_by': 'demo-user-0002',
      'claimed_by_name': 'Sam Chen',
      'created_at': _iso(_now.subtract(const Duration(hours: 6))),
    },
  ];

  static final timeOffRequests = <Map<String, dynamic>>[
    {
      'id': 'demo-tor-1',
      'organization_id': DemoMode.organizationId,
      'user_id': 'demo-user-0004',
      'user_name': 'Priya Nair',
      'start_date': _key(_today.add(const Duration(days: 10))),
      'end_date': _key(_today.add(const Duration(days: 12))),
      'reason': 'Family visit',
      'status': 'Pending',
      'notified': false,
      'created_at': _iso(_now.subtract(const Duration(days: 1))),
    },
    {
      'id': 'demo-tor-2',
      'organization_id': DemoMode.organizationId,
      'user_id': DemoMode.userId,
      'user_name': 'Alex Rivera',
      'start_date': _key(_today.add(const Duration(days: 20))),
      'end_date': _key(_today.add(const Duration(days: 20))),
      'reason': 'Dentist',
      'status': 'Approved',
      'notified': true,
      'created_at': _iso(_now.subtract(const Duration(days: 3))),
    },
  ];

  static final sidework = <Map<String, dynamic>>[
    {
      'id': 'demo-sw-1',
      'organization_id': DemoMode.organizationId,
      'task_date': _key(_today),
      'day_num': _today.day,
      'task': 'Restock ice and garnish trays',
      'assigned_to': 'Sam Chen',
      'completed': false,
      'completed_at': null,
      'completed_by': null,
      'created_at': _iso(_at(0, 10, 0)),
    },
    {
      'id': 'demo-sw-2',
      'organization_id': DemoMode.organizationId,
      'task_date': _key(_today),
      'day_num': _today.day,
      'task': 'Wipe bar and polish glassware',
      'assigned_to': 'Alex Rivera',
      'completed': true,
      'completed_at': _iso(_at(0, 11, 30)),
      'completed_by': DemoMode.userId,
      'created_at': _iso(_at(0, 10, 5)),
    },
    {
      'id': 'demo-sw-3',
      'organization_id': DemoMode.organizationId,
      'task_date': _key(_today),
      'day_num': _today.day,
      'task': 'Sweep patio before open',
      'assigned_to': 'Jordan Blake',
      'completed': false,
      'completed_at': null,
      'completed_by': null,
      'created_at': _iso(_at(0, 10, 10)),
    },
  ];

  static final organizationInvites = <Map<String, dynamic>>[
    {
      'id': 'demo-inv-1',
      'organization_id': DemoMode.organizationId,
      'code': 'DEMO42',
      'role': 'Staff',
      'created_by': DemoMode.userId,
      'expires_at': _iso(_now.add(const Duration(days: 14))),
      'used_at': null,
      'used_by': null,
      'created_at': _iso(_now.subtract(const Duration(hours: 2))),
    },
  ];

  static final notifications = <Map<String, dynamic>>[
    {
      'id': 'demo-notif-1',
      'user_id': DemoMode.userId,
      'organization_id': DemoMode.organizationId,
      'title': 'Schedule published',
      'body': 'Your Thursday and Friday dinner shifts are live.',
      'read_at': null,
      'created_at': _iso(_now.subtract(const Duration(hours: 3))),
    },
    {
      'id': 'demo-notif-2',
      'user_id': DemoMode.userId,
      'organization_id': DemoMode.organizationId,
      'title': 'Swap claimed',
      'body': 'Sam Chen claimed your Saturday mid. Awaiting approval.',
      'read_at': _iso(_now.subtract(const Duration(hours: 1))),
      'created_at': _iso(_now.subtract(const Duration(hours: 5))),
    },
  ];

  static final notificationPreferences = <Map<String, dynamic>>[
    {
      'user_id': DemoMode.userId,
      'organization_id': DemoMode.organizationId,
      'my_shifts': true,
      'shift_changes': true,
      'swap_opportunities': true,
      'team_messages': false,
      'schedule_published': true,
      'push_enabled': true,
      'sms_fallback': true,
      'quiet_start': '23:00:00',
      'quiet_end': '07:00:00',
      'critical_bypass_quiet': true,
      'updated_at': _iso(_now),
    },
  ];

  static const restaurantId = 'demo-rest-0001';

  static final restaurants = <Map<String, dynamic>>[
    {
      'id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'name': 'The Alder House',
      'public_token': 'alder',
      'created_at': _iso(_now.subtract(const Duration(days: 30))),
    },
  ];

  static final restaurantSettings = <Map<String, dynamic>>[
    {
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'paused': false,
      'prep_minutes': 30,
      'fee_cents': 0,
      'tax_rate': 0.06,
      'payment_mode': 'manual',
      'max_orders_per_hour': 15,
      'auto_pause_enabled': true,
      'auto_pause_threshold': 1,
    },
  ];

  static final capacityEvents = <Map<String, dynamic>>[
    {
      'id': 'demo-cap-0001',
      'organization_id': DemoMode.organizationId,
      'restaurant_id': restaurantId,
      'event': 'auto_resume',
      'staff_on_shift': 2,
      'orders_last_hour': 8,
      'max_capacity': 30,
      'detail': 'Staff on shift (2) meets threshold (1)',
      'created_at': DateTime.now().subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
    },
  ];

  static final serverTips = <Map<String, dynamic>>[
    {
      'id': 'demo-st-0001',
      'organization_id': DemoMode.organizationId,
      'user_id': DemoMode.userId,
      'staff_name': 'Demo Server',
      'shift_date': DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 1))),
      'cash_tips_cents': 4500,
      'card_tips_cents': 8200,
      'total_cents': 12700,
      'note': 'Busy Friday',
      'created_at': DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(),
      'updated_at': DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(),
    },
    {
      'id': 'demo-st-0002',
      'organization_id': DemoMode.organizationId,
      'user_id': DemoMode.userId,
      'staff_name': 'Demo Server',
      'shift_date': DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 2))),
      'cash_tips_cents': 3000,
      'card_tips_cents': 5500,
      'total_cents': 8500,
      'note': null,
      'created_at': DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String(),
      'updated_at': DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String(),
    },
  ];

  static final dailyRevenue = <Map<String, dynamic>>[
    {
      'id': 'demo-dr-0001',
      'organization_id': DemoMode.organizationId,
      'restaurant_id': restaurantId,
      'revenue_date': DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 1))),
      'total_cents': 240000,
      'source': 'manual',
      'note': 'POS closeout',
      'created_at': DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(),
    },
  ];

  static final menuCategories = <Map<String, dynamic>>[
    {
      'id': 'demo-cat-pizza',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'name': 'Old Forge Pizza Trays',
      'sort_order': 1,
    },
    {
      'id': 'demo-cat-wings',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'name': 'Award-Winning Wings',
      'sort_order': 2,
    },
    {
      'id': 'demo-cat-subs',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'name': 'Specialty Subs',
      'sort_order': 3,
    },
    {
      'id': 'demo-cat-apps',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'name': 'Starters & Sides',
      'sort_order': 4,
    },
    {
      'id': 'demo-cat-brews',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'name': 'House Brews To-Go',
      'sort_order': 5,
    },
  ];

  static final menuItems = <Map<String, dynamic>>[
    {
      'id': 'demo-item-p1',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-pizza',
      'name': 'Old Forge Red Tray (12 Cuts)',
      'description':
          'Signature rectangular thick-crust. Crispy bottom, pillowy center, secret blend of cheeses.',
      'price_cents': 1850,
      'available': true,
      'sort_order': 1,
    },
    {
      'id': 'demo-item-p2',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-pizza',
      'name': 'Old Forge White Tray (12 Cuts)',
      'description':
          'Double-crust pizza stuffed with a savory herb and cheese blend, topped with rosemary and sea salt.',
      'price_cents': 2100,
      'available': true,
      'sort_order': 2,
    },
    {
      'id': 'demo-item-p3',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-pizza',
      'name': 'The Enola Special Tray',
      'description':
          'Red tray loaded with house-roasted porketta, green peppers, and sharp onions.',
      'price_cents': 2350,
      'available': true,
      'sort_order': 3,
    },
    {
      'id': 'demo-item-p4',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-pizza',
      'name': 'Personal Red Pizza (4 Cuts)',
      'description':
          'Smaller 4-cut version of our famous rectangular Old Forge style red tray.',
      'price_cents': 850,
      'available': true,
      'sort_order': 4,
    },
    {
      'id': 'demo-item-p5',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-pizza',
      'name': 'The Meat Tray',
      'description': 'Red tray loaded with pepperoni, sausage, bacon, and ham.',
      'price_cents': 2450,
      'available': true,
      'sort_order': 5,
    },
    {
      'id': 'demo-item-w1',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-wings',
      'name': 'Jumbo Wings (10 Count)',
      'description':
          'Fresh, never frozen. Crisp fried and tossed in your custom signature house flavor.',
      'price_cents': 1495,
      'available': true,
      'sort_order': 1,
    },
    {
      'id': 'demo-item-w2',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-wings',
      'name': 'Jumbo Wings (20 Count)',
      'description':
          'Perfect for sharing. Choose up to two custom signature wing sauces.',
      'price_cents': 2850,
      'available': true,
      'sort_order': 2,
    },
    {
      'id': 'demo-item-w3',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-wings',
      'name': 'Boneless Wing Platter',
      'description':
          'All-white meat breast chunks breaded, fried golden, and tossed in your favorite sauce.',
      'price_cents': 1250,
      'available': true,
      'sort_order': 3,
    },
    {
      'id': 'demo-item-s1',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-subs',
      'name': 'Famous Italian Porketta Sub',
      'description':
          'Slow-roasted seasoned pork, shredded and topped with melted provolone on a toasted roll.',
      'price_cents': 1200,
      'available': true,
      'sort_order': 1,
    },
    {
      'id': 'demo-item-s2',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-subs',
      'name': 'Classic Italian Hoagie',
      'description':
          'Ham, capicola, salami, provolone, lettuce, tomato, onion, and house vinaigrette.',
      'price_cents': 1150,
      'available': true,
      'sort_order': 2,
    },
    {
      'id': 'demo-item-s3',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-subs',
      'name': 'Meatball Parm Sub',
      'description':
          'House-made Italian meatballs smothered in marinara and melted mozzarella.',
      'price_cents': 1200,
      'available': true,
      'sort_order': 3,
    },
    {
      'id': 'demo-item-s4',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-subs',
      'name': 'Chicken Cheesesteak',
      'description':
          'Finely chopped chicken breast with melted American cheese, onions, and sauce.',
      'price_cents': 1250,
      'available': true,
      'sort_order': 4,
    },
    {
      'id': 'demo-item-a1',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-apps',
      'name': 'Jigsy Fries',
      'description':
          'Crispy golden fries tossed in our custom house seasoning blend.',
      'price_cents': 650,
      'available': true,
      'sort_order': 1,
    },
    {
      'id': 'demo-item-a2',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-apps',
      'name': 'Mozzarella Sticks (6 Count)',
      'description':
          'Battered mozzarella sticks fried crisp, served with a side of warm marinara.',
      'price_cents': 800,
      'available': true,
      'sort_order': 2,
    },
    {
      'id': 'demo-item-a3',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-apps',
      'name': 'Onion Rings',
      'description':
          'Thick-cut, beer-battered onion rings served with Texas petal dipping sauce.',
      'price_cents': 750,
      'available': true,
      'sort_order': 3,
    },
    {
      'id': 'demo-item-a4',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-apps',
      'name': 'Pierogies (4 Count)',
      'description':
          'Classic PA coal-country style pierogies sautéed with butter and sweet onions.',
      'price_cents': 700,
      'available': true,
      'sort_order': 4,
    },
    {
      'id': 'demo-item-b1',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-brews',
      'name': 'Big J Double IPA (4-Pack To-Go)',
      'description':
          '8.2% ABV. Heavy citrus and pine hop profile with a smooth, malty backbone.',
      'price_cents': 1600,
      'available': true,
      'sort_order': 1,
    },
    {
      'id': 'demo-item-b2',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-brews',
      'name': 'Citra Wheat Ale (4-Pack To-Go)',
      'description':
          '5.4% ABV. Crisp, refreshing American wheat beer bursting with bright tropical notes.',
      'price_cents': 1400,
      'available': true,
      'sort_order': 2,
    },
    {
      'id': 'demo-item-b3',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'category_id': 'demo-cat-brews',
      'name': 'Enola Amber Lager (4-Pack To-Go)',
      'description':
          '5.0% ABV. Smooth, toasted malt character with a clean, classic finish.',
      'price_cents': 1400,
      'available': true,
      'sort_order': 3,
    },
  ];

  static final modifierGroups = <Map<String, dynamic>>[
    for (final id in ['p1', 'p2', 'p3', 'p4', 'p5'])
      {
        'id': 'demo-grp-$id-crust',
        'menu_item_id': 'demo-item-$id',
        'organization_id': DemoMode.organizationId,
        'name': 'Crust',
        'required': true,
        'min_select': 1,
        'max_select': 1,
      },
    for (final id in ['w1', 'w2', 'w3'])
      {
        'id': 'demo-grp-$id-sauce',
        'menu_item_id': 'demo-item-$id',
        'organization_id': DemoMode.organizationId,
        'name': 'Sauce',
        'required': true,
        'min_select': 1,
        'max_select': 1,
      },
  ];

  static final modifierOptions = <Map<String, dynamic>>[
    for (final id in ['p1', 'p2', 'p3', 'p4', 'p5']) ...[
      {
        'id': 'demo-opt-$id-crust-1',
        'modifier_group_id': 'demo-grp-$id-crust',
        'organization_id': DemoMode.organizationId,
        'name': 'Traditional Old Forge Thick-Crust',
        'price_delta_cents': 0,
      },
      {
        'id': 'demo-opt-$id-crust-2',
        'modifier_group_id': 'demo-grp-$id-crust',
        'organization_id': DemoMode.organizationId,
        'name': 'Thin & Crispy Tavern Crust',
        'price_delta_cents': 0,
      },
      {
        'id': 'demo-opt-$id-crust-3',
        'modifier_group_id': 'demo-grp-$id-crust',
        'organization_id': DemoMode.organizationId,
        'name': 'Double-Crust Stuffed Crust',
        'price_delta_cents': 0,
      },
    ],
    for (final id in ['w1', 'w2', 'w3']) ...[
      {
        'id': 'demo-opt-$id-sauce-1',
        'modifier_group_id': 'demo-grp-$id-sauce',
        'organization_id': DemoMode.organizationId,
        'name': 'House Mild Sauce',
        'price_delta_cents': 0,
      },
      {
        'id': 'demo-opt-$id-sauce-2',
        'modifier_group_id': 'demo-grp-$id-sauce',
        'organization_id': DemoMode.organizationId,
        'name': 'Signature Fire Hot',
        'price_delta_cents': 0,
      },
      {
        'id': 'demo-opt-$id-sauce-3',
        'modifier_group_id': 'demo-grp-$id-sauce',
        'organization_id': DemoMode.organizationId,
        'name': 'Garlic Parmesan Crust Glaze',
        'price_delta_cents': 0,
      },
      {
        'id': 'demo-opt-$id-sauce-4',
        'modifier_group_id': 'demo-grp-$id-sauce',
        'organization_id': DemoMode.organizationId,
        'name': 'Sweet Smokey BBQ',
        'price_delta_cents': 0,
      },
    ],
  ];

  static final onlineOrders = <Map<String, dynamic>>[
    {
      'id': 'demo-order-1',
      'restaurant_id': restaurantId,
      'organization_id': DemoMode.organizationId,
      'public_token': 'AB12CD',
      'status': 'waiting',
      'submitted_at': _iso(_now.subtract(const Duration(minutes: 4))),
      'accepted_at': null,
      'rejected_at': null,
      'completed_at': null,
      'reject_reason': null,
      'pickup_minutes': 30,
      'customer_json': {'name': 'Chris Park', 'phone': '717-555-0142'},
      'notes': '',
      'subtotal_cents': 3345,
      'fee_cents': 0,
      'tax_cents': 201,
      'total_cents': 3546,
      'payment_mode': 'manual',
      'payment_status': 'pending',
      'order_items': [
        {
          'id': 'demo-oi-1',
          'name': 'Old Forge Red Tray (12 Cuts)',
          'price_cents': 1850,
          'quantity': 1,
          'notes': 'Crust: Traditional Old Forge Thick-Crust',
          'order_item_modifiers': [
            {'name': 'Traditional Old Forge Thick-Crust', 'price_delta_cents': 0},
          ],
        },
        {
          'id': 'demo-oi-2',
          'name': 'Jumbo Wings (10 Count)',
          'price_cents': 1495,
          'quantity': 1,
          'notes': 'Sauce: House Mild Sauce',
          'order_item_modifiers': [
            {'name': 'House Mild Sauce', 'price_delta_cents': 0},
          ],
        },
      ],
    },
  ];

  static final callOuts = <Map<String, dynamic>>[
    {
      'id': 'demo-callout-1',
      'organization_id': DemoMode.organizationId,
      'shift_id': 'demo-shift-today',
      'shift_date': _key(_today),
      'start_time': '16:00',
      'end_time': '22:00',
      'staff_name': 'Sam Chen',
      'staff_user_id': 'demo-user-0002',
      'staff_role': 'server',
      'reason': 'Car trouble',
      'status': 'open',
      'filled_by': null,
      'filled_by_user_id': null,
      'created_at': _iso(_now.subtract(const Duration(minutes: 12))),
      'filled_at': null,
      'expires_at': _iso(_at(0, 16, 0)),
    },
  ];

  static final callOutNotifications = <Map<String, dynamic>>[
    {
      'id': 'demo-con-1',
      'call_out_id': 'demo-callout-1',
      'organization_id': DemoMode.organizationId,
      'user_id': DemoMode.userId,
      'staff_name': 'Alex Rivera',
      'phone': '+15555550101',
      'notified_at': _iso(_now.subtract(const Duration(minutes: 11))),
      'responded_at': null,
      'response': null,
    },
    {
      'id': 'demo-con-2',
      'call_out_id': 'demo-callout-1',
      'organization_id': DemoMode.organizationId,
      'user_id': 'demo-user-0004',
      'staff_name': 'Priya Nair',
      'phone': null,
      'notified_at': _iso(_now.subtract(const Duration(minutes: 11))),
      'responded_at': null,
      'response': null,
    },
  ];

  static List<Map<String, dynamic>> forTable(String table) {
    switch (table) {
      case 'profiles':
        return staff;
      case 'organizations':
        return [organization];
      case 'shifts':
        return shifts;
      case 'time_entries':
        return timeEntries;
      case 'shift_notes':
        return shiftNotes;
      case 'tip_pools':
        return tipPools;
      case 'tip_allocations':
        return tipAllocations;
      case 'messages':
        return messages;
      case 'swaps':
        return swaps;
      case 'time_off_requests':
        return timeOffRequests;
      case 'sidework':
        return sidework;
      case 'organization_invites':
        return organizationInvites;
      case 'notifications':
        return notifications;
      case 'notification_preferences':
        return notificationPreferences;
      case 'restaurants':
        return restaurants;
      case 'restaurant_settings':
        return restaurantSettings;
      case 'menu_categories':
        return menuCategories;
      case 'menu_items':
        return menuItems;
      case 'modifier_groups':
        return modifierGroups;
      case 'modifier_options':
        return modifierOptions;
      case 'online_orders':
        return onlineOrders;
      case 'order_items':
        return [
          for (final o in onlineOrders)
            ...((o['order_items'] as List?)?.cast<Map<String, dynamic>>() ??
                const []),
        ];
      case 'call_outs':
        return callOuts;
      case 'call_out_notifications':
        return callOutNotifications;
      case 'capacity_events':
        return capacityEvents;
      case 'daily_revenue':
        return dailyRevenue;
      case 'server_tips':
        return serverTips;
      default:
        return const [];
    }
  }
}

/// Answers PostgREST calls from seeded data.
///
/// Filters, ordering and limit are applied for real. An earlier version ignored
/// them and returned whole tables, which broke the dashboard: asking for "my
/// shift today" got all six seeded shifts back, and a single-row request cannot
/// take six rows. Ignoring filters was never merely imprecise — it answered a
/// different question than the screen asked.
///
/// `select=` shaping is *not* applied: rows come back whole. Screens only read
/// the columns they asked for, so extra keys are inert.
///
/// Writes are accepted and echoed back so buttons feel alive, but nothing
/// persists across a reload; that honesty is better than a demo that appears to
/// save and quietly loses the data.
class DemoHttpClient extends http.BaseClient {
  final _inner = http.Client();

  static const _nonFilterParams = {'select', 'order', 'limit', 'offset'};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;

    if (!path.contains('/rest/v1/')) {
      // Auth, realtime and anything else: fail fast and quietly rather than
      // reaching for a network that is not there.
      return _json(request, '{}', status: 200);
    }

    final table = path.split('/rest/v1/').last.split('?').first;

    if (request.method == 'POST' ||
        request.method == 'PATCH' ||
        request.method == 'PUT') {
      final body = request is http.Request ? request.body : '[]';
      return _json(request, body.isEmpty ? '[]' : _asList(body));
    }
    if (request.method == 'DELETE') {
      return _json(request, '[]');
    }

    final params = _withDemoIdentity(request.url.queryParametersAll);
    var rows = DemoSeed.forTable(table);

    for (final entry in params.entries) {
      if (_nonFilterParams.contains(entry.key)) continue;
      for (final expr in entry.value) {
        rows = rows.where((r) => _matches(r, entry.key, expr)).toList();
      }
    }

    final order = params['order']?.first;
    if (order != null) rows = _sorted(rows, order);

    final limit = int.tryParse(params['limit']?.first ?? '');
    if (limit != null && rows.length > limit) rows = rows.sublist(0, limit);

    // PostgREST returns a bare object (not a list) when the client asked for a
    // single row; supabase-flutter signals that with this Accept header.
    final wantsSingle =
        (request.headers['Accept'] ?? '').contains('vnd.pgrst.object');
    if (wantsSingle) {
      return _json(request, rows.isEmpty ? 'null' : jsonEncode(rows.first));
    }
    return _json(request, jsonEncode(rows));
  }

  /// Stands in for the signed-in user.
  ///
  /// Every screen reads identity as `auth.currentUser?.id ?? ''`, and demo mode
  /// has no session by design — so those queries arrive as `id=eq.` with an
  /// empty operand. An empty equality operand cannot match anything real and
  /// only ever arises from that missing session, so it is unambiguously "the
  /// current user", which in demo is the seeded manager.
  ///
  /// This backend already stands in for the database; standing in for identity
  /// too keeps the alternative — faking a session, or threading a user id
  /// through four verified screens — out of the feature code.
  static Map<String, List<String>> _withDemoIdentity(
      Map<String, List<String>> params) {
    return params.map((key, values) => MapEntry(
          key,
          [for (final v in values) v == 'eq.' ? 'eq.${DemoMode.userId}' : v],
        ));
  }

  /// `column=op.operand`, e.g. `shift_date=eq.2026-07-27` or `clock_out=is.null`.
  /// The column may be dotted (`tip_pools.organization_id`) for embedded rows.
  static bool _matches(Map<String, dynamic> row, String column, String expr) {
    final dot = expr.indexOf('.');
    if (dot < 0) return true;
    final op = expr.substring(0, dot);
    final operand = expr.substring(dot + 1);
    final actual = _resolve(row, column);

    switch (op) {
      case 'eq':
        return '$actual' == operand;
      case 'neq':
        return '$actual' != operand;
      case 'is':
        return operand == 'null' ? actual == null : '$actual' == operand;
      case 'gt':
      case 'gte':
      case 'lt':
      case 'lte':
        if (actual == null) return false;
        final c = _compare(actual, operand);
        if (c == null) return true;
        return switch (op) {
          'gt' => c > 0,
          'gte' => c >= 0,
          'lt' => c < 0,
          _ => c <= 0,
        };
      default:
        // Unimplemented operator: do not silently drop rows.
        return true;
    }
  }

  /// Numeric where both sides parse as numbers, lexicographic otherwise —
  /// which is correct for the ISO date strings these screens compare.
  static int? _compare(Object actual, String operand) {
    final a = actual is num ? actual : num.tryParse('$actual');
    final b = num.tryParse(operand);
    if (a != null && b != null) return a.compareTo(b);
    return '$actual'.compareTo(operand);
  }

  static Object? _resolve(Map<String, dynamic> row, String column) {
    if (!column.contains('.')) return row[column];
    Object? cur = row;
    for (final part in column.split('.')) {
      if (cur is! Map) return null;
      cur = cur[part];
    }
    return cur;
  }

  /// `order=created_at.desc` (PostgREST may append `.nullsfirst`/`.nullslast`).
  static List<Map<String, dynamic>> _sorted(
      List<Map<String, dynamic>> rows, String order) {
    final parts = order.split('.');
    final column = parts.first;
    final descending = parts.contains('desc');
    final sorted = [...rows]..sort((x, y) {
        final a = _resolve(x, column);
        final b = _resolve(y, column);
        if (a == null && b == null) return 0;
        if (a == null) return 1;
        if (b == null) return -1;
        return _compare(a, '$b') ?? 0;
      });
    return descending ? sorted.reversed.toList() : sorted;
  }

  static String _asList(String body) {
    final decoded = jsonDecode(body);
    return jsonEncode(decoded is List ? decoded : [decoded]);
  }

  http.StreamedResponse _json(http.BaseRequest request, String body,
      {int status = 200}) {
    final bytes = utf8.encode(body);
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      request: request,
      headers: {'content-type': 'application/json; charset=utf-8'},
      contentLength: bytes.length,
    );
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
