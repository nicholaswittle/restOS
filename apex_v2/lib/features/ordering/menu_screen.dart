import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cart_screen.dart';
import 'ordering_models.dart';

/// Customer-facing menu. Works with [organizationId] (staff preview) or
/// [publicToken] (walk-up customer — no auth required).
class MenuScreen extends StatefulWidget {
  const MenuScreen({
    super.key,
    this.organizationId,
    this.publicToken,
  }) : assert(
          organizationId != null || publicToken != null,
          'Provide organizationId or publicToken',
        );

  final String? organizationId;
  final String? publicToken;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  String _restaurantId = '';
  String _organizationId = '';
  String _restaurantName = '';
  RestaurantSettingsData? _settings;
  List<_MenuCategory> _categories = const [];
  List<_MenuItem> _items = const [];
  final Map<String, List<_ModifierGroup>> _groupsByItem = {};
  final List<CartEntry> _cart = [];

  final _subs = <StreamSubscription<dynamic>>[];

  int get _cartCount => _cart.fold(0, (s, e) => s + e.quantity);

  @override
  void initState() {
    super.initState();
    _load().then((_) => _subscribeRealtime());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _subscribeRealtime() {
    if (_organizationId.isEmpty) return;
    _subs.add(
      _client
          .from('menu_items')
          .stream(primaryKey: ['id'])
          .eq('organization_id', _organizationId)
          .listen((_) => _load(quiet: true)),
    );
    _subs.add(
      _client
          .from('restaurant_settings')
          .stream(primaryKey: ['restaurant_id'])
          .eq('organization_id', _organizationId)
          .listen((_) => _load(quiet: true)),
    );
  }

  Future<void> _load({bool quiet = false}) async {
    if (!mounted) return;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      Map<String, dynamic>? restaurant;
      if (widget.publicToken != null) {
        restaurant = await _client
            .from('restaurants')
            .select('id, organization_id, name, public_token')
            .eq('public_token', widget.publicToken!)
            .maybeSingle();
      } else {
        restaurant = await _client
            .from('restaurants')
            .select('id, organization_id, name, public_token')
            .eq('organization_id', widget.organizationId!)
            .maybeSingle();
      }

      if (restaurant == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Restaurant not found.';
        });
        return;
      }

      final restId = restaurant['id'] as String;
      final orgId = restaurant['organization_id'] as String;

      final results = await Future.wait<dynamic>([
        _client
            .from('restaurant_settings')
            .select()
            .eq('restaurant_id', restId)
            .eq('organization_id', orgId)
            .maybeSingle(),
        _client
            .from('menu_categories')
            .select()
            .eq('restaurant_id', restId)
            .eq('organization_id', orgId)
            .order('sort_order'),
        _client
            .from('menu_items')
            .select()
            .eq('restaurant_id', restId)
            .eq('organization_id', orgId)
            .order('sort_order'),
        _client
            .from('modifier_groups')
            .select()
            .eq('organization_id', orgId),
        _client
            .from('modifier_options')
            .select()
            .eq('organization_id', orgId),
      ]);

      final settingsRow = results[0] as Map<String, dynamic>?;
      final catRows = (results[1] as List).cast<Map<String, dynamic>>();
      final itemRows = (results[2] as List).cast<Map<String, dynamic>>();
      final groupRows = (results[3] as List).cast<Map<String, dynamic>>();
      final optionRows = (results[4] as List).cast<Map<String, dynamic>>();

      final optionsByGroup = <String, List<_ModifierOption>>{};
      for (final o in optionRows) {
        final opt = _ModifierOption.fromMap(o);
        optionsByGroup.putIfAbsent(opt.groupId, () => []).add(opt);
      }

      final groupsByItem = <String, List<_ModifierGroup>>{};
      for (final g in groupRows) {
        final itemId = g['menu_item_id'] as String?;
        if (itemId == null) continue;
        final group = _ModifierGroup.fromMap(g, optionsByGroup[g['id']] ?? const []);
        groupsByItem.putIfAbsent(itemId, () => []).add(group);
      }

