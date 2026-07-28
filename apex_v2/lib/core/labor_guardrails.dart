import 'package:supabase_flutter/supabase_flutter.dart';

import 'shift_time.dart';

/// Soft labor-law warnings before publish (plan #9). Start with PA rules.
///
/// Warnings are advisory — managers can continue. Hard blocks stay out until
/// legal review; restaurants vary and minors need a DOB on file.
class LaborGuardrails {
  LaborGuardrails(this._client, {this.stateCode = 'PA'});

  final SupabaseClient _client;

  /// ISO-ish state code. Only `PA` has rules today.
  final String stateCode;

  /// Returns human-readable warnings (empty = clear).
  Future<List<String>> checkProposedShifts({
    required String organizationId,
    required String staff,
    required List<String> shiftDates,
    required String startTime,
    required String endTime,
  }) async {
    if (staff.isEmpty || shiftDates.isEmpty) return [];
    if (stateCode.toUpperCase() != 'PA') return [];

    final warnings = <String>[];
    final hoursEach = hoursBetween(startTime, endTime);
    final sorted = [...shiftDates]..sort();

    // Break notice — PA meal period expectation for long shifts.
    if (hoursEach >= 6) {
      warnings.add(
        'Shifts of ${formatHours(hoursEach)}h usually need a 30-minute break (PA).',
      );
    }

    // Load profile for minor check + id for week hours.
    final profile = await _client
        .from('profiles')
        .select('id, date_of_birth, name')
        .eq('organization_id', organizationId)
        .eq('name', staff)
        .maybeSingle();

    final dobRaw = profile?['date_of_birth'] as String?;
    final age = _ageYears(dobRaw);
    if (age != null && age < 18) {
      for (final day in sorted) {
        final dt = DateTime.tryParse(day);
        if (dt == null) continue;
        final schoolNight = dt.weekday >= DateTime.monday &&
            dt.weekday <= DateTime.thursday;
        final endMins = _toMinutes(endTime);
        if (schoolNight && endMins != null && endMins > 22 * 60) {
          warnings.add(
            '$staff is $age — past 10 PM on a school night ($day).',
          );
        }
        if (hoursEach > 8) {
          warnings.add(
            '$staff is $age — over 8 hours on $day may exceed minor limits.',
          );
        }
      }
    }

    // Overtime: existing week hours + proposed.
    final weekHours = await _scheduledWeekHours(
      organizationId: organizationId,
      staff: staff,
      around: DateTime.parse(sorted.first),
    );
    final added = hoursEach * sorted.length;
    if (weekHours + added > 40) {
      warnings.add(
        '$staff is at ${formatHours(weekHours)}h this week; '
        'these shifts add ${formatHours(added)}h (overtime risk past 40).',
      );
    } else if (weekHours + added > 38) {
      warnings.add(
        '$staff is near overtime (${formatHours(weekHours)}h now + '
        '${formatHours(added)}h).',
      );
    }

    // Consecutive days across existing + proposed.
    final streak = await _consecutiveDayWarning(
      organizationId: organizationId,
      staff: staff,
      proposed: sorted,
    );
    if (streak != null) warnings.add(streak);

    return warnings;
  }

  Future<double> _scheduledWeekHours({
    required String organizationId,
    required String staff,
    required DateTime around,
  }) async {
    final monday = DateTime(around.year, around.month, around.day)
        .subtract(Duration(days: around.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    final rows = await _client
        .from('shifts')
        .select('start_time, end_time')
        .eq('organization_id', organizationId)
        .eq('staff', staff)
        .gte('shift_date', dateKeyOf(monday))
        .lte('shift_date', dateKeyOf(sunday));
    var total = 0.0;
    for (final r in (rows as List).cast<Map<String, dynamic>>()) {
      total += hoursBetween(
        r['start_time'] as String?,
        r['end_time'] as String?,
      );
    }
    return total;
  }

  Future<String?> _consecutiveDayWarning({
    required String organizationId,
    required String staff,
    required List<String> proposed,
  }) async {
    if (proposed.isEmpty) return null;
    final first = DateTime.parse(proposed.first);
    final from = first.subtract(const Duration(days: 10));
    final to = DateTime.parse(proposed.last).add(const Duration(days: 10));
    final rows = await _client
        .from('shifts')
        .select('shift_date')
        .eq('organization_id', organizationId)
        .eq('staff', staff)
        .gte('shift_date', dateKeyOf(from))
        .lte('shift_date', dateKeyOf(to));

    final days = <String>{
      for (final r in (rows as List).cast<Map<String, dynamic>>())
        if (r['shift_date'] != null) r['shift_date'] as String,
      ...proposed,
    };

    final sorted = days.map(DateTime.parse).toList()..sort();
    var best = 1;
    var run = 1;
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].difference(sorted[i - 1]).inDays == 1) {
        run++;
        if (run > best) best = run;
      } else {
        run = 1;
      }
    }
    if (best >= 7) {
      return '$staff would hit $best days in a row — PA recommends a rest day.';
    }
    return null;
  }

  static int? _ageYears(String? isoDate) {
    if (isoDate == null || isoDate.length < 10) return null;
    final dob = DateTime.tryParse(isoDate.substring(0, 10));
    if (dob == null) return null;
    final now = DateTime.now();
    var age = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      age--;
    }
    return age;
  }

  static int? _toMinutes(String hhmm) {
    final p = hhmm.split(':');
    if (p.length < 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }
}
