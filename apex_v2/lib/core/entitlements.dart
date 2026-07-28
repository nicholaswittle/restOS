/// Which parts of the Restaurant OS a venue can actually see.
///
/// Apex is sold two ways: a tier (Free / Pro / OS / Multi), or individual
/// pieces plugged into a venue that does not want the whole system. Both are
/// expressed here — a tier grants a baseline set of [OsModule]s, and per-org
/// `enabled_modules` / `disabled_modules` adjust that set either direction.
///
/// Screens should never hardcode a tier check. Ask
/// `entitlements.has(OsModule.tips)` so the answer stays in one place when
/// pricing changes.
library;

/// A pluggable piece of the OS.
enum OsModule {
  // Free — the wedge. Enough to be genuinely useful and become their tech.
  scheduling,
  shiftSwaps,
  timeClock,
  pushNotifications,

  // Pro ($25/mo) — the pieces competitors charge $15–70/mo extra for.
  managerLogBook,
  tipManagement,
  laborCost,
  offlineMode,
  teamChat,

  // OS ($99/mo) — scheduling and ordering in one system. Nobody else does this.
  onlineOrdering,
  smartCapacity,
  noShowEngine,
  laborVsRevenue,

  // Multi ($199/mo)
  multiLocation,
}

/// Pricing tier. Ordered cheapest to richest; each inherits everything below it.
enum OsTier {
  free,
  pro,
  os,
  multi;

  static OsTier parse(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'pro':
        return OsTier.pro;
      case 'os':
        return OsTier.os;
      case 'multi':
      case 'multi_location':
        return OsTier.multi;
      default:
        return OsTier.free;
    }
  }

  String get label => switch (this) {
        OsTier.free => 'Free',
        OsTier.pro => 'Pro',
        OsTier.os => 'Restaurant OS',
        OsTier.multi => 'Multi-Location',
      };

  /// Monthly price in cents. Display only — billing is not wired up.
  int get priceCents => switch (this) {
        OsTier.free => 0,
        OsTier.pro => 2500,
        OsTier.os => 9900,
        OsTier.multi => 19900,
      };
}

/// What each tier adds on top of the one before it.
const Map<OsTier, Set<OsModule>> _tierGrants = {
  OsTier.free: {
    OsModule.scheduling,
    OsModule.shiftSwaps,
    OsModule.timeClock,
    OsModule.pushNotifications,
  },
  OsTier.pro: {
    OsModule.managerLogBook,
    OsModule.tipManagement,
    OsModule.laborCost,
    OsModule.offlineMode,
    OsModule.teamChat,
  },
  OsTier.os: {
    OsModule.onlineOrdering,
    OsModule.smartCapacity,
    OsModule.noShowEngine,
    OsModule.laborVsRevenue,
  },
  OsTier.multi: {
    OsModule.multiLocation,
  },
};

/// The modules a venue can use right now.
class Entitlements {
  const Entitlements({
    required this.tier,
    this.extraModules = const {},
    this.blockedModules = const {},
  });

  final OsTier tier;

  /// Plugged in beyond the tier — how a venue buys one piece without the rest.
  final Set<OsModule> extraModules;

  /// Switched off despite the tier granting it (trial ended, venue opted out).
  /// Takes precedence over everything, so revoking access is never ambiguous.
  final Set<OsModule> blockedModules;

  /// Everything below the free tier only — used when a venue record is missing.
  static const Entitlements none = Entitlements(tier: OsTier.free);

  /// Builds from an `organizations` row.
  factory Entitlements.fromMap(Map<String, dynamic>? m) {
    if (m == null) return none;
    return Entitlements(
      tier: OsTier.parse(m['tier'] as String?),
      extraModules: _parseModules(m['enabled_modules']),
      blockedModules: _parseModules(m['disabled_modules']),
    );
  }

  Set<OsModule> get modules {
    final granted = <OsModule>{};
    for (final t in OsTier.values) {
      granted.addAll(_tierGrants[t] ?? const {});
      if (t == tier) break;
    }
    granted.addAll(extraModules);
    return granted.difference(blockedModules);
  }

  bool has(OsModule m) => modules.contains(m);

  /// True when the module exists but this venue has not bought it — the cue to
  /// show an upsell rather than hide the feature entirely.
  bool isUpsell(OsModule m) => !has(m) && !blockedModules.contains(m);

  /// The cheapest tier that includes [m], for upsell copy.
  OsTier? tierFor(OsModule m) {
    for (final t in OsTier.values) {
      if ((_tierGrants[t] ?? const {}).contains(m)) return t;
    }
    return null;
  }
}

Set<OsModule> _parseModules(dynamic raw) {
  if (raw is! List) return const {};
  final byName = {for (final m in OsModule.values) m.name.toLowerCase(): m};
  return {
    for (final v in raw)
      if (v is String && byName.containsKey(v.trim().toLowerCase()))
        byName[v.trim().toLowerCase()]!,
  };
}

/// Role hierarchy from the build plan. Manager and owner satisfy anything below.
enum StaffRole {
  owner,
  manager,
  server,
  kitchen,
  readonly;

  static StaffRole parse(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'owner':
        return StaffRole.owner;
      case 'manager':
        return StaffRole.manager;
      case 'kitchen':
        return StaffRole.kitchen;
      case 'readonly':
      case 'read_only':
        return StaffRole.readonly;
      default:
        return StaffRole.server;
    }
  }

  /// Mirrors the SQL `has_role()` helper — keep the two in step.
  bool get canManage => this == StaffRole.owner || this == StaffRole.manager;
}
