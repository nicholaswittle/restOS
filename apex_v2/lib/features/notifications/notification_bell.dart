import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/notification_service.dart';
import 'notification_prefs_screen.dart';

/// Dashboard bell — unread count + sheet of recent alerts (Apex v1 pattern).
class NotificationBell extends StatefulWidget {
  const NotificationBell({
    super.key,
    required this.organizationId,
  });

  final String organizationId;

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  int _unread = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Lightweight poll — avoids a second realtime subscription on every load.
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final count = await NotificationService.unreadCount();
      if (mounted) setState(() => _unread = count);
    } catch (_) {}
  }

  Future<void> _open() async {
    final rows = await NotificationService.recent();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * 0.55,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text('Alerts',
                          style: Theme.of(ctx).textTheme.titleLarge),
                    ),
                    TextButton(
                      onPressed: () async {
                        await NotificationService.markAllRead();
                        if (ctx.mounted) Navigator.pop(ctx);
                        await _refresh();
                      },
                      child: const Text('Mark all read'),
                    ),
                    IconButton(
                      tooltip: 'Notification settings',
                      onPressed: () {
                        Navigator.pop(ctx);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => NotificationPrefsScreen(
                              organizationId: widget.organizationId,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.tune_rounded),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Expanded(
                    child: rows.isEmpty
                        ? Center(
                            child: Text(
                              'No alerts yet.',
                              style: Theme.of(ctx)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(
                                    color:
                                        cs.onSurface.withValues(alpha: 0.55),
                                  ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: rows.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final n = rows[i];
                              final unread = n['read_at'] == null;
                              return Card(
                                color: unread
                                    ? cs.primaryContainer.withValues(alpha: 0.35)
                                    : null,
                                child: ListTile(
                                  title: Text(n['title'] as String? ?? ''),
                                  subtitle: Text(n['body'] as String? ?? ''),
                                  isThreeLine: true,
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Notifications',
      onPressed: _open,
      icon: Badge(
        isLabelVisible: _unread > 0,
        label: Text(_unread > 9 ? '9+' : '$_unread'),
        child: const Icon(Icons.notifications_outlined),
      ),
    );
  }
}
