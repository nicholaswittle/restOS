import 'shift_time.dart';

/// Build calendar payloads without Google OAuth (plan #10, shippable path).
///
/// Full two-way Google sync needs a Cloud OAuth client — later. ICS + Google
/// "TEMPLATE" links cover "add my shifts to my phone calendar" today.
class CalendarExport {
  CalendarExport._();

  /// ICS for Apple / Outlook / Google import.
  static String toIcs({
    required String calendarName,
    required List<CalendarShift> shifts,
  }) {
    final buf = StringBuffer()
      ..writeln('BEGIN:VCALENDAR')
      ..writeln('VERSION:2.0')
      ..writeln('PRODID:-//WiSense//Apex//EN')
      ..writeln('CALSCALE:GREGORIAN')
      ..writeln('X-WR-CALNAME:$calendarName');

    for (final s in shifts) {
      final start = _icsLocal(s.shiftDate, s.startTime);
      final end = _icsLocal(s.shiftDate, s.endTime);
      final uid = '${s.shiftDate}-${s.staff.hashCode}-${s.startTime}@apex';
      final summary = _escape('${s.staff} shift');
      buf
        ..writeln('BEGIN:VEVENT')
        ..writeln('UID:$uid')
        ..writeln('DTSTAMP:${_icsUtcNow()}')
        ..writeln('DTSTART:$start')
        ..writeln('DTEND:$end')
        ..writeln('SUMMARY:$summary')
        ..writeln('DESCRIPTION:Apex schedule')
        ..writeln('END:VEVENT');
    }
    buf.writeln('END:VCALENDAR');
    return buf.toString().replaceAll('\n', '\r\n');
  }

  /// Opens Google Calendar "create event" UI for one shift.
  static Uri googleTemplateUrl(CalendarShift s) {
    final start = _gcal(s.shiftDate, s.startTime);
    final end = _gcal(s.shiftDate, s.endTime);
    return Uri.https('calendar.google.com', '/calendar/render', {
      'action': 'TEMPLATE',
      'text': '${s.staff} shift',
      'dates': '$start/$end',
      'details': 'Apex schedule',
    });
  }

  static String _escape(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll(';', '\\;').replaceAll(',', '\\,');

  static String _icsUtcNow() {
    final n = DateTime.now().toUtc();
    return '${n.year.toString().padLeft(4, '0')}'
        '${n.month.toString().padLeft(2, '0')}'
        '${n.day.toString().padLeft(2, '0')}T'
        '${n.hour.toString().padLeft(2, '0')}'
        '${n.minute.toString().padLeft(2, '0')}'
        '${n.second.toString().padLeft(2, '0')}Z';
  }

  /// Floating local time (no Z) — restaurant shifts are local-wall-clock.
  static String _icsLocal(String dateKey, String hhmm) {
    final t = hhmm.replaceAll(':', '');
    final padded = t.length >= 4 ? t.substring(0, 4) : t.padLeft(4, '0');
    return '${dateKey.replaceAll('-', '')}T${padded}00';
  }

  static String _gcal(String dateKey, String hhmm) {
    final t = hhmm.replaceAll(':', '');
    final padded = t.length >= 4 ? t.substring(0, 4) : t.padLeft(4, '0');
    return '${dateKey.replaceAll('-', '')}T${padded}00';
  }
}

class CalendarShift {
  const CalendarShift({
    required this.staff,
    required this.shiftDate,
    required this.startTime,
    required this.endTime,
  });

  final String staff;
  final String shiftDate;
  final String startTime;
  final String endTime;

  factory CalendarShift.fromMap(Map<String, dynamic> m, {String? staff}) =>
      CalendarShift(
        staff: staff ?? (m['staff'] as String? ?? 'Shift'),
        shiftDate: m['shift_date'] as String? ?? dateKeyOf(DateTime.now()),
        startTime: m['start_time'] as String? ?? '16:00',
        endTime: m['end_time'] as String? ?? '22:00',
      );
}