      if (!mounted) return;
      setState(() {
        _restaurantId = restId;
        _organizationId = orgId;
        _restaurantName = restaurant!['name'] as String? ?? 'Menu';
        _settings = settingsRow == null
            ? null
            : RestaurantSettingsData.fromMap(settingsRow);
        _categories = catRows.map(_MenuCategory.fromMap).toList();
        _items = itemRows.map(_MenuItem.fromMap).toList();
        _groupsByItem
          ..clear()
          ..addAll(groupsByItem);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the menu. Check your connection.';
      });
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _onTapItem(_MenuItem item) async {
    if (_settings?.paused == true) {
      _snack('Ordering is temporarily unavailable.');
      return;
    }
    if (!item.available) {
      _snack('${item.name} is sold out right now.');
      return;
    }

    final groups = _groupsByItem[item.id] ?? const [];
    if (groups.isEmpty) {
      _addToCart(item, const []);
      return;
    }

    final selected = await showModalBottomSheet<List<CartModifier>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _ModifierSheet(item: item, groups: groups),
    );
    if (selected == null) return;
    _addToCart(item, selected);
  }

  void _addToCart(_MenuItem item, List<CartModifier> mods) {
    final key = CartEntry.buildKey(item.id, mods);
    final existing = _cart.indexWhere((e) => e.lineKey == key);
    setState(() {
      if (existing >= 0) {
        _cart[existing].quantity += 1;
      } else {
        _cart.add(CartEntry(
          menuItemId: item.id,
          name: item.name,
          unitPriceCents: item.priceCents,
          quantity: 1,
          modifiers: mods,
          lineKey: key,
        ));
      }
    });
    final label = mods.isEmpty
        ? item.name
        : '${item.name} (${mods.map((m) => m.name).join(', ')})';
    _snack('Added $label');
  }

  Future<void> _openCart() async {
    final settings = _settings;
    if (settings == null) return;
    final updated = await Navigator.of(context).push<List<CartEntry>>(
      MaterialPageRoute(
        builder: (_) => CartScreen(
          restaurantId: _restaurantId,
          organizationId: _organizationId,
          restaurantName: _restaurantName,
          settings: settings,
          cart: List<CartEntry>.from(_cart.map((e) => CartEntry(
                menuItemId: e.menuItemId,
                name: e.name,
                unitPriceCents: e.unitPriceCents,
                quantity: e.quantity,
                modifiers: List.from(e.modifiers),
                lineKey: e.lineKey,
              ))),
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() {
        _cart
          ..clear()
          ..addAll(updated);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(
        body: _ErrorView(message: _error!, onRetry: _load),
      );
    }

    final paused = _settings?.paused == true;

    return Scaffold(
      appBar: AppBar(
        title: Text(_restaurantName),
        actions: [
          IconButton(
            tooltip: 'Cart',
            onPressed: _cart.isEmpty || paused ? null : _openCart,
            icon: Badge(
              isLabelVisible: _cartCount > 0,
              label: Text('$_cartCount'),
              child: const Icon(Icons.shopping_bag_outlined),
            ),
          ),
        ],
      ),
      body: paused
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.pause_circle_outline_rounded,
                      size: 48, color: cs.onSurface.withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  Text(
                    'Ordering temporarily unavailable',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The kitchen paused online orders. Please try again shortly.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.65),
                        ),
                  ),
                ]),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                itemCount: _categories.length,
                itemBuilder: (context, i) {
                  final cat = _categories[i];
                  final items = _items
                      .where((it) => it.categoryId == cat.id)
                      .toList();
                  if (items.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 16, bottom: 10),
                        child: Text(
                          cat.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      for (final item in items)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _MenuItemCard(
                            item: item,
                            hasModifiers:
                                (_groupsByItem[item.id] ?? const []).isNotEmpty,
                            onTap: () => _onTapItem(item),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
      floatingActionButton: _cart.isEmpty || paused
          ? null
          : FloatingActionButton.extended(
              onPressed: _openCart,
              icon: Badge(
                isLabelVisible: _cartCount > 0,
                label: Text('$_cartCount'),
                child: const Icon(Icons.shopping_bag_outlined),
              ),
              label: Text('Cart · ${formatCents(_cart.fold(0, (s, e) => s + e.lineTotalCents))}'),
            ),
    );
  }
}

class _MenuCategory {
  const _MenuCategory({
    required this.id,
    required this.name,
    required this.sortOrder,
  });

  final String id;
  final String name;
  final int sortOrder;

  factory _MenuCategory.fromMap(Map<String, dynamic> m) => _MenuCategory(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
      );
}

class _MenuItem {
  const _MenuItem({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.description,
    required this.priceCents,
    required this.available,
  });

  final String id;
  final String categoryId;
  final String name;
  final String description;
  final int priceCents;
  final bool available;

  factory _MenuItem.fromMap(Map<String, dynamic> m) => _MenuItem(
        id: m['id'] as String,
        categoryId: m['category_id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        description: m['description'] as String? ?? '',
        priceCents: (m['price_cents'] as num?)?.toInt() ?? 0,
        available: m['available'] as bool? ?? true,
      );
}

class _ModifierGroup {
  const _ModifierGroup({
    required this.id,
    required this.name,
    required this.required,
    required this.minSelect,
    required this.maxSelect,
    required this.options,
  });

  final String id;
  final String name;
  final bool required;
  final int minSelect;
  final int maxSelect;
  final List<_ModifierOption> options;

  factory _ModifierGroup.fromMap(
    Map<String, dynamic> m,
    List<_ModifierOption> options,
  ) =>
      _ModifierGroup(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        required: m['required'] as bool? ?? false,
        minSelect: (m['min_select'] as num?)?.toInt() ?? 0,
        maxSelect: (m['max_select'] as num?)?.toInt() ?? 1,
        options: options,
      );
}

class _ModifierOption {
  const _ModifierOption({
    required this.id,
    required this.groupId,
    required this.name,
    required this.priceDeltaCents,
  });

  final String id;
  final String groupId;
  final String name;
  final int priceDeltaCents;

  factory _ModifierOption.fromMap(Map<String, dynamic> m) => _ModifierOption(
        id: m['id'] as String,
        groupId: m['modifier_group_id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        priceDeltaCents: (m['price_delta_cents'] as num?)?.toInt() ?? 0,
      );
}

class _ModifierSheet extends StatefulWidget {
  const _ModifierSheet({required this.item, required this.groups});

  final _MenuItem item;
  final List<_ModifierGroup> groups;

  @override
  State<_ModifierSheet> createState() => _ModifierSheetState();
}

class _ModifierSheetState extends State<_ModifierSheet> {
  late final Map<String, String> _picked;

  @override
  void initState() {
    super.initState();
    _picked = {
      for (final g in widget.groups)
        if (g.options.isNotEmpty) g.id: g.options.first.id,
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.item.name,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(formatCents(widget.item.priceCents),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: cs.primary,
                  )),
          const SizedBox(height: 16),
          for (final g in widget.groups) ...[
            Text(g.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final o in g.options)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: _picked[g.id] == o.id
                      ? cs.primary.withValues(alpha: 0.15)
                      : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => _picked[g.id] = o.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      child: Row(
                        children: [
                          Icon(
                            _picked[g.id] == o.id
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: cs.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(o.name)),
                          if (o.priceDeltaCents != 0)
                            Text(
                              '+${formatCents(o.priceDeltaCents)}',
                              style: TextStyle(
                                  color: cs.onSurface.withValues(alpha: 0.6)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              final mods = <CartModifier>[];
              for (final g in widget.groups) {
                final optId = _picked[g.id];
                if (optId == null) continue;
                final opt = g.options.firstWhere((o) => o.id == optId);
                mods.add(CartModifier(
                  optionId: opt.id,
                  groupName: g.name,
                  name: opt.name,
                  priceDeltaCents: opt.priceDeltaCents,
                ));
              }
              Navigator.pop(context, mods);
            },
            child: Text('Add to cart · ${formatCents(widget.item.priceCents)}'),
          ),
        ],
      ),
    );
  }
}

class _MenuItemCard extends StatelessWidget {
  const _MenuItemCard({
    required this.item,
    required this.hasModifiers,
    required this.onTap,
  });

  final _MenuItem item;
  final bool hasModifiers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = !item.available;
    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: muted ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: muted
                                ? cs.onSurface.withValues(alpha: 0.4)
                                : null,
                          ),
                    ),
                    if (item.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.description,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      muted ? 'Sold out' : formatCents(item.priceCents),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: muted ? cs.error : cs.primary,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: muted ? null : onTap,
                child: Text(hasModifiers ? 'Customize' : 'Add'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SkeletonBox(width: 180, height: 28, color: cs.surfaceContainerHigh),
          const SizedBox(height: 20),
          _SkeletonBox(
              width: double.infinity, height: 96, color: cs.surfaceContainerHigh),
          const SizedBox(height: 12),
          _SkeletonBox(
              width: double.infinity, height: 96, color: cs.surfaceContainerHigh),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    required this.color,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.wifi_off_rounded,
              size: 44, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ]),
      ),
    );
  }
}
