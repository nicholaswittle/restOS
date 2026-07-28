import 'package:apex_v2/core/clock_qr.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const org = 'org-test-0001';

  test('daily payload validates for today', () {
    final payload = ClockQr.payloadFor(org);
    expect(ClockQr.isValid(payload, org), isTrue);
    expect(ClockQr.accepts(payload, org), isTrue);
  });

  test('short code validates for today', () {
    final short = ClockQr.shortCode(org);
    expect(short.length, 6);
    expect(ClockQr.accepts(short, org), isTrue);
  });

  test('wrong org is rejected', () {
    final payload = ClockQr.payloadFor(org);
    expect(ClockQr.accepts(payload, 'other-org'), isFalse);
  });

  test('tampered digest is rejected', () {
    final payload = ClockQr.payloadFor(org);
    final parts = payload.split('|');
    parts[3] = 'DEADBEEF00';
    expect(ClockQr.isValid(parts.join('|'), org), isFalse);
  });
}
