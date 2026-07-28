import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Staff 86 / restock controls — same `menu_items.available` source as staff.html.
class MenuStockScreen extends StatefulWidget {
  const MenuStockScreen({
    super.key,
    required this.organizationId,
  });

  final String organizationId;

  @override
  State<MenuStockScreen> createState() => _MenuStockScreenState();
}

class _MenuStockScreenState extends State<MenuStockScreen> {
  final _client = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  String _restaurantId = '';
  List<_Cat> _categories = const [];
  List<_Item> _items = const [];
  String? _activeCategoryId;
  bool _busy = false;

  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load().then((_) => _subscribe());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _subscribe() {
    if (_restaurantId.isEmpty) return;
    _subs.add(
      _client
          .from('menu_items')
          .stream(primaryKey: ['id'])
          .eq('restaurant_id', _restaurantId)
          .listen((_) => _load(quiet: true)),
    );
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rest = await _client
          .from('restaurants')
          .select('id, name')
          .eq('organization_id', widget.organizationId)
          .limit(1)
          .maybeSingle();
      if (rest == null) throw Exception('restaurant_not_found');
      _restaurantId = rest['id'] as String;

      final results = await Future.wait([
        _client
            .from('menu_categories')
            .select('id, name, sort_order')
            .eq('restaurant_id', _restaurantId)
            .order('sort_order'),
        _client
            .from('menu_items')
            .select('id, category_id, name, description, available, sort_order')
            .eq('restaurant_id', _restaurantId)
            .order('sort_order'),
      ]);

      final cats = (results[0] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(_Cat.fromMap)
          .toList();
      final items = (results[1] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(_Item.fromMap)
          .toList();

      if (!mounted) return;
      setState(() {
        _categories = cats;
        _items = items;
        if (_activeCategoryId == null ||
            !cats.any((c) => c.id == _activeCategoryId)) {
          _activeCategoryId = cats.isEmpty ? null : cats.first.id;
        }
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!quiet) _error = e.toString();
      });
    }
  }

  Future<void> _toggle(_Item item) async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = !item.available;
    try {
      await _client.rpc(
        'apex_set_menu_item_available',
        params: {
          'p_item_id': item.id,
          'p_available': next,
        },
      );
      if (!mounted) return;
      setState(() {
        _items = [
          for (final i in _items)
            if (i.id == item.id) i.copyWith(available: next) else i,
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            next
                ? '${item.name} available again'
                : '${item.name} marked sold out',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Menu availability')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Menu availability')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }

    final activeItems = _items
        .where((i) => i.categoryId == _activeCategoryId)
        .toList();
    final sectionAvail =
        activeItems.where((i) => i.available).length;
    final totalAvail = _items.where((i) => i.available).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Menu availability'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : () => _load(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Tap an item to mark sold out or back in stock. Same as staff.html — guests cannot add sold-out items.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Material(
              color: cs.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Text(
                  '$sectionAvail of ${activeItems.length} in section · '
                  '$totalAvail/${_items.length} available',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final cat = _categories[i];
                final selected = cat.id == _activeCategoryId;
                return FilterChip(
                  selected: selected,
                  label: Text(cat.name),
                  onSelected: (_) =>
                      setState(() => _activeCategoryId = cat.id),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: activeItems.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 80),
                        Center(child: Text('No items in this section.')),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      itemCount: activeItems.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final item = activeItems[i];
                        final sold = !item.available;
                        return Material(
                          color: sold
                              ? cs.errorContainer.withValues(alpha: 0.35)
                              : cs.surfaceContainer,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: _busy ? null : () => _toggle(item),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.name,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall,
                                        ),
                                        if (item.description.isNotEmpty) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            item.description,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: cs.onSurface
                                                      .withValues(alpha: 0.6),
                                                ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: sold
                                          ? cs.error.withValues(alpha: 0.15)
                                          : cs.primary.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      sold ? 'ORDERING OFF' : 'AVAILABLE',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w800,
                                            color: sold
                                                ? cs.error
                                                : cs.primary,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Cat {
  const _Cat({required this.id, required this.name});
  final String id;
  final String name;

  factory _Cat.fromMap(Map<String, dynamic> m) => _Cat(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
      );
}

class _Item {
  const _Item({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.description,
    required this.available,
  });

  final String id;
  final String categoryId;
  final String name;
  final String description;
  final bool available;

  _Item copyWith({bool? available}) => _Item(
        id: id,
        categoryId: categoryId,
        name: name,
        description: description,
        available: available ?? this.available,
      );

  factory _Item.fromMap(Map<String, dynamic> m) => _Item(
        id: m['id'] as String,
        categoryId: m['category_id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        description: m['description'] as String? ?? '',
        available: m['available'] as bool? ?? true,
      );
}
