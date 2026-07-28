import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/demo_backend.dart';
import '../../core/shift_time.dart';

/// Org-wide team chat — replaces the group text for the venue.
class TeamChatScreen extends StatefulWidget {
  const TeamChatScreen({super.key, required this.organizationId});

  final String organizationId;

  @override
  State<TeamChatScreen> createState() => _TeamChatScreenState();
}

class _TeamChatScreenState extends State<TeamChatScreen> {
  final _client = Supabase.instance.client;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  bool _loading = true;
  String? _error;
  bool _sending = false;
  List<_ChatMessage> _messages = const [];

  final _subs = <StreamSubscription<dynamic>>[];

  String get _userId => DemoMode.enabled
      ? DemoMode.userId
      : (_client.auth.currentUser?.id ?? '');

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
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    _subs.add(
      _client
          .from('messages')
          .stream(primaryKey: ['id'])
          .eq('organization_id', widget.organizationId)
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
      final rows = await _client
          .from('messages')
          .select(
            'id, organization_id, user_id, text, pinned, system_generated, created_at, profiles(name)',
          )
          .eq('organization_id', widget.organizationId)
          .order('created_at', ascending: true)
          .limit(100);

      if (!mounted) return;
      setState(() {
        _messages = (rows as List)
            .cast<Map<String, dynamic>>()
            .map(_ChatMessage.fromMap)
            .toList();
        _loading = false;
        _error = null;
      });
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load chat. Pull to retry.';
      });
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;

    setState(() => _sending = true);
    try {
      await _client.from('messages').insert({
        'organization_id': widget.organizationId,
        'user_id': _userId,
        'text': text,
      });
      if (!mounted) return;
      _input.clear();
      setState(() => _sending = false);
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not send. Try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: _LoadingView());
    if (_error != null) {
      return Scaffold(body: _ErrorView(message: _error!, onRetry: _load));
    }

    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
            child: Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Expanded(
                child: Text('Team chat',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
            ]),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(),
            color: cs.primary,
            child: _messages.isEmpty
                ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
                    const SizedBox(height: 80),
                    Center(
                      child: Text(
                        'No messages yet. Say hey to the crew.',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                      ),
                    ),
                  ])
                : ListView.builder(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final m = _messages[i];
                      final mine = m.userId == _userId;
                      return _Bubble(message: m, mine: mine);
                    },
                  ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !_sending,
                  textCapitalization: TextCapitalization.sentences,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: 'Message the crew…',
                    filled: true,
                    fillColor: cs.surfaceContainer,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _ChatMessage {
  const _ChatMessage({
    required this.id,
    required this.userId,
    required this.senderName,
    required this.text,
    required this.createdAt,
    required this.pinned,
    required this.systemGenerated,
  });

  final String id;
  final String userId;
  final String senderName;
  final String text;
  final DateTime createdAt;
  final bool pinned;
  final bool systemGenerated;

  factory _ChatMessage.fromMap(Map<String, dynamic> m) => _ChatMessage(
        id: m['id'] as String? ?? '',
        userId: m['user_id'] as String? ?? '',
        senderName: (m['profiles'] as Map?)?['name'] as String? ?? 'Teammate',
        text: m['text'] as String? ?? '',
        createdAt:
            DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
        pinned: m['pinned'] as bool? ?? false,
        systemGenerated: m['system_generated'] as bool? ?? false,
      );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});

  final _ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: mine ? cs.primaryContainer : cs.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: message.pinned
                  ? Border.all(color: cs.primary.withValues(alpha: 0.5))
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!mine || message.pinned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      message.pinned
                          ? '📌 ${message.senderName}'
                          : message.senderName,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: cs.primary,
                          ),
                    ),
                  ),
                Text(
                  message.text,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: mine ? cs.onPrimaryContainer : null,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  relativeTime(message.createdAt),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: (mine ? cs.onPrimaryContainer : cs.onSurface)
                            .withValues(alpha: 0.45),
                      ),
                ),
              ],
            ),
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Container(
            height: 34,
            width: 140,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ]),
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
              size: 48, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
            onPressed: onRetry,
          ),
        ]),
      ),
    );
  }
}
