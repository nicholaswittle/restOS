import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ordering_models.dart';

/// Cart + checkout. Customer name/phone only — no auth.
class CartScreen extends StatefulWidget {
  const CartScreen({
    super.key,
    required this.restaurantId,
    required this.organizationId,
    required this.restaurantName,
    required this.settings,
    required this.cart,
  });

  final String restaurantId;
  final String organizationId;
  final String restaurantName;
  final RestaurantSettingsData settings;
  final List<CartEntry> cart;

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _client = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  late List<CartEntry> _cart;
  late int _pickupMinutes;
  bool _placing = false;

  @override
  void initState() {
    super.initState();
    _cart = widget.cart;
    _pickupMinutes = widget.settings.prepMinutes;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  int get _subtotal => _cart.fold(0, (s, e) => s + e.lineTotalCents);
  int get _fee => widget.settings.feeCents;
  int get _tax => widget.settings.taxCents(_subtotal);
  int get _total => widget.settings.totalCents(_subtotal);

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  void _bump(CartEntry entry, int delta) {
    setState(() {
      entry.quantity += delta;
      if (entry.quantity <= 0) {
        _cart.removeWhere((e) => e.lineKey == entry.lineKey);
      }
    });
  }

  Future<void> _placeOrder() async {
    if (_placing) return;
    if (_cart.isEmpty) {
      _snack('Your cart is empty.');
      return;
    }
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    if (name.isEmpty || phone.isEmpty) {
      _snack('Name and phone are required.');
      return;
    }
    if (widget.settings.paused) {
      _snack('Ordering is temporarily unavailable.');
      return;
    }

    setState(() => _placing = true);
    try {
      // Client-generated so the confirmation screen never needs a SELECT as anon.
      final token = _shortToken();
      final orderId = await _insertOrder(token);
      for (final line in _cart) {
        final itemId = await _insertLine(orderId, line);
        for (final mod in line.modifiers) {
          await _client.from('order_item_modifiers').insert({
            'order_item_id': itemId,
            'organization_id': widget.organizationId,
            'modifier_option_id': mod.optionId,
            'name': mod.name,
            'price_delta_cents': mod.priceDeltaCents,
          });
        }
      }

      if (!mounted) return;
      setState(() {
        _cart.clear();
        _placing = false;
      });
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Order placed'),
          content: Text(
            'Show this code at pickup:\n\n$token\n\n'
            'Ready in about $_pickupMinutes minutes.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: token));
                Navigator.pop(ctx);
              },
              child: const Text('Copy code'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      _snack('Order $token submitted');
      Navigator.of(context).pop(_cart);
    } catch (e) {
      if (!mounted) return;
      setState(() => _placing = false);
      _snack('Could not place order. Try again.');
    }
  }

  Future<String> _insertOrder(String token) async {
    final orderId = newUuid();
    await _client.from('online_orders').insert({
      'id': orderId,
      'restaurant_id': widget.restaurantId,
      'organization_id': widget.organizationId,
      'public_token': token,
      'status': 'waiting',
      'pickup_minutes': _pickupMinutes,
      'customer_json': {
        'name': _nameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
      },
      'notes': _notesCtrl.text.trim(),
      'subtotal_cents': _subtotal,
      'fee_cents': _fee,
      'tax_cents': _tax,
      'total_cents': _total,
      'payment_mode': widget.settings.paymentMode,
      'payment_status': 'pending',
    });
    return orderId;
  }

  Future<String> _insertLine(String orderId, CartEntry line) async {
    final delta =
        line.modifiers.fold<int>(0, (s, m) => s + m.priceDeltaCents);
    final itemId = newUuid();
    await _client.from('order_items').insert({
      'id': itemId,
      'order_id': orderId,
      'organization_id': widget.organizationId,
      'menu_item_id': line.menuItemId,
      'name': line.name,
      'price_cents': line.unitPriceCents + delta,
      'quantity': line.quantity,
      'notes':
          line.modifiers.map((m) => '${m.groupName}: ${m.name}').join('; '),
    });
    return itemId;
  }

  /// Short readable pickup code — unique enough for a busy dinner rush.
  String _shortToken() {
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase();
    return t.substring(t.length >= 6 ? t.length - 6 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_cart);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Your cart'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_cart),
          ),
        ),
        body: _cart.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.shopping_bag_outlined,
                      size: 48, color: cs.onSurface.withValues(alpha: 0.4)),
                  const SizedBox(height: 12),
                  Text('Cart is empty',
                      style: Theme.of(context).textTheme.titleMedium),
                ]),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                children: [
                  for (final line in _cart)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Material(
                        color: cs.surfaceContainer,
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(line.name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    if (line.modifiers.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        line.modifiers
                                            .map((m) => m.name)
                                            .join(' · '),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: cs.onSurface
                                                  .withValues(alpha: 0.6),
                                            ),
                                      ),
                                    ],
                                    const SizedBox(height: 6),
                                    Text(formatCents(line.lineTotalCents),
                                        style: TextStyle(color: cs.primary)),
                                  ],
                                ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: () => _bump(line, -1),
                                    icon: const Icon(Icons.remove_circle_outline),
                                  ),
                                  Text('${line.quantity}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  IconButton(
                                    onPressed: () => _bump(line, 1),
                                    icon: const Icon(Icons.add_circle_outline),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text('Pickup', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final m in [
                        widget.settings.prepMinutes,
                        widget.settings.prepMinutes + 15,
                        widget.settings.prepMinutes + 30,
                      ])
                        ChoiceChip(
                          label: Text('$m min'),
                          selected: _pickupMinutes == m,
                          onSelected: (_) =>
                              setState(() => _pickupMinutes = m),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Your info',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _notesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _TotalsCard(
                    subtotal: _subtotal,
                    fee: _fee,
                    tax: _tax,
                    total: _total,
                  ),
                ],
              ),
        bottomNavigationBar: _cart.isEmpty
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton(
                    onPressed: _placing ? null : _placeOrder,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        _placing
                            ? 'Placing…'
                            : 'Place order · ${formatCents(_total)}',
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({
    required this.subtotal,
    required this.fee,
    required this.tax,
    required this.total,
  });

  final int subtotal;
  final int fee;
  final int tax;
  final int total;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget row(String label, int cents, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: bold
                      ? Theme.of(context).textTheme.titleMedium
                      : Theme.of(context).textTheme.bodyLarge),
              Text(formatCents(cents),
                  style: bold
                      ? Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: cs.primary)
                      : null),
            ],
          ),
        );

    return Material(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            row('Subtotal', subtotal),
            row('Fee', fee),
            row('Tax', tax),
            const Divider(height: 20),
            row('Total', total, bold: true),
          ],
        ),
      ),
    );
  }
}
