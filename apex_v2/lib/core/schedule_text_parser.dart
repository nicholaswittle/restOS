import 'shift_time.dart';

/// One proposed shift from photo/text import — reviewed before insert.
class ParsedShift {
  ParsedShift({
    required this.staff,
    required this.shiftDate,
    required this.startTime,
    required this.endTime,
  });

  String staff;
  String shiftDate; // yyyy-MM-dd
  String startTime; // HH:MM
  String endTime;

  Map<String, dynamic> toInsertRow(String organizationId) => {
        'organization_id': organizationId,
        'shift_date': shiftDate,
        'staff': staff,
        'start_time': startTime,
        'end_time': endTime,
        'title': 'Shift',
        'day_num': DateTime.parse(shiftDate).day,
      };

  factory ParsedShift.fromJson(Map<String, dynamic> m) => ParsedShift(
        staff: (m['staff'] as String? ?? '').trim(),
        shiftDate: (m['shift_date'] as String? ?? '').trim(),
        startTime: ScheduleTextParser.normTime(m['start_time'] as String? ?? ''),
        endTime: ScheduleTextParser.normTime(m['end_time'] as String? ?? ''),
      );
}

/// Deterministic whiteboard/text → rows. No LLM required.
///
/// Accepts lines like:
///   Mike Tue 4-10
///   Sarah Friday 5pm-11pm
///   Jordan Blake Wed,Thu 16:00-22:00
class ScheduleTextParser {
  ScheduleTextParser({DateTime? weekAnchor})
      : _weekStart = _mondayOf(weekAnchor ?? DateTime.now());

  final DateTime _weekStart;

  static DateTime _mondayOf(DateTime d) =>
      DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

  List<ParsedShift> parse(String raw) {
    final out = <ParsedShift>[];
    for (final line in raw.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#') || trimmed.startsWith('//')) continue;
      out.addAll(_parseLine(trimmed));
    }
    return out
        .where((s) =>
            s.staff.isNotEmpty &&
            s.shiftDate.isNotEmpty &&
            hoursBetween(s.startTime, s.endTime) > 0)
        .toList();
  }

  List<ParsedShift> _parseLine(String line) {
    // "Name Day[,Day…] start-end"
    final timeMatch = RegExp(
      r'(.+?)\s+((?:mon|tue|wed|thu|fri|sat|sun|monday|tuesday|wednesday|thursday|friday|saturday|sunday)(?:\s*[,/&]\s*(?:mon|tue|wed|thu|fri|sat|sun|monday|tuesday|wednesday|thursday|friday|saturday|sunday))*)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (timeMatch == null) return const [];

    final staff = timeMatch.group(1)!.trim();
    final daysRaw = timeMatch.group(2)!;
    final timesRaw = timeMatch.group(3)!.trim();
    final times = _parseTimes(timesRaw);
    if (times == null) return const [];

    final days = daysRaw
        .split(RegExp(r'[,/&]+'))
        .map((d) => d.trim().toLowerCase())
        .where((d) => d.isNotEmpty);

    final rows = <ParsedShift>[];
    for (final d in days) {
      final date = _dateForWeekday(d);
      if (date == null) continue;
      rows.add(ParsedShift(
        staff: staff,
        shiftDate: dateKeyOf(date),
        startTime: times.$1,
        endTime: times.$2,
      ));
    }
    return rows;
  }

  DateTime? _dateForWeekday(String token) {
    final map = <String, int>{
      'mon': 1,
      'monday': 1,
      'tue': 2,
      'tues': 2,
      'tuesday': 2,
      'wed': 3,
      'wednesday': 3,
      'thu': 4,
      'thur': 4,
      'thurs': 4,
      'thursday': 4,
      'fri': 5,
      'friday': 5,
      'sat': 6,
      'saturday': 6,
      'sun': 7,
      'sunday': 7,
    };
    final wd = map[token];
    if (wd == null) return null;
    return _weekStart.add(Duration(days: wd - 1));
  }

  static (String, String)? _parseTimes(String raw) {
    final cleaned = raw
        .toLowerCase()
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll(' to ', '-')
        .trim();
    final parts = cleaned.split('-');
    if (parts.length != 2) return null;
    final start = normTime(parts[0].trim());
    final end = normTime(parts[1].trim());
    if (start.isEmpty || end.isEmpty) return null;
    return (start, end);
  }

  static String normTime(String raw) {
    var s = raw.trim().toLowerCase().replaceAll('.', '');
    if (s.isEmpty) return '';

    final am = s.contains('am');
    final pm = s.contains('pm');
    s = s.replaceAll('am', '').replaceAll('pm', '').trim();

    final m = RegExp(r'^(\d{1,2})(?::(\d{2}))?$').firstMatch(s);
    if (m == null) return '';
    var h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2) ?? '0');
    if (pm && h < 12) h += 12;
    if (am && h == 12) h = 0;
    // Bare "4" or "10" in restaurant context → PM if 1–11 and no am/pm.
    if (!am && !pm && h >= 1 && h <= 11) h += 12;
    if (h > 23 || min > 59) return '';
    return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
  }
}
