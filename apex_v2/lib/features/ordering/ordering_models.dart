/// Shared cart + money helpers for the ordering module.
library;

import 'dart:math';

String formatCents(int cents) {
  final dollars = cents / 100;
  return '\$${dollars.toStringAsFixed(2)}';
}

/// UUID v4 without adding a package dependency.
String newUuid() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// One selected modifier option on a cart line.
class CartModifier {
  const CartModifier({
    required this.optionId,
    required this.groupName,
    required this.name,
    required this.priceDeltaCents,
  });

  final String optionId;
  final String groupName;
  final String name;
  final int priceDeltaCents;
}

/// A cart line. Customized items get a unique [lineKey] so two crusts of the
/// same pizza stay separate instead of merging quantities incorrectly.
class CartEntry {
  CartEntry({
    required this.menuItemId,
    required this.name,
    required this.unitPriceCents,
    required this.quantity,
    required this.modifiers,
    required this.lineKey,
  });

  final String menuItemId;
  final String name;
  final int unitPriceCents;
  int quantity;
  final List<CartModifier> modifiers;
  final String lineKey;

  int get lineTotalCents {
    final delta = modifiers.fold<int>(0, (s, m) => s + m.priceDeltaCents);
    return (unitPriceCents + delta) * quantity;
  }

  static String buildKey(String menuItemId, List<CartModifier> mods) {
    final ids = mods.map((m) => m.optionId).toList()..sort();
    return '$menuItemId|${ids.join(',')}';
  }
}

class RestaurantSettingsData {
  const RestaurantSettingsData({
    required this.restaurantId,
    required this.organizationId,
    required this.paused,
    required this.prepMinutes,
    required this.feeCents,
    required this.taxRate,
    required this.paymentMode,
    this.maxOrdersPerHour = 15,
    this.autoPauseEnabled = true,
    this.autoPauseThreshold = 1,
  });

  final String restaurantId;
  final String organizationId;
  final bool paused;
  final int prepMinutes;
  final int feeCents;
  final double taxRate;
  final String paymentMode;
  final int maxOrdersPerHour;
  final bool autoPauseEnabled;
  final int autoPauseThreshold;

  factory RestaurantSettingsData.fromMap(Map<String, dynamic> m) {
    return RestaurantSettingsData(
      restaurantId: m['restaurant_id'] as String? ?? '',
      organizationId: m['organization_id'] as String? ?? '',
      paused: m['paused'] as bool? ?? false,
      prepMinutes: (m['prep_minutes'] as num?)?.toInt() ?? 30,
      feeCents: (m['fee_cents'] as num?)?.toInt() ?? 0,
      taxRate: (m['tax_rate'] as num?)?.toDouble() ?? 0.06,
      paymentMode: m['payment_mode'] as String? ?? 'manual',
      maxOrdersPerHour: (m['max_orders_per_hour'] as num?)?.toInt() ?? 15,
      autoPauseEnabled: m['auto_pause_enabled'] as bool? ?? true,
      autoPauseThreshold: (m['auto_pause_threshold'] as num?)?.toInt() ?? 1,
    );
  }

  int taxCents(int subtotalCents) => (subtotalCents * taxRate).round();

  int totalCents(int subtotalCents) =>
      subtotalCents + feeCents + taxCents(subtotalCents);
}
