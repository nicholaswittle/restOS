import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'shift_time.dart';

/// Daily rotating wall-QR payload for venue clock-in.
///
/// Format: `APEX|<orgId>|<yyyy-mm-dd>|<10-char digest>`
/// Digest covers org + date with an app pepper so yesterday's print is dead.
class ClockQr {
  ClockQr._();

  /// Override in release builds with `--dart-define=CLOCK_PEPPER=...`.
  static const pepper = String.fromEnvironment(
    'CLOCK_PEPPER',
    defaultValue: 'apex-v2-clock',
  );

  static String payloadFor(String organizationId, {DateTime? day}) {
    final key = dateKeyOf(day ?? DateTime.now());
    final digest = _digest(organizationId, key);
    return 'APEX|$organizationId|$key|$digest';
  }

  /// True when [raw] is a valid clock QR for [organizationId] today or
  /// yesterday (late close after midnight).
  static bool isValid(String raw, String organizationId) {
    final parts = raw.trim().split('|');
    if (parts.length != 4) return false;
    if (parts[0] != 'APEX') return false;
    if (parts[1] != organizationId) return false;
    final dateKey = parts[2];
    final digest = parts[3].toUpperCase();
    if (digest != _digest(organizationId, dateKey)) return false;

    final today = dateKeyOf(DateTime.now());
    final yesterday =
        dateKeyOf(DateTime.now().subtract(const Duration(days: 1)));
    return dateKey == today || dateKey == yesterday;
  }

  static String shortCode(String organizationId, {DateTime? day}) {
    final key = dateKeyOf(day ?? DateTime.now());
    return _digest(organizationId, key).substring(0, 6);
  }

  /// Accepts either the full QR payload or today's 6-char short code.
  static bool accepts(String raw, String organizationId) {
    final t = raw.trim().toUpperCase();
    if (t.isEmpty) return false;
    if (isValid(raw.trim(), organizationId)) return true;
    if (t.length == 6 && t == shortCode(organizationId).toUpperCase()) {
      return true;
    }
    // Yesterday's short code for late closes.
    if (t.length == 6 &&
        t ==
            shortCode(
              organizationId,
              day: DateTime.now().subtract(const Duration(days: 1)),
            ).toUpperCase()) {
      return true;
    }
    return false;
  }

  static String _digest(String organizationId, String dateKey) {
    final bytes = utf8.encode('$pepper|$organizationId|$dateKey');
    return sha256.convert(bytes).toString().substring(0, 10).toUpperCase();
  }
}
