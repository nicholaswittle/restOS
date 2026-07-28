import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'demo_backend.dart';

/// In-app notifications + smart route (push → SMS) via edge function.
///
/// Ported from Apex v1 NotificationService, pointed at `route-notification`
/// so SMS fallback is server-side.
class NotificationService {
  NotificationService._();

  static final _client = Supabase.instance.client;

  static String get _userId => DemoMode.enabled
      ? DemoMode.userId
      : (_client.auth.currentUser?.id ?? '');

  static Future<void> notifyUser({
    required String targetUserId,
    required String title,
    required String body,
    bool critical = false,
  }) async {
    try {
      if (DemoMode.enabled) {
        // Demo has no edge functions — write the in-app row shape only.
        return;
      }
      await _client.functions.invoke(
        'route-notification',
        body: {
          'target_user_id': targetUserId,
          'title': title,
          'body': body,
          'critical': critical,
        },
      );
    } catch (e, st) {
      debugPrint('Notification route skipped: $e');
      debugPrint('$st');
    }
  }

  static Future<int> unreadCount() async {
    final userId = _userId;
    if (userId.isEmpty) return 0;
    final rows = await _client
        .from('notifications')
        .select('id')
        .eq('user_id', userId)
        .isFilter('read_at', null);
    return (rows as List).length;
  }

  static Future<List<Map<String, dynamic>>> recent({int limit = 25}) async {
    final userId = _userId;
    if (userId.isEmpty) return [];
    final rows = await _client
        .from('notifications')
        .select('id, title, body, created_at, read_at')
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  static Future<void> markAllRead() async {
    final userId = _userId;
    if (userId.isEmpty) return;
    await _client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('user_id', userId)
        .isFilter('read_at', null);
  }
}
