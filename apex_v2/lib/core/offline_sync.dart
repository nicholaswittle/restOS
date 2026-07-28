import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Local queue for clock punches when the kitchen Wi‑Fi dies.
///
/// Client wins on the punch timestamp. Flush is ordered and best-effort.
class OfflinePunchQueue {
  OfflinePunchQueue._();

  static const _prefsKey = 'apex_offline_punches_v1';

  static Future<List<Map<String, dynamic>>> peek() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<int> pendingCount() async => (await peek()).length;

  /// True when a clock-in is queued with no clock-out yet — treat as on-the-clock.
  static Future<bool> hasOpenLocalPunch() async {
    final rows = await peek();
    for (final row in rows.reversed) {
      if (row['op'] == 'clock_in' && row['clock_out_at'] == null) return true;
      if (row['op'] == 'clock_out') return false;
    }
    return false;
  }

  static Future<void> _save(List<Map<String, dynamic>> rows) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(rows));
  }

  static Future<void> enqueueClockIn({
    required String organizationId,
    required String userId,
    required String userName,
    required String shiftId,
    DateTime? at,
  }) async {
    final rows = await peek();
    rows.add({
      'op': 'clock_in',
      'organization_id': organizationId,
      'user_id': userId,
      'user_name': userName,
      'shift_id': shiftId,
      'at': (at ?? DateTime.now()).toUtc().toIso8601String(),
    });
    await _save(rows);
  }

  static Future<void> enqueueClockOut({
    String? entryId,
    DateTime? at,
  }) async {
    final rows = await peek();
    final stamp = (at ?? DateTime.now()).toUtc().toIso8601String();

    // Prefer closing a still-queued local clock-in so one row syncs both times.
    for (var i = rows.length - 1; i >= 0; i--) {
      final row = rows[i];
      if (row['op'] == 'clock_in' && row['clock_out_at'] == null) {
        rows[i] = {...row, 'clock_out_at': stamp};
        await _save(rows);
        return;
      }
    }

    if (entryId == null || entryId.isEmpty) return;
    rows.add({
      'op': 'clock_out',
      'entry_id': entryId,
      'at': stamp,
    });
    await _save(rows);
  }

  /// How many ops applied. Stops on first failure so order is preserved.
  static Future<int> flush(SupabaseClient client) async {
    final rows = await peek();
    if (rows.isEmpty) return 0;

    var applied = 0;
    final remaining = <Map<String, dynamic>>[];

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      try {
        final op = row['op'] as String?;
        if (op == 'clock_in') {
          final payload = <String, dynamic>{
            'organization_id': row['organization_id'],
            'user_id': row['user_id'],
            'user_name': row['user_name'],
            'shift_id': row['shift_id'],
            'clock_in': row['at'],
          };
          final out = row['clock_out_at'] as String?;
          if (out != null) payload['clock_out'] = out;
          await client.from('time_entries').insert(payload);
          applied++;
        } else if (op == 'clock_out') {
          await client.from('time_entries').update({
            'clock_out': row['at'],
          }).eq('id', row['entry_id'] as String);
          applied++;
        } else {
          applied++;
        }
      } catch (_) {
        remaining.addAll(rows.sublist(i));
        break;
      }
    }

    await _save(remaining);
    return applied;
  }
}
