import 'package:apex_v2/core/calendar_export.dart';
import 'package:apex_v2/core/demo_backend.dart';
import 'package:apex_v2/core/labor_guardrails.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

void main() {
  test('ICS contains VEVENT for each shift', () {
    final ics = CalendarExport.toIcs(
      calendarName: 'Apex',
      shifts: const [
        CalendarShift(
          staff: 'Sam Chen',
          shiftDate: '2026-07-28',
          startTime: '16:00',
          endTime: '22:00',
        ),
      ],
    );
    expect(ics, contains('BEGIN:VEVENT'));
    expect(ics, contains('SUMMARY:Sam Chen shift'));
    expect(ics, contains('DTSTART:20260728T160000'));
    expect(ics, contains('DTEND:20260728T220000'));
  });

  test('Google template URL encodes dates', () {
    final uri = CalendarExport.googleTemplateUrl(
      const CalendarShift(
        staff: 'Sam',
        shiftDate: '2026-07-28',
        startTime: '16:00',
        endTime: '22:00',
      ),
    );
    expect(uri.host, 'calendar.google.com');
    expect(uri.queryParameters['dates'], '20260728T160000/20260728T220000');
  });

  test('guardrails warn on long PA shifts', () async {
    final client = SupabaseClient(
      'https://demo.invalid',
      'demo',
      httpClient: DemoHttpClient(),
    );
    final warnings = await LaborGuardrails(client).checkProposedShifts(
      organizationId: DemoMode.organizationId,
      staff: 'Alex Rivera',
      shiftDates: ['2026-07-28'],
      startTime: '10:00',
      endTime: '18:00',
    );
    expect(warnings.any((w) => w.contains('30-minute break')), isTrue);
  });
}
