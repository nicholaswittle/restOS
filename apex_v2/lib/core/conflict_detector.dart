import 'package:supabase_flutter/supabase_flutter.dart';

/// Publish-time conflict checks — ported from Apex v1.
///
/// Empty list = safe to insert. Used by Assign Days before batch write.
class ConflictDetector {
  ConflictDetector(this._client);

  final SupabaseClient _client;

  /// Human-readable conflicts for [staff] on each of [targetDates].
  Future<List<String>> findPublishConflicts({
    required String organizationId,
    required List<String> targetDates,
    required String staff,
  }) async {
    if (staff == 'Open' || staff.isEmpty || targetDates.isEmpty) return [];

    final conflicts = <String>[];
    final sorted = [...targetDates]..sort();

    for (final dateKey in sorted) {
      final existing = await _client
          .from('shifts')
          .select('id, title')
          .eq('organization_id', organizationId)
          .eq('shift_date', dateKey)
          .eq('staff', staff);
      final rows = (existing as List).cast<Map<String, dynamic>>();
      if (rows.isNotEmpty) {
        final title = rows.first['title'] ?? 'shift';
        conflicts.add('$staff already has a $title on $dateKey');
      }

      final vacation = await _client
          .from('time_off_requests')
          .select('id')
          .eq('organization_id', organizationId)
          .eq('user_name', staff)
          .eq('status', 'Approved')
          .lte('start_date', dateKey)
          .gte('end_date', dateKey);
      if ((vacation as List).isNotEmpty) {
        conflicts.add('$staff has approved time off on $dateKey');
      }
    }

    return conflicts;
  }
}
