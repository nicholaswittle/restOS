/// Typed models for the no-show call-out engine.
library;

import 'package:intl/intl.dart';

class CallOutData {
  const CallOutData({
    required this.id,
    required this.organizationId,
    required this.shiftId,
    required this.shiftDate,
    required this.startTime,
    required this.endTime,
    required this.staffName,
    required this.staffUserId,
    required this.staffRole,
    required this.reason,
    required this.status,
    required this.filledBy,
    required this.filledByUserId,
    required this.createdAt,
    required this.filledAt,
    required this.expiresAt,
  });

  final String id;
  final String organizationId;
  final String? shiftId;
  final String shiftDate;
  final String? startTime;
  final String? endTime;
  final String staffName;
  final String? staffUserId;
  final String? staffRole;
  final String? reason;
  final String status;
  final String? filledBy;
  final String? filledByUserId;
  final DateTime createdAt;
  final DateTime? filledAt;
  final DateTime? expiresAt;

  bool get isOpen => status == 'open';

  String get hoursLabel {
    final s = startTime;
    final e = endTime;
    if (s == null || e == null || s.isEmpty || e.isEmpty) return 'Hours TBD';
    return '$s – $e';
  }

  String get dayLabel {
    final d = DateTime.tryParse(shiftDate);
    if (d == null) return shiftDate;
    return DateFormat('EEE, MMM d').format(d);
  }

  factory CallOutData.fromMap(Map<String, dynamic> m) {
    return CallOutData(
      id: m['id'] as String,
      organizationId: m['organization_id'] as String? ?? '',
      shiftId: m['shift_id'] as String?,
      shiftDate: m['shift_date'] as String? ?? '',
      startTime: m['start_time'] as String?,
      endTime: m['end_time'] as String?,
      staffName: m['staff_name'] as String? ?? '',
      staffUserId: m['staff_user_id'] as String?,
      staffRole: m['staff_role'] as String?,
      reason: m['reason'] as String?,
      status: m['status'] as String? ?? 'open',
      filledBy: m['filled_by'] as String?,
      filledByUserId: m['filled_by_user_id'] as String?,
      createdAt: DateTime.tryParse(m['created_at'] as String? ?? '') ??
          DateTime.now(),
      filledAt: DateTime.tryParse(m['filled_at'] as String? ?? ''),
      expiresAt: DateTime.tryParse(m['expires_at'] as String? ?? ''),
    );
  }
}

class CallOutNotificationData {
  const CallOutNotificationData({
    required this.id,
    required this.callOutId,
    required this.userId,
    required this.staffName,
    required this.phone,
    required this.notifiedAt,
    required this.respondedAt,
    required this.response,
  });

  final String id;
  final String callOutId;
  final String userId;
  final String staffName;
  final String? phone;
  final DateTime notifiedAt;
  final DateTime? respondedAt;
  final String? response;

  factory CallOutNotificationData.fromMap(Map<String, dynamic> m) {
    return CallOutNotificationData(
      id: m['id'] as String,
      callOutId: m['call_out_id'] as String? ?? '',
      userId: m['user_id'] as String? ?? '',
      staffName: m['staff_name'] as String? ?? '',
      phone: m['phone'] as String?,
      notifiedAt: DateTime.tryParse(m['notified_at'] as String? ?? '') ??
          DateTime.now(),
      respondedAt: DateTime.tryParse(m['responded_at'] as String? ?? ''),
      response: m['response'] as String?,
    );
  }
}

/// A shift the signed-in user could call out from (next 7 days).
class ShiftOption {
  const ShiftOption({
    required this.id,
    required this.shiftDate,
    required this.startTime,
    required this.endTime,
    required this.role,
    required this.staff,
  });

  final String id;
  final String shiftDate;
  final String? startTime;
  final String? endTime;
  final String? role;
  final String staff;

  String get label {
    final d = DateTime.tryParse(shiftDate);
    final day = d == null
        ? shiftDate
        : DateFormat('EEE, MMM d').format(d);
    final hours = (startTime != null && endTime != null)
        ? '$startTime – $endTime'
        : 'Hours TBD';
    return '$day · $hours';
  }

  factory ShiftOption.fromMap(Map<String, dynamic> m) {
    return ShiftOption(
      id: m['id'] as String,
      shiftDate: m['shift_date'] as String? ?? '',
      startTime: m['start_time'] as String?,
      endTime: m['end_time'] as String?,
      role: m['role'] as String?,
      staff: m['staff'] as String? ?? '',
    );
  }
}
