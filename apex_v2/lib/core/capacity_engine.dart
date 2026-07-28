import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/ordering/ordering_models.dart';

/// Decides whether ordering should be open, paused, or warning customers.
///
/// Capacity = staff clocked in right now × max_orders_per_hour.
/// If staff < auto_pause_threshold and auto_pause is on → pause.
/// If orders in the last hour >= capacity → warn (longer wait).
class CapacityEngine {
  CapacityEngine(this._client);

  final SupabaseClient _client;

  /// Returns the current capacity status for a restaurant.
  Future<CapacityStatus> check({
    required String organizationId,
    required String restaurantId,
  }) async {
    final results = await Future.wait<dynamic>([
      _client
          .from('restaurant_settings')
          .select()
          .eq('restaurant_id', restaurantId)
          .maybeSingle(),
      _client
          .from('time_entries')
          .select('user_id')
          .eq('organization_id', organizationId)
          .isFilter('clock_out', null),
      _client
          .from('online_orders')
          .select('id')
          .eq('organization_id', organizationId)
          .eq('status', 'waiting')
          .gte('submitted_at',
              DateTime.now().subtract(const Duration(hours: 1)).toUtc().toIso8601String()),
    ]);

    final settings = results[0] == null
        ? null
        : RestaurantSettingsData.fromMap(results[0] as Map<String, dynamic>);

    if (settings == null) {
      return const CapacityStatus(
        staffOnShift: 0,
        ordersLastHour: 0,
        maxCapacity: 0,
        state: CapacityState.unknown,
      );
    }

    final staffOnShift = (results[1] as List).length;
    final ordersLastHour = (results[2] as List).length;
    final maxCapacity = staffOnShift * settings.maxOrdersPerHour;

    CapacityState state;
    if (settings.autoPauseEnabled &&
        staffOnShift < settings.autoPauseThreshold) {
      state = CapacityState.autoPaused;
    } else if (settings.paused) {
      state = CapacityState.manuallyPaused;
    } else if (ordersLastHour >= maxCapacity && maxCapacity > 0) {
      state = CapacityState.atCapacity;
    } else if (maxCapacity > 0 &&
        ordersLastHour >= (maxCapacity * 0.8).round()) {
      state = CapacityState.nearCapacity;
    } else {
      state = CapacityState.open;
    }

    return CapacityStatus(
      staffOnShift: staffOnShift,
      ordersLastHour: ordersLastHour,
      maxCapacity: maxCapacity,
      state: state,
    );
  }

  /// Auto-pause or auto-resume ordering based on staff count.
  /// Returns the action taken (or null if no change needed).
  Future<String?> autoAdjust({
    required String organizationId,
    required String restaurantId,
  }) async {
    final status = await check(
      organizationId: organizationId,
      restaurantId: restaurantId,
    );

    final settingsRow = await _client
        .from('restaurant_settings')
        .select('paused, auto_pause_enabled, auto_pause_threshold')
        .eq('restaurant_id', restaurantId)
        .maybeSingle();
    if (settingsRow == null) return null;

    final isPaused = settingsRow['paused'] as bool? ?? false;
    final autoEnabled = settingsRow['auto_pause_enabled'] as bool? ?? true;
    final threshold = (settingsRow['auto_pause_threshold'] as num?)?.toInt() ?? 1;

    if (!autoEnabled) return null;

    if (status.staffOnShift < threshold && !isPaused) {
      await _client
          .from('restaurant_settings')
          .update({'paused': true})
          .eq('restaurant_id', restaurantId);
      await _logEvent(
        organizationId: organizationId,
        restaurantId: restaurantId,
        event: 'auto_pause',
        status: status,
        detail: 'Staff on shift (${status.staffOnShift}) below threshold ($threshold)',
      );
      return 'auto_paused';
    }

    if (status.staffOnShift >= threshold && isPaused) {
      // Only auto-resume if the pause was automatic, not manual.
      // Check last capacity_event to see if it was auto_pause.
      final lastEvent = await _client
          .from('capacity_events')
          .select('event')
          .eq('restaurant_id', restaurantId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final lastWasAuto = lastEvent?['event'] == 'auto_pause';
      if (lastWasAuto) {
        await _client
            .from('restaurant_settings')
            .update({'paused': false})
            .eq('restaurant_id', restaurantId);
        await _logEvent(
          organizationId: organizationId,
          restaurantId: restaurantId,
          event: 'auto_resume',
          status: status,
          detail: 'Staff on shift (${status.staffOnShift}) meets threshold ($threshold)',
        );
        return 'auto_resumed';
      }
    }

    return null;
  }

  Future<void> _logEvent({
    required String organizationId,
    required String restaurantId,
    required String event,
    required CapacityStatus status,
    String? detail,
  }) async {
    await _client.from('capacity_events').insert({
      'organization_id': organizationId,
      'restaurant_id': restaurantId,
      'event': event,
      'staff_on_shift': status.staffOnShift,
      'orders_last_hour': status.ordersLastHour,
      'max_capacity': status.maxCapacity,
      'detail': detail,
    });
  }
}

enum CapacityState {
  open,
  nearCapacity,
  atCapacity,
  autoPaused,
  manuallyPaused,
  unknown,
}

class CapacityStatus {
  const CapacityStatus({
    required this.staffOnShift,
    required this.ordersLastHour,
    required this.maxCapacity,
    required this.state,
  });

  final int staffOnShift;
  final int ordersLastHour;
  final int maxCapacity;
  final CapacityState state;

  bool get acceptingOrders =>
      state == CapacityState.open || state == CapacityState.nearCapacity;

  bool get paused =>
      state == CapacityState.autoPaused ||
      state == CapacityState.manuallyPaused;

  String get customerMessage {
    switch (state) {
      case CapacityState.open:
        return '';
      case CapacityState.nearCapacity:
        return 'High demand — expect a slightly longer wait.';
      case CapacityState.atCapacity:
        return 'Kitchen is at capacity — new orders will have a longer wait.';
      case CapacityState.autoPaused:
        return 'Kitchen is short-staffed. Ordering will reopen when more staff arrive.';
      case CapacityState.manuallyPaused:
        return 'The kitchen paused online orders. Please try again shortly.';
      case CapacityState.unknown:
        return 'Checking kitchen status…';
    }
  }

  String get staffLabel {
    switch (state) {
      case CapacityState.open:
        return '$staffOnShift on shift · $ordersLastHour/$maxCapacity orders';
      case CapacityState.nearCapacity:
        return '$staffOnShift on shift · $ordersLastHour/$maxCapacity — near limit';
      case CapacityState.atCapacity:
        return '$staffOnShift on shift · $ordersLastHour/$maxCapacity — at capacity';
      case CapacityState.autoPaused:
        return 'Auto-paused — $staffOnShift on shift (need more staff)';
      case CapacityState.manuallyPaused:
        return 'Manually paused — $staffOnShift on shift';
      case CapacityState.unknown:
        return 'Status unknown';
    }
  }
}