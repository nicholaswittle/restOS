import 'package:apex_v2/core/schedule_text_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Freeze "today" so weekday mapping is stable: Monday 2026-07-27.
  final parser = ScheduleTextParser(weekAnchor: DateTime(2026, 7, 27));

  test('parses simple name day range', () {
    final rows = parser.parse('Sam Chen Tue 4-10');
    expect(rows, hasLength(1));
    expect(rows.first.staff, 'Sam Chen');
    expect(rows.first.shiftDate, '2026-07-28'); // Tuesday
    expect(rows.first.startTime, '16:00');
    expect(rows.first.endTime, '22:00');
  });

  test('parses multiple days on one line', () {
    final rows = parser.parse('Priya Nair Fri,Sat 5pm-11pm');
    expect(rows, hasLength(2));
    expect(rows.map((r) => r.shiftDate).toList(), [
      '2026-07-31',
      '2026-08-01',
    ]);
    expect(rows.first.startTime, '17:00');
    expect(rows.first.endTime, '23:00');
  });

  test('skips garbage lines', () {
    final rows = parser.parse('not a shift\n# comment\nAlex Mon 11:00-15:00');
    expect(rows, hasLength(1));
    expect(rows.first.staff, 'Alex');
  });
}
