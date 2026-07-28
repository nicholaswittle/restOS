/// Pure date/time helpers shared by Apex screens.
///
/// These are the same helpers proven in `employee_dashboard.dart`, lifted to a
/// shared library so feature screens can reuse one implementation instead of
/// each keeping a private copy (Dart privacy is per-library, so `_hoursBetween`
/// there cannot be imported).
///
/// Currently unused: `manager_log_book.dart` and `tip_management.dart` were
/// built in parallel with their own private copies. Kept as the dedupe target
/// if those screens are ever consolidated.
library;

import 'package:intl/intl.dart';

/// Combines a `yyyy-MM-dd` key with an `HH:mm`-ish time string.
DateTime? combineDateAndTime(String dateKey, String? timeRaw) {
  if (timeRaw == null) return null;
  final date = DateTime.tryParse(dateKey);
  if (date == null) return null;
  final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(timeRaw);
  if (m == null) return null;
  return DateTime(date.year, date.month, date.day,
      int.parse(m.group(1)!), int.parse(m.group(2)!));
}

/// Hours between two clock-face time strings (`'17:00'`, `'1:30 AM'`).
///
/// Used for *scheduled* shift times. An end at or before the start is treated
/// as an overnight shift and rolled to the next day.
double hoursBetween(String? start, String? end) {
  final s = combineDateAndTime('2000-01-01', start);
  var e = combineDateAndTime('2000-01-01', end);
  if (s == null || e == null) return 0;
  if (!e.isAfter(s)) e = e.add(const Duration(days: 1)); // overnight
  return e.difference(s).inMinutes / 60.0;
}

/// Hours between two absolute timestamps (`time_entries.clock_in/out`).
///
/// Deliberately *not* [hoursBetween]: clock punches are full timestamps, and
/// parsing them as clock-face strings would discard the date. A punch left open
/// across days would then read as a couple of hours instead of the real elapsed
/// time — a payroll and tip-split error. Returns 0 for a missing or reversed
/// pair rather than inventing hours.
double hoursBetweenTimestamps(String? clockIn, String? clockOut) {
  if (clockIn == null || clockOut == null) return 0;
  final s = DateTime.tryParse(clockIn);
  final e = DateTime.tryParse(clockOut);
  if (s == null || e == null) return 0;
  final minutes = e.difference(s).inMinutes;
  if (minutes <= 0) return 0;
  return minutes / 60.0;
}

/// `5:30 PM` from `'17:30'`.
String formatTime(String? raw) {
  final dt = combineDateAndTime('2000-01-01', raw);
  if (dt == null) return raw ?? '';
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:${dt.minute.toString().padLeft(2, '0')} $ampm';
}

/// `Today` / `Yesterday` / `Tomorrow`, else `Tue, Jul 27`.
String formatDayLabel(String dateKey) {
  final d = DateTime.tryParse(dateKey);
  if (d == null) return dateKey;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(d.year, d.month, d.day);
  final diff = target.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  return DateFormat('EEE, MMM d').format(d);
}

/// `just now` / `12m ago` / `3h ago` / `Jul 27`.
String relativeTime(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return DateFormat('MMM d').format(t);
}

/// `yyyy-MM-dd` key used by `shift_date` columns.
String dateKeyOf(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

/// Local-day bounds as UTC ISO strings, for filtering `timestamptz` columns.
///
/// Built from the venue's local midnight so a day boundary means the same thing
/// to staff as it does to the query.
({String startUtc, String endUtc}) localDayBoundsUtc(DateTime day) {
  final start = DateTime(day.year, day.month, day.day);
  final end = start.add(const Duration(days: 1));
  return (
    startUtc: start.toUtc().toIso8601String(),
    endUtc: end.toUtc().toIso8601String(),
  );
}

/// `$12.50` from cents.
String formatCents(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

/// Hours rendered without a trailing `.0`.
String formatHours(double h) =>
    h == h.roundToDouble() ? h.toStringAsFixed(0) : h.toStringAsFixed(1);
